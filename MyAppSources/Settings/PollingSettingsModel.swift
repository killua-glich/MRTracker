//
//  PollingSettingsModel.swift
//  MyApp
//
//  Drives the "Polling" section of the Settings view (MRT-012): polling interval presets
//  and the author/reviewer "Track" filter, both saved to `PollingPreferencesStore`
//  immediately on change. The poller (MRT-040) calls `PollingPreferencesStore.load()` at
//  the start of every cycle, so saving here is all that's needed for a change to take
//  effect without restarting the app.
//

import Foundation
import Observation

/// Which MRs to track, as a 3-way choice rather than independent toggles — this makes
/// "never none" a property of the type itself (there is no case that maps to an empty
/// `Set<MRRole>`), rather than something the UI has to police at runtime.
nonisolated enum TrackSelection: String, CaseIterable, Sendable, Equatable, Hashable {
    case authored
    case reviewing
    case both

    var roles: Set<MRRole> {
        switch self {
        case .authored: [.author]
        case .reviewing: [.reviewer]
        case .both: [.author, .reviewer]
        }
    }

    /// Maps a (possibly degenerate) role set back to a selection. `PollingPreferences`
    /// already guarantees `trackedRoles` is never empty, but an empty set is mapped to
    /// `.both` here too, defensively, rather than trapping.
    init(roles: Set<MRRole>) {
        switch (roles.contains(.author), roles.contains(.reviewer)) {
        case (true, true), (false, false):
            self = .both
        case (true, false):
            self = .authored
        case (false, true):
            self = .reviewing
        }
    }

    var label: String {
        switch self {
        case .authored: "Authored by me"
        case .reviewing: "Reviewing"
        case .both: "Both"
        }
    }
}

/// One selectable polling-interval preset. `PollingPreferences.defaultIntervalSeconds`
/// (90s) gets its own preset so the picker always shows an exact match for the default,
/// rather than falling through to an unlabeled custom value.
nonisolated struct PollingIntervalPreset: Identifiable, Sendable, Equatable {
    let seconds: Int
    let label: String
    var id: Int { seconds }

    static let all: [PollingIntervalPreset] = [
        PollingIntervalPreset(seconds: 30, label: "30 sec"),
        PollingIntervalPreset(seconds: 60, label: "1 min"),
        PollingIntervalPreset(seconds: 90, label: "1.5 min"),
        PollingIntervalPreset(seconds: 120, label: "2 min"),
        PollingIntervalPreset(seconds: 300, label: "5 min"),
        PollingIntervalPreset(seconds: 600, label: "10 min"),
        PollingIntervalPreset(seconds: 900, label: "15 min"),
    ]
}

/// View model for the Settings window's "Polling" section (MRT-012). `@MainActor` because
/// it's driven entirely by SwiftUI bindings; `@Observable` so the view invalidates only on
/// the fields it reads. Every mutation is saved to `PollingPreferencesStore` immediately —
/// there is no separate "Save" action for this section.
@Observable
@MainActor
final class PollingSettingsModel {
    var intervalSeconds: Int {
        didSet {
            guard intervalSeconds != oldValue else { return }
            persist()
        }
    }

    var trackSelection: TrackSelection {
        didSet {
            guard trackSelection != oldValue else { return }
            persist()
        }
    }

    private let store: PollingPreferencesStore

    init(defaults: UserDefaults = .standard) {
        let store = PollingPreferencesStore(defaults: defaults)
        self.store = store
        let preferences = store.load()
        self.intervalSeconds = preferences.intervalSeconds
        self.trackSelection = TrackSelection(roles: preferences.trackedRoles)
    }

    private func persist() {
        store.save(PollingPreferences(intervalSeconds: intervalSeconds, trackedRoles: trackSelection.roles))
    }
}
