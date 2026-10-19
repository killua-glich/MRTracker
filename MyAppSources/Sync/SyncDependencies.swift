//
//  SyncDependencies.swift
//  MyApp
//
//  Injection seams for `SyncCoordinator` (MRT-040). Everything the poller touches — account
//  + token, preferences, the GitLab assembler, the TLS preflight, the snapshot file, the
//  clock, the sleep/wake notification source and the widget reload — goes through here so
//  tests can drive the loop deterministically with fakes.
//

import AppKit
import Foundation
import os

// MARK: - Seams

/// What the poller needs to talk to GitLab. Never logged (holds the PAT).
nonisolated struct SyncAccount: Sendable, Equatable {
    var baseURL: URL
    var token: String
    /// Validated username from `GitLabAccountConfig`, used for the reviewer query. `nil` →
    /// the assembler fetches `GET /user` (once; the coordinator caches the result).
    var username: String?

    /// `host[:port]` — key for caches and the TLS preflight, and the host shown in messages.
    var displayHost: String { TLSDiagnostics.displayHost(of: baseURL) }
}

nonisolated enum SyncAccountLookup: Sendable, Equatable {
    case configured(SyncAccount)
    /// No base URL saved, or no token in the Keychain for it.
    case notConfigured
    /// Configured, but the token couldn't be read (Keychain error). Secret-free message.
    case unavailable(message: String)
}

/// `SnapshotAssembler.assemble` as a protocol, so tests can script results / block calls.
nonisolated protocol SnapshotAssembling: Sendable {
    func assemble(
        roles: Set<MRRole>,
        username: String?,
        previous: [MergeRequestSnapshot]
    ) async throws(GitLabAPIError) -> AssemblyResult
}

nonisolated extension SnapshotAssembler: SnapshotAssembling {}

/// Host power transitions the poller reacts to.
nonisolated enum SystemPowerEvent: Sendable, Equatable {
    case willSleep
    case didWake
}

// MARK: - Dependencies

nonisolated struct SyncDependencies: Sendable {
    /// Read at the start of every fetch (account changes apply without restart).
    var loadAccount: @Sendable () -> SyncAccountLookup
    /// Read every cycle, so interval / role changes apply on the next cycle.
    var loadPreferences: @Sendable () -> PollingPreferences
    var makeAssembler: @Sendable (SyncAccount) -> any SnapshotAssembling
    /// `TLSPreflight.runIfNeeded(baseURL:)`.
    var tlsPreflight: @Sendable (URL) async -> TLSPreflightResult
    /// `TLSPreflight.recheckAfterFailure(_:baseURL:)`.
    var tlsRecheck: @Sendable (GitLabAPIError, URL) async -> TLSDiagnosis?
    var store: SnapshotFileStore
    var now: @Sendable () -> Date
    /// Sleep used for poll cadence, wake delay and backoff. Must throw on cancellation.
    var sleep: @Sendable (Duration) async throws -> Void
    /// A fresh stream of sleep/wake events; consumed for as long as the coordinator runs.
    var powerEvents: @MainActor @Sendable () -> AsyncStream<SystemPowerEvent>
    /// The raw widget reload (wrapped in a `WidgetReloadDebouncer` by the coordinator).
    var reloadWidgets: @Sendable () async -> Void
    /// Sleep used by the reload debouncer (separate from `sleep` so tests can drive the poll
    /// loop by hand while the debouncer runs on real time with a tiny window).
    var debounceSleep: @Sendable (Duration) async throws -> Void
    var tuning: SyncTuning = SyncTuning()
}

/// Timing knobs. Defaults are the production values; see `SyncCoordinator` docs for why.
nonisolated struct SyncTuning: Sendable, Equatable {
    /// Delay after `didWake` before fetching, so Wi-Fi / VPN can come back first.
    var wakeFetchDelay: Duration = .seconds(5)
    /// Delay after `settingsDidChange()` before fetching — collapses a multi-field save.
    var settingsChangeFetchDelay: Duration = .seconds(1)
    /// Consecutive-failure backoff: interval × 2^(n-1), capped at this multiple.
    var maxBackoffMultiplier: Int = 5
    /// Upper bound on an honored `Retry-After`.
    var maxRetryAfter: Duration = .seconds(3600)
    /// Even without user-visible changes, reload the widget at most this often after a
    /// successful poll, so its "as of" stays honest (MRT-056).
    var stalenessReloadInterval: Duration = .seconds(30 * 60)
    /// `WidgetReloadDebouncer` window.
    var reloadDebounceWindow: Duration = WidgetReloadDebouncer.defaultWindow
}

