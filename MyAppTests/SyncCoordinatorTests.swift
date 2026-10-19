//
//  SyncCoordinatorTests.swift
//  MyAppTests
//
//  MRT-040 poll loop / MRT-061 manual refresh, driven by a `ManualSleeper` so no test waits
//  out a real poll interval.
//

import Foundation
import Testing
@testable import MyApp

@MainActor
final class SyncHarness {
    let sleeper = ManualSleeper()
    let assembler: ScriptedAssembler
    let preferences = LockedBox(PollingPreferences.default)
    let account: LockedBox<SyncAccountLookup>
    let preflightResult = LockedBox(TLSPreflightResult.ok)
    let factoryCalls = LockedBox(0)
    let preflightCalls = LockedBox(0)
    let recheckCalls = LockedBox(0)
    let reloads = LockedBox(0)
    let clockTick = LockedBox(0)
    let store: SnapshotFileStore
    let directory: URL
    let powerContinuation: AsyncStream<SystemPowerEvent>.Continuation
    let coordinator: SyncCoordinator

    nonisolated static let baseURL = URL(string: "https://gitlab.example.com")!
    nonisolated static let tlsDiagnosis = TLSDiagnostics.diagnose(code: .serverCertificateUntrusted, host: "gitlab.example.com", issuer: "Corp Root CA")

