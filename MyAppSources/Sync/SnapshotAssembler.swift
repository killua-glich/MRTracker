//
//  SnapshotAssembler.swift
//  MyApp
//
//  MRT-024: orchestrates list → detail + approvals into one `MergeRequestSnapshot` per MR.
//  Pure fetch-and-merge — no polling loop (MRT-040), no store writes (MRT-030), no UI.
//
//  Flow:
//  1. Authored + reviewer lists fetched concurrently (`async let`). The reviewer list needs
//     the current username; if the caller didn't pass one, `GET /user` runs first (only on
//     the reviewer branch — the authored list doesn't wait for it).
//  2. Duplicates (same MR in both lists) merged by `(projectId, iid)`, roles unioned.
//  3. Per MR, detail + approvals fetched concurrently (`async let`); across MRs a sliding
//     window task group keeps at most `maxConcurrentMergeRequests` MRs in flight
//     (PLAN.md → Risks: unknown instance rate limits) — i.e. at most 2× that many HTTP
//     requests at once.
//  4. Output sorted by `MergeRequestUrgency` (Shared/MergeRequestUrgency.swift).
//
//  Error policy (see `GitLabAPIError.isBatchFatal`):
//  - A list (or `/user`) failure throws — nothing trustworthy to show. The poller records
//    it via the store and keeps the last good snapshot.
//  - A batch-fatal error on any detail/approvals call (401, 403, 429, connectivity/TLS
//    transport failure, cancellation) cancels the remaining fan-out and throws that error. These
//    affect every request against the instance, so continuing would just send N more
//    doomed requests (and, for 429, make the rate limiting worse).
//  - Any other per-MR error (404, 5xx, decoding, timeout, ...) does NOT abort the
//    batch: the MR is still emitted, with the failed endpoint's fields taken from
//    `previous` (last good snapshot of that MR) when available, else left unknown — and
//    the failure is reported in `AssemblyResult.failures`.
//

import Foundation

// MARK: - Client seam

