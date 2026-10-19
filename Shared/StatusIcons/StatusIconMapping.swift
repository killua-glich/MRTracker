import Foundation

/// One SF Symbol + tint + label pairing for a single status indicator — e.g. "pipeline
/// failed" or "3 commits behind" (MRT-054). Pure data, no SwiftUI view code, so it's
/// `Sendable` and can be constructed/compared from a plain unit test (`StatusIconMappingTests`)
/// without touching rendering at all.
nonisolated struct StatusIconStyle: Sendable, Hashable {
    /// SF Symbol name. Every name produced by `StatusIconMapping` is verified to resolve
    /// via `NSImage(systemSymbolName:accessibilityDescription:)` on this OS in
    /// `StatusIconMappingTests`.
    var symbolName: String
    var tint: StatusTint
    /// Short label shown next to the icon (e.g. "approved", "2 behind") — see `StatusLabel`.
    var label: String
    /// VoiceOver label, phrased as a standalone sentence fragment rather than the terse
    /// `label` (e.g. "Pipeline failed" instead of "Failed").
    var accessibilityLabel: String
    /// Whether this icon should rotate continuously while visible (pipeline
    /// running/pending). `StatusIcon` only actually animates when its own
    /// `animationsEnabled` parameter is also `true` — widgets render a static snapshot and
    /// can't animate at all, so widget call sites leave that parameter at its `false`
    /// default regardless of this flag.
    var animated: Bool = false
}

/// Pure mapping from `MergeRequestSnapshot` fields to `StatusIconStyle` values, per
/// PLAN.md's "Menu bar popup" table and "Status dot" section (MRT-054). No SwiftUI import,
/// no view code — this is the single source of truth shared between the widget extension
/// and the menu bar popup (both MRT-052/053 and MRT-060 consume it via `StatusIcon` /
/// `StatusLabel`), and it's exercised directly by `StatusIconMappingTests`.
nonisolated enum StatusIconMapping {

    // MARK: - Pipeline

    /// PLAN.md → "Menu bar popup" table, Pipeline column. `nil` (no pipeline has run yet)
    /// is folded into the same `.minus.circle` / secondary treatment as `.canceled` —
    /// from the user's point of view both mean "nothing to report."
    static func pipeline(_ status: PipelineStatus?) -> StatusIconStyle {
        switch status?.displayBucket ?? .noneOrCanceled {
        case .runningOrPending:
            StatusIconStyle(
                symbolName: "arrow.triangle.2.circlepath",
                tint: .blue,
                label: "Running",
                accessibilityLabel: "Pipeline running",
                animated: true
            )
        case .success:
            StatusIconStyle(
                symbolName: "checkmark.circle",
                tint: .green,
                label: "Success",
                accessibilityLabel: "Pipeline succeeded"
            )
        case .failed:
            StatusIconStyle(
                symbolName: "xmark.circle",
                tint: .red,
                label: "Failed",
                accessibilityLabel: "Pipeline failed"
            )
        case .noneOrCanceled:
            StatusIconStyle(
                symbolName: "minus.circle",
                tint: .secondary,
                label: "No pipeline",
                accessibilityLabel: "No pipeline status"
            )
        }
    }

    // MARK: - Approval

    /// PLAN.md → "Menu bar popup" table, Approval column.
    static func approval(approved: Bool) -> StatusIconStyle {
        approved
            ? StatusIconStyle(
                symbolName: "checkmark.seal",
                tint: .green,
                label: "approved",
                accessibilityLabel: "Approved"
            )
            : StatusIconStyle(
                symbolName: "seal",
                tint: .secondary,
                label: "not approved",
                accessibilityLabel: "Not approved"
            )
    }

    // MARK: - Behind

    /// The three states `divergedCommitsCount` can represent. Kept distinct from
    /// `StatusIconStyle` so tests (and any future non-icon consumer, e.g. sorting by
    /// urgency) can assert on the semantic state rather than parsing rendered strings.
    nonisolated enum BehindState: Sendable, Hashable {
        case upToDate
        case behind(Int)
        /// `divergedCommitsCount == nil`.
        ///
        /// **Decision:** GitLab only omits this field when the detail call wasn't made
        /// with `include_diverged_commits_count=true`, or that call failed outright — it
        /// is never the API's way of reporting an actual zero (PLAN.md → GitLab API
        /// mapping lists it as a dedicated query parameter, not a default-included field).
        /// Treating `nil` the same as `0` would silently render a possibly out-of-date MR
        /// with the same reassuring checkmark as a genuinely up-to-date one; treating it
        /// as "behind" would invent a commit count that was never fetched. `.unknown` is
        /// surfaced as its own neutral state instead, so a fetch gap is visible rather
        /// than papered over as either extreme.
        case unknown
    }

    static func behindState(_ divergedCommitsCount: Int?) -> BehindState {
        guard let count = divergedCommitsCount else { return .unknown }
        return count > 0 ? .behind(count) : .upToDate
    }

    /// PLAN.md → "Menu bar popup" table, Behind column (plus the `.unknown` case for a
    /// `nil` count — see `BehindState.unknown`).
    static func behind(_ divergedCommitsCount: Int?) -> StatusIconStyle {
        switch behindState(divergedCommitsCount) {
        case .upToDate:
            StatusIconStyle(
                symbolName: "checkmark",
                tint: .secondary,
                label: "up to date",
                accessibilityLabel: "Up to date with the target branch"
            )
        case .behind(let count):
            StatusIconStyle(
                symbolName: "arrow.down.circle",
                tint: .orange,
                label: "\(count) behind",
                accessibilityLabel: "\(count) commit\(count == 1 ? "" : "s") behind the target branch"
            )
        case .unknown:
            StatusIconStyle(
                symbolName: "questionmark.circle",
                tint: .secondary,
                label: "unknown",
                accessibilityLabel: "Behind-target status unknown"
            )
        }
    }

    // MARK: - Conflicts, draft, unresolved threads
    //
    // Unlike pipeline/approval/behind (always exactly one of N states), these three are
    // additive warning badges: PLAN.md's table doesn't give them a "healthy" icon, and
    // showing a redundant "no conflicts" checkmark on every single row would add noise
    // without adding information. Each returns `nil` when the condition doesn't apply so
    // callers simply skip rendering that badge for the row.

    static func conflict(hasConflicts: Bool) -> StatusIconStyle? {
        guard hasConflicts else { return nil }
        return StatusIconStyle(
            symbolName: "exclamationmark.triangle",
            tint: .red,
            label: "conflicts",
            accessibilityLabel: "Has conflicts with the target branch"
        )
    }

    static func draft(isDraft: Bool) -> StatusIconStyle? {
        guard isDraft else { return nil }
        return StatusIconStyle(
            symbolName: "pencil.circle",
            tint: .secondary,
            label: "draft",
            accessibilityLabel: "Draft merge request"
        )
    }

    /// Derived from `MergeRequestSnapshot.blockingDiscussionsResolved`: `false` means at
    /// least one blocking discussion thread is still unresolved.
    static func unresolvedThreads(blockingDiscussionsResolved: Bool) -> StatusIconStyle? {
        guard !blockingDiscussionsResolved else { return nil }
        return StatusIconStyle(
            symbolName: "bubble.left.and.exclamationmark.bubble.right",
            tint: .orange,
            label: "unresolved threads",
            accessibilityLabel: "Has unresolved discussion threads"
        )
    }
}
