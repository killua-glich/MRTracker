import Foundation

/// What the widget (MRT-050/056) should render, independent of whether there's any MR data
/// at all. Kept distinct from `SnapshotReadResult` (which only talks about the *file*) so a
/// fetched-but-empty snapshot (`.empty`) is visibly different from "never fetched"
/// (`.neverFetched`) and from "the App Group container itself is unreachable"
/// (`.containerUnavailable`, which `SnapshotReadResult` can't even express — that failure
/// happens before a `SnapshotFileStore` exists, see `SnapshotFileStore.appGroup`).
nonisolated enum MergeRequestEntryState: Hashable, Sendable {
    /// A snapshot was read successfully and has at least one merge request.
    case ok
    /// A snapshot was read successfully but has zero merge requests (fetched, nothing open).
    case empty
    /// No snapshot file exists yet — the host app has never completed a poll.
    case neverFetched
    /// A snapshot file exists but couldn't be decoded (`SnapshotReadResult.unreadable`).
    case unreadable
    /// `SnapshotFileStore.appGroup` threw — the App Group entitlement/provisioning is
    /// missing, so there's no file to even attempt reading.
    case containerUnavailable
}

/// One widget timeline entry's data, built entirely from the on-disk snapshot — no
/// networking, no `WidgetKit` import. Plain `Foundation`-only data so it can be unit tested
/// from `MyAppTests` (hosted in the `MyApp` target, which can't import the widget
/// extension's module) and so `WidgetTimelineBuilder` stays a pure function.
///
/// `MRTrackerWidget.swift` declares the actual `TimelineEntry` conformance via an empty
/// `extension MergeRequestEntry: TimelineEntry {}` where `WidgetKit` is imported — the
/// protocol only requires `var date: Date { get }`, which this struct already has, so no
/// wrapper type is needed.
nonisolated struct MergeRequestEntry: Hashable, Sendable {
    /// When WidgetKit should switch to showing this entry.
    let date: Date
    /// `SnapshotStore.lastFetchedAt` from the last *successful* fetch, or `nil` when
    /// `state` is `.neverFetched`, `.unreadable`, or `.containerUnavailable` (there is no
    /// fetch to date).
    let asOf: Date?
    /// Urgency-sorted (`sortedByUrgency()`), per PLAN.md → "Menu bar popup" / MRT-052.
    let mergeRequests: [MergeRequestSnapshot]
    /// `SnapshotStore.lastError` from the last fetch attempt, if any — surfaced without a
    /// raw error dump (MRT-056).
    let lastError: String?
    let state: MergeRequestEntryState
    /// Whether `asOf` is already older than the staleness threshold *as of `date`* — baked
    /// in at build time (rather than recomputed by the view against wall-clock `Date()`) so
    /// the view stays a pure function of the entry, and so WidgetKit's own scheduling (it
    /// switches entries at their `date`) is what flips this, not a timer in the view.
    let isStale: Bool
}

/// Builds `MergeRequestEntry` values from a snapshot read result alone. Pure and
/// `nonisolated` so `WidgetTimelineBuilderTests` (in `MyAppTests`) can exercise it directly
/// without touching the filesystem, `WidgetKit`, or wall-clock time.
///
/// **Timeline policy (MRT-050/056):** the host app is the only writer of the shared
/// snapshot, and it already calls `WidgetCenter.shared.reloadTimelines` (debounced, MRT-041)
/// whenever the snapshot changes — so there is nothing useful for the widget process to
/// poll for on its own, and `getTimeline` uses `Timeline(..., policy: .never)`. The one
/// thing that *does* need to change without a host-triggered reload is staleness: if the
/// host app stops polling (quit, VPN down, sleeping laptop), the widget should still flip
/// to a visually "stale" look once `asOf` is older than `stalenessThreshold`, even though no
/// new snapshot ever arrives. `makeEntries` handles that by scheduling a *second* entry
/// dated exactly `asOf + stalenessThreshold` with `isStale == true` whenever the first entry
/// isn't already stale — WidgetKit will switch to it on its own at that date, no reload
/// needed. If `asOf` is already past the threshold, only one (already-stale) entry is
/// returned, since there's nothing further to schedule.
nonisolated enum WidgetTimelineBuilder {
    /// How old `asOf` can get before the widget should render as stale (MRT-056). Must
    /// exceed `SyncTuning.stalenessReloadInterval` (30 min): when nothing changes, the
    /// host app only reloads the widget that often, so a shorter threshold would flag
    /// data the app has just re-confirmed as stale.
    static let defaultStalenessThreshold: TimeInterval = 45 * 60

    /// - Parameters:
    ///   - result: the outcome of `SnapshotFileStore.read()`, or `nil` when the App Group
    ///     container itself is unavailable (`SnapshotFileStore.appGroup` threw before a
    ///     store could even be constructed).
    ///   - now: injected "current time" so tests are deterministic and so the caller (the
    ///     `TimelineProvider`) controls exactly what "now" means for this timeline build.
    ///   - stalenessThreshold: see `defaultStalenessThreshold`.
    /// - Returns: one entry, or two when a future staleness flip needs to be scheduled.
    static func makeEntries(
        for result: SnapshotReadResult?,
        now: Date,
        stalenessThreshold: TimeInterval = defaultStalenessThreshold
    ) -> [MergeRequestEntry] {
        guard let result else {
            return [
                MergeRequestEntry(date: now, asOf: nil, mergeRequests: [], lastError: nil, state: .containerUnavailable, isStale: false)
            ]
        }

        switch result {
        case .noSnapshotYet:
            return [
                MergeRequestEntry(date: now, asOf: nil, mergeRequests: [], lastError: nil, state: .neverFetched, isStale: false)
            ]
        case .unreadable:
            return [
                MergeRequestEntry(date: now, asOf: nil, mergeRequests: [], lastError: nil, state: .unreadable, isStale: false)
            ]
        case .snapshot(let store):
            let sorted = store.mergeRequests.sortedByUrgency()
            let state: MergeRequestEntryState = sorted.isEmpty ? .empty : .ok
            let asOf = store.lastFetchedAt
            let alreadyStale = now.timeIntervalSince(asOf) >= stalenessThreshold

            let current = MergeRequestEntry(
                date: now,
                asOf: asOf,
                mergeRequests: sorted,
                lastError: store.lastError,
                state: state,
                isStale: alreadyStale
            )
            guard !alreadyStale else { return [current] }

            let staleEntry = MergeRequestEntry(
                date: asOf.addingTimeInterval(stalenessThreshold),
                asOf: asOf,
                mergeRequests: sorted,
                lastError: store.lastError,
                state: state,
                isStale: true
            )
            return [current, staleEntry]
        }
    }
}
