//
//  StatusIconMappingTests.swift
//  MyAppTests
//

import AppKit
import Testing
@testable import MyApp

struct StatusIconMappingTests {

    // MARK: - Pipeline

    @Test(arguments: [
        (PipelineStatus?.none, "minus.circle", StatusTint.secondary, false),
        (.created, "arrow.triangle.2.circlepath", .blue, true),
        (.waitingForResource, "arrow.triangle.2.circlepath", .blue, true),
        (.preparing, "arrow.triangle.2.circlepath", .blue, true),
        (.pending, "arrow.triangle.2.circlepath", .blue, true),
        (.running, "arrow.triangle.2.circlepath", .blue, true),
        (.scheduled, "arrow.triangle.2.circlepath", .blue, true),
        (.success, "checkmark.circle", .green, false),
        (.failed, "xmark.circle", .red, false),
        (.canceled, "minus.circle", .secondary, false),
        (.skipped, "minus.circle", .secondary, false),
        (.manual, "minus.circle", .secondary, false),
        (.unknown("mystery"), "minus.circle", .secondary, false),
    ])
    func pipelineMapsToExpectedSymbolAndTint(
        status: PipelineStatus?,
        expectedSymbol: String,
        expectedTint: StatusTint,
        expectedAnimated: Bool
    ) {
        let style = StatusIconMapping.pipeline(status)
        #expect(style.symbolName == expectedSymbol)
        #expect(style.tint == expectedTint)
        #expect(style.animated == expectedAnimated)
    }

    @Test func nilPipelineStatusMapsSameAsNoPipeline() {
        #expect(StatusIconMapping.pipeline(nil) == StatusIconMapping.pipeline(.canceled))
    }

    // MARK: - Approval

    @Test func approvedMapsToGreenCheckmarkSeal() {
        let style = StatusIconMapping.approval(approved: true)
        #expect(style.symbolName == "checkmark.seal")
        #expect(style.tint == .green)
        #expect(style.label == "approved")
    }

    @Test func notApprovedMapsToSecondarySeal() {
        let style = StatusIconMapping.approval(approved: false)
        #expect(style.symbolName == "seal")
        #expect(style.tint == .secondary)
        #expect(style.label == "not approved")
    }

    // MARK: - Behind

    @Test func zeroDivergedCommitsMapsToUpToDate() {
        #expect(StatusIconMapping.behindState(0) == .upToDate)
        let style = StatusIconMapping.behind(0)
        #expect(style.symbolName == "checkmark")
        #expect(style.tint == .secondary)
        #expect(style.label == "up to date")
    }

    @Test func positiveDivergedCommitsMapsToBehindWithCount() {
        #expect(StatusIconMapping.behindState(5) == .behind(5))
        let style = StatusIconMapping.behind(5)
        #expect(style.symbolName == "arrow.down.circle")
        #expect(style.tint == .orange)
        #expect(style.label == "5 behind")
        #expect(style.accessibilityLabel.contains("5 commits"))
    }

    @Test func singularBehindCountUsesSingularAccessibilityWording() {
        let style = StatusIconMapping.behind(1)
        #expect(style.accessibilityLabel.contains("1 commit "))
        #expect(!style.accessibilityLabel.contains("1 commits"))
    }

    @Test func nilDivergedCommitsMapsToUnknownNotUpToDate() {
        #expect(StatusIconMapping.behindState(nil) == .unknown)
        let style = StatusIconMapping.behind(nil)
        #expect(style.symbolName == "questionmark.circle")
        #expect(style.tint == .secondary)
        // Must not be mistaken for the "up to date" state.
        #expect(style != StatusIconMapping.behind(0))
    }

    // MARK: - Conflicts, draft, unresolved threads

    @Test func hasConflictsProducesRedTriangle() {
        let style = StatusIconMapping.conflict(hasConflicts: true)
        #expect(style?.symbolName == "exclamationmark.triangle")
        #expect(style?.tint == .red)
    }

    @Test func noConflictsProducesNoBadge() {
        #expect(StatusIconMapping.conflict(hasConflicts: false) == nil)
    }

    @Test func draftProducesSecondaryPencil() {
        let style = StatusIconMapping.draft(isDraft: true)
        #expect(style?.symbolName == "pencil.circle")
        #expect(style?.tint == .secondary)
    }

    @Test func notDraftProducesNoBadge() {
        #expect(StatusIconMapping.draft(isDraft: false) == nil)
    }

    @Test func unresolvedDiscussionsProduceOrangeBubble() {
        let style = StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: false)
        #expect(style?.symbolName == "bubble.left.and.exclamationmark.bubble.right")
        #expect(style?.tint == .orange)
    }

    @Test func resolvedDiscussionsProduceNoBadge() {
        #expect(StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: true) == nil)
    }

    // MARK: - Every symbol name actually resolves on this OS

    @Test func allMappedSymbolNamesResolveToSystemImages() {
        let styles: [StatusIconStyle] = [
            StatusIconMapping.pipeline(nil),
            StatusIconMapping.pipeline(.running),
            StatusIconMapping.pipeline(.success),
            StatusIconMapping.pipeline(.failed),
            StatusIconMapping.pipeline(.canceled),
            StatusIconMapping.approval(approved: true),
            StatusIconMapping.approval(approved: false),
            StatusIconMapping.behind(0),
            StatusIconMapping.behind(3),
            StatusIconMapping.behind(nil),
        ] + ([
            StatusIconMapping.conflict(hasConflicts: true),
            StatusIconMapping.draft(isDraft: true),
            StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: false),
        ] as [StatusIconStyle?]).compactMap { $0 }

        for style in styles {
            let resolved = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)
            #expect(resolved != nil, "Expected \"\(style.symbolName)\" to resolve as a system symbol")
        }
    }
}
