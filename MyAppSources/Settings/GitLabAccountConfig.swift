//
//  GitLabAccountConfig.swift
//  MyApp
//
//  Non-secret account configuration (MRT-011), read by the Settings UI on reopen and,
//  later, by the polling scheduler (MRT-040) to know which host/username to poll as. Only
//  ever written after a successful `GET /user` validation — see
//  `GitLabAccountSettingsModel.verifyAndSave()`. The PAT itself never lives here: it's
//  Keychain-only (`TokenStore`), keyed by this struct's `baseURL`'s host.
//

import Foundation

/// The GitLab base URL + authenticated username, persisted in `UserDefaults` (no secrets).
///
/// `defaults` is injectable so tests can pass an isolated `UserDefaults(suiteName:)` instance
/// instead of `.standard`.
nonisolated struct GitLabAccountConfig: Sendable, Equatable {

    private enum Keys {
        static let baseURL = "GitLabAccountConfig.baseURL"
        static let username = "GitLabAccountConfig.username"
    }

    /// The validated GitLab base URL (e.g. `https://gitlab.example.com`), or `nil` if no
    /// account has ever been successfully verified.
    var baseURL: URL?
    /// The authenticated user's username (from `GET /user`), or `nil` alongside `baseURL`.
    var username: String?

    init(baseURL: URL? = nil, username: String? = nil) {
        self.baseURL = baseURL
        self.username = username
    }

    /// Loads whatever is currently persisted in `defaults`.
    init(defaults: UserDefaults) {
        if let urlString = defaults.string(forKey: Keys.baseURL) {
            baseURL = URL(string: urlString)
        } else {
            baseURL = nil
        }
        username = defaults.string(forKey: Keys.username)
    }

    /// Persists this config to `defaults`, overwriting whatever was there before. Passing a
    /// `nil` field removes that key rather than writing an empty string.
    func save(to defaults: UserDefaults) {
        if let baseURL {
            defaults.set(baseURL.absoluteString, forKey: Keys.baseURL)
        } else {
            defaults.removeObject(forKey: Keys.baseURL)
        }
        if let username {
            defaults.set(username, forKey: Keys.username)
        } else {
            defaults.removeObject(forKey: Keys.username)
        }
    }
}
