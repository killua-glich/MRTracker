//
//  SnapshotAssemblerTests.swift
//  MyAppTests
//
//  MRT-024: SnapshotAssembler (list → detail + approvals → [MergeRequestSnapshot]) and the
//  shared urgency sort (Shared/MergeRequestUrgency.swift).
//
//  Two kinds of client are used:
//  - the real `GitLabClient` over `MockURLProtocol` (end-to-end field mapping, list 401), and
//  - `FakeGitLab`, an in-memory `GitLabFetching` that can delay calls and instrument
//    in-flight counts (concurrency bound, fan-out short-circuit).
//

import Foundation
import Synchronization
import Testing
@testable import MyApp

// MARK: - Fake client

/// In-memory `GitLabFetching`. Configuration is immutable; call log + in-flight
/// instrumentation live behind a `Mutex`.
nonisolated final class FakeGitLab: GitLabFetching, Sendable {

    struct Config: Sendable {
        var username = "diego"
        var authored: Result<[MergeRequestListItem], GitLabAPIError> = .success([])
        var reviewer: Result<[MergeRequestListItem], GitLabAPIError> = .success([])
        /// Keyed by `MergeRequestSnapshot.id`; missing → `defaultDetail`.
        var details: [String: Result<MergeRequestDetail, GitLabAPIError>] = [:]
        var approvals: [String: Result<MergeRequestApprovals, GitLabAPIError>] = [:]
        var defaultDetail: MergeRequestDetail
        var defaultApprovals: MergeRequestApprovals
        /// Simulated latency per detail/approvals call; overridable per MR id.
        var delay: Duration = .zero
        var delays: [String: Duration] = [:]
    }

    struct Log: Sendable {
        var currentUserCalls = 0
        var listScopes: [GitLabClient.MRScope] = []
        var detailCalls: [String] = []
        var approvalsCalls: [String] = []
        var cancelledCalls = 0
        /// Requests in flight right now, per MR id.
        var inFlight: [String: Int] = [:]
        var maxInFlightRequests = 0
        var maxInFlightMergeRequests = 0
    }

    let config: Config
    private let state = Mutex(Log())

    init(_ config: Config) {
        self.config = config
    }

    var log: Log { state.withLock { $0 } }

    func currentUser() async throws(GitLabAPIError) -> GitLabUser {
        state.withLock { $0.currentUserCalls += 1 }
        return GitLabUser(id: 1, username: config.username, name: "Test User")
    }

    func openMergeRequests(scope: GitLabClient.MRScope) async throws(GitLabAPIError) -> [MergeRequestListItem] {
        state.withLock { $0.listScopes.append(scope) }
        switch scope {
        case .createdByMe: return try config.authored.get()
        case .reviewer: return try config.reviewer.get()
        }
    }

    func mergeRequestDetail(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestDetail {
        let id = MergeRequestSnapshot.makeId(projectId: projectId, iid: iid)
        state.withLock { $0.detailCalls.append(id) }
        try await simulateLatency(id)
        return try (config.details[id] ?? .success(config.defaultDetail)).get()
    }

    func approvals(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestApprovals {
        let id = MergeRequestSnapshot.makeId(projectId: projectId, iid: iid)
        state.withLock { $0.approvalsCalls.append(id) }
        try await simulateLatency(id)
        return try (config.approvals[id] ?? .success(config.defaultApprovals)).get()
    }

    private func simulateLatency(_ id: String) async throws(GitLabAPIError) {
        state.withLock { log in
            log.inFlight[id, default: 0] += 1
            log.maxInFlightRequests = max(log.maxInFlightRequests, log.inFlight.values.reduce(0, +))
            log.maxInFlightMergeRequests = max(log.maxInFlightMergeRequests, log.inFlight.count)
        }
        defer {
            state.withLock { log in
                log.inFlight[id, default: 0] -= 1
                if log.inFlight[id] == 0 { log.inFlight[id] = nil }
            }
        }
        let delay = config.delays[id] ?? config.delay
        guard delay > .zero else { return }
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Mirrors URLSession: a cancelled request fails with URLError.cancelled.
            state.withLock { $0.cancelledCalls += 1 }
            throw .transport(.cancelled)
        }
    }
}

// MARK: - Tests

@MainActor
struct SnapshotAssemblerTests {

    private let baseURL = URL(string: "https://gitlab.example.com")!

    // MARK: Model builders (decode through the real DTOs, so models match production)

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = GitLabDateDecoding.strategy
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func listItemJSON(projectId: Int, iid: Int, updatedAt: String) -> String {
        """
        {
          "id": \(projectId * 1000 + iid), "iid": \(iid), "project_id": \(projectId),
          "title": "MR \(iid)",
          "web_url": "https://gitlab.example.com/group/p\(projectId)/-/merge_requests/\(iid)",
          "source_branch": "feature/\(iid)", "target_branch": "main",
          "draft": false, "updated_at": "\(updatedAt)",
          "references": {"full": "group/p\(projectId)!\(iid)"}
        }
        """
    }

    private static func listItem(
        projectId: Int = 42,
        iid: Int,
        updatedAt: String = "2026-10-13T09:00:00Z"
    ) -> MergeRequestListItem {
        MergeRequestListItem(dto: decode(
            MergeRequestListItemDTO.self,
            listItemJSON(projectId: projectId, iid: iid, updatedAt: updatedAt)
        ))
    }

    private static func detail(_ json: String) -> MergeRequestDetail {
        MergeRequestDetail(dto: decode(MergeRequestDetailDTO.self, json))
    }

    private static func approvals(_ json: String) -> MergeRequestApprovals {
        MergeRequestApprovals(dto: decode(MergeRequestApprovalsDTO.self, json))
    }

    private static func config(
        authored: [MergeRequestListItem] = [],
        reviewer: [MergeRequestListItem] = []
    ) -> FakeGitLab.Config {
        FakeGitLab.Config(
            authored: .success(authored),
            reviewer: .success(reviewer),
            defaultDetail: detail(GitLabFixtures.detailNoPipelineYet),
            defaultApprovals: approvals(GitLabFixtures.approvalsZeroRequired)
        )
    }

    // MARK: Lists + dedupe

    @Test func mixedAuthoredAndReviewerMergesDuplicateAndUnionsRoles() async throws {
        let a = Self.listItem(iid: 1)
        let b = Self.listItem(iid: 2)
        let c = Self.listItem(projectId: 7, iid: 2) // same iid, other project → distinct MR
        let fake = FakeGitLab(Self.config(authored: [a, b], reviewer: [b, c]))

        let result = try await SnapshotAssembler(client: fake)
            .assemble(roles: [.author, .reviewer], username: "diego")

        #expect(result.snapshots.count == 3)
        #expect(Set(result.snapshots.map(\.id)) == ["42-1", "42-2", "7-2"])
        let byID = Dictionary(uniqueKeysWithValues: result.snapshots.map { ($0.id, $0) })
        #expect(byID["42-1"]?.roles == [.author])
        #expect(byID["42-2"]?.roles == [.author, .reviewer])
        #expect(byID["7-2"]?.roles == [.reviewer])
        #expect(result.failures.isEmpty)
        #expect(result.username == "diego")

        let log = fake.log
        #expect(log.currentUserCalls == 0) // username supplied → no GET /user
        #expect(log.listScopes.count == 2)
        #expect(log.listScopes.contains(.reviewer(username: "diego")))
        // Duplicate fetched once, not twice.
        #expect(log.detailCalls.sorted() == ["42-1", "42-2", "7-2"])
        #expect(log.approvalsCalls.sorted() == ["42-1", "42-2", "7-2"])
    }

    @Test func authorOnlyFilterSkipsReviewerListAndUserLookup() async throws {
        let fake = FakeGitLab(Self.config(authored: [Self.listItem(iid: 1)], reviewer: [Self.listItem(iid: 2)]))

        let result = try await SnapshotAssembler(client: fake).assemble(roles: [.author])

        #expect(result.snapshots.map(\.id) == ["42-1"])
        #expect(result.username == nil)
        #expect(fake.log.listScopes == [.createdByMe])
        #expect(fake.log.currentUserCalls == 0)
    }

    @Test func emptyRoleFilterMakesNoRequests() async throws {
        let fake = FakeGitLab(Self.config(authored: [Self.listItem(iid: 1)]))

        let result = try await SnapshotAssembler(client: fake).assemble(roles: [])

        #expect(result.snapshots.isEmpty)
        #expect(fake.log.listScopes.isEmpty)
        #expect(fake.log.detailCalls.isEmpty)
    }

    // MARK: End-to-end field mapping (real GitLabClient + MockURLProtocol)

    @Test func completeFieldMappingEndToEnd() async throws {
        let (session, controller) = URLSession.mock()
        let client = GitLabClient(baseURL: baseURL, token: "glpat-test", session: session)

        controller.stub(path: "/api/v4/user", body: Data(GitLabFixtures.user.utf8))
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["scope": "created_by_me"],
            body: Data(GitLabFixtures.listPage1.utf8) // 42!3
        )
        let reviewerList = "[\(Self.trimArray(GitLabFixtures.listPage1)), \(Self.trimArray(GitLabFixtures.listPage2))]"
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["scope": "all", "reviewer_username": "diego"],
            body: Data(reviewerList.utf8) // 42!3 (again) + 42!4
        )
        controller.stub(path: "/api/v4/projects/42/merge_requests/3", body: Data(GitLabFixtures.detailConflicting.utf8))
        controller.stub(path: "/api/v4/projects/42/merge_requests/3/approvals", body: Data(GitLabFixtures.approvalsPending.utf8))
        controller.stub(path: "/api/v4/projects/42/merge_requests/4", body: Data(GitLabFixtures.detailMergeStatusFallback.utf8))
        controller.stub(path: "/api/v4/projects/42/merge_requests/4/approvals", body: Data(GitLabFixtures.approvalsZeroRequired.utf8))

        // No username passed → resolved via GET /user.
        let result = try await SnapshotAssembler(client: client).assemble(roles: [.author, .reviewer])

        #expect(result.username == "diego")
        #expect(result.failures.isEmpty)
        // 42-3 has a failed pipeline → sorted first; 42-4 is 1 behind.
        try #require(result.snapshots.map(\.id) == ["42-3", "42-4"])

        let mr3 = result.snapshots[0]
        var expected3 = MergeRequestSnapshot(
            projectId: 42,
            projectPath: "group/backend-api",
            iid: 3,
            title: "Add retry logic to poller",
            webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/3")!,
            sourceBranch: "feature/retry-logic",
            targetBranch: "main",
            roles: [.author, .reviewer],
            isDraft: false,
            pipelineStatus: .failed,
            divergedCommitsCount: 5,
            approved: false,
            approvalsLeft: 2,
            approvedBy: ["alice", "bob"],
            detailedMergeStatus: "conflict",
            hasConflicts: true,
            blockingDiscussionsResolved: false,
            updatedAt: mr3.updatedAt
        )
        #expect(mr3 == expected3)
        let expectedDate = try Date("2026-10-13T10:22:31.123Z", strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        #expect(abs(mr3.updatedAt.timeIntervalSince(expectedDate)) < 0.001)

        let mr4 = result.snapshots[1]
        expected3 = MergeRequestSnapshot(
            projectId: 42,
            projectPath: "group/backend-api",
            iid: 4,
            title: "Second MR",
            webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/4")!,
            sourceBranch: "feature/second",
            targetBranch: "main",
            roles: [.reviewer],
            isDraft: false,
            pipelineStatus: .success,
            divergedCommitsCount: 1,
            approved: true,
            approvalsLeft: 0,
            approvedBy: [],
            detailedMergeStatus: "can_be_merged",
            hasConflicts: false,
            blockingDiscussionsResolved: true,
            updatedAt: Date(timeIntervalSince1970: 1_791_889_200) // 2026-10-13T11:00:00Z
        )
        #expect(mr4 == expected3)

        // 1 user + 2 lists + 2×(detail + approvals); the duplicate isn't fetched twice.
        let paths = controller.recordedRequests.compactMap { $0.url?.path }
        #expect(paths.count == 7)
        #expect(paths.filter { $0 == "/api/v4/projects/42/merge_requests/3" }.count == 1)
    }

    /// `"[\n  {...}\n]"` → `"{...}"`, so two fixture pages can be joined into one array.
    private static func trimArray(_ json: String) -> String {
        var s = json.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeFirst()
        s.removeLast()
        return s
    }

    @Test func listUnauthorizedThrows() async {
        let (session, controller) = URLSession.mock()
        let client = GitLabClient(baseURL: baseURL, token: "glpat-revoked", session: session)
        controller.stub(path: "/api/v4/merge_requests", queryContains: ["scope": "created_by_me"], status: 401)
        controller.stub(path: "/api/v4/merge_requests", queryContains: ["scope": "all"], body: Data(GitLabFixtures.listPage1.utf8))

        await #expect(throws: GitLabAPIError.unauthorized) {
            try await SnapshotAssembler(client: client).assemble(roles: [.author, .reviewer], username: "diego")
        }
        // No detail/approvals fan-out after a list failure.
        let paths = controller.recordedRequests.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.hasPrefix("/api/v4/projects/") })
    }

    // MARK: Partial failure

    @Test func approvalsServerErrorReusesPreviousValuesAndReportsFailure() async throws {
        let items = (1...3).map { Self.listItem(iid: $0) }
        var config = Self.config(authored: items)
        config.approvals["42-2"] = .failure(.server(status: 500))
        let fake = FakeGitLab(config)

        let previous2 = MergeRequestSnapshot(
            projectId: 42, projectPath: "group/p42", iid: 2, title: "Old title",
            webURL: URL(string: "https://gitlab.example.com/group/p42/-/merge_requests/2")!,
            sourceBranch: "feature/2", targetBranch: "main", roles: [.author], isDraft: true,
            pipelineStatus: .running, divergedCommitsCount: 9,
            approved: true, approvalsLeft: 0, approvedBy: ["carol"],
            detailedMergeStatus: "need_rebase", hasConflicts: true, blockingDiscussionsResolved: false,
            updatedAt: .distantPast
        )

        let result = try await SnapshotAssembler(client: fake)
            .assemble(roles: [.author], previous: [previous2])

        #expect(result.snapshots.count == 3)
        #expect(result.failures == [
            MergeRequestFetchFailure(
                id: "42-2", projectId: 42, iid: 2,
                detailError: nil, approvalsError: .server(status: 500),
                usedPreviousValues: true
            ),
        ])

        let byID = Dictionary(uniqueKeysWithValues: result.snapshots.map { ($0.id, $0) })
        let mr2 = try #require(byID["42-2"])
        // Approval fields from `previous`…
        #expect(mr2.approved == true)
        #expect(mr2.approvalsLeft == 0)
        #expect(mr2.approvedBy == ["carol"])
        // …but list + detail fields are fresh (detail call succeeded).
        #expect(mr2.title == "MR 2")
        #expect(mr2.isDraft == false)
        #expect(mr2.pipelineStatus == nil)
        #expect(mr2.divergedCommitsCount == 0)
        #expect(mr2.detailedMergeStatus == "mergeable")
        #expect(mr2.hasConflicts == false)

        // Others complete with fresh data.
        for id in ["42-1", "42-3"] {
            #expect(byID[id]?.approved == true)
            #expect(byID[id]?.detailedMergeStatus == "mergeable")
        }
    }

    @Test func detailFailureWithoutPreviousLeavesFieldsUnknown() async throws {
        var config = Self.config(authored: [Self.listItem(iid: 1), Self.listItem(iid: 2)])
        config.details["42-1"] = .failure(.notFound)
        config.approvals["42-1"] = .failure(.transport(.timedOut))
        let fake = FakeGitLab(config)

        let result = try await SnapshotAssembler(client: fake).assemble(roles: [.author])

        #expect(result.failures.map(\.id) == ["42-1"])
        #expect(result.failures.first?.detailError == .notFound)
        #expect(result.failures.first?.approvalsError == .transport(.timedOut))
        #expect(result.failures.first?.usedPreviousValues == false)

        let mr1 = try #require(result.snapshots.first { $0.id == "42-1" })
        #expect(mr1.pipelineStatus == nil)
        #expect(mr1.divergedCommitsCount == nil)
        #expect(mr1.detailedMergeStatus == nil) // never "mergeable" on unknown data
        #expect(mr1.isMergeable == false)
        #expect(mr1.approved == false)          // documented default: not claimed approved
        #expect(mr1.approvalsLeft == nil)
        #expect(mr1.approvedBy.isEmpty)
        #expect(mr1.hasConflicts == false)
        #expect(mr1.title == "MR 1")            // list fields still fresh
        #expect(result.snapshots.contains { $0.id == "42-2" && $0.approved })
    }

    // MARK: Bounded concurrency

    @Test func concurrencyBoundIsRespected() async throws {
        let items = (1...12).map { Self.listItem(iid: $0) }
        var config = Self.config(authored: items)
        config.delay = .milliseconds(20)
        let fake = FakeGitLab(config)

        let result = try await SnapshotAssembler(client: fake, maxConcurrentMergeRequests: 3)
            .assemble(roles: [.author])

        #expect(result.snapshots.count == 12)
        let log = fake.log
        #expect(log.maxInFlightMergeRequests <= 3)
        #expect(log.maxInFlightMergeRequests >= 2) // actually concurrent, not serialized
        #expect(log.maxInFlightRequests <= 6)      // ≤ 2 requests (detail + approvals) per MR
        #expect(log.detailCalls.count == 12)
        #expect(log.approvalsCalls.count == 12)
    }

    @Test func defaultConcurrencyBoundAndClampToOne() async throws {
        #expect(SnapshotAssembler(client: FakeGitLab(Self.config())).maxConcurrentMergeRequests == 4)
        #expect(SnapshotAssembler(client: FakeGitLab(Self.config()), maxConcurrentMergeRequests: 0).maxConcurrentMergeRequests == 1)

        var config = Self.config(authored: (1...5).map { Self.listItem(iid: $0) })
        config.delay = .milliseconds(5)
        let fake = FakeGitLab(config)
        _ = try await SnapshotAssembler(client: fake, maxConcurrentMergeRequests: 1).assemble(roles: [.author])
        #expect(fake.log.maxInFlightMergeRequests == 1)
    }

    // MARK: Fatal short-circuit

    @Test(arguments: [
        GitLabAPIError.rateLimited(retryAfter: 30),
        .unauthorized,
        .forbidden,
        .transport(.serverCertificateUntrusted),
    ])
    func fatalDetailErrorStopsFanOut(error: GitLabAPIError) async {
        let items = (1...10).map { Self.listItem(iid: $0) }
        var config = Self.config(authored: items)
        config.delay = .seconds(5) // everyone else is slow; must be cancelled, not awaited
        config.delays["42-1"] = .zero
        config.details["42-1"] = .failure(error)
        let fake = FakeGitLab(config)

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: error) {
            try await SnapshotAssembler(client: fake, maxConcurrentMergeRequests: 2).assemble(roles: [.author])
        }
        let elapsed = clock.now - start

        let log = fake.log
        // Only the primed window was ever started — no further MRs after the fatal error.
        #expect(log.detailCalls.count <= 2)
        #expect(log.detailCalls.contains("42-1"))
        #expect(!log.detailCalls.contains("42-3"))
        // The in-flight MR was cancelled rather than waited out.
        #expect(log.cancelledCalls >= 1)
        #expect(elapsed < .seconds(4))
    }

    @Test func nonFatalTransportErrorDoesNotStopFanOut() async throws {
        var config = Self.config(authored: (1...6).map { Self.listItem(iid: $0) })
        config.details["42-1"] = .failure(.transport(.timedOut))
        let fake = FakeGitLab(config)

        let result = try await SnapshotAssembler(client: fake, maxConcurrentMergeRequests: 2).assemble(roles: [.author])

        #expect(result.snapshots.count == 6)
        #expect(result.failures.map(\.id) == ["42-1"])
        #expect(fake.log.detailCalls.count == 6)
    }

    @Test func outputIsSortedByUrgency() async throws {
        let items = [
            Self.listItem(iid: 1, updatedAt: "2026-10-13T12:00:00Z"), // healthy, newest
            Self.listItem(iid: 2, updatedAt: "2026-10-13T08:00:00Z"), // failed pipeline
            Self.listItem(iid: 3, updatedAt: "2026-10-13T09:00:00Z"), // behind
        ]
        var config = Self.config(authored: items)
        config.details["42-2"] = .success(Self.detail(GitLabFixtures.detailConflicting))
        config.details["42-3"] = .success(Self.detail(GitLabFixtures.detailMergeStatusFallback))
        let fake = FakeGitLab(config)

        let result = try await SnapshotAssembler(client: fake).assemble(roles: [.author])

        #expect(result.snapshots.map(\.id) == ["42-2", "42-3", "42-1"])
    }
}

