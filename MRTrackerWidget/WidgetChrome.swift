//
//  WidgetChrome.swift
//  MRTrackerWidget
//
//  Small pieces of widget UI shared across all three sizes (MRT-051/052/053/056): the
//  "as of HH:mm" footer every size shows, the subtle "may be out of date" notice shown
//  when the last fetch failed but data is still on screen, and the placeholder for the
//  non-data states (never fetched / unreadable / container unavailable / empty). Kept
//  here rather than in `Shared/` because these are rendering-only views specific to the
//  widget extension, not shared with the menu bar popup.
//

import SwiftUI
import WidgetKit

/// The four `MergeRequestEntryState` cases that mean "there is no merge request list to
/// render" (MRT-056). Deliberately excludes `.ok`, which the caller handles by rendering
/// `entry.mergeRequests` directly — keeping that case out of this enum means
/// `WidgetStatePlaceholder` can switch over it exhaustively without an `.ok` case that
/// would never make sense to render as a placeholder.
enum NonDataState {
    case empty
    case neverFetched
    case unreadable
    case containerUnavailable

    init?(_ state: MergeRequestEntryState) {
        switch state {
        case .empty: self = .empty
        case .neverFetched: self = .neverFetched
        case .unreadable: self = .unreadable
        case .containerUnavailable: self = .containerUnavailable
        case .ok: return nil
        }
    }
}

/// "as of HH:mm" — shown on every widget size per MRT-056. Renders more prominently when
/// `isStale` is true, since staleness is otherwise conveyed only by dimming the rest of
/// the content (the timestamp itself should stay legible and get *more* emphasis, not
/// less).
struct AsOfFooter: View {
    var asOf: Date?
    var isStale: Bool

    var body: some View {
        if let asOf {
            Text("as of \(asOf.formatted(date: .omitted, time: .shortened))")
                .font(isStale ? .caption.weight(.semibold) : .caption2)
                .foregroundStyle(isStale ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// A small, subtle notice shown alongside data that was fetched successfully at some
/// point but whose most recent fetch attempt failed (`SnapshotStore.lastError != nil`) —
/// MRT-056: "keep showing data but add a small subtle indicator (no raw error text
/// dump)". Deliberately never renders `lastError`'s own text.
struct StaleDataNotice: View {
    var body: some View {
        Label("May be out of date", systemImage: "exclamationmark.triangle")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .widgetAccentable()
    }
}

/// Renders the non-data widget states (MRT-056) — no App Group container, never fetched,
/// unreadable snapshot, or fetched-but-empty — consistently across all three sizes.
struct WidgetStatePlaceholder: View {
    var state: NonDataState
    /// Smaller symbol/text for the small widget, where there's less room.
    var compact: Bool = false

    private var symbolName: String {
        switch state {
        case .empty: "checkmark.circle"
        case .neverFetched: "tray"
        case .unreadable, .containerUnavailable: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch state {
        case .empty: "No open merge requests"
        case .neverFetched: "Open GitLab MRs to set up"
        case .unreadable, .containerUnavailable: "Data unavailable"
        }
    }

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: symbolName)
                .font(compact ? .title3 : .title)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(title)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 3 : 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
