//
//  GitLabAccountSettingsModel.swift
//  MyApp
//
//  View model for the Settings UI (MRT-011): GitLab base URL + PAT entry, validated against
//  `GET /user` before anything is persisted. No polling-interval / role-filter controls here
//  (MRT-012) and no menu bar entry point beyond what MyAppApp.swift already wires up
//  (MRT-062) — both out of scope for this ticket.
//

import Foundation
import Observation

/// What `GitLabAccountSettingsModel` needs from a Keychain-backed token store. `TokenStore`
/// (the real Keychain implementation) already matches this shape exactly; tests inject an
/// in-memory fake instead so they never touch the real Keychain.
protocol GitLabTokenStoring: Sendable {
    func save(token: String, forHost host: String) throws(TokenStoreError)
    func readToken(forHost host: String) throws(TokenStoreError) -> String?
    func deleteToken(forHost host: String) throws(TokenStoreError)
}

extension TokenStore: GitLabTokenStoring {}

/// Errors in normalizing the user-entered base URL text, before any network call is made.
nonisolated enum GitLabBaseURLError: Error, Sendable, Equatable {
    case empty
    case invalid
    case httpsRequired
}

/// Drives the Settings view: owns the base URL / token text fields, normalizes and validates
/// the URL, calls `GET /user` to verify the token, and only then writes to the Keychain and
/// `UserDefaults`. `@MainActor` because it's driven entirely by SwiftUI bindings and button
/// taps; `@Observable` so the view invalidates on every field it actually reads.
@Observable
@MainActor
final class GitLabAccountSettingsModel {

    /// Inline status shown under the form fields.
    enum Status: Equatable {
        case idle
        case validating
        case success(String)
        case failure(String)
    }

    var baseURLText: String
    var tokenText: String = ""
    private(set) var status: Status

    /// Whether a token is currently believed to be stored in the Keychain for the persisted
    /// account — i.e. whether `config.username` survived from a previous successful
    /// `verifyAndSave()` (or hasn't been cleared by `removeToken()`). Drives the "Remove
    /// token" button and the SecureField's "Stored in Keychain" placeholder.
    var hasStoredToken: Bool { config.username != nil }

    var isValidating: Bool { status == .validating }

    private var config: GitLabAccountConfig
    private let tokenStore: GitLabTokenStoring
    private let defaults: UserDefaults
    private let validate: (URL, String) async throws(GitLabAPIError) -> GitLabUser

    init(
        tokenStore: GitLabTokenStoring = TokenStore(),
        defaults: UserDefaults = .standard,
        validate: @escaping (URL, String) async throws(GitLabAPIError) -> GitLabUser = { baseURL, token in
            try await GitLabClient(baseURL: baseURL, token: token).currentUser()
        }
    ) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.validate = validate

