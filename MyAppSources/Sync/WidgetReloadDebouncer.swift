//
//  WidgetReloadDebouncer.swift
//  MyApp
//
//  MRT-041: collapses bursts of "snapshot changed" signals into a single
//  `WidgetCenter.shared.reloadTimelines(ofKind:)` call, protecting the widget's limited daily
//  reload budget (PLAN.md → Refresh strategy & widget budget).
//
//  Semantics: **trailing edge, fixed window.** The first `requestReload()` opens a window of
//  `window` length; every further request inside that window is absorbed; when the window
//  elapses exactly one reload fires. The window is *not* extended by later requests, so a
//  steady stream of requests can never starve the widget — worst-case latency is `window`.
//  A request arriving after the reload fired opens a new window.
//
//  Why not leading edge (fire immediately, then suppress)? A burst would then cost two
//  reloads (leading + trailing, otherwise the last change in the burst is lost), and the only
//  benefit is ~3 s lower latency on a widget whose data is already up to one poll interval old.
//  Trailing-only gives exactly one reload per burst, which is the whole point.
//

import Foundation
import WidgetKit

actor WidgetReloadDebouncer {

    static let defaultWindow: Duration = .seconds(3)

    /// The live reload: all timelines of the MR widget kind.
    static let reloadMergeRequestWidgets: @Sendable () async -> Void = {
        await MainActor.run {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.mergeRequests)
        }
    }

    let window: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let reload: @Sendable () async -> Void

    private var pending: Task<Void, Never>?

    /// When the last reload actually fired (PLAN.md → Risks: surface it in Settings so a broken
    /// debounce is diagnosable). `nil` until the first reload.
    private(set) var lastReloadAt: Date?
    /// Number of reloads actually fired.
    private(set) var reloadCount = 0
    /// Number of `requestReload()` calls absorbed into an already-open window.
    private(set) var coalescedRequestCount = 0

    /// - Parameters:
    ///   - window: collapse window (default 3 s).
    ///   - sleep: injectable for tests; must throw on task cancellation like `Task.sleep`.
    ///   - now: timestamp source for `lastReloadAt`.
    ///   - reload: the actual reload; defaults to `WidgetCenter` for `WidgetKinds.mergeRequests`.
    init(
        window: Duration = WidgetReloadDebouncer.defaultWindow,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        reload: @escaping @Sendable () async -> Void = WidgetReloadDebouncer.reloadMergeRequestWidgets
    ) {
        self.window = window
        self.sleep = sleep
        self.now = now
        self.reload = reload
    }

    /// Asks for a widget reload. Returns immediately; the reload fires at the end of the
    /// current window (opening one if none is open).
    func requestReload() {
        guard pending == nil else {
            coalescedRequestCount += 1
            return
        }
        pending = Task {
            do {
                try await sleep(window)
            } catch {
                return // cancelled
            }
            await fire()
        }
    }

    /// Whether a reload is scheduled but hasn't fired yet.
    var hasPendingReload: Bool { pending != nil }

    /// Drops a pending reload without firing it (e.g. on app quit).
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func fire() async {
        // Clear first: a request arriving while `reload` runs opens a fresh window instead of
        // being swallowed by this (already firing) one.
        pending = nil
        reloadCount += 1
        lastReloadAt = now()
        await reload()
    }
}
