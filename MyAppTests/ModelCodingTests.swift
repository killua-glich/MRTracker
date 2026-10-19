//
//  ModelCodingTests.swift
//  MyAppTests
//

import Foundation
import Testing
@testable import MyApp

struct ModelCodingTests {

    private func makeFullSnapshot() -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: 42,
            projectPath: "group/backend-api",
            iid: 3,
            title: "Add retry logic to poller",
            webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/3")!,
            sourceBranch: "feature/retry-logic",
            targetBranch: "main",
            roles: [.author, .reviewer],
            isDraft: false,
            pipelineStatus: .running,
            divergedCommitsCount: 2,
            approved: true,
            approvalsLeft: 0,
            approvedBy: ["alice", "bob"],
            detailedMergeStatus: "mergeable",
            hasConflicts: false,
            blockingDiscussionsResolved: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeMinimalSnapshot() -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: 7,
            projectPath: "group/frontend-web",
            iid: 17,
            title: "WIP: experiment",
            webURL: URL(string: "https://gitlab.example.com/group/frontend-web/-/merge_requests/17")!,
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

    @Test func idIsDerivedFromProjectIdAndIid() {
        let snapshot = makeFullSnapshot()
        #expect(snapshot.id == "42-3")
    }

    @Test func fullyPopulatedSnapshotRoundTripsThroughJSON() throws {
        let original = makeFullSnapshot()
        let data = try JSONEncoder.snapshot.encode(original)
        let decoded = try JSONDecoder.snapshot.decode(MergeRequestSnapshot.self, from: data)
        #expect(decoded == original)
    }

    @Test func minimalSnapshotWithNilOptionalsRoundTripsThroughJSON() throws {
        let original = makeMinimalSnapshot()
        let data = try JSONEncoder.snapshot.encode(original)
        let decoded = try JSONDecoder.snapshot.decode(MergeRequestSnapshot.self, from: data)
        #expect(decoded == original)
        #expect(decoded.pipelineStatus == nil)
        #expect(decoded.divergedCommitsCount == nil)
        #expect(decoded.approvalsLeft == nil)
        #expect(decoded.detailedMergeStatus == nil)
    }

    @Test func isMergeableReflectsDetailedMergeStatus() {
        #expect(makeFullSnapshot().isMergeable)
        #expect(!makeMinimalSnapshot().isMergeable)
    }

    @Test func snapshotStoreRoundTripsThroughJSON() throws {
        let store = SnapshotStore(
            mergeRequests: [makeFullSnapshot(), makeMinimalSnapshot()],
            lastFetchedAt: Date(timeIntervalSince1970: 1_700_000_200),
            lastError: "network unreachable"
        )
        let data = try JSONEncoder.snapshot.encode(store)
        let decoded = try JSONDecoder.snapshot.decode(SnapshotStore.self, from: data)
        #expect(decoded == store)
    }

    @Test func emptySnapshotStoreHasNoMergeRequestsAndNoError() {
        #expect(SnapshotStore.empty.mergeRequests.isEmpty)
        #expect(SnapshotStore.empty.lastError == nil)
    }

    @Test func unknownPipelineStatusDecodesWithoutFailing() throws {
        let json = Data(#"{"status":"some_future_status"}"#.utf8)
        struct Wrapper: Codable { var status: PipelineStatus }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(decoded.status == .unknown("some_future_status"))
        #expect(decoded.status.displayBucket == .noneOrCanceled)
    }

    @Test func unknownPipelineStatusRoundTripsThroughJSON() throws {
        struct Wrapper: Codable, Equatable { var status: PipelineStatus }
        let original = Wrapper(status: .unknown("brand_new_status"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
        #expect(decoded == original)
    }

    @Test(arguments: [
        (PipelineStatus.created, PipelineStatus.DisplayBucket.runningOrPending),
        (.waitingForResource, .runningOrPending),
        (.preparing, .runningOrPending),
        (.pending, .runningOrPending),
        (.running, .runningOrPending),
        (.scheduled, .runningOrPending),
        (.success, .success),
        (.failed, .failed),
        (.canceled, .noneOrCanceled),
        (.skipped, .noneOrCanceled),
        (.manual, .noneOrCanceled),
        (.unknown("mystery"), .noneOrCanceled),
    ])
    func pipelineStatusMapsToExpectedDisplayBucket(
        status: PipelineStatus,
        expectedBucket: PipelineStatus.DisplayBucket
    ) {
        #expect(status.displayBucket == expectedBucket)
    }
}