        let storedConfig = GitLabAccountConfig(defaults: defaults)
        self.config = storedConfig
        self.baseURLText = storedConfig.baseURL?.absoluteString ?? ""
        if let username = storedConfig.username {
            self.status = .success("Signed in as @\(username).")
        } else {
            self.status = .idle
        }
    }

    // MARK: - Actions

    /// Normalizes the entered URL, calls `GET /user` with the entered token, and — only on
    /// success — saves the token to the Keychain (deleting any previous host's token first)
    /// and the base URL + username to `UserDefaults`.
    func verifyAndSave() async {
        guard !isValidating else { return }

        let normalized: URL
        switch Self.normalizeBaseURL(baseURLText) {
        case .failure(let error):
            status = .failure(Self.message(for: error))
            return
        case .success(let url):
            normalized = url
        }

        guard !tokenText.isEmpty else {
            status = .failure("Enter a personal access token.")
            return
        }

        baseURLText = normalized.absoluteString
        status = .validating
        let newHost = Self.host(of: normalized)

        do {
            let user = try await validate(normalized, tokenText)

            if let previousHost = config.baseURL.map(Self.host(of:)), previousHost != newHost {
                try? tokenStore.deleteToken(forHost: previousHost)
            }
            try tokenStore.save(token: tokenText, forHost: newHost)

            config.baseURL = normalized
            config.username = user.username
            config.save(to: defaults)

            tokenText = ""
            status = .success("Signed in as \(user.name) (@\(user.username)).")
        } catch {
            status = .failure(message(for: error, baseURL: normalized))
        }
    }

    /// Deletes the stored token for the current account's host and clears the persisted
    /// config, returning the form to its never-configured state.
    func removeToken() {
        if let baseURL = config.baseURL {
            try? tokenStore.deleteToken(forHost: Self.host(of: baseURL))
        }
        config = GitLabAccountConfig()
        config.save(to: defaults)
        tokenText = ""
        status = .idle
    }

    // MARK: - URL normalization

    /// Trims whitespace, strips a trailing slash and/or a pasted `/api/v4` suffix, and
    /// requires an `https` scheme with a non-empty host.
    static func normalizeBaseURL(_ raw: String) -> Result<URL, GitLabBaseURLError> {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        trimmed = stripTrailingSlashes(from: trimmed)
        if trimmed.lowercased().hasSuffix("/api/v4") {
            trimmed.removeLast("/api/v4".count)
            trimmed = stripTrailingSlashes(from: trimmed)
        }

        guard let components = URLComponents(string: trimmed) else {
            return .failure(.invalid)
        }
        guard let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        guard scheme == "https" else {
            return .failure(.httpsRequired)
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.invalid)
        }
        guard let url = components.url else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    private static func stripTrailingSlashes(from string: String) -> String {
        var result = string
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func host(of url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    // MARK: - Error messages

    private static func message(for error: GitLabBaseURLError) -> String {
        switch error {
        case .empty:
            "Enter a GitLab URL."
        case .invalid:
            "That doesn't look like a valid URL."
        case .httpsRequired:
            "The GitLab URL must start with https://."
        }
    }

    /// Maps any error from `verifyAndSave()` (the `validate` call or the Keychain save) to a
    /// short, specific, user-facing message. Never includes the token.
    private func message(for error: Error, baseURL: URL) -> String {
        if let apiError = error as? GitLabAPIError {
            return Self.message(for: apiError, baseURL: baseURL)
        }
        if let storeError = error as? TokenStoreError {
            return "Could not save the token to the Keychain: \(storeError)"
        }
        return "Something went wrong: \(error)"
    }

    private static func message(for error: GitLabAPIError, baseURL: URL) -> String {
        switch error {
        case .invalidURL:
            return "Could not build a valid request URL."
        case .unauthorized:
            return "Token rejected (401) — check that it's valid and hasn't expired."
        case .forbidden:
            return "Token lacks permission (403) — it needs at least the read_api scope."
        case .notFound:
            return "GitLab did not recognize this request (404) — check the base URL."
        case .rateLimited:
            return "Rate limited by GitLab (429) — wait a moment and try again."
        case .server(let status):
            return "GitLab server error (HTTP \(status))."
        case .unexpectedStatus(let status):
            return "Unexpected response from GitLab (HTTP \(status))."
        case .decoding:
            return "Received an unexpected response from GitLab."
        case .transport(let code):
            let diagnosis = TLSDiagnostics.diagnose(error, baseURL: baseURL)
            if diagnosis.isTLSRelated {
                return diagnosis.message
            }
            return message(forNonTLSTransport: code, host: diagnosis.host)
        }
    }

    /// `GitLabAPIError.transport` codes that `TLSDiagnostics` classifies as unrelated to
    /// TLS (offline, DNS, timeout…) — kept distinct from the TLS-related wording above.
    private static func message(forNonTLSTransport code: URLError.Code, host: String) -> String {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .timedOut,
             .networkConnectionLost, .dnsLookupFailed:
            return "Could not reach \(host) — check the URL and your network connection."
        default:
            return "Network error reaching \(host): \(code)."
        }
    }
}
