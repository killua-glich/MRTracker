//
//  HoverHighlight.swift
//  MyApp
//
//  Row hover highlight for the menu bar popup's MR list. Deliberately kept out of
//  `Shared/MergeRequestList/MergeRequestRow` — `onHover` only makes sense for a pointer-
//  driven app window; the widget extension (which reuses the row per MRT-053) never
//  receives hover events, so this modifier is applied by the app-only list container
//  instead of baked into the shared row.
//

import SwiftUI

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Highlights the view's background while the pointer hovers over it — used for rows
    /// in `MergeRequestListPopup` (menu bar app only).
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}
