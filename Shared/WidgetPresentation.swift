import Foundation

/// Pure, `nonisolated` presentation logic for the WidgetKit extension's small/medium/large
/// layouts (MRT-051/052/053/055). Kept out of SwiftUI view bodies so it can be unit tested
/// directly from `MyAppTests` (`WidgetPresentationTests`) without touching WidgetKit,
/// rendering, or the filesystem — same rationale as `WidgetTimelineBuilder`.
nonisolated enum WidgetPresentation {

    // MARK: - Small widget headline (MRT-051)

    /// What the small widget's headline should say, computed from a single entry's merge
    /// requests. Only meaningful for `MergeRequestEntryState.ok` (at least one MR) — the
    /// zero-MR case is `.empty`, handled by a dedicated empty-state view, not this headline.
    nonisolated struct SmallWidgetHeadline: Equatable, Sendable {
        /// The large, prominent line: either the needs-attention count or "All clear".
        var primaryText: String
        /// The secondary line underneath.
        var secondaryText: String
        /// Whether the red badge-style treatment should be used (`true` when at least one
        /// MR needs attention).
        var needsAttention: Bool
    }

    /// - Parameter mergeRequests: the entry's merge requests (any order — this only counts
    ///   and totals, it doesn't care about sort order).
    static func smallWidgetHeadline(mergeRequests: [MergeRequestSnapshot]) -> SmallWidgetHeadline {
        let attentionCount = mergeRequests.filter { $0.urgency != .healthy }.count
        if attentionCount > 0 {
            return SmallWidgetHeadline(
                primaryText: "\(attentionCount)",
                secondaryText: attentionCount == 1 ? "MR needs attention" : "MRs need attention",
                needsAttention: true
            )
        }
        let total = mergeRequests.count
        return SmallWidgetHeadline(
            primaryText: "All clear",
            secondaryText: total == 1 ? "1 open MR" : "\(total) open MRs",
            needsAttention: false
        )
    }

    // MARK: - Deep link target (MRT-055)

    /// The URL the small widget's single tap target (`widgetURL`) should open: the most
    /// urgent merge request's web URL, or `nil` when there's nothing to link to (no merge
    /// requests at all).
    ///
    /// - Parameter sortedMergeRequests: must already be urgency-sorted
    ///   (`sortedByUrgency()`, as `MergeRequestEntry.mergeRequests` already is) — this
    ///   simply takes the first element.
    static func widgetURL(forSortedMergeRequests sortedMergeRequests: [MergeRequestSnapshot]) -> URL? {
        sortedMergeRequests.first?.webURL
    }

    // MARK: - Truncation ("+N more") (MRT-052/053)

    /// The subset of (already urgency-sorted) items a medium/large widget has room to show.
    static func visibleRows<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        return Array(items.prefix(limit))
    }

    /// How many items are hidden past `limit` — never negative.
    static func hiddenCount(total: Int, limit: Int) -> Int {
        max(0, total - limit)
    }

    /// "+N more" text for the footer, or `nil` when nothing was truncated.
    static func moreLabel(total: Int, limit: Int) -> String? {
        let hidden = hiddenCount(total: total, limit: limit)
        return hidden > 0 ? "+\(hidden) more" : nil
    }
}
