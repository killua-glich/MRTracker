//
//  GitLabAccountSettingsTests.swift
//  MyAppTests
//
//  Swift Testing coverage for GitLabAccountSettingsModel (MRT-011): base URL normalization,
//  the verify-then-save ordering, error message mapping, host-change token migration, and
//  token removal. Uses an in-memory fake `GitLabTokenStoring` (never the real Keychain) and
//  an isolated `UserDefaults` suite per test.
//

import Foundation
import Testing
@testable import MyApp

@MainActor
struct GitLabAccountSettingsTests {

    /// In-memory stand-in for `TokenStore`, so these tests never touch the real Keychain.
    final class FakeTokenStore: GitLabTokenStoring, @unchecked Sendable {
        private(set) var tokens: [String: String] = [:]
        private(set) var deletedHosts: [String] = []
        private(set) var savedHosts: [String] = []

        func save(token: String, forHost host: String) throws(TokenStoreError) {
            tokens[host] = token
            savedHosts.append(host)
        }

        func readToken(forHost host: String) throws(TokenStoreError) -> String? {
            tokens[host]
        }

        func deleteToken(forHost host: String) throws(TokenStoreError) {
            deletedHosts.append(host)
            tokens.removeValue(forKey: host)
        }
    }

    /// Runs `body` with an isolated `UserDefaults` suite and removes it afterwards, so tests
    /// never collide with each other or with real app settings.
    private func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let suiteName = "GitLabAccountSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try await body(defaults)
    }

    private func makeModel(
        tokenStore: FakeTokenStore,
        defaults: UserDefaults,
        validate: @escaping (URL, String) async throws(GitLabAPIError) -> GitLabUser
    ) -> GitLabAccountSettingsModel {
        GitLabAccountSettingsModel(tokenStore: tokenStore, defaults: defaults, validate: validate)
    }

    // MARK: - URL normalization

    private let normalizedExample = URL(string: "https://gitlab.example.com")!

    @Test func trailingSlashIsStripped() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("https://gitlab.example.com/")
        #expect(result == .success(normalizedExample))
    }

    @Test func pastedApiV4SuffixIsStripped() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("https://gitlab.example.com/api/v4")
        #expect(result == .success(normalizedExample))
    }

    @Test func pastedApiV4SuffixWithTrailingSlashIsStripped() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("https://gitlab.example.com/api/v4/")
        #expect(result == .success(normalizedExample))
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("  https://gitlab.example.com  ")
        #expect(result == .success(normalizedExample))
    }

    @Test func httpIsRejected() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("http://gitlab.example.com")
        #expect(result == .failure(.httpsRequired))
    }

    @Test func garbageIsRejected() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("not a url")
        #expect(result == .failure(.invalid))
    }

    @Test func schemelessHostIsRejected() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("gitlab.example.com")
        #expect(result == .failure(.invalid))
    }

    @Test func emptyTextIsRejected() {
        let result = GitLabAccountSettingsModel.normalizeBaseURL("   ")
        #expect(result == .failure(.empty))
    }

    // MARK: - Successful verify & save

    @Test func successSavesTokenAndDefaultsAndUsername() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ in
                GitLabUser(id: 1, username: "diego", name: "Diego Pandolfo")
            }
            model.baseURLText = "https://gitlab.example.com/"
            model.tokenText = "glpat-secret"

            await model.verifyAndSave()

            #expect(tokenStore.tokens["gitlab.example.com"] == "glpat-secret")
            #expect(model.status == .success("Signed in as Diego Pandolfo (@diego)."))
            #expect(model.hasStoredToken == true)
            #expect(model.tokenText.isEmpty)

            let config = GitLabAccountConfig(defaults: defaults)
            #expect(config.baseURL == URL(string: "https://gitlab.example.com"))
            #expect(config.username == "diego")
        }
    }

    // MARK: - 401

    @Test func unauthorizedShowsErrorAndDoesNotSaveToken() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .unauthorized
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-bad"

            await model.verifyAndSave()

            #expect(tokenStore.tokens.isEmpty)
            #expect(model.hasStoredToken == false)
            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            #expect(message.contains("401"))

            let config = GitLabAccountConfig(defaults: defaults)
            #expect(config.username == nil)
        }
    }

    @Test func forbiddenMentionsScope() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .forbidden
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-limited"

            await model.verifyAndSave()

            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            #expect(message.contains("403"))
            #expect(tokenStore.tokens.isEmpty)
        }
    }

    // MARK: - Transport errors

    @Test func transportErrorShowsUnreachableMessage() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .transport(.cannotFindHost)
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-whatever"

            await model.verifyAndSave()

            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            #expect(message.contains("gitlab.example.com"))
            #expect(tokenStore.tokens.isEmpty)
        }
    }

    @Test func tlsTransportErrorShowsCertificateMessage() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .transport(.serverCertificateUntrusted)
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-whatever"

            await model.verifyAndSave()

            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            #expect(message.lowercased().contains("secure") || message.lowercased().contains("certificate"))
        }
    }

    // MARK: - TLS wiring (MRT-025)

    @Test func tlsTransportErrorMessageComesFromTLSDiagnostics() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .transport(.serverCertificateHasUnknownRoot)
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-whatever"

            await model.verifyAndSave()

            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            let expected = TLSDiagnostics.diagnose(
                .transport(.serverCertificateHasUnknownRoot),
                baseURL: normalizedExample
            ).message
            #expect(message == expected)
            #expect(message.contains("gitlab.example.com"))
        }
    }

    @Test func nonTLSTransportErrorStaysDistinctFromTLSWording() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ throws(GitLabAPIError) in
                throw .transport(.notConnectedToInternet)
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-whatever"

            await model.verifyAndSave()

            guard case .failure(let message) = model.status else {
                Issue.record("expected .failure, got \(model.status)")
                return
            }
            #expect(message.contains("gitlab.example.com"))
            #expect(!message.lowercased().contains("certificate"))
        }
    }

    // MARK: - Host change deletes old token

    @Test func savingWithAChangedHostDeletesTheOldHostsToken() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ in
                GitLabUser(id: 1, username: "diego", name: "Diego Pandolfo")
            }

            model.baseURLText = "https://gitlab.old.example.com"
            model.tokenText = "glpat-old"
            await model.verifyAndSave()
            #expect(tokenStore.tokens["gitlab.old.example.com"] == "glpat-old")

            model.baseURLText = "https://gitlab.new.example.com"
            model.tokenText = "glpat-new"
            await model.verifyAndSave()

            #expect(tokenStore.deletedHosts.contains("gitlab.old.example.com"))
            #expect(tokenStore.tokens["gitlab.old.example.com"] == nil)
            #expect(tokenStore.tokens["gitlab.new.example.com"] == "glpat-new")

            let config = GitLabAccountConfig(defaults: defaults)
            #expect(config.baseURL == URL(string: "https://gitlab.new.example.com"))
        }
    }

    @Test func savingTwiceWithTheSameHostDoesNotDeleteItsOwnToken() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ in
                GitLabUser(id: 1, username: "diego", name: "Diego Pandolfo")
            }

            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-first"
            await model.verifyAndSave()

            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-second"
            await model.verifyAndSave()

            #expect(tokenStore.deletedHosts.isEmpty)
            #expect(tokenStore.tokens["gitlab.example.com"] == "glpat-second")
        }
    }

    // MARK: - Remove token

    @Test func removeTokenClearsKeychainAndPersistedState() async {
        await withDefaults { defaults in
            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ in
                GitLabUser(id: 1, username: "diego", name: "Diego Pandolfo")
            }
            model.baseURLText = "https://gitlab.example.com"
            model.tokenText = "glpat-secret"
            await model.verifyAndSave()
            #expect(model.hasStoredToken == true)

            model.removeToken()

            #expect(tokenStore.deletedHosts.contains("gitlab.example.com"))
            #expect(tokenStore.tokens["gitlab.example.com"] == nil)
            #expect(model.hasStoredToken == false)
            #expect(model.status == .idle)

            let config = GitLabAccountConfig(defaults: defaults)
            #expect(config.username == nil)
            #expect(config.baseURL == nil)
        }
    }

    // MARK: - Reopen state

    @Test func reopeningWithPersistedConfigShowsSignedInState() async {
        await withDefaults { defaults in
            var config = GitLabAccountConfig()
            config.baseURL = URL(string: "https://gitlab.example.com")
            config.username = "diego"
            config.save(to: defaults)

            let tokenStore = FakeTokenStore()
            let model = makeModel(tokenStore: tokenStore, defaults: defaults) { _, _ in
                GitLabUser(id: 1, username: "diego", name: "Diego Pandolfo")
            }

            #expect(model.baseURLText == "https://gitlab.example.com")
            #expect(model.hasStoredToken == true)
            #expect(model.tokenText.isEmpty)
            guard case .success(let message) = model.status else {
                Issue.record("expected .success, got \(model.status)")
                return
            }
            #expect(message.contains("diego"))
        }
    }
}
