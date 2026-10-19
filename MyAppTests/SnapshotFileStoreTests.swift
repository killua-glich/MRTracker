//
//  SnapshotFileStoreTests.swift
//  MyAppTests
//

import Foundation
import Testing
@testable import MyApp

struct SnapshotFileStoreTests {

    // MARK: - Fixtures

    /// Fresh, unique temp directory per test; caller removes it via `defer`.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "SnapshotFileStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func makeMR(iid: Int, pipeline: PipelineStatus?, title: String = "Add retry logic to poller") -> MergeRequestSnapshot {
        MergeRequestSnapshot(
            projectId: 42,
            projectPath: "group/backend-api",
            iid: iid,
            title: title,
            webURL: URL(string: "https://gitlab.example.com/group/backend-api/-/merge_requests/\(iid)")!,
            sourceBranch: "feature/retry-logic-\(iid)",
            targetBranch: "main",
            roles: [.author, .reviewer],
            isDraft: false,
            pipelineStatus: pipeline,
            divergedCommitsCount: 2,
            approved: true,
            approvalsLeft: 0,
            approvedBy: ["alice", "bob"],
            detailedMergeStatus: "mergeable",
            hasConflicts: false,
            blockingDiscussionsResolved: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private nonisolated static func makeSnapshot(count: Int, pipeline: PipelineStatus? = .running, error: String? = nil) -> SnapshotStore {
        SnapshotStore(
            mergeRequests: (0..<count).map { makeMR(iid: $0 + 1, pipeline: pipeline) },
            lastFetchedAt: Date(timeIntervalSince1970: 1_700_000_500),
            lastError: error
        )
    }

    // MARK: - Tests

    @Test func writeThenReadRoundTrips() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))
        let original = Self.makeSnapshot(count: 3)

        try store.write(original)

        #expect(store.read() == .snapshot(original))
    }

    @Test func zeroMergeRequestsIsDistinctFromNoSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))
        let emptyFetch = Self.makeSnapshot(count: 0)

        try store.write(emptyFetch)

        #expect(store.read() == .snapshot(emptyFetch))
        #expect(store.read() != .noSnapshotYet)
    }

    @Test func missingFileReturnsNoSnapshotYet() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "nope/snapshot.json"))

        let result = store.read()

        #expect(result == .noSnapshotYet)
        #expect(result.snapshotOrEmpty == .empty)
        #expect(result.snapshotOrEmpty.lastFetchedAt == .distantPast)
    }

    @Test(arguments: [
        Data([0xFF, 0xFE, 0x00, 0x13, 0x37, 0xDE, 0xAD, 0xBE, 0xEF]),
        Data(),
        Data("not json at all".utf8),
        Data(#"{"mergeRequests":"wrong type","lastFetchedAt":"2024-01-01T00:00:00Z"}"#.utf8),
    ])
    func garbageFileReturnsUnreadableAndKeepsFile(bytes: Data) throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appending(path: "snapshot.json")
        try bytes.write(to: url)
        let store = SnapshotFileStore(fileURL: url)

        let result = store.read()

        #expect(result == .unreadable)
        #expect(result.snapshotOrEmpty == .empty)
        // Evidence is not silently destroyed by a read.
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func truncatedJSONReturnsUnreadable() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appending(path: "snapshot.json")
        let full = try JSONEncoder.snapshot.encode(Self.makeSnapshot(count: 3))
        try full.prefix(full.count / 2).write(to: url)
        let store = SnapshotFileStore(fileURL: url)

        #expect(store.read() == .unreadable)

        // Next good write recovers.
        let good = Self.makeSnapshot(count: 1)
        try store.write(good)
        #expect(store.read() == .snapshot(good))
    }

    @Test func overwriteReplacesFully() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appending(path: "snapshot.json")
        let store = SnapshotFileStore(fileURL: url)
        let large = Self.makeSnapshot(count: 50)
        let small = Self.makeSnapshot(count: 1, pipeline: .failed, error: nil)

        try store.write(large)
        try store.write(small)

        #expect(store.read() == .snapshot(small))
        // File holds exactly the new encoding — no leftover tail from the larger write.
        // (Compare length, not bytes: JSONEncoder without .sortedKeys doesn't guarantee a
        // stable key order between encodes.)
        #expect(try Data(contentsOf: url).count == JSONEncoder.snapshot.encode(small).count)
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(leftovers == ["snapshot.json"])
    }

    @Test func writeCreatesIntermediateDirectories() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appending(path: "Library/Application Support/snapshot.json")
        let store = SnapshotFileStore(fileURL: url)
        let snapshot = Self.makeSnapshot(count: 2)

        try store.write(snapshot)

        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.read() == .snapshot(snapshot))
    }

    @Test func appGroupFactoryUsesApplicationSupportPath() throws {
        let container = URL(filePath: "/tmp/fake-container", directoryHint: .isDirectory)
        let store = try SnapshotFileStore.appGroup(containerURL: container, identifier: "group.test")
        #expect(store.fileURL.path(percentEncoded: false) == "/tmp/fake-container/Library/Application Support/snapshot.json")
    }

    @Test func appGroupFactoryThrowsWhenContainerUnavailable() {
        #expect(throws: SnapshotFileStore.StoreError.appGroupContainerUnavailable(identifier: "group.test")) {
            try SnapshotFileStore.appGroup(containerURL: nil, identifier: "group.test")
        }
    }

    @Test func recordFailurePreservesMergeRequestsAndTimestamp() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))
        let good = Self.makeSnapshot(count: 3)
        try store.write(good)

        try store.recordFailure("GitLab unreachable")

        let result = store.read().snapshotOrEmpty
        #expect(result.mergeRequests == good.mergeRequests)
        #expect(result.lastFetchedAt == good.lastFetchedAt)
        #expect(result.lastError == "GitLab unreachable")
    }

    @Test func recordFailureWithoutSnapshotWritesEmptyWithError() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))

        try store.recordFailure("Authentication failed")

        let result = store.read().snapshotOrEmpty
        #expect(result.mergeRequests.isEmpty)
        #expect(result.lastFetchedAt == .distantPast)
        #expect(result.lastError == "Authentication failed")
    }

    /// A reader polling the file while a writer replaces it many times must only ever see
    /// a complete snapshot (old or new) — never a decode failure or a missing file.
    @Test func concurrentReadsNeverObservePartialWrites() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))
        // Large-ish payloads (~100+ KB) so a non-atomic write would plausibly be observed mid-way.
        let a = Self.makeSnapshot(count: 200, pipeline: .running)
        let b = Self.makeSnapshot(count: 150, pipeline: .failed, error: "previous failure")
        try store.write(a)

        let writes = 300
        let reads = 1_500

        async let writer: Void = Task.detached {
            for i in 0..<writes {
                try store.write(i.isMultiple(of: 2) ? b : a)
            }
        }.value

        async let reader: [SnapshotReadResult] = Task.detached {
            var bad: [SnapshotReadResult] = []
            for _ in 0..<reads {
                let result = store.read()
                if result != .snapshot(a) && result != .snapshot(b) {
                    bad.append(result)
                }
            }
            return bad
        }.value

        try await writer
        let badReads = await reader

        #expect(badReads.isEmpty, "Observed \(badReads.count) non-complete reads")
    }

    /// Concurrent writes + recordFailure within one process must not corrupt the file.
    @Test func concurrentWritersLeaveValidFile() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let store = SnapshotFileStore(fileURL: dir.appending(path: "snapshot.json"))
        let snapshot = Self.makeSnapshot(count: 20)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i.isMultiple(of: 3) {
                        try store.recordFailure("failure \(i)")
                    } else {
                        try store.write(snapshot)
                    }
                }
            }
            try await group.waitForAll()
        }

        let result = store.read()
        guard case .snapshot(let final) = result else {
            Issue.record("Expected a decodable snapshot, got \(result)")
            return
        }
        #expect(final.mergeRequests == snapshot.mergeRequests)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(leftovers == ["snapshot.json"])
    }
}
