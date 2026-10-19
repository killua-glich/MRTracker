//
//  WidgetTimelineBuilderTests.swift
//  MyAppTests
//
//  MRT-050: `WidgetTimelineBuilder.makeEntries` is pure (no filesystem, no WidgetKit, no
//  wall-clock), so every `SnapshotReadResult` path — including "container unavailable",
//  which isn't a `SnapshotReadResult` case at all — can be exercised directly here, even
//  though MyAppTests can't import the widget extension module.
//

import Foundation
import Testing
@testable import MyApp

struct WidgetTimelineBuilderTests {

    // MARK: - Fixtures

    private nonisolated static func makeMR(
        iid: Int,
        pipeline: PipelineStatus? = nil,
        hasConflicts: Bool = false,
        divergedCommitsCount: Int? = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: 1,
            projectPath: "group/backend-api",
            iid: iid,
            title: "MR \(iid)",
            webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/\(iid)")!,
            sourceBranch: "feature/\(iid)",
            targetBranch: "main",
            roles: [.author],
            isDraft: false,
            pipelineStatus: pipeline,
            divergedCommitsCount: divergedCommitsCount,
            approved: false,
            approvalsLeft: nil,
            approvedBy: [],
            detailedMergeStatus: hasConflicts ? "conflict" : "mergeable",
            hasConflicts: hasConflicts,
            blockingDiscussionsResolved: true,
            updatedAt: updatedAt
        )
    }

    private static let now = Date(timeIntervalSince1970: 1_700_100_000)

    // MARK: - State mapping

    @Test func snapshotWithMergeRequestsIsOk() {
        let store = SnapshotStore(mergeRequests: [Self.makeMR(iid: 1)], lastFetchedAt: Self.now, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now)

        #expect(entries.first?.state == .ok)
        #expect(entries.first?.asOf == Self.now)
        #expect(entries.first?.isStale == false)
    }

    @Test func snapshotWithZeroMergeRequestsIsEmpty() {
        let store = SnapshotStore(mergeRequests: [], lastFetchedAt: Self.now, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now)

        #expect(entries.first?.state == .empty)
        #expect(entries.first?.mergeRequests.isEmpty == true)
        #expect(entries.first?.asOf == Self.now)
    }

    @Test func noSnapshotYetIsNeverFetched() {
        let entries = WidgetTimelineBuilder.makeEntries(for: .noSnapshotYet, now: Self.now)

        #expect(entries.count == 1)
        #expect(entries[0].state == .neverFetched)
        #expect(entries[0].asOf == nil)
        #expect(entries[0].mergeRequests.isEmpty)
        #expect(entries[0].isStale == false)
    }

    @Test func unreadableIsUnreadable() {
        let entries = WidgetTimelineBuilder.makeEntries(for: .unreadable, now: Self.now)

        #expect(entries.count == 1)
        #expect(entries[0].state == .unreadable)
        #expect(entries[0].asOf == nil)
    }

    @Test func containerUnavailablePathUsesNilResult() {
        // There is no `SnapshotReadResult` case for "the App Group container itself is
        // unreachable" — that failure happens before a `SnapshotFileStore` can even be
        // constructed (`SnapshotFileStore.appGroup` throws). The provider passes `nil` in
        // that case.
        let entries = WidgetTimelineBuilder.makeEntries(for: nil, now: Self.now)

        #expect(entries.count == 1)
        #expect(entries[0].state == .containerUnavailable)
        #expect(entries[0].asOf == nil)
        #expect(entries[0].mergeRequests.isEmpty)
        #expect(entries[0].lastError == nil)
    }

    @Test func lastErrorIsCarriedThrough() {
        let store = SnapshotStore(mergeRequests: [Self.makeMR(iid: 1)], lastFetchedAt: Self.now, lastError: "GitLab unreachable")

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now)

        #expect(entries.allSatisfy { $0.lastError == "GitLab unreachable" })
    }

    // MARK: - Sorting

    @Test func mergeRequestsAreSortedByUrgency() {
        let healthy = Self.makeMR(iid: 1, pipeline: .success, divergedCommitsCount: 0)
        let failed = Self.makeMR(iid: 2, pipeline: .failed)
        let conflicted = Self.makeMR(iid: 3, hasConflicts: true)
        let behind = Self.makeMR(iid: 4, pipeline: .success, divergedCommitsCount: 3)
        let store = SnapshotStore(mergeRequests: [healthy, behind, failed, conflicted], lastFetchedAt: Self.now, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now)

        #expect(entries.first?.mergeRequests.map(\.iid) == [2, 3, 4, 1])
    }

    // MARK: - Staleness

    @Test func freshSnapshotSchedulesAFutureStaleEntry() {
        let store = SnapshotStore(mergeRequests: [Self.makeMR(iid: 1)], lastFetchedAt: Self.now, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now, stalenessThreshold: 900)

        #expect(entries.count == 2)
        #expect(entries[0].isStale == false)
        #expect(entries[0].date == Self.now)
        #expect(entries[1].isStale == true)
        #expect(entries[1].date == Self.now.addingTimeInterval(900))
        #expect(entries[1].asOf == Self.now)
        #expect(entries[1].state == entries[0].state)
        #expect(entries[1].mergeRequests == entries[0].mergeRequests)
    }

    @Test func alreadyStaleSnapshotReturnsOnlyOneEntry() {
        let longAgo = Self.now.addingTimeInterval(-1000)
        let store = SnapshotStore(mergeRequests: [Self.makeMR(iid: 1)], lastFetchedAt: longAgo, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now, stalenessThreshold: 900)

        #expect(entries.count == 1)
        #expect(entries[0].isStale == true)
        #expect(entries[0].asOf == longAgo)
    }

    @Test func exactlyAtStalenessThresholdCountsAsStale() {
        let asOf = Self.now.addingTimeInterval(-900)
        let store = SnapshotStore(mergeRequests: [Self.makeMR(iid: 1)], lastFetchedAt: asOf, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now, stalenessThreshold: 900)

        #expect(entries.count == 1)
        #expect(entries[0].isStale == true)
    }

    @Test func emptySnapshotAlsoSchedulesAStaleEntry() {
        let store = SnapshotStore(mergeRequests: [], lastFetchedAt: Self.now, lastError: nil)

        let entries = WidgetTimelineBuilder.makeEntries(for: .snapshot(store), now: Self.now, stalenessThreshold: 900)

        #expect(entries.count == 2)
        #expect(entries[1].state == .empty)
        #expect(entries[1].isStale == true)
    }
}
