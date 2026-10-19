//
//  TokenStoreTests.swift
//  MyAppTests
//

import Foundation
import Testing
@testable import MyApp

@MainActor
struct TokenStoreTests {

    /// Each test gets its own disposable Keychain service so tests never
    /// collide with each other, with the real app's stored token, or
    /// leave items behind in the login Keychain between runs.
    private func makeStore() -> TokenStore {
        TokenStore(service: "\(AppIdentity.bundleIdentifier).tests.\(UUID().uuidString)")
    }

    @Test func saveAndReadToken() throws {
        let store = makeStore()
        defer { try? store.deleteToken(forHost: "gitlab.example.com") }

        try store.save(token: "glpat-abc123", forHost: "gitlab.example.com")
        let read = try store.readToken(forHost: "gitlab.example.com")

        #expect(read == "glpat-abc123")
    }

    @Test func overwritingExistingTokenUpdatesInPlace() throws {
        let store = makeStore()
        defer { try? store.deleteToken(forHost: "gitlab.example.com") }

        try store.save(token: "glpat-first", forHost: "gitlab.example.com")
        try store.save(token: "glpat-second", forHost: "gitlab.example.com")
        let read = try store.readToken(forHost: "gitlab.example.com")

        #expect(read == "glpat-second")
    }

    @Test func deleteRemovesToken() throws {
        let store = makeStore()

        try store.save(token: "glpat-abc123", forHost: "gitlab.example.com")
        try store.deleteToken(forHost: "gitlab.example.com")
        let read = try store.readToken(forHost: "gitlab.example.com")

        #expect(read == nil)
    }

    @Test func readingMissingTokenReturnsNilNotError() throws {
        let store = makeStore()

        let read = try store.readToken(forHost: "nonexistent.example.com")

        #expect(read == nil)
    }

    @Test func deletingMissingTokenDoesNotThrow() throws {
        let store = makeStore()

        try store.deleteToken(forHost: "nonexistent.example.com")
    }

    @Test func tokensForDifferentHostsAreIndependent() throws {
        let store = makeStore()
        defer {
            try? store.deleteToken(forHost: "a.example.com")
            try? store.deleteToken(forHost: "b.example.com")
        }

        try store.save(token: "token-a", forHost: "a.example.com")
        try store.save(token: "token-b", forHost: "b.example.com")

        #expect(try store.readToken(forHost: "a.example.com") == "token-a")
        #expect(try store.readToken(forHost: "b.example.com") == "token-b")
    }
}