    init(_ steps: [ScriptedAssembler.Step], gated: Bool = false, configured: Bool = true) {
        assembler = ScriptedAssembler(steps, gated: gated)
        account = LockedBox(configured
            ? .configured(SyncAccount(baseURL: Self.baseURL, token: "glpat-test", username: nil))
            : .notConfigured)
        directory = FileManager.default.temporaryDirectory.appending(path: "SyncCoordinatorTests-\(UUID().uuidString)")
        store = SnapshotFileStore(fileURL: directory.appending(path: "snapshot.json"))
        let (stream, continuation) = AsyncStream<SystemPowerEvent>.makeStream()
        powerContinuation = continuation

        let sleeper = sleeper, assembler = assembler, preferences = preferences, account = account
        let factoryCalls = factoryCalls, preflightCalls = preflightCalls, recheckCalls = recheckCalls
        let preflightResult = preflightResult, reloads = reloads, clockTick = clockTick
        var tuning = SyncTuning()
        tuning.reloadDebounceWindow = .milliseconds(10)

        let deps = SyncDependencies(
            loadAccount: { account.value },
            loadPreferences: { preferences.value },
            makeAssembler: { _ in
                factoryCalls.mutate { $0 += 1 }
                return assembler
            },
            tlsPreflight: { _ in
                preflightCalls.mutate { $0 += 1 }
                return preflightResult.value
            },
            tlsRecheck: { _, _ in
                recheckCalls.mutate { $0 += 1 }
                return SyncHarness.tlsDiagnosis
            },
            store: store,
            now: {
                // Strictly increasing so `lastFetchedAt` visibly advances between polls.
                var tick = 0
                clockTick.mutate { $0 += 1; tick = $0 }
                return Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(tick))
            },
            sleep: { try await sleeper.sleep($0) },
            powerEvents: { stream },
            reloadWidgets: { reloads.mutate { $0 += 1 } },
            debounceSleep: { try await ContinuousClock().sleep(for: $0) },
            tuning: tuning
        )
        coordinator = SyncCoordinator(dependencies: deps)
    }

    func storedSnapshot() -> SnapshotStore? {
        if case .snapshot(let snapshot) = store.read() { return snapshot }
        return nil
    }

    /// Waits until fetch #`count` finished and the loop is parked in its next sleep.
    func waitForCycle(_ count: Int) async -> Bool {
        await waitUntil {
            self.assembler.callCount == count && !self.coordinator.isRefreshing && self.sleeper.pendingCount == 1
        }
    }

    func tearDown() {
        coordinator.stop()
        powerContinuation.finish()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct SyncCoordinatorTests {

    private let mrA = makeSyncTestMR(iid: 1, title: "A")
    private let mrB = makeSyncTestMR(iid: 2, title: "B")

    @Test func notConfiguredSetsStatusWithoutFetching() async {
        let h = SyncHarness([.success([])], configured: false)
        defer { h.tearDown() }
        h.coordinator.start()

        #expect(await waitUntil { h.coordinator.status == .notConfigured && h.sleeper.pendingCount == 1 })
        #expect(h.factoryCalls.value == 0)
        #expect(h.preflightCalls.value == 0)
        #expect(h.assembler.callCount == 0)
        #expect(h.store.read() == .noSnapshotYet)
        #expect(h.coordinator.lastAttemptAt != nil)
    }

    @Test func successfulFetchWritesStoreAndReloadsWidget() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()

        #expect(await h.waitForCycle(1))
        #expect(h.coordinator.status == .ok)
        let stored = h.storedSnapshot()
        #expect(stored?.mergeRequests == [mrA])
        #expect(stored?.lastError == nil)
        #expect(h.coordinator.snapshot == stored)
        #expect(h.coordinator.widgetReloadRequestCount == 1)
        #expect(h.preflightCalls.value == 1)
        #expect(h.sleeper.pendingDurations == [.seconds(PollingPreferences.defaultIntervalSeconds)])

        // Debounced (10 ms window) reload actually fires, and the timestamp is surfaced.
        #expect(await waitUntil { h.reloads.value == 1 && h.coordinator.lastWidgetReloadAt != nil })
    }

    @Test func noOpPollWritesFreshTimestampButDoesNotReload() async throws {
        let h = SyncHarness([.success([mrA]), .success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        let first = try #require(h.storedSnapshot())

        h.sleeper.advance()
        #expect(await h.waitForCycle(2))
        let second = try #require(h.storedSnapshot())

        #expect(second.lastFetchedAt > first.lastFetchedAt, "every successful poll persists lastFetchedAt")
        #expect(second.mergeRequests == first.mergeRequests)
        #expect(h.coordinator.widgetReloadRequestCount == 1, "no user-visible change → no reload")
        #expect(h.preflightCalls.value == 1, "TLS preflight only on the first fetch")
        // Username resolved by the first assembly is reused (skips GET /user).
        #expect(h.assembler.calls.map(\.username) == [nil, "diego"])
        #expect(h.assembler.calls[1].previousIDs == [mrA.id])
    }

    @Test func failureKeepsLastGoodDataAndLoopRecovers() async throws {
        let h = SyncHarness([.success([mrA]), .failure(.transport(.notConnectedToInternet)), .success([mrA, mrB])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        let good = try #require(h.storedSnapshot())

        h.sleeper.advance()
        #expect(await h.waitForCycle(2))
        let failed = try #require(h.storedSnapshot())
        #expect(failed.mergeRequests == [mrA], "last good MRs preserved")
        #expect(failed.lastFetchedAt == good.lastFetchedAt, "lastFetchedAt = last *successful* fetch")
        #expect(failed.lastError != nil)
        #expect(h.coordinator.status.problem?.kind == .unreachable)
        #expect(h.coordinator.snapshot.mergeRequests == [mrA])
        #expect(h.coordinator.widgetReloadRequestCount == 2, "error appeared → reload")
        #expect(h.sleeper.pendingDurations == [.seconds(90)], "first failure: no stretch yet")

        h.sleeper.advance()
        #expect(await h.waitForCycle(3))
        let recovered = try #require(h.storedSnapshot())
        #expect(h.coordinator.status == .ok)
        #expect(recovered.mergeRequests == [mrA, mrB])
        #expect(recovered.lastError == nil)
        #expect(h.coordinator.widgetReloadRequestCount == 3)
    }

    @Test func repeatedFailuresBackOffUpToFiveTimesInterval() async {
        let h = SyncHarness([.failure(.server(status: 502))])
        defer { h.tearDown() }
        h.coordinator.start()
        for cycle in 1...5 {
            #expect(await h.waitForCycle(cycle))
            if cycle < 5 { h.sleeper.advance() }
        }
        #expect(h.sleeper.requested == [90, 180, 360, 450, 450].map { Duration.seconds($0) })
        #expect(h.coordinator.widgetReloadRequestCount == 1, "same error repeated → one reload")
        #expect(h.coordinator.status.problem?.kind == .serverError)
    }

    @Test func rateLimitHonorsRetryAfter() async {
        let h = SyncHarness([.failure(.rateLimited(retryAfter: 600))])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        #expect(h.sleeper.pendingDurations == [.seconds(600)])
        #expect(h.coordinator.status.problem?.kind == .rateLimited)
    }

    @Test func authFailureIsDegradedAuthentication() async {
        let h = SyncHarness([.failure(.unauthorized)])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        #expect(h.coordinator.status.problem?.kind == .authentication)
        #expect(h.storedSnapshot()?.lastError == h.coordinator.status.problem?.message)
    }

    @Test func tlsTransportFailureUsesRecheckDiagnosis() async {
        let h = SyncHarness([.failure(.transport(.serverCertificateUntrusted))])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        #expect(h.recheckCalls.value == 1)
        #expect(h.coordinator.status == .degraded(SyncProblem(kind: .tls, message: SyncHarness.tlsDiagnosis.message)))
    }

    @Test func tlsPreflightFailureBlocksFetch() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.preflightResult.value = .tlsFailure(SyncHarness.tlsDiagnosis)
        h.coordinator.start()
        #expect(await waitUntil { h.coordinator.status.problem != nil && h.sleeper.pendingCount == 1 })
        #expect(h.assembler.callCount == 0)
        #expect(h.coordinator.status.problem?.kind == .tls)

        // Fixed (e.g. CA installed) → next cycle preflights again and fetches.
        h.preflightResult.value = .ok
        h.sleeper.advance()
        #expect(await h.waitForCycle(1))
        #expect(h.coordinator.status == .ok)
        #expect(h.preflightCalls.value == 2)
    }

    @Test func refreshNowDuringInFlightFetchIsCoalesced() async {
        let h = SyncHarness([.success([mrA])], gated: true)
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await waitUntil { h.assembler.callCount == 1 && h.coordinator.isRefreshing })

        let manual = Task { await h.coordinator.refreshNow() }
        #expect(await waitUntil { h.coordinator.joinedInFlightFetchCount == 1 })
        h.assembler.release()
        await manual.value

        #expect(h.assembler.callCount == 1, "one assemble for poll + manual refresh")
        #expect(h.coordinator.status == .ok)
        #expect(await waitUntil { h.sleeper.pendingCount == 1 }, "cadence resumes after manual refresh")
    }

    @Test func refreshNowRunsOutOfCycleFetch() async {
        let h = SyncHarness([.success([mrA]), .success([mrA, mrB])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))

        await h.coordinator.refreshNow()
        #expect(h.assembler.callCount == 2)
        #expect(h.coordinator.snapshot.mergeRequests == [mrA, mrB])
        // The cadence restarts from the manual fetch: exactly one sleep pending.
        #expect(await waitUntil { h.sleeper.pendingCount == 1 })
    }

    @Test func refreshNowWorksWhenNotStarted() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        await h.coordinator.refreshNow()
        #expect(h.coordinator.status == .ok)
        #expect(h.sleeper.pendingCount == 0, "no loop started")
        #expect(h.coordinator.isRunning == false)
    }

    @Test func intervalChangeIsPickedUpNextCycle() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))
        #expect(h.sleeper.pendingDurations == [.seconds(90)])

        h.preferences.value = PollingPreferences(intervalSeconds: 300, trackedRoles: [.reviewer])
        h.sleeper.advance()
        #expect(await h.waitForCycle(2))
        #expect(h.sleeper.pendingDurations == [.seconds(300)])
        #expect(h.assembler.calls[1].roles == [.reviewer], "roles also re-read per cycle")
    }

    @Test func settingsDidChangeFetchesSoon() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))

        h.coordinator.settingsDidChange()
        #expect(await waitUntil { h.sleeper.pendingDurations == [.seconds(1)] })
        h.sleeper.advance()
        #expect(await h.waitForCycle(2))
        #expect(h.preflightCalls.value == 2, "account may have changed → preflight again")
    }

    @Test func stopCancelsLoopCleanly() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))

        h.coordinator.stop()
        #expect(h.coordinator.isRunning == false)
        #expect(await waitUntil { h.sleeper.pendingCount == 0 }, "pending sleep cancelled")
        h.sleeper.advance()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.assembler.callCount == 1)
    }

    @Test func stopDuringInFlightFetchDiscardsResult() async {
        let h = SyncHarness([.success([mrA])], gated: true)
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await waitUntil { h.assembler.callCount == 1 && h.coordinator.isRefreshing })

        h.coordinator.stop()
        #expect(h.coordinator.isRefreshing == false)
        h.assembler.release()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.coordinator.status == .idle)
        #expect(h.store.read() == .noSnapshotYet)
        #expect(h.coordinator.widgetReloadRequestCount == 0)
        #expect(h.sleeper.pendingCount == 0)
    }

    @Test func sleepPausesAndWakeTriggersPromptFetch() async {
        let h = SyncHarness([.success([mrA])])
        defer { h.tearDown() }
        h.coordinator.start()
        #expect(await h.waitForCycle(1))

        h.powerContinuation.yield(.willSleep)
        #expect(await waitUntil { h.sleeper.pendingCount == 0 }, "poll paused on sleep")

        h.powerContinuation.yield(.didWake)
        #expect(await waitUntil { h.sleeper.pendingDurations == [.seconds(5)] }, "short wake delay, not a full interval")
        h.sleeper.advance()
        #expect(await h.waitForCycle(2))
        #expect(h.sleeper.pendingDurations == [.seconds(90)], "cadence resumes")
    }
}
