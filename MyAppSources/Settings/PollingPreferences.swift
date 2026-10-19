import Foundation

/// Non-secret polling preferences (MRT-012), persisted in `UserDefaults`.
///
/// The poller (MRT-040) calls `PollingPreferencesStore.load()` at the start of every
/// cycle, so a change made in Settings takes effect on the next cycle without a restart.
nonisolated struct PollingPreferences: Sendable, Equatable {
    /// Allowed polling interval range, in seconds.
    static let intervalRange: ClosedRange<Int> = 30...900
    static let defaultIntervalSeconds = 90

    /// Seconds between polls, always clamped to `intervalRange`.
    var intervalSeconds: Int {
        didSet { intervalSeconds = Self.clamp(intervalSeconds) }
    }
    /// Which MRs to track: authored by me, reviewer, or both. Never empty.
    var trackedRoles: Set<MRRole> {
        didSet { if trackedRoles.isEmpty { trackedRoles = Self.defaultRoles } }
    }

    static let defaultRoles: Set<MRRole> = [.author, .reviewer]
    static let `default` = PollingPreferences(
        intervalSeconds: defaultIntervalSeconds,
        trackedRoles: defaultRoles
    )

    init(intervalSeconds: Int, trackedRoles: Set<MRRole>) {
        self.intervalSeconds = Self.clamp(intervalSeconds)
        self.trackedRoles = trackedRoles.isEmpty ? Self.defaultRoles : trackedRoles
    }

    var interval: Duration { .seconds(intervalSeconds) }

    private static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }
}

/// Reads/writes `PollingPreferences` from an injectable `UserDefaults`.
nonisolated struct PollingPreferencesStore: Sendable {
    private static let intervalKey = "polling.intervalSeconds"
    private static let rolesKey = "polling.trackedRoles"

    // `UserDefaults` is documented thread-safe but not marked Sendable in the SDK.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PollingPreferences {
        let storedInterval = defaults.object(forKey: Self.intervalKey) as? Int
        let storedRoles = (defaults.stringArray(forKey: Self.rolesKey) ?? [])
            .compactMap(MRRole.init(rawValue:))
        return PollingPreferences(
            intervalSeconds: storedInterval ?? PollingPreferences.defaultIntervalSeconds,
            trackedRoles: storedRoles.isEmpty ? PollingPreferences.defaultRoles : Set(storedRoles)
        )
    }

    func save(_ preferences: PollingPreferences) {
        defaults.set(preferences.intervalSeconds, forKey: Self.intervalKey)
        defaults.set(preferences.trackedRoles.map(\.rawValue).sorted(), forKey: Self.rolesKey)
    }
}
