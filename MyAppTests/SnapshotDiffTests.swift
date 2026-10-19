//
//  SnapshotDiffTests.swift
//  MyAppTests
//

import Foundation
import Testing
@testable import MyApp

struct SnapshotDiffTests {

    // MARK: - Fixtures

    private nonisolated static func makeMR(
        projectId: Int = 42,
        projectPath: String = "group/backend-api",
        iid: Int = 3,
        title: String = "Add retry logic to poller",
        webURL: String = "https://gitlab.example.com/group/backend-api/-/merge_requests/3",
        sourceBranch: String = "feature/retry-logic",
        targetBranch: String = "main",
        roles: Set<MRRole> = [.author],
        isDraft: Bool = false,
        pipelineStatus: PipelineStatus? = .running,
        divergedCommitsCount: Int? = 2,
        approved: Bool = false,
        approvalsLeft: Int? = 1,
        approvedBy: [String] = [],
        detailedMergeStatus: String? = "need_rebase",
        hasConflicts: Bool = false,
        blockingDiscussionsResolved: Bool = true,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: projectId,
            projectPath: projectPath,
            iid: iid,
            title: title,
            webURL: URL(string: webURL)!,
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            roles: roles,
            isDraft: isDraft,
            pipelineStatus: pipelineStatus,
            divergedCommitsCount: divergedCommitsCount,
            approved: approved,
            approvalsLeft: approvalsLeft,
            approvedBy: approvedBy,
            detailedMergeStatus: detailedMergeStatus,
            hasConflicts: hasConflicts,
            blockingDiscussionsResolved: blockingDiscussionsResolved,
            updatedAt: updatedAt
        )
    }

    private nonisolated static func makeOtherMR() -> MergeRequestSnapshot {
        makeMR(
            projectId: 7,
            projectPath: "group/frontend-web",
            iid: 17,
            title: "WIP: experiment",
            webURL: "https://gitlab.example.com/group/frontend-web/-/merge_requests/17",
            sourceBranch: "wip/experiment",
            targetBranch: "develop",
            roles: [.reviewer],
            isDraft: true,
            pipelineStatus: nil,
            divergedCommitsCount: nil,
            approved: false,
            approvalsLeft: nil,
            approvedBy: [],
            detailedMergeStatus: nil,
            hasConflicts: false,
            blockingDiscussionsResolved: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private nonisolated static func makeStore(
        _ mergeRequests: [MergeRequestSnapshot],
        lastFetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_500),
        lastError: String? = nil
    ) -> SnapshotStore {
        SnapshotStore(mergeRequests: mergeRequests, lastFetchedAt: lastFetchedAt, lastError: lastError)
    }

    // MARK: - No change

    @Test func equalSnapshotsProduceNoChange() {
        let store = Self.makeStore([Self.makeMR(), Self.makeOtherMR()])

        let diff = SnapshotDiffing.diff(previous: store, new: store)

        #expect(!diff.hasUserVisibleChanges)
        #expect(diff.addedIds.isEmpty)
        #expect(diff.removedIds.isEmpty)
        #expect(diff.changedMRs.isEmpty)
        #expect(!diff.errorChanged)
    }

    @Test func reorderedMergeRequestsWithEqualContentProduceNoChange() {
        let old = Self.makeStore([Self.makeMR(), Self.makeOtherMR()])
        let new = Self.makeStore([Self.makeOtherMR(), Self.makeMR()])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(!diff.hasUserVisibleChanges)
    }

    // MARK: - Added / removed

    @Test func addedMergeRequestIsDetected() {
        let old = Self.makeStore([Self.makeMR()])
        let new = Self.makeStore([Self.makeMR(), Self.makeOtherMR()])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.addedIds == [Self.makeOtherMR().id])
        #expect(diff.removedIds.isEmpty)
        #expect(diff.changedMRs.isEmpty)
    }

    @Test func removedMergeRequestIsDetected() {
        let old = Self.makeStore([Self.makeMR(), Self.makeOtherMR()])
        let new = Self.makeStore([Self.makeMR()])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.removedIds == [Self.makeOtherMR().id])
        #expect(diff.addedIds.isEmpty)
        #expect(diff.changedMRs.isEmpty)
    }

    // MARK: - Per-field change detection (parameterized)

    /// Mutates exactly the given field on a copy of `mr`, so the parameterized test below can
    /// assert the diff reports precisely that field changed — nothing more, nothing less.
    /// A plain `switch` (rather than a closure per case) sidesteps Swift 6 strict-concurrency
    /// complaints about non-`Sendable` function values living in a `@Test(arguments:)` array.
    private nonisolated static func mutatedCopy(of mr: MergeRequestSnapshot, changing field: MRField) -> MergeRequestSnapshot {
        var mr = mr
        switch field {
        case .title:
            mr.title = "Changed title"
        case .projectPath:
            mr.projectPath = "group/other-path"
        case .branches:
            mr.sourceBranch = "feature/other-branch"
        case .roles:
            mr.roles = [.author, .reviewer]
        case .isDraft:
            mr.isDraft = true
        case .pipelineStatus:
            mr.pipelineStatus = .failed
        case .divergedCommitsCount:
            mr.divergedCommitsCount = 9
        case .approved:
            mr.approved = true
        case .approvalsLeft:
            mr.approvalsLeft = 0
        case .approvedBy:
            mr.approvedBy = ["alice"]
        case .detailedMergeStatus:
            mr.detailedMergeStatus = "mergeable"
        case .hasConflicts:
            mr.hasConflicts = true
        case .blockingDiscussionsResolved:
            mr.blockingDiscussionsResolved = false
        case .webURL:
            mr.webURL = URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/999")!
        }
        return mr
    }

    @Test(arguments: MRField.allCases)
    func individualUserVisibleFieldChangeIsDetectedWithTheRightField(field: MRField) {
        let original = Self.makeMR()
        let mutated = Self.mutatedCopy(of: original, changing: field)
        let old = Self.makeStore([original])
        let new = Self.makeStore([mutated])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.changedMRs.count == 1)
        #expect(diff.changedMRs.first?.id == original.id)
        #expect(diff.changedMRs.first?.changedFields == [field])
        #expect(diff.changedMRs.first?.old == original)
        #expect(diff.changedMRs.first?.new == mutated)
    }

    /// `.branches` covers both halves of the pair (see `MRField.branches` doc comment) — the
    /// parameterized test above exercises `sourceBranch`; this covers `targetBranch` alone.
    @Test func targetBranchChangeAloneIsDetectedAsBranchesField() {
        let original = Self.makeMR()
        var mutated = original
        mutated.targetBranch = "develop"
        let old = Self.makeStore([original])
        let new = Self.makeStore([mutated])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.changedMRs.first?.changedFields == [.branches])
    }

    // MARK: - updatedAt-only

    @Test func updatedAtOnlyChangeIsNotUserVisible() {
        let original = Self.makeMR()
        var mutated = original
        mutated.updatedAt = original.updatedAt.addingTimeInterval(3600)
        let old = Self.makeStore([original])
        let new = Self.makeStore([mutated])

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(!diff.hasUserVisibleChanges)
        #expect(diff.changedMRs.isEmpty)
    }

    // MARK: - lastFetchedAt-only

    @Test func lastFetchedAtOnlyChangeIsNotUserVisible() {
        let mr = Self.makeMR()
        let old = Self.makeStore([mr], lastFetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let new = Self.makeStore([mr], lastFetchedAt: Date(timeIntervalSince1970: 1_700_999_999))

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(!diff.hasUserVisibleChanges)
    }

    // MARK: - lastError transitions

    @Test func errorAppearingIsUserVisible() {
        let mr = Self.makeMR()
        let old = Self.makeStore([mr], lastError: nil)
        let new = Self.makeStore([mr], lastError: "GitLab unreachable")

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.errorChanged)
    }

    @Test func errorClearingIsUserVisible() {
        let mr = Self.makeMR()
        let old = Self.makeStore([mr], lastError: "GitLab unreachable")
        let new = Self.makeStore([mr], lastError: nil)

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.errorChanged)
    }

    @Test func sameErrorMessageRepeatedIsNotUserVisible() {
        let mr = Self.makeMR()
        let old = Self.makeStore([mr], lastError: "GitLab unreachable")
        let new = Self.makeStore([mr], lastError: "GitLab unreachable")

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(!diff.hasUserVisibleChanges)
        #expect(!diff.errorChanged)
    }

    @Test func differentErrorMessageIsUserVisible() {
        let mr = Self.makeMR()
        let old = Self.makeStore([mr], lastError: "GitLab unreachable")
        let new = Self.makeStore([mr], lastError: "Authentication failed")

        let diff = SnapshotDiffing.diff(previous: old, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.errorChanged)
    }

    // MARK: - Nil / missing / unreadable previous

    @Test func nilPreviousWithNonEmptyNewIsUserVisible() {
        let new = Self.makeStore([Self.makeMR()])

        let diff = SnapshotDiffing.diff(previous: nil, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.addedIds == [Self.makeMR().id])
    }

    @Test func nilPreviousWithEmptyNewAndNoErrorIsNotUserVisible() {
        let new = Self.makeStore([])

        let diff = SnapshotDiffing.diff(previous: nil, new: new)

        #expect(!diff.hasUserVisibleChanges)
    }

    @Test func nilPreviousWithEmptyNewButErrorIsUserVisible() {
        let new = Self.makeStore([], lastError: "Authentication failed")

        let diff = SnapshotDiffing.diff(previous: nil, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.errorChanged)
    }

    @Test func noSnapshotYetPreviousBehavesLikeNil() {
        let new = Self.makeStore([Self.makeMR()])

        let diff = SnapshotDiffing.diff(previous: .noSnapshotYet, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.addedIds == [Self.makeMR().id])
    }

    @Test func unreadablePreviousBehavesLikeNil() {
        let new = Self.makeStore([Self.makeMR()])

        let diff = SnapshotDiffing.diff(previous: .unreadable, new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.addedIds == [Self.makeMR().id])
    }

    @Test func unreadablePreviousWithEmptyNewAndNoErrorIsNotUserVisible() {
        let new = Self.makeStore([])

        let diff = SnapshotDiffing.diff(previous: .unreadable, new: new)

        #expect(!diff.hasUserVisibleChanges)
    }

    // MARK: - SnapshotReadResult.snapshot(...) overload behaves like the plain overload

    @Test func snapshotReadResultSnapshotCaseComparesAgainstThatStore() {
        let mr = Self.makeMR()
        var mutated = mr
        mutated.approved = true
        let old = Self.makeStore([mr])
        let new = Self.makeStore([mutated])

        let diff = SnapshotDiffing.diff(previous: .snapshot(old), new: new)

        #expect(diff.hasUserVisibleChanges)
        #expect(diff.changedMRs.first?.changedFields == [.approved])
    }
}
