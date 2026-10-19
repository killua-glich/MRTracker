//
//  GitLabDTOs.swift
//  MyApp
//
//  Raw wire-format decoding targets for the GitLab REST API. These are intentionally not
//  exposed outside this file — `GitLabClient` maps every DTO into one of the plain,
//  already-cleaned-up types in `GitLabModels.swift` before returning it, the same way
//  `MergeRequestSnapshot`'s doc comment describes keeping the API's wire format separate
//  from the app's own persisted model. Keeping that mapping boundary here too (rather than
//  letting MRT-024 see raw snake_case/optional-everywhere DTOs) is what should make MRT-024
//  easy: it only ever deals with `GitLabUser` / `MergeRequestListItem` /
//  `MergeRequestDetail` / `MergeRequestApprovals`.
//
//  Every field GitLab might omit or send as `null` is decoded as optional here, even where
//  the current GitLab docs call it non-optional — GitLab's version drift (PLAN.md → Risks)
//  means a field present on gitlab.com may be missing on an older self-hosted instance, and
//  a missing/null field must never crash decoding of an otherwise-valid response.
//
//  CodingKeys are spelled out explicitly rather than using
//  `keyDecodingStrategy = .convertFromSnakeCase`: Foundation's automatic conversion turns
//  `web_url` into `webUrl`, not `webURL`, which would silently fail to match a
//  Swift-API-guidelines-correct property name. Explicit keys avoid that whole class of
//  acronym mismatches.

import Foundation

// MARK: - /user

struct GitLabUserDTO: Decodable {
    let id: Int
    let username: String
    let name: String
}

// MARK: - /merge_requests (list)

struct MergeRequestListItemDTO: Decodable {
    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    let webUrl: URL
    let sourceBranch: String
    let targetBranch: String
    let draft: Bool?
    let workInProgress: Bool?
    let updatedAt: Date
    let references: ReferencesDTO?

    struct ReferencesDTO: Decodable {
        /// e.g. `"group/proj!12"` — see `MergeRequestListItem.resolveProjectPath`.
        let full: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case iid
        case projectId = "project_id"
        case title
        case webUrl = "web_url"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case draft
        case workInProgress = "work_in_progress"
        case updatedAt = "updated_at"
        case references
    }
}

// MARK: - /projects/:id/merge_requests/:iid (detail)

struct MergeRequestDetailDTO: Decodable {
    let title: String?
    let headPipeline: HeadPipelineDTO?
    let divergedCommitsCount: Int?
    /// Newer field. Falls back to `mergeStatus` when absent — see PLAN.md → Open questions
    /// ("does the MVP need a fallback (e.g. `merge_status` + `has_conflicts`)?").
    let detailedMergeStatus: String?
    /// Older field, present on GitLab instances that predate `detailed_merge_status`.
    let mergeStatus: String?
    let hasConflicts: Bool?
    let blockingDiscussionsResolved: Bool?
    let draft: Bool?
    let workInProgress: Bool?

    struct HeadPipelineDTO: Decodable {
        /// `PipelineStatus` (Shared/PipelineStatus.swift) already decodes defensively —
        /// any status string this app doesn't recognize becomes `.unknown(String)` rather
        /// than failing the decode, so it's reused as-is rather than re-implemented here.
        let status: PipelineStatus
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case headPipeline = "head_pipeline"
        case divergedCommitsCount = "diverged_commits_count"
        case detailedMergeStatus = "detailed_merge_status"
        case mergeStatus = "merge_status"
        case hasConflicts = "has_conflicts"
        case blockingDiscussionsResolved = "blocking_discussions_resolved"
        case draft
        case workInProgress = "work_in_progress"
    }
}

// MARK: - /projects/:id/merge_requests/:iid/approvals

struct MergeRequestApprovalsDTO: Decodable {
    let approved: Bool?
    let approvalsLeft: Int?
    let approvedBy: [ApprovedByEntryDTO]?

    struct ApprovedByEntryDTO: Decodable {
        let user: UserRefDTO
    }

    struct UserRefDTO: Decodable {
        let username: String
    }

    private enum CodingKeys: String, CodingKey {
        case approved
        case approvalsLeft = "approvals_left"
        case approvedBy = "approved_by"
    }
}
