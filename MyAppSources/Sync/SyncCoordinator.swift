//
//  SyncCoordinator.swift
//  MyApp
//
//  MRT-040 (polling scheduler) + the sync half of MRT-061 (manual refresh) and MRT-062
//  (degraded state for the menu bar icon). Owns the poll loop, runs each fetch through the
//  assembler, persists the result to the App Group file and asks the debounced widget
//  reloader (MRT-041) for a reload when warranted. No UI.
//
//  ## Loop
//  One `Task` running `fetch → sleep(nextDelay)` forever. `nextDelay` re-reads
//  `PollingPreferences` every cycle, so an interval change applies on the next cycle (or
//  immediately via `settingsDidChange()`). Fetches go through `fetchCoalesced()`: if one is
//  already in flight (poll + "Refresh now" racing), the second caller awaits the first
//  instead of starting another — one code path, one error handling, never two concurrent
//  fetches.
//
//  ## Clock: ContinuousClock
//  `Task.sleep`/`ContinuousClock` keeps counting while the Mac sleeps; `SuspendingClock` does
//  not. We pause explicitly on `willSleep` (cancel the loop) and fetch `wakeFetchDelay`
//  after `didWake`, so normally neither matters. The choice matters when a notification is
//  missed (e.g. a dark wake, or sleep before the observer subscribed): with ContinuousClock
//  an overdue deadline fires right after wake, which is what we want for a "how fresh is
//  this" poller; SuspendingClock would wait out the remainder of the interval after wake,
//  showing stale data for up to a full interval.
//
//  ## Write vs. reload policy
//  - Every successful poll writes the file (cheap atomic rename) with a fresh
//    `lastFetchedAt` and `lastError = nil`, so any reader (popup, widget on its next
//    natural timeline refresh) sees an honest "as of".
//  - Widget reloads (budgeted) are requested only when `SnapshotDiffing` reports a
//    user-visible change, or — at most every `stalenessReloadInterval` (30 min) — to
//    advance the widget's "as of" when nothing else changed. The first successful poll after
//    launch also reloads once (the widget may be showing data from before the app quit).
//    Keep MRT-056's staleness threshold above 30 min, or it will flag data as stale that
//    the host app has in fact re-confirmed.
//  - Failures: `store.recordFailure(message)` keeps the last good MRs and the old
//    `lastFetchedAt`, only setting `lastError`; a reload is requested only when the error
//    message changed (a repeat of the same error doesn't change pixels).
//
//  ## Backoff
//  Consecutive failures (any kind) stretch the next delay to interval × 2^(n-1), capped at
//  5× — 1×, 2×, 4×, 5×, 5×… — so a VPN-off afternoon or a revoked token doesn't hammer the
//  instance, while recovery is still noticed within ≤ 5 intervals (≤ 75 min at the max
//  interval). A 429's `Retry-After` is honored (capped at 1 h) if longer. Success resets.
//  `refreshNow()` and `settingsDidChange()` bypass the backoff (explicit user intent).
//

import Foundation
import Observation
import os

// MARK: - Status

/// Why the last fetch failed, as far as the menu bar icon / popup care.
nonisolated struct SyncProblem: Sendable, Equatable {
    nonisolated enum Kind: Sendable, Equatable {
        /// 401/403 — token invalid, expired, revoked, or lacking scope.
        case authentication
        /// Offline / VPN down / DNS / timeout.
        case unreachable
        /// Certificate trust or handshake failure (message from `TLSDiagnosis`).
        case tls
        /// 429.
        case rateLimited
        /// 5xx, unexpected status, undecodable response.
        case serverError
        /// Anything else (e.g. Keychain read failure).
        case other
    }

    let kind: Kind
    /// User-presentable, secret-free. Also what gets persisted as `SnapshotStore.lastError`.
    let message: String
}

nonisolated enum SyncStatus: Sendable, Equatable {
    /// Not started, or started but no fetch has finished yet.
    case idle
    /// No base URL or no token — nothing to poll. No network is used.
    case notConfigured
    /// Last fetch succeeded.
    case ok
    /// Last fetch failed; the snapshot still holds the last good data.
    case degraded(SyncProblem)

    var problem: SyncProblem? {
        if case .degraded(let problem) = self { return problem }
        return nil
    }
}

