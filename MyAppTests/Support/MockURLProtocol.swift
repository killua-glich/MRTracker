//
//  MockURLProtocol.swift
//  MyAppTests
//
//  Reusable `URLProtocol`-based test harness (MRT-070): stub GitLab API responses/errors by
//  request matcher, and record every request a `GitLabClient` under test actually sent.
//

import Foundation

/// Intercepts every request made through a `URLSession` built by `URLSession.mock()` and
/// resolves it against a per-session `MockURLProtocol.Session`'s stubs, instead of hitting
/// the network.
///
/// **Isolation.** `URLProtocol` registration (`URLSessionConfiguration.protocolClasses`) is
/// per-session, but the class itself is otherwise a process-global singleton-ish type — any
/// static mutable state on `MockURLProtocol` would be shared by every test. Swift Testing
/// runs tests (and whole suites) concurrently by default, so that would make tests stomp on
/// each other's stubs and recorded requests. Instead, every call to `URLSession.mock()`:
///
/// 1. Creates a fresh `Session` (its own stub list + recorded-request log, lock-protected).
/// 2. Generates a random session ID and stores `session -> Session` in a lock-protected
///    static registry.
/// 3. Builds a `URLSession` whose `URLSessionConfiguration.httpAdditionalHeaders` includes
///    that ID under a private header name. `URLSession` attaches `httpAdditionalHeaders` to
///    every request made through that session automatically, so `startLoading()` below can
///    read the header back off `request` to look up the right `Session` — giving each test
///    real isolation (not just "probably fine in practice") without resorting to
///    `@Suite(.serialized)`.
final class MockURLProtocol: URLProtocol {

    private static let sessionIDHeaderName = "X-MockURLProtocol-Session-ID"

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Session] = [:]

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let sessionID = request.value(forHTTPHeaderField: Self.sessionIDHeaderName),
            let session = Self.session(forID: sessionID)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        session.record(request)

        switch session.resolve(request) {
        case .success(let status, let headers, let body):
            guard
                let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .unmatched:
            // A programmer error in the test (missing stub), not something under test —
            // fail loudly and specifically rather than returning an ambiguous network error.
            let description = "MockURLProtocol: no stub matched \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<no url>")"
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: description]))
        }
    }

    override func stopLoading() {}

    // MARK: - Session factory

    fileprivate static func makeSession() -> (session: URLSession, controller: Session) {
        let sessionID = UUID().uuidString
        let controller = Session()

        registryLock.lock()
        registry[sessionID] = controller
        registryLock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [sessionIDHeaderName: sessionID]
        let urlSession = URLSession(configuration: configuration)

        return (urlSession, controller)
    }

    private static func session(forID id: String) -> Session? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[id]
    }
}

extension MockURLProtocol {

    /// Per-session stub registry + request recorder, returned alongside the `URLSession`
    /// from `URLSession.mock()`. `@unchecked Sendable`: all mutable state is behind an
    /// `NSLock`.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var _recordedRequests: [URLRequest] = []

        fileprivate init() {}

        /// Every request this session's `MockURLProtocol` has handled so far, in order —
        /// for asserting on auth headers, exact query strings, call counts, etc.
        var recordedRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _recordedRequests
        }

        /// Stubs a successful (or non-2xx, but still a real HTTP response) result.
        func stub(
            method: String = "GET",
            path: String,
            queryContains: [String: String] = [:],
            status: Int = 200,
            headers: [String: String] = [:],
            body: Data = Data()
        ) {
            addStub(Stub(method: method, path: path, queryContains: queryContains) { _ in
                .success(status: status, headers: headers, body: body)
            })
        }

        /// Stubs a transport-level failure (no HTTP response at all) — e.g. to simulate a
        /// corp TLS failure or an offline network.
        func stub(
            method: String = "GET",
            path: String,
            queryContains: [String: String] = [:],
            error: URLError
        ) {
            addStub(Stub(method: method, path: path, queryContains: queryContains) { _ in
                .failure(error)
            })
        }

        private func addStub(_ stub: Stub) {
            lock.lock()
            stubs.append(stub)
            lock.unlock()
        }

        fileprivate func record(_ request: URLRequest) {
            lock.lock()
            _recordedRequests.append(request)
            lock.unlock()
        }

        fileprivate func resolve(_ request: URLRequest) -> Outcome {
            lock.lock()
            let match = stubs.first { $0.matches(request) }
            lock.unlock()
            guard let match else {
                return .unmatched
            }
            return match.respond(request)
        }
    }

    /// A single stubbed request matcher + canned response/error.
    private struct Stub {
        let method: String
        let path: String
        let queryContains: [String: String]
        let respond: @Sendable (URLRequest) -> Outcome

        func matches(_ request: URLRequest) -> Bool {
            guard let url = request.url else { return false }
            guard (request.httpMethod ?? "GET").caseInsensitiveCompare(method) == .orderedSame else { return false }
            guard url.path == path else { return false }
            guard !queryContains.isEmpty else { return true }

            let actualItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return queryContains.allSatisfy { key, value in
                actualItems.contains { $0.name == key && $0.value == value }
            }
        }
    }

    /// The result of resolving a request against a `Session`'s stubs.
    enum Outcome {
        case success(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
        /// No stub matched — a missing-stub bug in the test, not a simulated API response.
        case unmatched
    }
}

extension URLSession {
    /// Builds an isolated `URLSession` wired to `MockURLProtocol`, plus the `Session`
    /// handle used to stub responses/errors and inspect recorded requests.
    ///
    /// Every call returns an independently isolated session (see `MockURLProtocol`'s doc
    /// comment) — safe to call from parallel Swift Testing tests without `.serialized`.
    static func mock() -> (session: URLSession, controller: MockURLProtocol.Session) {
        MockURLProtocol.makeSession()
    }
}
