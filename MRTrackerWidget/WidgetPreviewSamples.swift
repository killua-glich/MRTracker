//
//  WidgetPreviewSamples.swift
//  MRTrackerWidget
//
//  Sample `MergeRequestEntry` fixtures used by every size's `#Preview` (MRT-051/052/053/
//  056) and by `Provider`'s `placeholder`/non-preview `getSnapshot` fallback. Kept in one
//  place, per the ticket, so all three widget sizes preview the exact same states instead
//  of each hand-rolling its own slightly different fixtures.
//

import Foundation

enum WidgetPreviewSamples {

    private static func mr(
        projectId: Int,
        project: String,
        iid: Int,
        title: String,
        source: String,
        target: String = "main",
        pipeline: PipelineStatus?,
        behind: Int?,
        approved: Bool,
        mergeable: Bool = false,
        hasConflicts: Bool = false,
        isDraft: Bool = false,
        unresolvedThreads: Bool = false
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: projectId,
            projectPath: project,
            iid: iid,
            title: title,
            webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
            sourceBranch: source,
            targetBranch: target,
            roles: [.author],
            isDraft: isDraft,
            pipelineStatus: pipeline,
            divergedCommitsCount: behind,
            approved: approved,
            approvalsLeft: approved ? 0 : 1,
            approvedBy: approved ? ["alice"] : [],
            detailedMergeStatus: mergeable ? "mergeable" : (hasConflicts ? "conflict" : "ci_must_pass"),
            hasConflicts: hasConflicts,
            blockingDiscussionsResolved: !unresolvedThreads,
            updatedAt: .now
        )
    }

    /// 6 MRs spanning failed pipeline, conflicts + unresolved threads, behind, a canceled
    /// pipeline with an unknown behind-count, a mergeable draft, and a fully healthy one —
    /// exercises every badge plus the "+N more" truncation path in the medium (top 4) and
    /// large (top 7) widgets.
    static let manyMixed: [MergeRequestSnapshot] = [
        mr(projectId: 1, project: "group/backend-api", iid: 42, title: "Add retry logic to poller", source: "feature/retry-logic", pipeline: .failed, behind: 0, approved: false),
        mr(projectId: 2, project: "group/frontend-web", iid: 17, title: "Fix layout on settings page", source: "fix/settings-layout", pipeline: .running, behind: 0, approved: false, hasConflicts: true, unresolvedThreads: true),
        mr(projectId: 3, project: "group/codefair", iid: 8, title: "Rework challenge catalog loader", source: "feature/catalog-rework", pipeline: .success, behind: 5, approved: false),
        mr(projectId: 4, project: "group/codefair", iid: 21, title: "Sandbox toolchain cleanup", source: "chore/sandbox-cleanup", pipeline: .canceled, behind: nil, approved: true),
        mr(projectId: 5, project: "group/design-system", iid: 9, title: "New icon set", source: "feature/icon-set", pipeline: .success, behind: 0, approved: true, mergeable: true, isDraft: true),
        mr(projectId: 6, project: "group/backend-api", iid: 50, title: "Bump dependency versions", source: "chore/deps", pipeline: .success, behind: 0, approved: true, mergeable: true),
    ].sortedByUrgency()

    static let singleMR: [MergeRequestSnapshot] = [
        mr(projectId: 1, project: "group/backend-api", iid: 42, title: "Add retry logic to poller", source: "feature/retry-logic", pipeline: .failed, behind: 0, approved: false),
    ]

    private static let referenceAsOf = Date(timeIntervalSince1970: 1_760_000_000)

    static let manyMixedOk = MergeRequestEntry(
        date: .now, asOf: referenceAsOf, mergeRequests: manyMixed, lastError: nil, state: .ok, isStale: false
    )

    static let singleMROk = MergeRequestEntry(
        date: .now, asOf: referenceAsOf, mergeRequests: singleMR, lastError: nil, state: .ok, isStale: false
    )

    static let empty = MergeRequestEntry(
        date: .now, asOf: referenceAsOf, mergeRequests: [], lastError: nil, state: .empty, isStale: false
    )

    static let neverFetched = MergeRequestEntry(
        date: .now, asOf: nil, mergeRequests: [], lastError: nil, state: .neverFetched, isStale: false
    )

    static let errorWithData = MergeRequestEntry(
        date: .now, asOf: referenceAsOf, mergeRequests: singleMR, lastError: "Couldn't reach gitlab.example.com", state: .ok, isStale: false
    )

    static let stale = MergeRequestEntry(
        date: .now, asOf: Date(timeIntervalSinceNow: -3600), mergeRequests: manyMixed, lastError: nil, state: .ok, isStale: true
    )
}
