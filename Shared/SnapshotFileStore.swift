import Foundation
import os

/// Outcome of reading the snapshot file. Lets callers (MRT-056 widget states, the menu bar)
/// tell "never fetched" apart from "fetched, zero MRs" and from "file is unusable", instead
/// of collapsing everything into `SnapshotStore.empty`.
///
/// Note `SnapshotStore.empty.lastFetchedAt == .distantPast`, so a renderer that only looks at
/// `snapshotOrEmpty` will still see the fallback as "infinitely stale" — but the explicit
/// cases avoid having to rely on that sentinel.
nonisolated enum SnapshotReadResult: Hashable, Sendable {
    /// A snapshot was decoded successfully (may legitimately contain zero MRs).
    case snapshot(SnapshotStore)
    /// No file exists yet — the host app has never written one (first launch).
    case noSnapshotYet
    /// A file exists but could not be read or decoded (corrupted, truncated, schema drift,
    /// I/O error). The file is left untouched on disk; the next good write replaces it.
    case unreadable

    /// The decoded snapshot, or the empty-but-valid fallback for both non-success cases.
    var snapshotOrEmpty: SnapshotStore {
        if case .snapshot(let store) = self { return store }
        return .empty
    }
}

/// Reads and writes `SnapshotStore` as JSON in the App Group container. The host app is the
/// single writer; the widget extension (another process) and the host app's menu read it.
///
/// Design notes:
/// - **Atomicity.** `write` encodes, writes the bytes to a uniquely named temp file in the
///   *same directory* as the target, then `rename(2)`s it over the target. Same-directory
///   rename on one volume is atomic on APFS/HFS+: a reader that opens the path sees either
///   the complete old inode or the complete new one, never a partial file; a reader that
///   already has the old file open keeps reading the old inode. This is what
///   `Data.write(options: .atomic)` does internally too, but doing it explicitly guarantees
///   the temp file is in the same directory (no cross-volume fallback) and gives us cleanup
///   on failure. `FileManager.replaceItemAt` adds metadata/backup semantics meant for
///   documents and isn't needed for a plain cache file.
/// - **No `NSFileCoordinator`.** Every write is a whole-file atomic replace and readers only
///   ever read the whole file, so there is no torn state to coordinate around; there is
///   no `NSFilePresenter` consumer (the widget is told to reload via WidgetKit, not file
///   observation); and blocking coordination in a widget timeline provider is undesirable.
/// - **Concurrency.** The type has no mutable state and is `Sendable`. Writes within one
///   process are serialized through a process-wide lock so `recordFailure`'s
///   read-modify-write can't interleave with a concurrent `write` and lose data. Cross-process,
///   the host app is assumed to be the only writer (the widget never writes).
/// - **Secrets.** Only `SnapshotStore` data is persisted — never the PAT. Logs never include
///   file contents.
nonisolated struct SnapshotFileStore: Sendable {
    nonisolated enum StoreError: Error, Equatable, Sendable {
        /// `containerURL(forSecurityApplicationGroupIdentifier:)` returned nil — the
        /// application-groups entitlement or provisioning is missing/misconfigured.
        case appGroupContainerUnavailable(identifier: String)
    }

    static let fileName = "snapshot.json"

    /// Destination file URL.
    let fileURL: URL

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SnapshotFileStore")

    /// Serializes writes (incl. read-modify-write in `recordFailure`) within this process.
    /// Process-wide rather than per-instance so two store values for the same file also
    /// serialize. Writes are infrequent (once per poll), so contention is irrelevant.
    private static let writeLock = OSAllocatedUnfairLock()

    /// Store backed by an arbitrary file URL (tests use a temp directory).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Store backed by `<App Group container>/Library/Application Support/snapshot.json`.
    ///
    /// `Library/Application Support` is Apple's conventional location for app-managed data
    /// that isn't user documents or a purgeable cache (`Library/Caches` could be purged,
    /// leaving the widget empty while the app is not running). Keeps the container root
    /// clean for anything else that may be shared later.
    ///
    /// Throws `StoreError.appGroupContainerUnavailable` rather than silently falling back to
    /// some other location the widget could never read.
    ///
    /// Call as `try SnapshotFileStore.appGroup(containerURL: AppGroup.containerURL, identifier: AppGroup.identifier)`.
    /// The values are passed in (no default arguments) because `AppGroup` is not marked
    /// `nonisolated`, so in the host app (default MainActor isolation) it is MainActor-isolated
    /// and can't be referenced from this nonisolated type; callers read it in their own context.
    static func appGroup(containerURL: URL?, identifier: String) throws -> SnapshotFileStore {
        guard let containerURL else {
            logger.error("App Group container unavailable for \(identifier, privacy: .public); check application-groups entitlement/provisioning")
            throw StoreError.appGroupContainerUnavailable(identifier: identifier)
        }
        let url = containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
        return SnapshotFileStore(fileURL: url)
    }

    // MARK: - Read

    /// Synchronous read, suitable for `TimelineProvider` callbacks. Never throws or crashes.
    func read() -> SnapshotReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .noSnapshotYet
        } catch {
            Self.logger.error("Snapshot file unreadable (I/O): \(String(describing: type(of: error)), privacy: .public) code \((error as NSError).code, privacy: .public)")
            return .unreadable
        }
        do {
            return .snapshot(try JSONDecoder.snapshot.decode(SnapshotStore.self, from: data))
        } catch {
            // Deliberately not logging `error` itself: DecodingError descriptions can echo
            // values from the file. Size is enough to tell truncation from schema drift.
            Self.logger.error("Snapshot file undecodable (\(data.count, privacy: .public) bytes); leaving it in place until next successful write")
            return .unreadable
        }
    }

    // MARK: - Write

    /// Atomically replaces the snapshot file, creating intermediate directories as needed.
    func write(_ snapshot: SnapshotStore) throws {
        try Self.writeLock.withLock {
            try writeUnlocked(snapshot)
        }
    }

    /// Records a failed fetch while preserving the last good data (PLAN.md → Risks: VPN off
    /// must not wipe the snapshot). Keeps `mergeRequests` and `lastFetchedAt` (which means
    /// "last *successful* fetch", so staleness keeps growing) and only sets `lastError`.
    ///
    /// If there is no snapshot yet, or the existing file is unreadable, writes `.empty` with
    /// the error so the UI can show the error state. `message` must be user-presentable and
    /// contain no secrets (it is persisted and shown by the widget).
    func recordFailure(_ message: String) throws {
        try Self.writeLock.withLock {
            var current = read().snapshotOrEmpty
            current.lastError = message
            try writeUnlocked(current)
        }
    }

    private func writeUnlocked(_ snapshot: SnapshotStore) throws {
        let data = try JSONEncoder.snapshot.encode(snapshot)
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            // rename(2) atomically replaces an existing destination (unlike
            // FileManager.moveItem, which fails if the destination exists).
            let renameErrno: Int32 = tempURL.withUnsafeFileSystemRepresentation { tempPath in
                fileURL.withUnsafeFileSystemRepresentation { destPath in
                    guard let tempPath, let destPath else { return EINVAL }
                    return rename(tempPath, destPath) == 0 ? 0 : errno
                }
            }
            if renameErrno != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: renameErrno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            Self.logger.error("Snapshot write failed: \(String(describing: type(of: error)), privacy: .public) code \((error as NSError).code, privacy: .public)")
            throw error
        }
    }
}