/// The four `GitLabClient` endpoints the assembler composes. Exists so tests can inject a
/// fake that instruments concurrency (in-flight counts, delays); `GitLabClient` conforms
/// as-is with no changes to it.
nonisolated protocol GitLabFetching: Sendable {
    func currentUser() async throws(GitLabAPIError) -> GitLabUser
    func openMergeRequests(scope: GitLabClient.MRScope) async throws(GitLabAPIError) -> [MergeRequestListItem]
    func mergeRequestDetail(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestDetail
    func approvals(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestApprovals
}

nonisolated extension GitLabClient: GitLabFetching {}

// MARK: - Result types

/// One MR whose detail and/or approvals call failed with a non-batch-fatal error. The MR
/// is still present in `AssemblyResult.snapshots` (built with fallback values).
nonisolated struct MergeRequestFetchFailure: Sendable, Equatable {
    /// `MergeRequestSnapshot.id` of the affected MR.
    let id: String
    let projectId: Int
    let iid: Int
    /// `nil` when the detail call succeeded.
    let detailError: GitLabAPIError?
    /// `nil` when the approvals call succeeded.
    let approvalsError: GitLabAPIError?
    /// `true` when the failed endpoint's fields were filled from the `previous` snapshot;
    /// `false` when no previous snapshot of this MR existed and they were left unknown.
    let usedPreviousValues: Bool
}

nonisolated struct AssemblyResult: Sendable, Equatable {
    /// One entry per open MR (deduplicated), sorted by urgency.
    let snapshots: [MergeRequestSnapshot]
    /// Per-MR partial failures; empty on a fully clean fetch.
    let failures: [MergeRequestFetchFailure]
    /// The username used for the reviewer query (fetched via `GET /user` when not passed
    /// in) — so the caller can cache it and skip that request on the next poll. `nil` when
    /// the reviewer role isn't tracked.
    let username: String?
}

// MARK: - Assembler

nonisolated struct SnapshotAssembler: Sendable {

    static let defaultMaxConcurrentMergeRequests = 4

    private let client: any GitLabFetching
    /// Max MRs whose detail + approvals are in flight at once (each MR = 2 requests).
    let maxConcurrentMergeRequests: Int

    init(client: any GitLabFetching, maxConcurrentMergeRequests: Int = Self.defaultMaxConcurrentMergeRequests) {
        self.client = client
        self.maxConcurrentMergeRequests = max(1, maxConcurrentMergeRequests)
    }

    /// Fetches and assembles the full snapshot list.
    ///
    /// - Parameters:
    ///   - roles: which lists to fetch (MRT-012's author/reviewer filter). Empty → empty
    ///     result, no requests.
    ///   - username: current user's username for the reviewer query. Pass the cached value
    ///     (e.g. from MRT-011's token validation or a previous `AssemblyResult.username`)
    ///     to save a request; `nil` → fetched via `GET /user`. Ignored if `.reviewer` isn't
    ///     in `roles`.
    ///   - previous: last good snapshots, used as per-MR fallback when a detail/approvals
    ///     call fails non-fatally.
    func assemble(
        roles: Set<MRRole>,
        username: String? = nil,
        previous: [MergeRequestSnapshot] = []
    ) async throws(GitLabAPIError) -> AssemblyResult {
        guard !roles.isEmpty else {
            return AssemblyResult(snapshots: [], failures: [], username: nil)
        }

        let (items, resolvedUsername) = try await fetchLists(roles: roles, username: username)
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (snapshots, failures) = try await fetchDetails(for: items, previousByID: previousByID)

        return AssemblyResult(
            snapshots: snapshots.sortedByUrgency(),
            failures: failures.sorted { $0.id < $1.id },
            username: resolvedUsername
        )
    }

    // MARK: Lists

    /// A list item with every role it was found under.
    private struct TrackedItem: Sendable {
        let item: MergeRequestListItem
        var roles: Set<MRRole>
        var id: String { MergeRequestSnapshot.makeId(projectId: item.projectId, iid: item.iid) }
    }

    private func fetchLists(
        roles: Set<MRRole>,
        username: String?
    ) async throws(GitLabAPIError) -> (items: [TrackedItem], username: String?) {
        let client = self.client

        async let authoredResult: Result<[MergeRequestListItem], GitLabAPIError> = roles.contains(.author)
            ? Self.capture { () async throws(GitLabAPIError) in try await client.openMergeRequests(scope: .createdByMe) }
            : .success([])

        async let reviewerResult: Result<(items: [MergeRequestListItem], username: String?), GitLabAPIError> =
            roles.contains(.reviewer)
            ? Self.capture { () async throws(GitLabAPIError) in
                let name: String
                if let username {
                    name = username
                } else {
                    name = try await client.currentUser().username
                }
                return (try await client.openMergeRequests(scope: .reviewer(username: name)), name)
            }
            : .success(([], nil))

        let authored = try await authoredResult.get()
        let reviewer = try await reviewerResult.get()

        // Merge, preserving first-seen order (authored first). Order doesn't matter for
        // the output (sorted later) but keeps fan-out order predictable.
        var order: [String] = []
        var byID: [String: TrackedItem] = [:]
        let tagged = authored.map { ($0, MRRole.author) } + reviewer.items.map { ($0, MRRole.reviewer) }
        for (item, role) in tagged {
            let id = MergeRequestSnapshot.makeId(projectId: item.projectId, iid: item.iid)
            if byID[id] == nil {
                order.append(id)
                byID[id] = TrackedItem(item: item, roles: [role])
            } else {
                byID[id]?.roles.insert(role)
            }
        }
        return (order.compactMap { byID[$0] }, reviewer.username)
    }

    // MARK: Detail fan-out

    private enum MergeRequestOutcome: Sendable {
        case assembled(MergeRequestSnapshot, MergeRequestFetchFailure?)
        case fatal(GitLabAPIError)
    }

    private func fetchDetails(
        for items: [TrackedItem],
        previousByID: [String: MergeRequestSnapshot]
    ) async throws(GitLabAPIError) -> ([MergeRequestSnapshot], [MergeRequestFetchFailure]) {
        let client = self.client
        let limit = maxConcurrentMergeRequests

        let (snapshots, failures, fatal) = await withTaskGroup(
            of: MergeRequestOutcome.self,
            returning: ([MergeRequestSnapshot], [MergeRequestFetchFailure], GitLabAPIError?).self
        ) { group in
            var snapshots: [MergeRequestSnapshot] = []
            var failures: [MergeRequestFetchFailure] = []
            var fatal: GitLabAPIError?
            var iterator = items.makeIterator()

            func addNext() -> Bool {
                guard let tracked = iterator.next() else { return false }
                let previous = previousByID[tracked.id]
                group.addTask {
                    await Self.assembleOne(tracked, previous: previous, client: client)
                }
                return true
            }

            // Sliding window: prime `limit` tasks, then start one more per completion.
            for _ in 0..<limit where !addNext() { break }

            while let outcome = await group.next() {
                switch outcome {
                case .assembled(let snapshot, let failure):
                    snapshots.append(snapshot)
                    if let failure { failures.append(failure) }
                    if fatal == nil { _ = addNext() }
                case .fatal(let error):
                    // Keep the first fatal error; later ones are typically `.cancelled`
                    // echoes of the cancellation below.
                    if fatal == nil {
                        fatal = error
                        group.cancelAll()
                    }
                }
            }
            return (snapshots, failures, fatal)
        }

        if let fatal {
            throw fatal
        }
        if Task.isCancelled {
            throw .transport(.cancelled)
        }
        return (snapshots, failures)
    }

    private static func assembleOne(
        _ tracked: TrackedItem,
        previous: MergeRequestSnapshot?,
        client: any GitLabFetching
    ) async -> MergeRequestOutcome {
        let item = tracked.item
        async let detailResult = capture { () async throws(GitLabAPIError) in
            try await client.mergeRequestDetail(projectId: item.projectId, iid: item.iid)
        }
        async let approvalsResult = capture { () async throws(GitLabAPIError) in
            try await client.approvals(projectId: item.projectId, iid: item.iid)
        }
        let detail = await detailResult
        let approvals = await approvalsResult

        let detailError = detail.error
        let approvalsError = approvals.error
        if let fatal = [detailError, approvalsError].compactMap({ $0 }).first(where: \.isBatchFatal) {
            return .fatal(fatal)
        }

        let snapshot = makeSnapshot(
            item: item,
            roles: tracked.roles,
            detail: detail.value,
            approvals: approvals.value,
            previous: previous
        )
        let failure: MergeRequestFetchFailure? = (detailError == nil && approvalsError == nil)
            ? nil
            : MergeRequestFetchFailure(
                id: tracked.id,
                projectId: item.projectId,
                iid: item.iid,
                detailError: detailError,
                approvalsError: approvalsError,
                usedPreviousValues: previous != nil
            )
        return .assembled(snapshot, failure)
    }

    // MARK: Mapping

    /// List fields always come from the fresh list item. Detail/approvals fields come from
    /// the fresh response when that call succeeded; otherwise from `previous` (same MR's
    /// last good snapshot); otherwise "unknown": `nil` for optionals, and for the
    /// non-optional booleans the value that does NOT claim a good state
    /// (`approved = false`, `blockingDiscussionsResolved = false`, `hasConflicts = false`
    /// — the last one so an unknown MR isn't sorted as conflicting). `detailedMergeStatus`
    /// stays `nil`, so no "ready to merge" dot is ever shown on unknown data.
    static func makeSnapshot(
        item: MergeRequestListItem,
        roles: Set<MRRole>,
        detail: MergeRequestDetail?,
        approvals: MergeRequestApprovals?,
        previous: MergeRequestSnapshot?
    ) -> MergeRequestSnapshot {
        var snapshot = MergeRequestSnapshot(
            projectId: item.projectId,
            projectPath: item.projectPath,
            iid: item.iid,
            title: item.title,
            webURL: item.webURL,
            sourceBranch: item.sourceBranch,
            targetBranch: item.targetBranch,
            roles: roles,
            isDraft: detail?.isDraft ?? item.isDraft,
            pipelineStatus: nil,
            divergedCommitsCount: nil,
            approved: false,
            approvalsLeft: nil,
            approvedBy: [],
            detailedMergeStatus: nil,
            hasConflicts: false,
            blockingDiscussionsResolved: false,
            updatedAt: item.updatedAt
        )

        if let detail {
            snapshot.pipelineStatus = detail.pipelineStatus
            snapshot.divergedCommitsCount = detail.divergedCommitsCount
            snapshot.detailedMergeStatus = detail.detailedMergeStatus
            snapshot.hasConflicts = detail.hasConflicts
            snapshot.blockingDiscussionsResolved = detail.blockingDiscussionsResolved
        } else if let previous {
            snapshot.pipelineStatus = previous.pipelineStatus
            snapshot.divergedCommitsCount = previous.divergedCommitsCount
            snapshot.detailedMergeStatus = previous.detailedMergeStatus
            snapshot.hasConflicts = previous.hasConflicts
            snapshot.blockingDiscussionsResolved = previous.blockingDiscussionsResolved
        }

        if let approvals {
            snapshot.approved = approvals.approved
            snapshot.approvalsLeft = approvals.approvalsLeft
            snapshot.approvedBy = approvals.approvedBy
        } else if let previous {
            snapshot.approved = previous.approved
            snapshot.approvalsLeft = previous.approvalsLeft
            snapshot.approvedBy = previous.approvedBy
        }

        return snapshot
    }

    // MARK: Helpers

    /// Runs a typed-throwing operation and captures its outcome, so `async let` children
    /// never throw (an unawaited throwing `async let` would otherwise be implicitly
    /// cancelled + awaited, losing the sibling's result).
    private static func capture<T: Sendable>(
        _ operation: @Sendable () async throws(GitLabAPIError) -> T
    ) async -> Result<T, GitLabAPIError> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Error classification

nonisolated extension GitLabAPIError {
    /// `true` for errors that will almost certainly hit every other request against the
    /// same instance right now, so the assembler stops fanning out and throws instead of
    /// degrading per MR:
    /// - `.unauthorized` (token invalid/revoked/expired),
    /// - `.forbidden` (per MRT-024 spec: with a `read_api` token + Developer role every
    ///   endpoint used here should be readable, so a 403 most likely means the token lost
    ///   its scope or the account was blocked — it would repeat for every MR),
    /// - `.rateLimited` (GitLab told us to back off),
    /// - `.invalidURL` (base URL broken),
    /// - `.transport` with a connectivity/TLS/cancellation code (offline, VPN down, DNS,
    ///   untrusted corp cert, task cancelled).
    ///
    /// Deliberately NOT fatal: `.notFound` (MR deleted/moved between list and detail), `.server`,
    /// `.unexpectedStatus`, `.decoding`, and other transport codes such as `.timedOut`
    /// (one slow request isn't proof the instance is down).
    var isBatchFatal: Bool {
        switch self {
        case .unauthorized, .forbidden, .rateLimited, .invalidURL:
            return true
        case .transport(let code):
            return Self.batchFatalTransportCodes.contains(code)
        case .notFound, .server, .unexpectedStatus, .decoding:
            return false
        }
    }

    private static let batchFatalTransportCodes: Set<URLError.Code> = [
        .cancelled,
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .secureConnectionFailed,
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection,
    ]
}

private nonisolated extension Result {
    var value: Success? {
        if case .success(let value) = self { value } else { nil }
    }

    var error: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
