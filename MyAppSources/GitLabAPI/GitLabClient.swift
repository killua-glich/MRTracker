//
//  GitLabClient.swift
//  MyApp
//
//  REST client for the GitLab API endpoints this app needs (MRT-021/022/023). Async/await
//  only, no Combine (PLAN.md → Tech stack). Lives in MyAppSources/ (host-only) — the widget
//  extension never links this file and never touches the network (PLAN.md → Security).
//
//  Orchestrating list → detail → approvals into a full `MergeRequestSnapshot` with bounded
//  concurrency is MRT-024's job, not this file's — each endpoint below is a standalone,
//  independently callable async function so MRT-024 can compose them with `async let`/a
//  task group however it likes.
//

import Foundation

/// Thin async/await GitLab REST API v4 client.
///
/// `Sendable` and holds no mutable state, so a single instance can be shared freely across
/// the polling background task (MRT-040), manual refresh (MRT-061), and the settings
/// screen's "validate token" check (MRT-011) without synchronization.
nonisolated struct GitLabClient: Sendable {

    /// Which GitLab merge requests to list — mirrors PLAN.md → GitLab API mapping's two
    /// "Own MRs" rows.
    enum MRScope: Sendable, Equatable {
        /// `scope=created_by_me&state=opened` — MRs the current user authored.
        case createdByMe
        /// `scope=all&state=opened&reviewer_username=<username>` — MRs where the current
        /// user is a reviewer. `scope=all` is required here: GitLab's `reviewer_username`
        /// filter only has an effect when `scope` isn't restricted to the caller's own MRs.
        case reviewer(username: String)
    }

    /// Safety valve against an instance that (due to a bug, or a GitLab version that never
    /// stops sending `x-next-page`) would otherwise page forever. 100 per page × 50 pages =
    /// 5,000 open MRs, far beyond anything this app's "glance at my open MRs" use case
    /// should ever see.
    private static let maxPages = 50
    private static let perPage = 100

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Endpoints

    /// `GET /user` — token validation (MRT-011) and the username `reviewer(username:)`
    /// needs.
    func currentUser() async throws(GitLabAPIError) -> GitLabUser {
        let request = try makeRequest(path: "user")
        let dto: GitLabUserDTO = try await performAndDecode(request)
        return GitLabUser(id: dto.id, username: dto.username, name: dto.name)
    }

    /// `GET /merge_requests` for the given scope, following pagination until exhausted (or
    /// `maxPages` is hit). Non-2xx responses throw before any decoding is attempted, so a
    /// failed request can never be mistaken for "no open MRs".
    func openMergeRequests(scope: MRScope) async throws(GitLabAPIError) -> [MergeRequestListItem] {
        var baseQueryItems = [
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "per_page", value: String(Self.perPage)),
        ]
        switch scope {
        case .createdByMe:
            baseQueryItems.append(URLQueryItem(name: "scope", value: "created_by_me"))
        case .reviewer(let username):
            baseQueryItems.append(URLQueryItem(name: "scope", value: "all"))
            baseQueryItems.append(URLQueryItem(name: "reviewer_username", value: username))
        }

        var items: [MergeRequestListItem] = []
        var page = 1

        for _ in 0..<Self.maxPages {
            let queryItems = baseQueryItems + [URLQueryItem(name: "page", value: String(page))]
            let request = try makeRequest(path: "merge_requests", queryItems: queryItems)
            let (dtos, response): ([MergeRequestListItemDTO], HTTPURLResponse) = try await perform(request)
            items.append(contentsOf: dtos.map(MergeRequestListItem.init(dto:)))

            guard let nextPage = nextPageNumber(from: response) else {
                break
            }
            page = nextPage
        }

        return items
    }

    /// `GET /projects/:id/merge_requests/:iid?include_diverged_commits_count=true`.
    func mergeRequestDetail(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestDetail {
        let request = try makeRequest(
            path: "projects/\(projectId)/merge_requests/\(iid)",
            queryItems: [URLQueryItem(name: "include_diverged_commits_count", value: "true")]
        )
        let dto: MergeRequestDetailDTO = try await performAndDecode(request)
        return MergeRequestDetail(dto: dto)
    }

    /// `GET /projects/:id/merge_requests/:iid/approvals`.
    func approvals(projectId: Int, iid: Int) async throws(GitLabAPIError) -> MergeRequestApprovals {
        let request = try makeRequest(path: "projects/\(projectId)/merge_requests/\(iid)/approvals")
        let dto: MergeRequestApprovalsDTO = try await performAndDecode(request)
        return MergeRequestApprovals(dto: dto)
    }

    // MARK: - Request building

    private var apiRoot: URL {
        baseURL.appendingPathComponent("api").appendingPathComponent("v4")
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws(GitLabAPIError) -> URLRequest {
        var url = apiRoot.appendingPathComponent(path)
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw .invalidURL
            }
            components.queryItems = (components.queryItems ?? []) + queryItems
            guard let composedURL = components.url else {
                throw .invalidURL
            }
            url = composedURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // `PRIVATE-TOKEN` is GitLab's own header name for PAT auth. Never logged — see
        // `GitLabAPIError`'s doc comment — and this method is the only place that reads
        // `token`, so an accidental `print(request)`/log of the *error* path elsewhere in
        // this file can never include it.
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        return request
    }

    // MARK: - Request execution

    private func performAndDecode<T: Decodable>(_ request: URLRequest) async throws(GitLabAPIError) -> T {
        let (value, _): (T, HTTPURLResponse) = try await perform(request)
        return value
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws(GitLabAPIError) -> (T, HTTPURLResponse) {
        let (data, rawResponse) = try await send(request)

        guard let response = rawResponse as? HTTPURLResponse else {
            // Should be unreachable for http(s) requests, but there's no HTTPURLResponse
            // case to report as a specific status — surface it as an unexpected status
            // rather than force-casting.
            throw .unexpectedStatus(-1)
        }
        try checkStatus(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = GitLabDateDecoding.strategy
        do {
            let value = try decoder.decode(T.self, from: data)
            return (value, response)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    private func send(_ request: URLRequest) async throws(GitLabAPIError) -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw .transport(urlError.code)
        } catch {
            throw .transport(.unknown)
        }
    }

    private func checkStatus(_ response: HTTPURLResponse) throws(GitLabAPIError) {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw .unauthorized
        case 403:
            throw .forbidden
        case 404:
            throw .notFound
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw .rateLimited(retryAfter: retryAfter)
        case 500..<600:
            throw .server(status: response.statusCode)
        default:
            throw .unexpectedStatus(response.statusCode)
        }
    }

    /// Reads GitLab's `x-next-page` pagination header (present on every list response;
    /// empty string on the last page). Deliberately not using the `Link` header's
    /// `rel="next"` instead — functionally equivalent on GitLab, but `x-next-page` is a
    /// plain integer with no parsing beyond `Int(_:)`.
    private func nextPageNumber(from response: HTTPURLResponse) -> Int? {
        guard
            let value = response.value(forHTTPHeaderField: "x-next-page"),
            !value.isEmpty,
            let page = Int(value)
        else {
            return nil
        }
        return page
    }
}
