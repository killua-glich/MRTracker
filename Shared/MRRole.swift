import Foundation

/// The current user's relationship to a merge request.
///
/// A single MR can be *both* authored by the current user and have them listed as a
/// reviewer at the same time (e.g. a reviewer added to their own stacked MR, or GitLab
/// configurations that add the author as a reviewer on follow-up MRs). A single
/// `role: MRRole` field would force picking one and silently discarding the other, which
/// would break the author/reviewer filter in MRT-012 and any "why is this MR in my list"
/// reasoning. `MergeRequestSnapshot.roles` is therefore a `Set<MRRole>` rather than a
/// single value — callers that only care about "is this mine at all" can check
/// `!roles.isEmpty`, and callers that need a single badge can prefer `.author` when both
/// are present (author is the stronger claim on the MR).
nonisolated enum MRRole: String, Codable, Hashable, Sendable, CaseIterable {
    case author
    case reviewer
}