// MARK: - Coordinator

@Observable
@MainActor
final class SyncCoordinator {

    // MARK: Observable state (for the popup / menu bar icon / settings)

    /// Latest snapshot (as persisted). Initially whatever is on disk.
    private(set) var snapshot: SnapshotStore
    /// `true` while a fetch is running (scheduled or manual) — MRT-061's progress indicator.
    private(set) var isRefreshing = false
    /// When the last fetch attempt (successful or not) started.
    private(set) var lastAttemptAt: Date?
    private(set) var status: SyncStatus = .idle
    /// When the debouncer last actually called `reloadTimelines` (PLAN.md → Risks: show in
    /// Settings for debugging the widget budget).
    private(set) var lastWidgetReloadAt: Date?
    /// Whether `start()` has been called (and not `stop()`).
    private(set) var isRunning = false

    // MARK: Internals

    @ObservationIgnored private let deps: SyncDependencies
    @ObservationIgnored let reloadDebouncer: WidgetReloadDebouncer

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var powerTask: Task<Void, Never>?
    @ObservationIgnored private var currentFetch: (id: UInt64, task: Task<Void, Never>)?
    @ObservationIgnored private var fetchCounter: UInt64 = 0
    @ObservationIgnored private var isSystemAsleep = false

    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var retryAfter: Duration?
    /// Username resolved by `GET /user`, keyed by host — skips that request on later polls.
    @ObservationIgnored private var cachedUsername: (host: String, username: String)?
    /// Host whose TLS preflight has run this launch (verified, or non-TLS inconclusive).
    @ObservationIgnored private var preflightedHost: String?
    @ObservationIgnored private var lastReloadRequestAt: Date?

