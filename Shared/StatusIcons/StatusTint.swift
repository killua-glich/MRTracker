import SwiftUI

/// Semantic tint for a status icon (MRT-054), kept as its own small enum rather than a bare
/// `Color` so the pure mapping layer (`StatusIconMapping`) only ever names a *meaning*
/// ("this is a failure", "this is informational") and the view layer decides how that
/// meaning is painted.
///
/// Maps to the system semantic colors (`Color.green`, `Color.secondary`, ...) rather than
/// fixed RGB values, so the menu bar popup's vibrant/dark-mode material and widget
/// backgrounds both render correctly without any extra work here.
nonisolated enum StatusTint: Sendable, Hashable {
    case green
    case red
    case orange
    case blue
    case secondary

    var color: Color {
        switch self {
        case .green: .green
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .secondary: .secondary
        }
    }
}
