//
//  GitLabDateDecoding.swift
//  MyApp
//
//  Custom `JSONDecoder.DateDecodingStrategy` for GitLab API timestamps.
//

import Foundation

/// GitLab's REST API has been observed to return ISO 8601 timestamps both with and
/// without fractional seconds — e.g. `"2026-10-13T10:22:31.123Z"` (typical) and
/// `"2026-10-13T10:22:31Z"` (seen on some fields/instances). `JSONDecoder`'s built-in
/// `.iso8601` strategy only accepts one of the two forms (no fractional seconds), so every
/// GitLab API DTO in this file uses this custom strategy instead, which tries the
/// fractional-seconds formatter first and falls back to the whole-seconds one.
///
/// Note this is deliberately separate from `JSONDecoder.snapshot` (`Shared/
/// SnapshotJSONCoding.swift`), which only ever decodes dates this app wrote itself (always
/// whole-seconds `.iso8601`) — the GitLab wire format and the App Group on-disk format are
/// independent and allowed to drift.
nonisolated enum GitLabDateDecoding {
    static let strategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)

        // Fresh formatter instances per call rather than shared `static let`s: Foundation
        // does not document `ISO8601DateFormatter` as safe to share across concurrent
        // decodes, and decoding happens off the main actor (polling background task), so
        // this sidesteps any thread-safety question at a cost (one small allocation per
        // date field) that's negligible for this app's MR counts.
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        if let date = withoutFractionalSeconds.date(from: string) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an ISO 8601 date string, got \"\(string)\"."
        )
    }
}
