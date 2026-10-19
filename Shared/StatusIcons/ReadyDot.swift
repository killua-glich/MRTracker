import SwiftUI

/// The menu bar popup's "ready to merge" indicator — PLAN.md → "Status dot": modeled on
/// the camera-in-use indicator on Apple devices. A small solid green circle (~7pt) with a
/// soft glow of the same color, no border, no symbol. Shown only when
/// `MergeRequestSnapshot.isMergeable` is `true`; otherwise an equally-sized clear
/// placeholder is drawn instead so the column keeps its alignment across rows (PLAN.md:
/// "anything else — no dot (empty slot keeps alignment)").
struct ReadyDot: View {
    var isMergeable: Bool
    var diameter: CGFloat = 7

    var body: some View {
        Circle()
            .fill(isMergeable ? Color.green : Color.clear)
            .frame(width: diameter, height: diameter)
            .shadow(color: isMergeable ? .green.opacity(0.6) : .clear, radius: 3)
            .accessibilityLabel(isMergeable ? "Ready to merge" : "")
            .accessibilityHidden(!isMergeable)
    }
}

#Preview("ReadyDot — lit and empty") {
    HStack(spacing: 16) {
        ReadyDot(isMergeable: true)
        ReadyDot(isMergeable: false)
    }
    .padding()
    .background(Color.black.opacity(0.8))
}
