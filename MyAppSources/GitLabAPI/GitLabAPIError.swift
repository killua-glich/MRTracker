//
//  GitLabAPIError.swift
//  MyApp
//
//  Typed errors for `GitLabClient` (MRT-021/022/023).
//

import Foundation

/// Errors produced by `GitLabClient`.
///
/// Every case is safe to log, print, or show in the UI as-is: none of them carry the PAT,
/// the full request (headers included), or any other secret material (see PLAN.md →
/// Security). `transport` keeps the underlying `URLError.Code` around (rather than
/// collapsing to a single "network error" case) specifically so MRT-025's corp TLS check
/// can distinguish `.serverCertificateUntrusted`, `.secureConnectionFailed`, and friends
/// from an ordinary offline/timeout failure.
nonisolated enum GitLabAPIError: Error, Sendable, Equatable {
    /// The request URL could not be constructed (e.g. an unparseable base URL or query).
    case invalidURL
    /// `URLSession` failed before a response was received — offline, timed out, DNS
    /// failure, TLS failure, etc. The `URLError.Code` is preserved so callers (MRT-025) can
    /// branch on TLS-specific codes.
    case transport(URLError.Code)
    /// HTTP 401 — the token is missing, invalid, expired, or revoked.
    case unauthorized
    /// HTTP 403 — the token is valid but lacks permission for this resource.
    case forbidden
    /// HTTP 404.
    case notFound
    /// HTTP 429, with the `Retry-After` header value (seconds) when GitLab sent one.
    case rateLimited(retryAfter: Int?)
    /// HTTP 5xx.
    case server(status: Int)
    /// Any other non-2xx status this client doesn't special-case.
    case unexpectedStatus(Int)
    /// The response body didn't match the expected shape. Carries a short, non-secret
    /// description (type/key name from `DecodingError`) — never the response body itself,
    /// which could echo back request data.
    case decoding(String)
}

nonisolated extension GitLabAPIError: CustomStringConvertible {
    /// A human-readable, secret-free description — safe to surface directly in UI or logs.
    var description: String {
        switch self {
        case .invalidURL:
            "GitLab API error: could not construct a valid request URL."
        case .transport(let code):
            "GitLab API error: network transport failure (\(code))."
        case .unauthorized:
            "GitLab API error: unauthorized (401) — check that the token is valid and unexpired."
        case .forbidden:
            "GitLab API error: forbidden (403) — the token lacks permission for this resource."
        case .notFound:
            "GitLab API error: not found (404)."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "GitLab API error: rate limited (429) — retry after \(retryAfter)s."
            } else {
                "GitLab API error: rate limited (429)."
            }
        case .server(let status):
            "GitLab API error: server error (HTTP \(status))."
        case .unexpectedStatus(let status):
            "GitLab API error: unexpected HTTP status (\(status))."
        case .decoding(let detail):
            "GitLab API error: failed to decode response (\(detail))."
        }
    }
}
