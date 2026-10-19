//
//  MergeRequestListPopup.swift
//  MyApp
//
//  The `MenuBarExtra` popup content (MRT-060), `.menuBarExtraStyle(.window)`. Pure
//  SwiftUI view — takes the current snapshot and callbacks as parameters, holds no
//  sync/polling state of its own. The real coordinator (built in parallel; exposes
//  `snapshot`, `isRefreshing`, a status enum, and `refresh`/`openSettings` actions) is
//  wired up at the call site, not in here.
//
//  Layout follows PLAN.md → "Menu bar popup":
//  ┌──────────────────────────────────────────────────────────────────┐
//  │ backend-api     MR-03   [pipe]  [appr] approved       [beh] 2 behind      │
//  │ frontend-web    MR-17   [pipe]  [appr] approved       [ok]  up to date  • │
//  │ codefair        MR-08   [pipe]  [appr] not approved   [beh] 5 behind      │
//  ├──────────────────────────────────────────────────────────────────┤
//  │ Updated 14:32 · Refresh now · Settings…                          │
//  └──────────────────────────────────────────────────────────────────┘
//
//  **Design decision — one `statusMessage: String?` covers both the "not configured" and
//  "degraded" banners.** The coordinator's status (ok / notConfigured / degraded(message))
//  collapses to a single optional string by the time it reaches this view, so the banner
//  can't structurally distinguish *why* it's non-nil. Rather than smuggling a second enum
//  parameter past the agreed initializer, the banner always offers an "Open Settings…"
//  action next to the message — appropriate for "not configured" (the obvious next step)
//  and still reasonable for "degraded" (e.g. an auth/network error the user may fix via
//  Settings). `lastError` (from the snapshot itself) is shown the same way when
//  `statusMessage` is nil, so a scheduled-poll failure gets a banner even when the
//  coordinator hasn't set an explicit status message. The row list underneath always
//  reflects `snapshot.mergeRequests` regardless of the banner, so stale-but-present data
//  stays visible under a "degraded" banner instead of being hidden.
//

import SwiftUI

struct MergeRequestListPopup: View {
    var snapshot: SnapshotStore
    var isRefreshing: Bool
    /// Degraded/not-configured banner text from the coordinator's status. `nil` when the
    /// status is `.ok`. See the file-level comment for how this interacts with
    /// `snapshot.lastError`.
    var statusMessage: String?
    var onOpen: (URL) -> Void
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// Measured height of the row stack; drives the ScrollView's explicit height.
    @State private var rowsContentHeight: CGFloat = 0

    private enum Layout {
        static let width: CGFloat = 480
        static let maxListHeight: CGFloat = 420
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner

            listOrEmptyState

            Divider()