// MARK: - Urgency sort (Shared/MergeRequestUrgency.swift)

struct MergeRequestUrgencyTests {

    private static func mr(
        iid: Int,
        projectId: Int = 42,
        pipeline: PipelineStatus? = .success,
        diverged: Int? = 0,
        hasConflicts: Bool = false,
        mergeStatus: String? = "mergeable",
        updatedAt: TimeInterval = 0
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: projectId, projectPath: "group/p", iid: iid, title: "MR \(iid)",
            webURL: URL(string: "https://gitlab.example.com/group/p/-/merge_requests/\(iid)")!,
            sourceBranch: "f", targetBranch: "main", roles: [.author], isDraft: false,
            pipelineStatus: pipeline, divergedCommitsCount: diverged,
            approved: false, approvalsLeft: nil, approvedBy: [],
            detailedMergeStatus: mergeStatus, hasConflicts: hasConflicts,
            blockingDiscussionsResolved: true,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @Test func bucketsPickMostUrgentReason() {
        #expect(Self.mr(iid: 1, pipeline: .failed, diverged: 3, hasConflicts: true).urgency == .failedPipeline)
        #expect(Self.mr(iid: 1, diverged: 3, hasConflicts: true).urgency == .conflicts)
        #expect(Self.mr(iid: 1, mergeStatus: "conflict").urgency == .conflicts)
        #expect(Self.mr(iid: 1, diverged: 2).urgency == .behind)
        #expect(Self.mr(iid: 1).urgency == .healthy)
        // Unknown data isn't treated as a problem.
        #expect(Self.mr(iid: 1, pipeline: nil, diverged: nil, mergeStatus: nil).urgency == .healthy)
        #expect(Self.mr(iid: 1, pipeline: .running).urgency == .healthy)
        #expect(Self.mr(iid: 1, pipeline: .canceled).urgency == .healthy)
    }

    @Test func sortsByBucketThenUpdatedAtDescThenID() {
        let input = [
            Self.mr(iid: 1, updatedAt: 500),                         // healthy
            Self.mr(iid: 2, diverged: 4, updatedAt: 100),            // behind, older
            Self.mr(iid: 3, hasConflicts: true, updatedAt: 50),      // conflicts
            Self.mr(iid: 4, pipeline: .failed, updatedAt: 10),       // failed, older
            Self.mr(iid: 5, diverged: 1, updatedAt: 300),            // behind, newer
            Self.mr(iid: 6, pipeline: .failed, updatedAt: 20),       // failed, newer
            Self.mr(iid: 7, updatedAt: 500),                         // healthy, same time as 1
            Self.mr(iid: 1, projectId: 10, updatedAt: 500),          // healthy, same time; id "10-1"
        ]

        let sorted = input.sortedByUrgency()

        #expect(sorted.map(\.id) == ["42-6", "42-4", "42-3", "42-5", "42-2", "10-1", "42-1", "42-7"])
        // Deterministic regardless of input order.
        #expect(input.reversed().sortedByUrgency().map(\.id) == sorted.map(\.id))
    }
}
