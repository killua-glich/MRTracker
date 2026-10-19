import Foundation

/// Shared `JSONEncoder`/`JSONDecoder` factories for `SnapshotStore` / `MergeRequestSnapshot`
/// persistence, so every writer (host app, MRT-030's App Group store) and every reader
/// (widget extension, tests) agree on the same date strategy. Using `.iso8601` rather than
/// the default `.deferredToDate` keeps the on-disk/shared-container JSON human-readable and
/// stable, independent of `Date`'s internal reference-date representation.
extension JSONEncoder {
    nonisolated static var snapshot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var snapshot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
