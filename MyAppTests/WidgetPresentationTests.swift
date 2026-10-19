//
//  WidgetPresentationTests.swift
//  MyAppTests
//
//  MRT-051/052/053/055: `WidgetPresentation`'s pure functions (small-widget headline text,
//  "+N more" truncation, and the small widget's `widgetURL` target) are exercised here
//  directly — no WidgetKit, no rendering, no filesystem — same rationale as
//  `WidgetTimelineBuilderTests`.
//

import Foundation
import Testing
@testable import MyApp

struct WidgetPresentationTests {

    // MARK: - Fixtures

    private nonisolated static func makeMR(
        iid: Int,
        pipeline: PipelineStatus? = .success,
        hasConflicts: Bool = false,
        divergedCommitsCount: Int? = 0,
        webURL: String? = nil
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: 1,
            projectPath: "group/backend-api",
            iid: iid,
            title: "MR \(iid)",
            webURL: URL(string: webURL ?? "https://gitlab.example.com/group/backend-api/-/merge_requests/\(iid)")!,
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
            updatedAt: .now
        )
    }

    // MARK: - Small widget headline

    @Test func zeroAttentionIsAllClearWithTotalCount() {
        let mrs = [
            Self.makeMR(iid: 1, pipeline: .success, divergedCommitsCount: 0),
            Self.makeMR(iid: 2, pipeline: .success, divergedCommitsCount: 0),
        ]
        let headline = WidgetPresentation.smallWidgetHeadline(mergeRequests: mrs)

        #expect(headline.needsAttention == false)
        #expect(headline.primaryText == "All clear")
        #expect(headline.secondaryText == "2 open MRs")
    }

    @Test func singleHealthyMRUsesSingularOpenMRWording() {
        let mrs = [Self.makeMR(iid: 1, pipeline: .success, divergedCommitsCount: 0)]
        let headline = WidgetPresentation.smallWidgetHeadline(mergeRequests: mrs)

        #expect(headline.needsAttention == false)
        #expect(headline.secondaryText == "1 open MR")
    }

    @Test func oneMRNeedingAttentionUsesSingularWording() {
        let mrs = [Self.makeMR(iid: 1, pipeline: .failed)]
        let headline = WidgetPresentation.smallWidgetHeadline(mergeRequests: mrs)

        #expect(headline.needsAttention == true)
        #expect(headline.primaryText == "1")
        #expect(headline.secondaryText == "MR needs attention")
    }

    @Test func manyMRsNeedingAttentionUsesPluralWording() {
        let mrs = [
            Self.makeMR(iid: 1, pipeline: .failed),
            Self.makeMR(iid: 2, hasConflicts: true),
            Self.makeMR(iid: 3, pipeline: .success, divergedCommitsCount: 0),
        ]
        let headline = WidgetPresentation.smallWidgetHeadline(mergeRequests: mrs)

        #expect(headline.needsAttention == true)
        #expect(headline.primaryText == "2")
        #expect(headline.secondaryText == "MRs need attention")
    }

    @Test func noMergeRequestsAtAllIsAllClearWithZeroCount() {
        let headline = WidgetPresentation.smallWidgetHeadline(mergeRequests: [])

        #expect(headline.needsAttention == false)
        #expect(headline.primaryText == "All clear")
        #expect(headline.secondaryText == "0 open MRs")
    }

    // MARK: - widgetURL (MRT-055)

    @Test func widgetURLIsFirstOfSortedList() {
        let first = Self.makeMR(iid: 1, webURL: "https://gitlab.example.com/first")
        let second = Self.makeMR(iid: 2, webURL: "https://gitlab.example.com/second")

        let url = WidgetPresentation.widgetURL(forSortedMergeRequests: [first, second])

        #expect(url == URL(string: "https://gitlab.example.com/first"))
    }

    @Test func widgetURLIsNilWhenThereAreNoMergeRequests() {
        #expect(WidgetPresentation.widgetURL(forSortedMergeRequests: []) == nil)
    }

    // MARK: - Truncation ("+N more")

    @Test func visibleRowsTakesAtMostLimit() {
        let mrs = (1...6).map { Self.makeMR(iid: $0) }

        #expect(WidgetPresentation.visibleRows(mrs, limit: 4).map(\.iid) == [1, 2, 3, 4])
        #expect(WidgetPresentation.visibleRows(mrs, limit: 10).count == 6)
        #expect(WidgetPresentation.visibleRows(mrs, limit: 0).isEmpty)
    }

    @Test func hiddenCountNeverGoesNegative() {
        #expect(WidgetPresentation.hiddenCount(total: 6, limit: 4) == 2)
        #expect(WidgetPresentation.hiddenCount(total: 2, limit: 4) == 0)
        #expect(WidgetPresentation.hiddenCount(total: 0, limit: 4) == 0)
    }

    @Test func moreLabelIsNilWhenNothingIsHidden() {
        #expect(WidgetPresentation.moreLabel(total: 3, limit: 4) == nil)
        #expect(WidgetPresentation.moreLabel(total: 4, limit: 4) == nil)
    }

    @Test func moreLabelFormatsHiddenCount() {
        #expect(WidgetPresentation.moreLabel(total: 6, limit: 4) == "+2 more")
        #expect(WidgetPresentation.moreLabel(total: 5, limit: 4) == "+1 more")
    }
}
