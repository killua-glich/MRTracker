//
//  FooterTimeFormatting.swift
//  MyApp
//
//  Pure formatting for the menu bar popup's footer timestamp (PLAN.md → "Menu bar
//  popup": "Updated 14:32 · Refresh now · Settings…"). Extracted from
//  `MergeRequestListPopup` so `MergeRequestListTests` can assert exact output — including
//  the `SnapshotStore.empty` / `.distantPast` fallback — without rendering a view.
//

import Foundation

nonisolated enum FooterTimeFormatting {
    /// `"Updated HH:mm"`, or `"Never updated"` when `lastFetchedAt == .distantPast`
    /// (`SnapshotStore.empty`'s sentinel — before the first successful poll, or after a
    /// corrupted/missing App Group file recovery, per MRT-030).
    static func updatedText(lastFetchedAt: Date, timeZone: TimeZone = .current) -> String {
        guard lastFetchedAt != .distantPast else { return "Never updated" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Updated \(formatter.string(from: lastFetchedAt))"
    }
}
