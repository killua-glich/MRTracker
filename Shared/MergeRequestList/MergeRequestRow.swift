//
//  MergeRequestRow.swift
//  Shared (MyApp + MRTrackerWidgetExtension)
//
//  Single-row rendering of a merge request for the menu bar popup (MRT-060) and, per
//  MRT-053's "shares row view code with the menu bar dropdown where practical", reused by
//  the large widget. Pure view: takes data as parameters, no sync/polling state, no
//  `SnapshotStore`/coordinator dependency — lives in `Shared/` precisely so both targets
//  can compile it in.
//
//  Column layout follows PLAN.md → "Menu bar popup":
//  `[ project  MR-03  pipeline  approved/not approved  behind-or-clean  status dot ]`,
//  with compact badge icons (conflicts / draft / unresolved threads) inserted before the
//  status dot — `StatusIconMapping` returns `nil` for those when not applicable, so a
//  healthy row shows no badges at all, keeping the common case clean per PLAN.md's
//  "no emojis... clean and minimal" visual style.
//
//  Fixed-width columns (rather than `Grid`) were chosen deliberately: a `Grid` only
//  aligns columns across rows that are direct children of the *same* `Grid` container, so
//  every call site embedding this row (the menu bar list today, the large widget later)
//  would have to also become a `Grid`. Fixed widths keep per-row alignment self-contained,
//  so the row drops into a `VStack`, `LazyVStack`, or `List` without extra coupling.
//

import SwiftUI

struct MergeRequestRow: View {
    var mr: MergeRequestSnapshot
    /// Opt-in, matching `StatusIcon`/`StatusLabel`'s own convention: a WidgetKit timeline
    /// entry is a static snapshot and can't animate, so widget call sites should leave this
    /// at its `false` default; the live menu bar popup passes `true`.
    var animationsEnabled: Bool = false

    private enum Layout {
        // Column widths are tuned to fit the popup's ~440–480pt width (PLAN.md →
        // "Menu bar popup") with all 7 columns + spacing + the list's own padding —
        // verified by rendering `MergeRequestListPopup`'s previews, not just this row's.
        static let spacing: CGFloat = 6
        static let projectWidth: CGFloat = 88
        static let iidWidth: CGFloat = 40
        static let pipelineWidth: CGFloat = 18
        static let approvalWidth: CGFloat = 112
        static let behindWidth: CGFloat = 84
        /// Room for up to 3 badges (conflict, draft, unresolved threads) at a fixed width,
        /// so the status dot after it lands in the same place whether a row has 0 or 3
        /// badges.
        static let badgesWidth: CGFloat = 28
        static let dotWidth: CGFloat = 14
    }

    private var projectShortName: String {
        ProjectPathFormatting.shortName(mr.projectPath)
    }

    private var badgeStyles: [StatusIconStyle] {
        [
            StatusIconMapping.conflict(hasConflicts: mr.hasConflicts),
            StatusIconMapping.draft(isDraft: mr.isDraft),
            StatusIconMapping.unresolvedThreads(blockingDiscussionsResolved: mr.blockingDiscussionsResolved),
        ].compactMap { $0 }
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Text(projectShortName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Layout.projectWidth, alignment: .leading)
                .help(mr.projectPath)

            Text("MR-\(mr.iid)")
                .monospacedDigit()
                .frame(width: Layout.iidWidth, alignment: .leading)

            StatusIcon(
                style: StatusIconMapping.pipeline(mr.pipelineStatus),
                animationsEnabled: animationsEnabled
            )
            .frame(width: Layout.pipelineWidth, alignment: .center)

            StatusLabel(
                style: StatusIconMapping.approval(approved: mr.approved),
                animationsEnabled: animationsEnabled
            )
            .frame(width: Layout.approvalWidth, alignment: .leading)

            StatusLabel(
                style: StatusIconMapping.behind(mr.divergedCommitsCount),
                animationsEnabled: animationsEnabled
            )
            .frame(width: Layout.behindWidth, alignment: .leading)

            HStack(spacing: 3) {
                ForEach(Array(badgeStyles.enumerated()), id: \.offset) { _, style in
                    StatusIcon(style: style, animationsEnabled: animationsEnabled)
                        .imageScale(.small)
                }
            }
            .frame(width: Layout.badgesWidth, alignment: .leading)

            ReadyDot(isMergeable: mr.isMergeable)
                .frame(width: Layout.dotWidth, alignment: .center)
        }
        .font(.callout)
        .lineLimit(1)
        // The mockup is single-line per row; the title (not shown in any column) surfaces
        // as a tooltip rather than a second line, so rows stay compact and uniform height.
        .help(mr.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(projectShortName), merge request \(mr.iid)",
            mr.title,
            StatusIconMapping.pipeline(mr.pipelineStatus).accessibilityLabel,
            StatusIconMapping.approval(approved: mr.approved).accessibilityLabel,
            StatusIconMapping.behind(mr.divergedCommitsCount).accessibilityLabel,
        ]
        parts.append(contentsOf: badgeStyles.map(\.accessibilityLabel))
        if mr.isMergeable {
            parts.append("Ready to merge")
        }
        return parts.joined(separator: ". ")
    }
}

#Preview("MergeRequestRow — all states") {
    VStack(alignment: .leading, spacing: 6) {
        MergeRequestRow(mr: .preview(iid: 3, project: "group/backend-api", pipeline: .failed, approved: false, behind: 2), animationsEnabled: true)
        MergeRequestRow(mr: .preview(iid: 17, project: "group/frontend-web", pipeline: .running, approved: true, behind: 0, mergeable: true), animationsEnabled: true)
        MergeRequestRow(mr: .preview(iid: 8, project: "group/codefair", pipeline: .success, approved: false, behind: 5), animationsEnabled: true)
        MergeRequestRow(mr: .preview(iid: 21, project: "group/codefair", pipeline: .success, approved: true, behind: nil, mergeable: true), animationsEnabled: true)
        MergeRequestRow(mr: .preview(iid: 42, project: "group/backend-api", pipeline: .canceled, approved: false, behind: 0, hasConflicts: true, isDraft: true, unresolvedThreads: true), animationsEnabled: true)
    }
    .padding()
    .frame(width: 460)
}

/// Preview-only fixture builder, kept next to the row it previews. Not `#if DEBUG`:
/// `#Preview` bodies are type-checked in Release builds too.
extension MergeRequestSnapshot {
    static func preview(
        iid: Int,
        project: String,
        pipeline: PipelineStatus?,
        approved: Bool,
        behind: Int?,
        mergeable: Bool = false,
        hasConflicts: Bool = false,
        isDraft: Bool = false,
        unresolvedThreads: Bool = false
    ) -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: iid * 100,
            projectPath: project,
            iid: iid,
            title: "Preview merge request #\(iid)",
            webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
            sourceBranch: "feature/preview-\(iid)",
            targetBranch: "main",
            roles: [.author],
            isDraft: isDraft,
            pipelineStatus: pipeline,
            divergedCommitsCount: behind,
            approved: approved,
            approvalsLeft: approved ? 0 : 1,
            approvedBy: approved ? ["alice"] : [],
            detailedMergeStatus: mergeable ? "mergeable" : (hasConflicts ? "conflict" : "ci_must_pass"),
            hasConflicts: hasConflicts,
            blockingDiscussionsResolved: !unresolvedThreads,
            updatedAt: .now
        )
    }
}
