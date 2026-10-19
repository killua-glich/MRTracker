//
//  LargeWidgetView.swift
//  MRTrackerWidget
//
//  MRT-053: large widget — a fuller list (top 7) with title, branch (`source → target`),
//  all status icons (pipeline/approval/conflict/draft/unresolved-threads) and the behind
//  count, plus the ready-to-merge dot. Each row is its own `Link` to the MR's web URL
//  (MRT-055). Reuses `StatusIcon`/`StatusLabel`/`StatusIconMapping`/`ReadyDot`/
//  `ProjectPathFormatting` from `Shared/` — the same source of truth the menu bar popup's
//  `MergeRequestRow` uses — but as a dedicated, narrower 3-line row: `MergeRequestRow`'s
//  single-line, fixed ~420pt-wide columns (with "approved"/"not approved" text) don't fit
//  a macOS large widget (~364×382pt), and this layout needs a title + branch line that
//  `MergeRequestRow` doesn't render at all. `MergeRequestRow` itself is untouched.
//

import SwiftUI
import WidgetKit

private let largeRowLimit = 7

struct LargeWidgetView: View {
    var entry: MergeRequestEntry

    private var rows: [MergeRequestSnapshot] {
        WidgetPresentation.visibleRows(entry.mergeRequests, limit: largeRowLimit)
    }

    private var moreLabel: String? {
        WidgetPresentation.moreLabel(total: entry.mergeRequests.count, limit: largeRowLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let nonDataState = NonDataState(entry.state) {
                WidgetStatePlaceholder(state: nonDataState)
            } else {
                header

                if entry.lastError != nil {
                    StaleDataNotice()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { mr in
                        Link(destination: mr.webURL) {
                            LargeMergeRequestRow(mr: mr)
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

                Spacer(minLength: 0)
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

/// A 3-line row: project/`MR-<iid>`/ready-dot, then the title, then the branch and all
/// status icons together. Kept to 3 compact lines so ~7 rows fit a large widget's height.
private struct LargeMergeRequestRow: View {
    var mr: MergeRequestSnapshot

    private var badgeStyles: [StatusIconStyle] {
        [
            StatusIconMapping.conflict(hasConflicts: mr.hasConflicts),
            StatusIconMapping.draft(isDraft: mr.isDraft),
            StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: mr.blockingDiscussionsResolved),
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(ProjectPathFormatting.shortName(mr.projectPath))
                Text("MR-\(mr.iid)")
                    .monospacedDigit()
                Spacer(minLength: 4)
                ReadyDot(isMergeable: mr.isMergeable, diameter: 6)
                    .widgetAccentable()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(mr.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Text(mr.sourceBranch)
                    Image(systemName: "arrow.right")
                    Text(mr.targetBranch)
                }
                .lineLimit(1)
                .truncationMode(.middle)

                Spacer(minLength: 4)

                StatusIcon(style: StatusIconMapping.pipeline(mr.pipelineStatus))
                    .widgetAccentable()
                StatusIcon(style: StatusIconMapping.approval(approved: mr.approved))
                    .widgetAccentable()
                StatusLabel(style: StatusIconMapping.behind(mr.divergedCommitsCount))
                ForEach(Array(badgeStyles.enumerated()), id: \.offset) { _, style in
                    StatusIcon(style: style)
                        .widgetAccentable()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .imageScale(.small)
        }
        .accessibilityElement(children: .combine)
    }
}
