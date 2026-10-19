//
//  MergeRequestListTests.swift
//  MyAppTests
//
//  Covers the pure logic extracted out of the menu bar popup views (MRT-060) so it's
//  testable without rendering: project name shortening (`ProjectPathFormatting`), footer
//  timestamp formatting (`FooterTimeFormatting`), and the sort order the list renders
//  (`MergeRequestListPopup.sortedRows`, which must match `MergeRequestUrgency`).
//

import Foundation
import Testing
@testable import MyApp

struct MergeRequestListTests {

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
        divergedCommitsCount: Int? = 0,
        approved: Bool = false,
        approvalsLeft: Int? = 1,
        approvedBy: [String] = [],
        detailedMergeStatus: String? = "ci_must_pass",
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

    // MARK: - ProjectPathFormatting

    @Test(arguments: [
        ("group/backend-api", "backend-api"),
        ("group/subgroup/codefair", "codefair"),
        ("standalone-project", "standalone-project"),
        ("", ""),
    ])
    func shortNameReturnsLastPathComponent(projectPath: String, expected: String) {
        #expect(ProjectPathFormatting.shortName(projectPath) == expected)
    }

    // MARK: - FooterTimeFormatting

    @Test func distantPastFormatsAsNeverUpdated() {
        #expect(FooterTimeFormatting.updatedText(lastFetchedAt: .distantPast) == "Never updated")
    }

    @Test func realTimestampFormatsAsUpdatedHHmm() {
        // 2026-10-17T14:32:00Z
        let date = Date(timeIntervalSince1970: 1_792_247_520)
        let text = FooterTimeFormatting.updatedText(lastFetchedAt: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == "Updated 14:32")
    }

    @Test func midnightUTCStillFormatsWithLeadingZero() {
        // 2026-10-17T00:05:00Z
        let date = Date(timeIntervalSince1970: 1_792_195_500)
        let text = FooterTimeFormatting.updatedText(lastFetchedAt: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == "Updated 00:05")
    }

    // MARK: - Sorted order (must match MergeRequestUrgency)

    @Test func sortedRowsMatchesMergeRequestUrgencyOrder() {
        let failed = Self.makeMR(projectId: 1, iid: 1, pipelineStatus: .failed, divergedCommitsCount: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let conflicting = Self.makeMR(projectId: 2, iid: 2, pipelineStatus: .success, divergedCommitsCount: 0, hasConflicts: true, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let behind = Self.makeMR(projectId: 3, iid: 3, pipelineStatus: .success, divergedCommitsCount: 4, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let healthy = Self.makeMR(projectId: 4, iid: 4, pipelineStatus: .success, divergedCommitsCount: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_300))

        // Deliberately scrambled input order.
        let input = [healthy, behind, failed, conflicting]

        let sorted = MergeRequestListPopup.sortedRows(input)

        #expect(sorted.map(\.id) == [failed.id, conflicting.id, behind.id, healthy.id])
        // And it must be the exact same order `sortedByUrgency()` (Shared/MergeRequestUrgency)
        // produces — the list has no independent sort logic of its own.
        #expect(sorted.map(\.id) == input.sortedByUrgency().map(\.id))
    }

    @Test func sortedRowsIsStableAcrossRepeatedCalls() {
        let mrs = [
            Self.makeMR(projectId: 1, iid: 1, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            Self.makeMR(projectId: 1, iid: 2, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let first = MergeRequestListPopup.sortedRows(mrs).map(\.id)
        let second = MergeRequestListPopup.sortedRows(mrs).map(\.id)
        #expect(first == second)
    }

    @Test func sortedRowsOnEmptyInputIsEmpty() {
        #expect(MergeRequestListPopup.sortedRows([]).isEmpty)
    }
}
