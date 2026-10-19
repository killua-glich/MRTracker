//
//  MergeRequestUrgency.swift
//  Shared (MyApp + MRTrackerWidgetExtension)
//
//  Urgency bucketing + sort order for merge requests, per PLAN.md → "Menu bar popup":
//  "Rows sorted by urgency: failed pipeline → conflicts → behind → healthy." Lives in
//  Shared/ because the menu bar popup (MRT-060), the widget (MRT-052/053), and the snapshot
//  assembler (MRT-024) all need the exact same order.
//

import Foundation

/// How urgently a merge request needs the user's attention. Declaration order (and
/// `rawValue`) is the sort order: lower = more urgent.
///
/// Each MR lands in the *most* urgent bucket it qualifies for — an MR with a failed
/// pipeline *and* conflicts is `.failedPipeline`.
nonisolated enum MergeRequestUrgency: Int, Comparable, Sendable, CaseIterable {
    /// Head pipeline status is in the `.failed` display bucket.
    case failedPipeline = 0
    /// `has_conflicts == true` or `detailed_merge_status == "conflict"`.
    case conflicts = 1
    /// `diverged_commits_count > 0`.
    case behind = 2
    /// None of the above. Also covers *unknown* data (no pipeline yet, `nil`
    /// diverged count after a failed detail fetch) — unknown is not evidence of a problem,
    /// and the row's own icons already show the "unknown" state (`StatusIconMapping`).
    case healthy = 3

    init(_ snapshot: MergeRequestSnapshot) {
        if snapshot.pipelineStatus?.displayBucket == .failed {
            self = .failedPipeline
        } else if snapshot.hasConflicts || snapshot.detailedMergeStatus == "conflict" {
            self = .conflicts
        } else if case .behind = StatusIconMapping.behindState(snapshot.divergedCommitsCount) {
            self = .behind
        } else {
            self = .healthy
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Strict-weak-ordering predicate for `sorted(by:)`: urgency bucket first, then most
    /// recently updated first (`updatedAt` desc), then `id` ascending so the order is fully
    /// deterministic even for identical timestamps (stable across polls → no row jitter,
    /// and no spurious "snapshot changed" diffs in MRT-031).
    static func areInIncreasingOrder(_ lhs: MergeRequestSnapshot, _ rhs: MergeRequestSnapshot) -> Bool {
        let lhsUrgency = MergeRequestUrgency(lhs)
        let rhsUrgency = MergeRequestUrgency(rhs)
        if lhsUrgency != rhsUrgency {
            return lhsUrgency < rhsUrgency
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }
}

nonisolated extension MergeRequestSnapshot {
    var urgency: MergeRequestUrgency {
        MergeRequestUrgency(self)
    }
}

nonisolated extension Sequence where Element == MergeRequestSnapshot {
    /// Sorted most-urgent first — see `MergeRequestUrgency.areInIncreasingOrder`.
    func sortedByUrgency() -> [MergeRequestSnapshot] {
        sorted(by: MergeRequestUrgency.areInIncreasingOrder)
    }
}