    /// Test instrumentation: reload requests handed to the debouncer, and callers that
    /// joined an in-flight fetch instead of starting one.
    @ObservationIgnored private(set) var widgetReloadRequestCount = 0
    @ObservationIgnored private(set) var joinedInFlightFetchCount = 0

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "Sync")

    init(dependencies: SyncDependencies) {
        self.deps = dependencies
        self.snapshot = dependencies.store.read().snapshotOrEmpty
        let rawReload = dependencies.reloadWidgets
        // The debouncer can't hold `self` strongly (it's owned by `self`), and the timestamp
        // has to land on the main actor for observation.
        let ref = WeakCoordinatorRef()
        let now = dependencies.now
        self.reloadDebouncer = WidgetReloadDebouncer(
            window: dependencies.tuning.reloadDebounceWindow,
            sleep: dependencies.debounceSleep,
            now: now,
            reload: {
                await rawReload()
                let firedAt = now()
                await MainActor.run { ref.coordinator?.lastWidgetReloadAt = firedAt }
            }
        )
        ref.coordinator = self
    }

    /// Production instance (App Group store, Keychain, `WidgetCenter`, `NSWorkspace`).
    static func live() -> SyncCoordinator {
        SyncCoordinator(dependencies: .live())
    }

    // MARK: Lifecycle

    /// Starts polling (fetches immediately) and observing sleep/wake. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let events = deps.powerEvents()
        powerTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        restartLoop(.fetchAfter(.zero))
    }

    /// Stops polling: cancels the loop, the sleep/wake observer and any in-flight fetch (its
    /// result is discarded). A widget reload already queued in the debouncer is left to fire
    /// (if the process lives that long) — the file is already written, so the widget should
    /// catch up. Safe to call repeatedly; `start()` may be called again afterwards. Call from
    /// `applicationWillTerminate`.
    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        powerTask?.cancel()
        powerTask = nil
        cancelInFlightFetch()
    }

    // MARK: Triggers

    /// MRT-061 "Refresh now": an out-of-cycle fetch through the same path (and error
    /// handling) as a scheduled poll. Joins an in-flight fetch instead of starting a second
    /// one. Afterwards the cadence restarts from now (no scheduled poll right after a manual
    /// one) and any failure backoff is bypassed. Works even when not started.
    func refreshNow() async {
        await fetchCoalesced()
        if isRunning, !isSystemAsleep {
            restartLoop(.sleepFirst)
        }
    }

    /// Call after any saved settings change (account/token, interval, tracked roles). Drops
    /// cached per-account state and backoff, abandons an in-flight fetch made with the old
    /// settings, and fetches again after a short delay (collapsing multi-field saves).
    func settingsDidChange() {
        consecutiveFailures = 0
        retryAfter = nil
        cachedUsername = nil
        preflightedHost = nil
        guard isRunning else { return }
        cancelInFlightFetch()
        restartLoop(.fetchAfter(deps.tuning.settingsChangeFetchDelay))
    }

    // MARK: Loop

    private enum LoopStart {
        case fetchAfter(Duration)
        case sleepFirst
    }

    private func restartLoop(_ start: LoopStart) {
        loopTask?.cancel()
        loopTask = nil
        guard isRunning, !isSystemAsleep else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop(start)
        }
    }

    private func runLoop(_ start: LoopStart) async {
        do {
            switch start {
            case .fetchAfter(let delay):
                if delay > .zero { try await deps.sleep(delay) }
            case .sleepFirst:
                try await deps.sleep(nextDelay())
            }
            while !Task.isCancelled {
                await fetchCoalesced()
                try Task.checkCancellation()
                try await deps.sleep(nextDelay())
            }
        } catch {
            // Cancelled (stop / sleep / restart) — exit quietly.
        }
    }

    /// Delay until the next scheduled poll: the configured interval, stretched by failure
    /// backoff and `Retry-After`.
    func nextDelay() -> Duration {
        let interval = deps.loadPreferences().interval
        guard consecutiveFailures > 0 else { return interval }
        let multiplier = min(1 << min(consecutiveFailures - 1, 16), max(1, deps.tuning.maxBackoffMultiplier))
        let backoff = interval * multiplier
        if let retryAfter {
            return max(backoff, min(retryAfter, deps.tuning.maxRetryAfter))
        }
        return backoff
    }

    private func handle(_ event: SystemPowerEvent) {
        switch event {
        case .willSleep:
            isSystemAsleep = true
            loopTask?.cancel()
            loopTask = nil
            // A fetch spanning sleep would only fail with a spurious "unreachable".
            cancelInFlightFetch()
        case .didWake:
            isSystemAsleep = false
            restartLoop(.fetchAfter(deps.tuning.wakeFetchDelay))
        }
    }

    // MARK: Fetch

    private func fetchCoalesced() async {
        if let currentFetch {
            joinedInFlightFetchCount += 1
            await currentFetch.task.value
            return
        }
        fetchCounter += 1
        let id = fetchCounter
        isRefreshing = true
        let task = Task { [weak self] in
            await self?.performFetch()
            self?.fetchFinished(id)
        }
        currentFetch = (id, task)
        await task.value
    }

    private func fetchFinished(_ id: UInt64) {
        guard currentFetch?.id == id else { return }
        currentFetch = nil
        isRefreshing = false
    }

    private func cancelInFlightFetch() {
        currentFetch?.task.cancel()
        currentFetch = nil
        isRefreshing = false
    }

    /// One fetch. Never throws; on cancellation leaves all state untouched.
    private func performFetch() async {
        lastAttemptAt = deps.now()
        let preferences = deps.loadPreferences()

        let account: SyncAccount
        switch deps.loadAccount() {
        case .notConfigured:
            status = .notConfigured
            return
        case .unavailable(let message):
            recordFailure(SyncProblem(kind: .other, message: message))
            return
        case .configured(let configured):
            account = configured
        }
        let host = account.displayHost

        // MRT-025 first-run TLS check, once per host per launch (it's a no-op for a host
        // verified on an earlier launch). A TLS verdict blocks the fetch with the precise
        // message; an inconclusive (offline) probe lets the real fetch report the problem.
        if preflightedHost != host {
            let result = await deps.tlsPreflight(account.baseURL)
            guard !Task.isCancelled else { return }
            switch result {
            case .ok, .otherFailure:
                preflightedHost = host
            case .tlsFailure(let diagnosis):
                recordFailure(SyncProblem(kind: .tls, message: diagnosis.message))
                return
            }
        }

        let username = account.username ?? (cachedUsername?.host == host ? cachedUsername?.username : nil)
        let assembler = deps.makeAssembler(account)
        let previous = snapshot.mergeRequests
        do {
            let result = try await assembler.assemble(
                roles: preferences.trackedRoles,
                username: username,
                previous: previous
            )
            guard !Task.isCancelled else { return }
            if let resolved = result.username {
                cachedUsername = (host, resolved)
            }
            if !result.failures.isEmpty {
                Self.logger.info("Poll finished with \(result.failures.count, privacy: .public) partial per-MR failure(s)")
            }
            recordSuccess(result.snapshots)
        } catch {
            guard !Task.isCancelled else { return }
            let problem = await problem(for: error, account: account)
            guard !Task.isCancelled else { return }
            recordFailure(problem)
        }
    }

    private func recordSuccess(_ mergeRequests: [MergeRequestSnapshot]) {
        let now = deps.now()
        let new = SnapshotStore(mergeRequests: mergeRequests, lastFetchedAt: now, lastError: nil)
        let diff = SnapshotDiffing.diff(previous: snapshot, new: new)
        do {
            try deps.store.write(new)
        } catch {
            Self.logger.error("Snapshot write failed; widget will show older data")
        }
        snapshot = new
        status = .ok
        consecutiveFailures = 0
        retryAfter = nil

        let stalenessDue = lastReloadRequestAt.map {
            now.timeIntervalSince($0) >= deps.tuning.stalenessReloadInterval.timeInterval
        } ?? true
        if diff.hasUserVisibleChanges || stalenessDue {
            requestWidgetReload(at: now)
        }
    }

    private func recordFailure(_ problem: SyncProblem) {
        let errorChanged = snapshot.lastError != problem.message
        do {
            try deps.store.recordFailure(problem.message)
        } catch {
            Self.logger.error("Recording fetch failure to snapshot file failed")
        }
        snapshot.lastError = problem.message
        status = .degraded(problem)
        consecutiveFailures += 1
        if errorChanged {
            requestWidgetReload(at: deps.now())
        }
    }

    private func requestWidgetReload(at date: Date) {
        lastReloadRequestAt = date
        widgetReloadRequestCount += 1
        let debouncer = reloadDebouncer
        Task { await debouncer.requestReload() }
    }

    // MARK: Error mapping

    private func problem(for error: GitLabAPIError, account: SyncAccount) async -> SyncProblem {
        let host = account.displayHost
        retryAfter = nil
        switch error {
        case .unauthorized:
            return SyncProblem(kind: .authentication, message: "GitLab at \(host) rejected the access token. It may be expired or revoked — update it in Settings.")
        case .forbidden:
            return SyncProblem(kind: .authentication, message: "The access token for \(host) lacks permission. It needs the read_api scope.")
        case .rateLimited(let seconds):
            if let seconds { retryAfter = .seconds(seconds) }
            return SyncProblem(kind: .rateLimited, message: "GitLab at \(host) is rate limiting this app. It will retry later.")
        case .transport(let code):
            if TLSDiagnostics.category(for: code) != .notTLSRelated {
                let diagnosis = await deps.tlsRecheck(error, account.baseURL)
                    ?? TLSDiagnostics.diagnose(error, baseURL: account.baseURL)
                return SyncProblem(kind: .tls, message: diagnosis.message)
            }
            return SyncProblem(kind: .unreachable, message: "Can't reach \(host). Check your network or VPN connection.")
        case .server(let status):
            return SyncProblem(kind: .serverError, message: "GitLab at \(host) returned a server error (HTTP \(status)).")
        case .unexpectedStatus(let status):
            return SyncProblem(kind: .serverError, message: "GitLab at \(host) returned an unexpected response (HTTP \(status)).")
        case .notFound:
            return SyncProblem(kind: .serverError, message: "GitLab at \(host) returned 'not found' — check the GitLab URL in Settings.")
        case .decoding:
            return SyncProblem(kind: .serverError, message: "GitLab at \(host) sent a response this app couldn't read.")
        case .invalidURL:
            return SyncProblem(kind: .other, message: "The GitLab URL in Settings is invalid.")
        }
    }
}

/// Weak back-reference handed to the debouncer's reload closure (the coordinator owns the
/// debouncer, so a strong capture would be a cycle). Main-actor isolated, hence Sendable.
@MainActor
private final class WeakCoordinatorRef {
    weak var coordinator: SyncCoordinator?
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
