//
//  GitLabClientTests.swift
//  MyAppTests
//
//  Swift Testing coverage for GitLabClient (MRT-021/022/023) using the MockURLProtocol
//  harness (MRT-070). No `.serialized`: MockURLProtocol.Session gives every test its own
//  isolated stub list and recorded-request log, so these are safe to run concurrently.
//

import Foundation
import Testing
@testable import MyApp

struct GitLabClientTests {

    private let baseURL = URL(string: "https://gitlab.example.com")!
    private let token = "glpat-test-token"

    private func makeClient() -> (client: GitLabClient, controller: MockURLProtocol.Session) {
        let (session, controller) = URLSession.mock()
        let client = GitLabClient(baseURL: baseURL, token: token, session: session)
        return (client, controller)
    }

    // MARK: - Auth header

    @Test func authHeaderIsSentOnEveryRequest() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", body: Data(GitLabFixtures.user.utf8))

        _ = try await client.currentUser()

        let sent = controller.recordedRequests
        #expect(sent.count == 1)
        #expect(sent.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == token)
    }

    // MARK: - List: scope query building

    @Test func createdByMeScopeBuildsExpectedQuery() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["scope": "created_by_me", "state": "opened", "page": "1"],
            body: Data(GitLabFixtures.listPage1.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.count == 1)
        #expect(items.first?.iid == 3)
        #expect(items.first?.projectId == 42)
        #expect(items.first?.projectPath == "group/backend-api")
        #expect(items.first?.isDraft == false)
    }

    @Test func reviewerScopeBuildsExpectedQuery() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: [
                "scope": "all",
                "state": "opened",
                "reviewer_username": "diego",
                "page": "1",
            ],
            body: Data(GitLabFixtures.listPage1.utf8)
        )

        let items = try await client.openMergeRequests(scope: .reviewer(username: "diego"))

        #expect(items.count == 1)
    }

    // MARK: - Pagination

    @Test func paginationFollowsXNextPageAcrossTwoPages() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            headers: ["x-next-page": "2"],
            body: Data(GitLabFixtures.listPage1.utf8)
        )
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "2"],
            body: Data(GitLabFixtures.listPage2.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.map(\.iid) == [3, 4])
        #expect(controller.recordedRequests.count == 2)
    }

    @Test func dateDecodingHandlesFractionalAndWholeSecondISO8601() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            headers: ["x-next-page": "2"],
            body: Data(GitLabFixtures.listPage1.utf8)
        )
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "2"],
            body: Data(GitLabFixtures.listPage2.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]

        #expect(items.count == 2)
        #expect(items[0].updatedAt == fractional.date(from: "2026-10-13T10:22:31.123Z"))
        #expect(items[1].updatedAt == whole.date(from: "2026-10-13T11:00:00Z"))
    }

    // MARK: - Draft fallback (list)

    @Test func draftFieldTrueMarksListItemAsDraft() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            body: Data(GitLabFixtures.listItemDraftFieldTrue.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.first?.isDraft == true)
    }

    @Test func workInProgressFallbackMarksListItemAsDraftWhenDraftFieldMissing() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            body: Data(GitLabFixtures.listItemWorkInProgressFallback.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.first?.isDraft == true)
    }

    @Test func titlePrefixFallbackMarksListItemAsDraftOnOlderInstances() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            body: Data(GitLabFixtures.listItemTitlePrefixFallback.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.first?.isDraft == true)
    }

    // MARK: - Project path derivation

    @Test func projectPathFallsBackToWebURLWhenReferencesMissing() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            body: Data(GitLabFixtures.listItemWithoutReferences.utf8)
        )

        let items = try await client.openMergeRequests(scope: .createdByMe)

        #expect(items.first?.projectPath == "group/backend-api")
    }

    // MARK: - Detail decoding

    @Test func mergeRequestDetailDecodesWithNoPipelineYet() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3",
            body: Data(GitLabFixtures.detailNoPipelineYet.utf8)
        )

        let detail = try await client.mergeRequestDetail(projectId: 42, iid: 3)

        #expect(detail.pipelineStatus == nil)
        #expect(detail.divergedCommitsCount == 0)
        #expect(detail.detailedMergeStatus == "mergeable")
        #expect(detail.hasConflicts == false)
        #expect(detail.blockingDiscussionsResolved == true)
        #expect(detail.isDraft == false)
    }

    @Test func mergeRequestDetailDecodesUnknownPipelineStatusWithoutFailing() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3",
            body: Data(GitLabFixtures.detailUnknownPipelineStatus.utf8)
        )

        let detail = try await client.mergeRequestDetail(projectId: 42, iid: 3)

        #expect(detail.pipelineStatus == .unknown("some_future_status"))
        #expect(detail.divergedCommitsCount == nil)
    }

    @Test func mergeRequestDetailFallsBackToMergeStatusWhenDetailedMergeStatusMissing() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3",
            body: Data(GitLabFixtures.detailMergeStatusFallback.utf8)
        )

        let detail = try await client.mergeRequestDetail(projectId: 42, iid: 3)

        #expect(detail.detailedMergeStatus == "can_be_merged")
        #expect(detail.pipelineStatus == .success)
    }

    @Test func mergeRequestDetailDecodesConflictingMR() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3",
            body: Data(GitLabFixtures.detailConflicting.utf8)
        )

        let detail = try await client.mergeRequestDetail(projectId: 42, iid: 3)

        #expect(detail.hasConflicts == true)
        #expect(detail.detailedMergeStatus == "conflict")
        #expect(detail.pipelineStatus == .failed)
        #expect(detail.divergedCommitsCount == 5)
    }

    @Test func mergeRequestDetailRequestIncludesDivergedCommitsCountQueryItem() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3",
            queryContains: ["include_diverged_commits_count": "true"],
            body: Data(GitLabFixtures.detailNoPipelineYet.utf8)
        )

        _ = try await client.mergeRequestDetail(projectId: 42, iid: 3)

        #expect(controller.recordedRequests.count == 1)
    }

    // MARK: - Approvals

    @Test func approvalsDecodesZeroRequiredApprovals() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3/approvals",
            body: Data(GitLabFixtures.approvalsZeroRequired.utf8)
        )

        let approvals = try await client.approvals(projectId: 42, iid: 3)

        #expect(approvals.approved == true)
        #expect(approvals.approvalsLeft == 0)
        #expect(approvals.approvedBy.isEmpty)
    }

    @Test func approvalsDecodesPendingApprovalsWithApprovers() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/projects/42/merge_requests/3/approvals",
            body: Data(GitLabFixtures.approvalsPending.utf8)
        )

        let approvals = try await client.approvals(projectId: 42, iid: 3)

        #expect(approvals.approved == false)
        #expect(approvals.approvalsLeft == 2)
        #expect(approvals.approvedBy == ["alice", "bob"])
    }

    // MARK: - HTTP error mapping

    @Test func unauthorizedProducesDistinctError() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", status: 401)

        await #expect(throws: GitLabAPIError.unauthorized) {
            try await client.currentUser()
        }
    }

    @Test func notFoundProducesDistinctError() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/projects/42/merge_requests/3", status: 404)

        await #expect(throws: GitLabAPIError.notFound) {
            try await client.mergeRequestDetail(projectId: 42, iid: 3)
        }
    }

    @Test func rateLimitedProducesDistinctErrorWithRetryAfter() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", status: 429, headers: ["Retry-After": "30"])

        await #expect(throws: GitLabAPIError.rateLimited(retryAfter: 30)) {
            try await client.currentUser()
        }
    }

    @Test func serverErrorProducesDistinctError() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", status: 503)

        await #expect(throws: GitLabAPIError.server(status: 503)) {
            try await client.currentUser()
        }
    }

    /// A non-2xx response must never be silently decoded as "no results" — the error check
    /// runs before any attempt to decode the body, even when the body happens to look like
    /// a valid (empty) list.
    @Test func nonTwoHundredStatusNeverDecodesAsEmptyList() async throws {
        let (client, controller) = makeClient()
        controller.stub(
            path: "/api/v4/merge_requests",
            queryContains: ["page": "1"],
            status: 500,
            body: Data("[]".utf8)
        )

        await #expect(throws: GitLabAPIError.server(status: 500)) {
            try await client.openMergeRequests(scope: .createdByMe)
        }
    }

    // MARK: - Transport errors

    @Test func transportErrorMapsToDistinguishableCode() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", error: URLError(.cannotFindHost))

        await #expect(throws: GitLabAPIError.transport(.cannotFindHost)) {
            try await client.currentUser()
        }
    }

    @Test func tlsTransportErrorsStayDistinguishableFromOtherTransportErrors() async throws {
        let (client, controller) = makeClient()
        controller.stub(path: "/api/v4/user", error: URLError(.serverCertificateUntrusted))

        await #expect(throws: GitLabAPIError.transport(.serverCertificateUntrusted)) {
            try await client.currentUser()
        }
    }
}
