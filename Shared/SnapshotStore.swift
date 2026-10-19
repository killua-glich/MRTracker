import Foundation

/// The full payload written by the host app into the App Group container (MRT-030) and
/// read back by both the host app and the widget extension (MRT-050). Holds no secrets —
/// the PAT lives in the Keychain, never here (see PLAN.md → Security).
nonisolated struct SnapshotStore: Codable, Hashable, Sendable {
    var mergeRequests: [MergeRequestSnapshot]
    var lastFetchedAt: Date
    var lastError: String?

    init(mergeRequests: [MergeRequestSnapshot], lastFetchedAt: Date, lastError: String?) {
        self.mergeRequests = mergeRequests
        self.lastFetchedAt = lastFetchedAt
        self.lastError = lastError
    }

    /// The fallback state before the first successful poll, or when the shared container
    /// file is missing/corrupted (MRT-030) — valid and safe to render, never a crash.
    static let empty = SnapshotStore(mergeRequests: [], lastFetchedAt: .distantPast, lastError: nil)
}
