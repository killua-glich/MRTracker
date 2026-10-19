//
//  SmallWidgetView.swift
//  MRTrackerWidget
//
//  MRT-051: small widget — a prominent count of merge requests needing attention
//  (`urgency != .healthy`) with a red badge-style treatment when that count is > 0, or a
//  calm "All clear" + total open-MR count otherwise. MRT-055: deep-links via `widgetURL`
//  to the most urgent MR (first of the already urgency-sorted list), or no link at all
//  when there are none. MRT-056: explicit empty/never-fetched/unreadable states, a subtle
//  "may be out of date" notice when the last fetch failed but data is still shown, and
//  dimmed content + a prominent timestamp when stale.
//

import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
    var entry: MergeRequestEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var headline: WidgetPresentation.SmallWidgetHeadline {
        WidgetPresentation.smallWidgetHeadline(mergeRequests: entry.mergeRequests)
    }

    private var linkURL: URL? {
        WidgetPresentation.widgetURL(forSortedMergeRequests: entry.mergeRequests)
    }

    var body: some View {
        VStack(spacing: 4) {
            if let nonDataState = NonDataState(entry.state) {
                WidgetStatePlaceholder(state: nonDataState, compact: true)
            } else {
                headlineContent
                    .opacity(entry.isStale ? 0.55 : 1.0)

                if entry.lastError != nil {
                    StaleDataNotice()
                }

                AsOfFooter(asOf: entry.asOf, isStale: entry.isStale)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(linkURL)
    }

    @ViewBuilder
    private var headlineContent: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            if headline.needsAttention {
                badge
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                    .widgetAccentable()
            }

            Text(headline.secondaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Full-color rendering gets an explicit red "badge" (a filled capsule, matching the
    /// camera-indicator/`ReadyDot` convention of a plain colored shape, no emoji). In
    /// accented/vibrant rendering (macOS desktop widgets), an arbitrary background color
    /// would be ignored or look wrong, so this falls back to a single SF Symbol marked
    /// `.widgetAccentable()` and lets the system apply its own tint — the shape (an
    /// exclamation mark, not just a color) still carries the "needs attention" meaning on
    /// its own, per PLAN.md's "don't rely on color alone."
    @ViewBuilder
    private var badge: some View {
        if renderingMode == .fullColor {
            Text(headline.primaryText)
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.red, in: Capsule())
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(headline.primaryText)
                    .monospacedDigit()
            }
            .font(.system(.title2, design: .rounded, weight: .bold))
            .widgetAccentable()
        }
    }
}
