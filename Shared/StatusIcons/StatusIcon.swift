import SwiftUI

/// Renders a single `StatusIconStyle` as a monochrome, semantically-tinted SF Symbol —
/// PLAN.md → "Visual style: no emojis. Only monochrome SF Symbols with semantic tint."
///
/// Animation is opt-in via `animationsEnabled` rather than implicit: a WidgetKit timeline
/// entry is a static snapshot and can't animate at all, so widget call sites should leave
/// the default `false`. The menu bar popup (MRT-060), which is a live view, passes `true`.
/// Reduce Motion is always honored, even when the caller opts in.
struct StatusIcon: View {
    var style: StatusIconStyle
    var animationsEnabled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRotating: Bool {
        style.animated && animationsEnabled && !reduceMotion
    }

    var body: some View {
        Image(systemName: style.symbolName)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(style.tint.color)
            .symbolEffect(.rotate, isActive: isRotating)
            .accessibilityLabel(style.accessibilityLabel)
    }
}

#Preview("StatusIcon — pipeline states") {
    HStack(spacing: 16) {
        StatusIcon(style: StatusIconMapping.pipeline(.running), animationsEnabled: true)
        StatusIcon(style: StatusIconMapping.pipeline(.success))
        StatusIcon(style: StatusIconMapping.pipeline(.failed))
        StatusIcon(style: StatusIconMapping.pipeline(.canceled))
        StatusIcon(style: StatusIconMapping.pipeline(nil))
    }
    .font(.title)
    .padding()
}

#Preview("StatusIcon — approval, behind, and badges") {
    HStack(spacing: 16) {
        StatusIcon(style: StatusIconMapping.approval(approved: true))
        StatusIcon(style: StatusIconMapping.approval(approved: false))
        StatusIcon(style: StatusIconMapping.behind(3))
        StatusIcon(style: StatusIconMapping.behind(0))
        StatusIcon(style: StatusIconMapping.behind(nil))
        if let style = StatusIconMapping.conflict(hasConflicts: true) {
            StatusIcon(style: style)
        }
        if let style = StatusIconMapping.draft(isDraft: true) {
            StatusIcon(style: style)
        }
        if let style = StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: false) {
            StatusIcon(style: style)
        }
    }
    .font(.title)
    .padding()
}
