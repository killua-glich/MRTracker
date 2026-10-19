//
//  SyncTestSupport.swift
//  MyAppTests
//
//  Fakes for MRT-040/041 tests: a hand-driven sleeper (no real-time waits for poll
//  intervals), a scriptable/gateable assembler, and a lock-protected box.
//

import Foundation
import Synchronization
@testable import MyApp

/// Thread-safe mutable value usable from `@Sendable` closures.
nonisolated final class LockedBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) {
        storage.withLock { body(&$0) }
    }
}

/// A sleep that only returns when the test calls `advance()`. Honors task cancellation
/// (throws `CancellationError`, like `Task.sleep`).
@MainActor
final class ManualSleeper {
    private var pending: [Int: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var nextID = 0
    /// Every duration ever requested, in order.
    private(set) var requested: [Duration] = []

    var pendingCount: Int { pending.count }
    var pendingDurations: [Duration] {
        pending.sorted { $0.key < $1.key }.map(\.value.duration)
    }

    func sleep(_ duration: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = (duration, continuation)
                requested.append(duration)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Resumes every pending sleep.
    func advance() {
        let all = pending
        pending = [:]
        for entry in all.values { entry.continuation.resume() }
    }

    private func cancel(_ id: Int) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

/// `SnapshotAssembling` fake returning scripted results in order (last one repeats), with
/// an optional gate that blocks calls until `release()`.
nonisolated final class ScriptedAssembler: SnapshotAssembling, Sendable {
    enum Step: Sendable {
        case success([MergeRequestSnapshot], username: String? = "diego")
        case failure(GitLabAPIError)
    }

    struct Call: Sendable {
        var roles: Set<MRRole>
        var username: String?
        var previousIDs: [String]
    }

    private struct State {
        var steps: [Step]
        var calls: [Call] = []
        var gated: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ steps: [Step], gated: Bool = false) {
        state = Mutex(State(steps: steps, gated: gated))
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var callCount: Int { state.withLock { $0.calls.count } }

    func release() {
        let waiters = state.withLock { state in
            state.gated = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func assemble(
        roles: Set<MRRole>,
        username: String?,
        previous: [MergeRequestSnapshot]
    ) async throws(GitLabAPIError) -> AssemblyResult {
        let step: Step = state.withLock { state in
            state.calls.append(Call(roles: roles, username: username, previousIDs: previous.map(\.id)))
            return state.steps.count > 1 ? state.steps.removeFirst() : state.steps[0]
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.gated {
                    state.waiters.append(continuation)
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
        switch step {
        case .success(let snapshots, let username):
            return AssemblyResult(snapshots: snapshots, failures: [], username: username)
        case .failure(let error):
            throw error
        }
    }
}

/// Polls `condition` (1 ms steps) until true or ~2 s elapse.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

nonisolated func makeSyncTestMR(iid: Int, title: String = "MR", pipeline: PipelineStatus? = .success) -> MergeRequestSnapshot {
    MergeRequestSnapshot(
        projectId: 42,
        projectPath: "group/backend-api",
        iid: iid,
        title: title,
        webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/\(iid)")!,
        sourceBranch: "feature/\(iid)",
        targetBranch: "main",
        roles: [.author],
        isDraft: false,
        pipelineStatus: pipeline,
        divergedCommitsCount: 0,
        approved: false,
        approvalsLeft: 1,
        approvedBy: [],
        detailedMergeStatus: "mergeable",
        hasConflicts: false,
        blockingDiscussionsResolved: true,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}