            footer
        }
        .frame(width: Layout.width, alignment: .leading)
    }

    // MARK: - Banner

    private var bannerText: String? {
        statusMessage ?? snapshot.lastError
    }

    @ViewBuilder
    private var banner: some View {
        if let bannerText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)

                Text(bannerText)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Open Settings…") { onOpenSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Rows / empty state

    /// Pure sort step, pulled out of `body` so `MergeRequestListTests` can assert the list
    /// uses `MergeRequestUrgency`'s order without rendering anything. `nonisolated` since
    /// it touches no view/UI state — lets tests (which run off the main actor by default)
    /// call it directly instead of needing `@MainActor` / `await`.
    nonisolated static func sortedRows(_ mergeRequests: [MergeRequestSnapshot]) -> [MergeRequestSnapshot] {
        mergeRequests.sortedByUrgency()
    }

    private var rows: [MergeRequestSnapshot] {
        Self.sortedRows(snapshot.mergeRequests)
    }

    @ViewBuilder
    private var listOrEmptyState: some View {
        if rows.isEmpty {
            // Suppress the "all caught up" checkmark when a banner is already showing —
            // pairing a success glyph directly under a warning/not-configured banner reads
            // as contradictory. The banner alone (with its "Open Settings…" action) already
            // explains why the list is empty in those cases.
            if bannerText == nil {
                emptyState
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { mr in
                        Button {
                            onOpen(mr.webURL)
                        } label: {
                            MergeRequestRow(mr: mr, animationsEnabled: true)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    rowsContentHeight = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // A `MenuBarExtra` window sizes itself to its content's ideal size, and a
            // ScrollView has no ideal height — with only `maxHeight` it collapses to zero
            // (the list vanished while the footer still showed). Give it an explicit
            // height: the measured rows, capped so long lists scroll.
            .frame(height: min(rowsContentHeight, Layout.maxListHeight))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No open merge requests")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(FooterTimeFormatting.updatedText(lastFetchedAt: snapshot.lastFetchedAt))
                .foregroundStyle(.secondary)
                .font(.footnote)

            Spacer()

            Button {
                onRefresh()
            } label: {
                HStack(spacing: 4) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Refresh now")
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Button("Settings…") { onOpenSettings() }
                .buttonStyle(.plain)

            Button("Quit") { onQuit() }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Previews

#Preview("Populated — mixed states") {
    MergeRequestListPopup(
        snapshot: SnapshotStore(
            mergeRequests: [
                .preview(iid: 3, project: "group/backend-api", pipeline: .failed, approved: false, behind: 2),
                .preview(iid: 42, project: "group/backend-api", pipeline: .running, approved: false, behind: 0, hasConflicts: true, unresolvedThreads: true),
                .preview(iid: 17, project: "group/frontend-web", pipeline: .success, approved: true, behind: 0, mergeable: true),
                .preview(iid: 8, project: "group/codefair", pipeline: .success, approved: false, behind: 5),
                .preview(iid: 21, project: "group/codefair", pipeline: .canceled, approved: true, behind: nil),
                .preview(iid: 9, project: "group/design-system", pipeline: .success, approved: true, behind: 0, mergeable: true, isDraft: true),
            ],
            lastFetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastError: nil
        ),
        isRefreshing: false,
        statusMessage: nil,
        onOpen: { _ in },
        onRefresh: {},
        onOpenSettings: {},
        onQuit: {}
    )
}

#Preview("Refreshing") {
    MergeRequestListPopup(
        snapshot: SnapshotStore(
            mergeRequests: [
                .preview(iid: 3, project: "group/backend-api", pipeline: .running, approved: false, behind: 1),
            ],
            lastFetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastError: nil
        ),
        isRefreshing: true,
        statusMessage: nil,
        onOpen: { _ in },
        onRefresh: {},
        onOpenSettings: {},
        onQuit: {}
    )
}

#Preview("Empty — no open MRs") {
    MergeRequestListPopup(
        snapshot: SnapshotStore(mergeRequests: [], lastFetchedAt: Date(timeIntervalSince1970: 1_760_000_000), lastError: nil),
        isRefreshing: false,
        statusMessage: nil,
        onOpen: { _ in },
        onRefresh: {},
        onOpenSettings: {},
        onQuit: {}
    )
}

#Preview("Not configured — never updated") {
    MergeRequestListPopup(
        snapshot: .empty,
        isRefreshing: false,
        statusMessage: "Not configured — add a GitLab URL and token in Settings.",
        onOpen: { _ in },
        onRefresh: {},
        onOpenSettings: {},
        onQuit: {}
    )
}

#Preview("Degraded — stale data with error banner") {
    MergeRequestListPopup(
        snapshot: SnapshotStore(
            mergeRequests: [
                .preview(iid: 3, project: "group/backend-api", pipeline: .success, approved: true, behind: 0, mergeable: true),
                .preview(iid: 17, project: "group/frontend-web", pipeline: .failed, approved: false, behind: 4),
            ],
            lastFetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastError: "Couldn't reach gitlab.example.com — showing last known data."
        ),
        isRefreshing: false,
        statusMessage: nil,
        onOpen: { _ in },
        onRefresh: {},
        onOpenSettings: {},
        onQuit: {}
    )
}
