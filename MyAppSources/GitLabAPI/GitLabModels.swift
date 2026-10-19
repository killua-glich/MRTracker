//
//  GitLabModels.swift
//  MyApp
//
//  The types `GitLabClient` actually returns — already mapped from the raw wire DTOs in
//  GitLabDTOs.swift, with GitLab's version-drift fallbacks (draft, merge status) and the
//  project-path derivation already resolved. MRT-024 (orchestration into
//  `MergeRequestSnapshot`, out of scope here) should be able to build a full
//  `MergeRequestSnapshot` from one `MergeRequestListItem` + its `MergeRequestDetail` +
//  its `MergeRequestApprovals` without touching GitLab's wire format at all.
//

import Foundation

/// `GET /user` — used both to validate a token (MRT-011) and to get the username needed
/// for the reviewer-scope query (`reviewer_username=<me>`).
nonisolated struct GitLabUser: Sendable, Equatable {
    let id: Int
    let username: String
    let name: String
}

/// One entry from `GET /merge_requests` (list endpoint: MRT-021).
nonisolated struct MergeRequestListItem: Sendable, Equatable {
    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    let webURL: URL
    let sourceBranch: String
    let targetBranch: String
    /// Resolved via `resolveDraft`: `draft` field, else `work_in_progress`, else a
    /// `"Draft:"`/`"WIP:"` title prefix (older GitLab instances — PLAN.md → GitLab API
    /// mapping, "Draft state").
    let isDraft: Bool
    let updatedAt: Date
    /// e.g. `"group/backend-api"`. Resolved via `resolveProjectPath`.
    let projectPath: String

    init(dto: MergeRequestListItemDTO) {
        id = dto.id
        iid = dto.iid
        projectId = dto.projectId
        title = dto.title
        webURL = dto.webUrl
        sourceBranch = dto.sourceBranch
        targetBranch = dto.targetBranch
        updatedAt = dto.updatedAt
        isDraft = Self.resolveDraft(draft: dto.draft, workInProgress: dto.workInProgress, title: dto.title)
        projectPath = Self.resolveProjectPath(referencesFull: dto.references?.full, webURL: dto.webUrl)
    }

    /// `draft` wins when present (current GitLab). Falls back to `work_in_progress` (the
    /// field `draft` replaced), then to a `"Draft:"`/`"WIP:"` title prefix (pre-`draft`-field
    /// GitLab versions used the title prefix as the only signal) — see PLAN.md → GitLab API
    /// mapping, "Draft state".
    static func resolveDraft(draft: Bool?, workInProgress: Bool?, title: String) -> Bool {
        if let draft { return draft }
        if let workInProgress { return workInProgress }
        return title.hasPrefix("Draft:") || title.hasPrefix("WIP:")
    }

    /// Prefers `references.full` (e.g. `"group/proj!12"`): GitLab reserves `!` to separate
    /// the project path from the MR `iid` in a reference string, and a project *path*
    /// (namespace segments joined by `/`) cannot itself contain `!`, so splitting on the
    /// *last* `!` and keeping everything before it is safe regardless of the `iid`'s value
    /// or how many `/`-separated namespace levels the project has.
    ///
    /// Falls back to parsing the MR's `web_url` path (`"/<group>/.../<project>/-/merge_requests/<iid>"`,
    /// taking everything before `/-/merge_requests/`) for instances/responses where
    /// `references` is absent — GitLab reserves `/-/` as a path separator before
    /// resource-specific routes, so this is just as unambiguous as the `!` split above.
    static func resolveProjectPath(referencesFull: String?, webURL: URL) -> String {
        if let referencesFull, let bangIndex = referencesFull.lastIndex(of: "!") {
            return String(referencesFull[referencesFull.startIndex..<bangIndex])
        }

        let marker = "/-/merge_requests/"
        let path = webURL.path
        if let markerRange = path.range(of: marker) {
            let prefix = path[path.startIndex..<markerRange.lowerBound]
            return prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return referencesFull ?? ""
    }
}

/// `GET /projects/:id/merge_requests/:iid` (detail endpoint: MRT-022).
nonisolated struct MergeRequestDetail: Sendable, Equatable {
    /// `nil` when the MR has no head pipeline yet (brand-new MR, no CI configured, etc.).
    let pipelineStatus: PipelineStatus?
    let divergedCommitsCount: Int?
    /// `detailed_merge_status`, falling back to the older `merge_status` field when the
    /// instance doesn't send `detailed_merge_status` (PLAN.md → Open questions). Kept as a
    /// raw `String?` for the same reason `MergeRequestSnapshot.detailedMergeStatus` is —
    /// the value set has drifted across GitLab versions.
    let detailedMergeStatus: String?
    let hasConflicts: Bool
    let blockingDiscussionsResolved: Bool
    let isDraft: Bool

    init(dto: MergeRequestDetailDTO) {
        pipelineStatus = dto.headPipeline?.status
        divergedCommitsCount = dto.divergedCommitsCount
        detailedMergeStatus = dto.detailedMergeStatus ?? dto.mergeStatus
        hasConflicts = dto.hasConflicts ?? false
        blockingDiscussionsResolved = dto.blockingDiscussionsResolved ?? false
        isDraft = MergeRequestListItem.resolveDraft(
            draft: dto.draft,
            workInProgress: dto.workInProgress,
            title: dto.title ?? ""
        )
    }
}

/// `GET /projects/:id/merge_requests/:iid/approvals` (MRT-023).
nonisolated struct MergeRequestApprovals: Sendable, Equatable {
    let approved: Bool
    /// `0` for an MR with zero required approvals (and already `approved == true`) — not
    /// `nil`; `nil` only when GitLab omits the field entirely.
    let approvalsLeft: Int?
    let approvedBy: [String]

    init(dto: MergeRequestApprovalsDTO) {
        approved = dto.approved ?? false
        approvalsLeft = dto.approvalsLeft
        approvedBy = (dto.approvedBy ?? []).map(\.user.username)
    }
}
