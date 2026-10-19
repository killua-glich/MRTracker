//
//  PollingSettingsTests.swift
//  MyAppTests
//
//  Swift Testing coverage for `PollingSettingsModel` and `TrackSelection` (MRT-012):
//  default values, that interval and role-filter changes persist across store instances
//  (the same contract the poller relies on to pick up changes without a restart), and that
//  "none" is unreachable. Uses an isolated `UserDefaults` suite per test.
//

import Foundation
import Testing
@testable import MyApp

@MainActor
struct PollingSettingsTests {

    /// Runs `body` with an isolated `UserDefaults` suite and removes it afterwards, so
    /// tests never collide with each other or with real app settings.
    private func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let suiteName = "PollingSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try await body(defaults)
    }

    // MARK: - Defaults

    @Test func defaultsMatchPollingPreferencesDefault() async {
        await withDefaults { defaults in
            let model = PollingSettingsModel(defaults: defaults)
            #expect(model.intervalSeconds == PollingPreferences.defaultIntervalSeconds)
            #expect(model.trackSelection == .both)
            #expect(model.trackSelection.roles == PollingPreferences.defaultRoles)
        }
    }

    // MARK: - Interval persists

    @Test func intervalChangePersistsAcrossStoreInstances() async {
        await withDefaults { defaults in
            let model = PollingSettingsModel(defaults: defaults)
            model.intervalSeconds = 300

            let reloaded = PollingPreferencesStore(defaults: defaults).load()
            #expect(reloaded.intervalSeconds == 300)

            // A freshly-constructed model (as if the Settings window were reopened) picks
            // up the persisted value too.
            let reopened = PollingSettingsModel(defaults: defaults)
            #expect(reopened.intervalSeconds == 300)
        }
    }

    @Test func settingSameIntervalDoesNotClobberStore() async {
        await withDefaults { defaults in
            let model = PollingSettingsModel(defaults: defaults)
            model.intervalSeconds = 600
            model.intervalSeconds = 600

            let reloaded = PollingPreferencesStore(defaults: defaults).load()
            #expect(reloaded.intervalSeconds == 600)
        }
    }

    // MARK: - Role selection persists

    @Test func roleSelectionPersistsAcrossStoreInstances() async {
        await withDefaults { defaults in
            let model = PollingSettingsModel(defaults: defaults)
            model.trackSelection = .authored

            let reloaded = PollingPreferencesStore(defaults: defaults).load()
            #expect(reloaded.trackedRoles == [.author])

            let reopened = PollingSettingsModel(defaults: defaults)
            #expect(reopened.trackSelection == .authored)
        }
    }

    @Test func reviewingSelectionPersists() async {
        await withDefaults { defaults in
            let model = PollingSettingsModel(defaults: defaults)
            model.trackSelection = .reviewing

            let reloaded = PollingPreferencesStore(defaults: defaults).load()
            #expect(reloaded.trackedRoles == [.reviewer])
        }
    }

    // MARK: - Cannot select none

    @Test func trackSelectionHasNoEmptyCase() {
        // `TrackSelection.roles` is never empty for any case — "none" is structurally
        // unreachable through this type, not merely discouraged by UI.
        for selection in TrackSelection.allCases {
            #expect(!selection.roles.isEmpty)
        }
    }

    @Test func emptyRoleSetMapsToBothRatherThanNone() {
        #expect(TrackSelection(roles: []) == .both)
    }

    @Test func pollingPreferencesNeverPersistsEmptyRoles() async {
        await withDefaults { defaults in
            let store = PollingPreferencesStore(defaults: defaults)
            // Even constructing `PollingPreferences` directly with an empty set falls back
            // to the default roles rather than persisting "none".
            store.save(PollingPreferences(intervalSeconds: 90, trackedRoles: []))
            #expect(store.load().trackedRoles == PollingPreferences.defaultRoles)
        }
    }
}
