//
//  WidgetReloadDebouncerTests.swift
//  MyAppTests
//
//  MRT-041: bursts collapse into one reload; an isolated request still reloads promptly.
//

import Foundation
import Testing
@testable import MyApp

@MainActor
struct WidgetReloadDebouncerTests {

    private nonisolated static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDebouncer(sleeper: ManualSleeper, reloads: LockedBox<Int>) -> WidgetReloadDebouncer {
        WidgetReloadDebouncer(
            window: .seconds(3),
            sleep: { try await sleeper.sleep($0) },
            now: { Self.fixedDate },
            reload: { reloads.mutate { $0 += 1 } }
        )
    }

    @Test func burstOfRequestsCollapsesIntoOneReload() async {
        let sleeper = ManualSleeper()
        let reloads = LockedBox(0)
        let debouncer = makeDebouncer(sleeper: sleeper, reloads: reloads)

        for _ in 0..<10 { await debouncer.requestReload() }
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        #expect(sleeper.requested == [.seconds(3)], "one window for the whole burst")
        #expect(reloads.value == 0, "trailing edge: nothing fires before the window ends")

        sleeper.advance()
        #expect(await waitUntil { reloads.value == 1 })
        #expect(await debouncer.reloadCount == 1)
        #expect(await debouncer.coalescedRequestCount == 9)
        #expect(await debouncer.lastReloadAt == Self.fixedDate)
        #expect(await debouncer.hasPendingReload == false)
    }

    @Test func isolatedRequestReloadsAfterOneWindow() async {
        let sleeper = ManualSleeper()
        let reloads = LockedBox(0)
        let debouncer = makeDebouncer(sleeper: sleeper, reloads: reloads)

        await debouncer.requestReload()
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        #expect(sleeper.requested == [.seconds(3)])
        sleeper.advance()
        #expect(await waitUntil { reloads.value == 1 })
    }

    @Test func isolatedRequestFiresPromptlyOnRealClock() async {
        let reloads = LockedBox(0)
        let debouncer = WidgetReloadDebouncer(window: .milliseconds(20), reload: { reloads.mutate { $0 += 1 } })
        let start = ContinuousClock.now
        await debouncer.requestReload()
        #expect(await waitUntil { reloads.value == 1 })
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await debouncer.lastReloadAt != nil)
    }

    @Test func burstsSeparatedByMoreThanTheWindowReloadTwice() async {
        let sleeper = ManualSleeper()
        let reloads = LockedBox(0)
        let debouncer = makeDebouncer(sleeper: sleeper, reloads: reloads)

        for _ in 0..<3 { await debouncer.requestReload() }
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        sleeper.advance()
        #expect(await waitUntil { reloads.value == 1 })

        for _ in 0..<3 { await debouncer.requestReload() }
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        sleeper.advance()
        #expect(await waitUntil { reloads.value == 2 })
        #expect(sleeper.requested.count == 2)
    }

    @Test func cancelDropsPendingReload() async {
        let sleeper = ManualSleeper()
        let reloads = LockedBox(0)
        let debouncer = makeDebouncer(sleeper: sleeper, reloads: reloads)

        await debouncer.requestReload()
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        await debouncer.cancel()
        #expect(await waitUntil { sleeper.pendingCount == 0 })
        #expect(reloads.value == 0)
        #expect(await debouncer.hasPendingReload == false)
    }
}
