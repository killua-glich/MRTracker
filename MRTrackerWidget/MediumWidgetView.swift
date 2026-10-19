//
//  MediumWidgetView.swift
//  MRTrackerWidget
//
//  MRT-052: medium widget — the top 4 urgency-sorted MRs, each showing project short
//  name, `MR-<iid>`, and icon-only pipeline/approval/behind status plus the ready-to-merge
//  dot, reusing the same `StatusIcon`/`StatusIconMapping`/`ReadyDot`/`ProjectPathFormatting`
//  building blocks as the menu bar popup's `MergeRequestRow` (MRT-054) — just without that
//  row's text labels ("approved", "5 behind") and fixed ~420pt-wide columns, which don't
//  fit a macOS medium widget (~364×170pt). `MergeRequestRow` itself is untouched; this is a
//  dedicated, narrower row rather than a change to the popup's row.
//

import SwiftUI
import WidgetKit

private let mediumRowLimit = 4

struct MediumWidgetView: View {
    var entry: MergeRequestEntry

    private var rows: [MergeRequestSnapshot] {
        WidgetPresentation.visibleRows(entry.mergeRequests, limit: mediumRowLimit)
    }

    private var moreLabel: String? {
        WidgetPresentation.moreLabel(total: entry.mergeRequests.count, limit: mediumRowLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let nonDataState = NonDataState(entry.state) {
                WidgetStatePlaceholder(state: nonDataState)
            } else {
                header

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { mr in
                        Link(destination: mr.webURL) {
                            MediumMergeRequestRow(mr: mr)
                        }
                        .buttonStyle(.plain)
                    }

                    if let moreLabel {
                        Text(moreLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(entry.isStale ? 0.55 : 1.0)

                if entry.lastError != nil {
                    StaleDataNotice()
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack {
            Text("GitLab MRs")
                .font(.headline)
            Spacer()
            AsOfFooter(asOf: entry.asOf, isStale: entry.isStale)
        }
    }
}

/// One icon-only row for the medium widget: project short name, `MR-<iid>`, pipeline/
/// approval/behind icons, and the ready-to-merge dot. Same underlying data/mapping as
/// `MergeRequestRow`'s columns, just without its text labels (no room for "approved" /
/// "5 behind" at this width) and never animated (`StatusIcon`'s `animationsEnabled`
/// defaults to `false`, which every widget call site relies on).
private struct MediumMergeRequestRow: View {
    var mr: MergeRequestSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Text(ProjectPathFormatting.shortName(mr.projectPath))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 72, alignment: .leading)

            Text("MR-\(mr.iid)")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)

            StatusIcon(style: StatusIconMapping.pipeline(mr.pipelineStatus))
                .widgetAccentable()

            StatusIcon(style: StatusIconMapping.approval(approved: mr.approved))
                .widgetAccentable()

            StatusIcon(style: StatusIconMapping.behind(mr.divergedCommitsCount))
                .widgetAccentable()

            Spacer(minLength: 0)

            ReadyDot(isMergeable: mr.isMergeable)
                .widgetAccentable()
        }
        .font(.caption)
        .imageScale(.small)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
