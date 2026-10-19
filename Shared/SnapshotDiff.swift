import Foundation

/// A single field of `MergeRequestSnapshot` that is rendered somewhere in the UI (menu bar
/// popup per PLAN.md → "Menu bar popup" table, or the small/medium/large widget per PLAN.md →
/// "Widget") and therefore should gate a reload (MRT-031) when it changes.
///
/// `sourceBranch`/`targetBranch` are folded into a single `.branches` case: PLAN.md never
/// shows them independently (the popup has no branch column at all; the large widget shows
/// "branch" as one unit), and no ticket treats "source branch renamed" differently from
/// "target branch changed" — one combined field keeps the enum aligned with what's actually
/// drawn on screen instead of inventing a distinction nothing consumes.
///
/// Deliberately **excludes** `updatedAt` — see "Why `updatedAt` is excluded" on
/// `SnapshotDiffing` for the full reasoning.
nonisolated enum MRField: Sendable, Hashable, CaseIterable {
    case title
    case projectPath
    case branches
    case roles
    case isDraft
    case pipelineStatus
    case divergedCommitsCount
    case approved
    case approvalsLeft
    case approvedBy
    case detailedMergeStatus
    case hasConflicts
    case blockingDiscussionsResolved
    case webURL
}

/// One merge request whose user-visible fields differ between two polls. Carries both the
/// old and new full snapshot (not just the changed fields) so a later consumer — MRT-100's
/// local notifications are the known one, e.g. "pipeline success → failed", "approved false →
/// true", "became behind" — can inspect whatever transition it cares about without this type
/// needing to know about notifications.
nonisolated struct MRChange: Sendable, Hashable {
    var id: String
    var changedFields: Set<MRField>
    var old: MergeRequestSnapshot
    var new: MergeRequestSnapshot
}

/// The result of comparing two `SnapshotStore` values for user-visible change. This is the
/// gate MRT-031 asks about before writing the new snapshot and calling
/// `WidgetCenter.shared.reloadTimelines` — *not* the write/reload call itself (that's
/// MRT-030/MRT-041's job; this type only decides yes/no and what changed).
nonisolated struct SnapshotDiff: Sendable, Hashable {
    /// Ids present in the new snapshot but not the old one.
    var addedIds: Set<String>
    /// Ids present in the old snapshot but not the new one.
    var removedIds: Set<String>
    /// MRs present in both snapshots whose user-visible fields differ. Order follows the
    /// new snapshot's `mergeRequests` order (not that order is itself meaningful — see
    /// "Why ordering alone is never a change" below).
    var changedMRs: [MRChange]
    /// `true` when `lastError` transitioned no-error → error or error → no-error (or changed
    /// message). `false` when both sides agree, including "same error message repeated" —
    /// the widget's error state (PLAN.md → MRT-056) doesn't change pixels on a repeat.
    var errorChanged: Bool

    /// Whether MRT-031 should write the new snapshot and trigger a (debounced, MRT-041)
    /// widget reload. `false` means: write is still fine to do (cheap, and keeps
    /// `lastFetchedAt` current for staleness — see the note on `SnapshotDiffing`), but no
    /// reload is warranted.
    var hasUserVisibleChanges: Bool {
        !addedIds.isEmpty || !removedIds.isEmpty || !changedMRs.isEmpty || errorChanged
    }
}

