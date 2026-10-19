//
//  MyAppTests.swift
//  MyAppTests
//
//  Created by Pandolfo Diego on 13.10.26.
//

import Testing
@testable import MyApp

@MainActor
struct MyAppTests {

    /// `APP_GROUP_ID` from Config/App.xcconfig must reach the code via Info.plist, and the
    /// entitlement expanded from the same setting must make the container resolvable.
    @Test func appGroupIdentifierComesFromConfigAndResolves() {
        #expect(AppGroup.identifier.hasPrefix("group."))
        #expect(AppGroup.containerURL != nil)
    }

    @Test func bundleIdentifierComesFromConfig() {
        #expect(!AppIdentity.bundleIdentifier.isEmpty)
        #expect(AppIdentity.bundleIdentifier == TokenStore.defaultService)
    }

}
