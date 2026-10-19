import Foundation

/// Identifies the App Group shared between the host app and the widget extension, used
/// for the shared snapshot container.
///
/// The ID is configured once in `Config/App.xcconfig` (`APP_GROUP_ID`) and reaches the
/// code through each target's Info.plist (`AppGroupIdentifier`), so it always matches
/// the entitlements, which are expanded from the same setting.
nonisolated enum AppGroup {
    static let identifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? ""

    /// The shared container URL for the App Group, or `nil` if the group
    /// is unavailable (e.g. missing entitlement or provisioning issue).
    static var containerURL: URL? {
        guard !identifier.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// The running bundle's identifier (from `APP_BUNDLE_ID` in `Config/App.xcconfig`), used
/// for log subsystems and the Keychain service name instead of hardcoded strings.
nonisolated enum AppIdentity {
    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "GitLabMRTracker"
}
