//
//  TokenStore.swift
//  MyApp
//
//  Keychain wrapper for storing the GitLab Personal Access Token (PAT).
//

import Foundation
import Security

/// Errors produced by `TokenStore` operations.
///
/// Intentionally never carries a token value — only an `OSStatus` (or a
/// local encoding/decoding failure) — so it is always safe to log, print,
/// or include in a crash report.
nonisolated enum TokenStoreError: Error, Sendable, Equatable {
    /// A Keychain API call returned an unexpected `OSStatus`.
    case unhandled(status: OSStatus)
    /// The token string could not be encoded as UTF-8 data before being
    /// written to the Keychain.
    case encodingFailed
    /// Data read back from the Keychain could not be decoded as a UTF-8
    /// string.
    case decodingFailed
}

nonisolated extension TokenStoreError: CustomStringConvertible {
    /// A description that never includes any secret material — only the
    /// `OSStatus` code and its system-provided (non-secret) message.
    var description: String {
        switch self {
        case .unhandled(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown Keychain error"
            return "TokenStore error: \(message) (OSStatus \(status))"
        case .encodingFailed:
            return "TokenStore error: failed to encode token as UTF-8 data"
        case .decodingFailed:
            return "TokenStore error: failed to decode stored token as UTF-8 string"
        }
    }
}

/// A Keychain-backed store for GitLab Personal Access Tokens.
///
/// Uses `kSecClassGenericPassword` items, keyed by a `service` (the app,
/// or a disposable per-test value — see `init(service:)`) and an
/// `account` equal to the GitLab host the token belongs to, so storing
/// tokens for multiple GitLab instances later (MRT-104) only means
/// varying the host string, not the storage shape.
///
/// This type is `nonisolated` and `Sendable` so it can be called from any
/// context — the main actor (e.g. Settings UI, per MRT-011) or a
/// background polling task (per MRT-040) — without an actor hop.
///
/// The underlying `Security` framework Keychain APIs (`SecItemAdd`,
/// `SecItemUpdate`, `SecItemCopyMatching`, `SecItemDelete`) are
/// synchronous, blocking calls to `securityd` with no asynchronous
/// variant to bridge to `async`/`await` — wrapping them in `async` would
/// just add a `Task` hop around a call that is already fast and
/// non-blocking in practice, with no real concurrency benefit. A plain
/// synchronous `Sendable` API is simpler and just as safe to call from
/// off the main actor.
///
/// The widget extension never links this file: it lives in
/// `MyAppSources/` only, compiled into the `MyApp` target, so the widget
/// process has no code path that can ever read the token.
nonisolated struct TokenStore: Sendable {

    /// The default Keychain service name used by the running app.
    static let defaultService = AppIdentity.bundleIdentifier

    /// The Keychain service name this instance reads/writes under.
    ///
    /// Injectable so tests can pass a unique, disposable service name
    /// (e.g. including a `UUID`) and avoid colliding with real app data
    /// or leaving test items behind in the user's login Keychain.
    let service: String

    init(service: String = TokenStore.defaultService) {
        self.service = service
    }

    /// Saves `token` for `host`, inserting a new Keychain item or
    /// updating the existing one (upsert).
    func save(token: String, forHost host: String) throws(TokenStoreError) {
        guard let tokenData = token.data(using: .utf8) else {
            throw .encodingFailed
        }

        let query = baseQuery(account: host)
        let existsStatus = SecItemCopyMatching(query as CFDictionary, nil)

        switch existsStatus {
        case errSecSuccess:
            let update: [String: Any] = [kSecValueData as String: tokenData]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw .unhandled(status: status)
            }

        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = tokenData
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw .unhandled(status: status)
            }

        default:
            throw .unhandled(status: existsStatus)
        }
    }

    /// Reads the token stored for `host`, or `nil` if none is stored.
    ///
    /// A missing token is an expected, normal state (e.g. before the user
    /// has entered a PAT) and is represented by a `nil` return, not a
    /// thrown error.
    func readToken(forHost host: String) throws(TokenStoreError) -> String? {
        var query = baseQuery(account: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw .unhandled(status: status)
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw .decodingFailed
        }
        return token
    }

    /// Deletes the token stored for `host`, if any.
    ///
    /// Deleting a token that doesn't exist is treated as success (it's
    /// already in the desired end state), not an error.
    func deleteToken(forHost host: String) throws(TokenStoreError) {
        let status = SecItemDelete(baseQuery(account: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unhandled(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
