import Foundation

/// The app's own persisted snapshot of a single GitLab merge request, as of the last
/// successful poll. This is NOT a GitLab API decoding target — the API client (MRT-021+)
/// has its own DTOs for the raw REST responses and maps them into this type. Keeping the
/// two separate means GitLab's wire format (snake_case, version drift, nested objects like
/// `head_pipeline.status`) can change without touching the format persisted to the App
/// Group container and read by the widget (MRT-030).
///
/// Property names double as the `Codable` keys (see `CodingKeys` below) and are
/// intentionally pinned — this struct is serialized to disk (MRT-030) and read back across
/// app launches and by the widget extension, so silently renaming a property must not
/// silently change the on-disk/shared-container JSON shape.
nonisolated struct MergeRequestSnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var projectId: Int
    /// e.g. "group/backend-api" — shown as the Project column in the menu bar popup
    /// (PLAN.md → "Menu bar popup"); missing from the original data model sketch.
    var projectPath: String
    var iid: Int
    var title: String
    var webURL: URL
    var sourceBranch: String
    var targetBranch: String
    /// See `MRRole` for why this is a set rather than a single role.
    var roles: Set<MRRole>
    var isDraft: Bool
    var pipelineStatus: PipelineStatus?
    /// Commits behind the target branch.
    var divergedCommitsCount: Int?
    var approved: Bool
    var approvalsLeft: Int?
    var approvedBy: [String]
    /// Kept as a raw `String?` rather than an enum: `detailed_merge_status` values
    /// (`mergeable`, `conflict`, `need_rebase`, `ci_must_pass`, `draft_status`, ...) have
    /// drifted across GitLab versions (see PLAN.md → Risks), and an exhaustive enum here
    /// would need updating every time the self-hosted instance is upgraded.
    var detailedMergeStatus: String?
    var hasConflicts: Bool
    var blockingDiscussionsResolved: Bool
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case projectPath
        case iid
        case title
        case webURL
        case sourceBranch
        case targetBranch
        case roles
        case isDraft
        case pipelineStatus
        case divergedCommitsCount
        case approved
        case approvalsLeft
        case approvedBy
        case detailedMergeStatus
        case hasConflicts
        case blockingDiscussionsResolved
        case updatedAt
    }

    init(
        projectId: Int,
        projectPath: String,
        iid: Int,
        title: String,
        webURL: URL,
        sourceBranch: String,
        targetBranch: String,
        roles: Set<MRRole>,
        isDraft: Bool,
        pipelineStatus: PipelineStatus?,
        divergedCommitsCount: Int?,
        approved: Bool,
        approvalsLeft: Int?,
        approvedBy: [String],
        detailedMergeStatus: String?,
        hasConflicts: Bool,
        blockingDiscussionsResolved: Bool,
        updatedAt: Date
    ) {
        self.id = Self.makeId(projectId: projectId, iid: iid)
        self.projectId = projectId
        self.projectPath = projectPath
        self.iid = iid
        self.title = title
        self.webURL = webURL
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.roles = roles
        self.isDraft = isDraft
        self.pipelineStatus = pipelineStatus
        self.divergedCommitsCount = divergedCommitsCount
        self.approved = approved
        self.approvalsLeft = approvalsLeft
        self.approvedBy = approvedBy
        self.detailedMergeStatus = detailedMergeStatus
        self.hasConflicts = hasConflicts
        self.blockingDiscussionsResolved = blockingDiscussionsResolved
        self.updatedAt = updatedAt
    }

    /// Builds the stable identity string: `"<projectId>-<iid>"`. A single GitLab instance
    /// scopes MR `iid`s per-project, not globally, so the pair is needed for uniqueness.
    static func makeId(projectId: Int, iid: Int) -> String {
        "\(projectId)-\(iid)"
    }

    /// `true` when `detailedMergeStatus` reports the MR as ready to merge right now.
    /// Drives the status dot in the menu bar popup (PLAN.md → "Status dot").
    var isMergeable: Bool {
        detailedMergeStatus == "mergeable"
    }
}