/// Pure diffing logic for MRT-031 (detect snapshot changes to gate widget reload) and
/// MRT-072 (unit tests for that logic). No I/O, no `WidgetCenter` call, no debounce — see
/// PLAN.md → "Refresh strategy & widget budget" for where those live (MRT-030, MRT-041).
///
/// ### Why ordering alone is never a change
/// MRs are compared by `id` (`"<projectId>-<iid>"`), not by position in `mergeRequests`. The
/// menu bar popup and widget both sort rows themselves by urgency (PLAN.md → "Menu bar
/// popup": "Rows sorted by urgency"), so two snapshots containing the same MRs with the same
/// field values but listed in a different order render identically — diffing by id makes
/// that automatic rather than something every caller has to remember.
///
/// ### Why `updatedAt` is excluded
/// `updatedAt` is GitLab's "this resource was touched" timestamp, bumped by things that never
/// reach the screen today — e.g. a new non-blocking comment, a label change, or any other
/// edit not covered by `blockingDiscussionsResolved`/`detailedMergeStatus`/etc. Neither the
/// menu bar popup table nor the small/medium/large widget descriptions in PLAN.md render
/// `updatedAt` or a "last updated" value per MR — the widget's only timestamp is the
/// timeline entry's own "as of" time (`lastFetchedAt`, via MRT-050's `TimelineProvider`), not
/// a per-MR value. Treating `updatedAt` as user-visible would burn the widget's limited daily
/// reload budget (PLAN.md → "Refresh strategy & widget budget") on changes nobody can see. If
/// a future large-widget revision renders `updatedAt` directly, add `.updatedAt` to `MRField`
/// and this decision should be revisited — it is not a hidden/permanent exclusion, just the
/// correct call given the current UI surface.
///
/// ### Why `lastFetchedAt` is excluded
/// Same shape of reasoning: `lastFetchedAt` changes on *every* successful poll, including
/// no-op ones, so treating it as user-visible would defeat the entire point of this type.
/// The widget shows "as of" from its own timeline entry (PLAN.md → "Refresh strategy"), which
/// still advances on an unrelated schedule — the widget needs *some* periodic reload to keep
/// that "as of" readout from going stale even when nothing else changed; that occasional
/// staleness-driven reload is MRT-041/MRT-056's concern (a time-based nudge independent of
/// this diff), not something `SnapshotDiff` should manufacture by treating `lastFetchedAt` as
/// a change.
nonisolated enum SnapshotDiffing {
    /// Diffs two snapshots directly. `previous == nil` is treated identically to
    /// `SnapshotStore.empty` as the baseline (no MRs, no error) — i.e. "no prior snapshot to
    /// compare against" reads as "everything in `new` is new", and `new.lastError` reads as
    /// a fresh error IF non-nil, matching the required "treat as changed if new snapshot is
    /// non-empty or has error" rule.
    static func diff(previous: SnapshotStore?, new: SnapshotStore) -> SnapshotDiff {
        let old = previous ?? .empty

        let oldByID = Dictionary(uniqueKeysWithValues: old.mergeRequests.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.mergeRequests.map { ($0.id, $0) })

        let oldIDs = Set(oldByID.keys)
        let newIDs = Set(newByID.keys)

        let addedIds = newIDs.subtracting(oldIDs)
        let removedIds = oldIDs.subtracting(newIDs)

        let changedMRs: [MRChange] = new.mergeRequests.compactMap { newMR in
            guard let oldMR = oldByID[newMR.id] else { return nil }
            let fields = changedFields(old: oldMR, new: newMR)
            guard !fields.isEmpty else { return nil }
            return MRChange(id: newMR.id, changedFields: fields, old: oldMR, new: newMR)
        }

        let errorChanged = old.lastError != new.lastError

        return SnapshotDiff(
            addedIds: addedIds,
            removedIds: removedIds,
            changedMRs: changedMRs,
            errorChanged: errorChanged
        )
    }

    /// Convenience overload accepting `SnapshotFileStore.read()`'s result type directly.
    /// `.noSnapshotYet` and `.unreadable` both fold into "no baseline" (`previous: nil`) —
    /// per the ticket, a missing or corrupt prior file is handled the same way as a genuinely
    /// first-ever poll: if the new snapshot carries any MRs or an error, that's a change
    /// worth surfacing; a `new` snapshot that is itself empty with no error produces no
    /// change (nothing to show either way).
    static func diff(previous: SnapshotReadResult, new: SnapshotStore) -> SnapshotDiff {
        switch previous {
        case .snapshot(let store):
            diff(previous: store, new: new)
        case .noSnapshotYet, .unreadable:
            diff(previous: nil, new: new)
        }
    }

    /// Per-MR field comparison. Only called for MRs present in both snapshots (by `id`) —
    /// added/removed MRs are reported separately in `SnapshotDiff.addedIds`/`removedIds`
    /// rather than as a degenerate `MRChange`, since there is no meaningful "old" or "new"
    /// value to pair with a field list in those cases.
    static func changedFields(old: MergeRequestSnapshot, new: MergeRequestSnapshot) -> Set<MRField> {
        var changed: Set<MRField> = []
        if old.title != new.title { changed.insert(.title) }
        if old.projectPath != new.projectPath { changed.insert(.projectPath) }
        if old.sourceBranch != new.sourceBranch || old.targetBranch != new.targetBranch {
            changed.insert(.branches)
        }
        if old.roles != new.roles { changed.insert(.roles) }
        if old.isDraft != new.isDraft { changed.insert(.isDraft) }
        if old.pipelineStatus != new.pipelineStatus { changed.insert(.pipelineStatus) }
        if old.divergedCommitsCount != new.divergedCommitsCount { changed.insert(.divergedCommitsCount) }
        if old.approved != new.approved { changed.insert(.approved) }
        if old.approvalsLeft != new.approvalsLeft { changed.insert(.approvalsLeft) }
        if old.approvedBy != new.approvedBy { changed.insert(.approvedBy) }
        if old.detailedMergeStatus != new.detailedMergeStatus { changed.insert(.detailedMergeStatus) }
        if old.hasConflicts != new.hasConflicts { changed.insert(.hasConflicts) }
        if old.blockingDiscussionsResolved != new.blockingDiscussionsResolved { changed.insert(.blockingDiscussionsResolved) }
        if old.webURL != new.webURL { changed.insert(.webURL) }
        return changed
    }
}
