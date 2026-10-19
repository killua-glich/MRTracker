import SwiftUI

/// A `StatusIcon` paired with its short text label (e.g. the "appr" / "beh" cells in
/// PLAN.md → "Menu bar popup": `[appr] approved`, `[beh] 2 behind`).
///
/// Digits in the label are always rendered with `.monospacedDigit()` so "2 behind" /
/// "12 behind" don't visually reflow against neighboring rows — harmless for labels with
/// no digits (e.g. "approved").
///
/// Exposes the same `animationsEnabled` opt-in as `StatusIcon` for the same reason: widgets
/// render a static snapshot, the live menu bar popup opts in.
struct StatusLabel: View {
    var style: StatusIconStyle
    var animationsEnabled: Bool = false

    var body: some View {
        Label {
            Text(style.label)
                .monospacedDigit()
        } icon: {
            StatusIcon(style: style, animationsEnabled: animationsEnabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel)
    }
}

#Preview("StatusLabel — menu bar row columns") {
    VStack(alignment: .leading, spacing: 8) {
        StatusLabel(style: StatusIconMapping.pipeline(.running), animationsEnabled: true)
        StatusLabel(style: StatusIconMapping.pipeline(.success))
        StatusLabel(style: StatusIconMapping.pipeline(.failed))
        StatusLabel(style: StatusIconMapping.approval(approved: true))
        StatusLabel(style: StatusIconMapping.approval(approved: false))
        StatusLabel(style: StatusIconMapping.behind(2))
        StatusLabel(style: StatusIconMapping.behind(12))
        StatusLabel(style: StatusIconMapping.behind(0))
        StatusLabel(style: StatusIconMapping.behind(nil))
    }
    .padding()
}