// MARK: - Live wiring

extension SyncDependencies {

    nonisolated private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "Sync")

    /// Production dependencies: `UserDefaults` config/prefs, Keychain token, real
    /// `GitLabClient`, App Group snapshot file, `ContinuousClock`, `NSWorkspace` sleep/wake,
    /// `WidgetCenter`.
    static func live(
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        session: URLSession = .shared
    ) -> SyncDependencies {
        nonisolated(unsafe) let defaults = defaults
        let preflight = TLSPreflight(defaults: defaults)
        let preferences = PollingPreferencesStore(defaults: defaults)
        let continuousSleep: @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }

        return SyncDependencies(
            loadAccount: { liveAccount(defaults: defaults, tokenStore: tokenStore) },
            loadPreferences: { preferences.load() },
            makeAssembler: { account in
                SnapshotAssembler(client: GitLabClient(baseURL: account.baseURL, token: account.token, session: session))
            },
            tlsPreflight: { await preflight.runIfNeeded(baseURL: $0, session: session) },
            tlsRecheck: { await preflight.recheckAfterFailure($0, baseURL: $1, session: session) },
            store: liveStore(),
            now: { Date() },
            sleep: continuousSleep,
            powerEvents: { workspacePowerEvents() },
            reloadWidgets: WidgetReloadDebouncer.reloadMergeRequestWidgets,
            debounceSleep: continuousSleep
        )
    }

    nonisolated static func liveAccount(defaults: UserDefaults, tokenStore: TokenStore) -> SyncAccountLookup {
        let config = GitLabAccountConfig(defaults: defaults)
        // Same Keychain account key as `GitLabAccountSettingsModel` (host, no port).
        guard let baseURL = config.baseURL, let host = baseURL.host(percentEncoded: false), !host.isEmpty else {
            return .notConfigured
        }
        do {
            guard let token = try tokenStore.readToken(forHost: host), !token.isEmpty else {
                return .notConfigured
            }
            return .configured(SyncAccount(baseURL: baseURL, token: token, username: config.username))
        } catch {
            logger.error("Token read failed: \(error.description, privacy: .public)")
            return .unavailable(message: "Couldn't read the GitLab access token from the Keychain. Re-enter it in Settings.")
        }
    }

    /// The App Group file the widget reads. If the container is unavailable (entitlement /
    /// provisioning problem) falls back to the app's own Application Support so the menu
    /// bar still works — the widget then can't see data, which the logged error explains.
    static func liveStore() -> SnapshotFileStore {
        do {
            return try SnapshotFileStore.appGroup(containerURL: AppGroup.containerURL, identifier: AppGroup.identifier)
        } catch {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            logger.error("App Group unavailable; snapshot falls back to app-local storage (widget won't see it)")
            return SnapshotFileStore(fileURL: base.appending(path: SnapshotFileStore.fileName, directoryHint: .notDirectory))
        }
    }

    /// `NSWorkspace` sleep/wake notifications (posted on the *workspace* notification
    /// center, not `NotificationCenter.default`) as one stream.
    static func workspacePowerEvents() -> AsyncStream<SystemPowerEvent> {
        let center = NSWorkspace.shared.notificationCenter
        return AsyncStream { continuation in
            let sleepTask = Task {
                for await _ in center.notifications(named: NSWorkspace.willSleepNotification) {
                    continuation.yield(.willSleep)
                }
            }
            let wakeTask = Task {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                    continuation.yield(.didWake)
                }
            }
            continuation.onTermination = { _ in
                sleepTask.cancel()
                wakeTask.cancel()
            }
        }
    }
}
