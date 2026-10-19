//
//  GitLabFixtures.swift
//  MyAppTests
//
//  Canned GitLab API JSON responses for GitLabClientTests, as Swift string literals
//  (simpler than bundled resource files — no `Bundle` path lookups to get wrong).
//

import Foundation

enum GitLabFixtures {

    // MARK: - /user

    static let user = #"{"id": 99, "username": "diego", "name": "Diego Pandolfo"}"#

    // MARK: - /merge_requests (list)

    /// Page 1 of a paginated list response. `updated_at` uses fractional seconds.
    static let listPage1 = #"""
    [
      {
        "id": 501, "iid": 3, "project_id": 42, "title": "Add retry logic to poller",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/3",
        "source_branch": "feature/retry-logic", "target_branch": "main",
        "draft": false, "updated_at": "2026-10-13T10:22:31.123Z",
        "references": {"full": "group/backend-api!3"}
      }
    ]
    """#

    /// Page 2 of a paginated list response — the last page (no `x-next-page` stubbed for
    /// it). `updated_at` has no fractional seconds, to exercise the other branch of
    /// `GitLabDateDecoding`.
    static let listPage2 = #"""
    [
      {
        "id": 502, "iid": 4, "project_id": 42, "title": "Second MR",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/4",
        "source_branch": "feature/second", "target_branch": "main",
        "draft": false, "updated_at": "2026-10-13T11:00:00Z",
        "references": {"full": "group/backend-api!4"}
      }
    ]
    """#

    static let listItemDraftFieldTrue = #"""
    [
      {
        "id": 503, "iid": 5, "project_id": 42, "title": "Draft work",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/5",
        "source_branch": "wip/a", "target_branch": "main",
        "draft": true, "updated_at": "2026-10-13T09:00:00Z",
        "references": {"full": "group/backend-api!5"}
      }
    ]
    """#

    /// No `draft` field at all — only the older `work_in_progress` field.
    static let listItemWorkInProgressFallback = #"""
    [
      {
        "id": 504, "iid": 6, "project_id": 42, "title": "Draft work 2",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/6",
        "source_branch": "wip/b", "target_branch": "main",
        "work_in_progress": true, "updated_at": "2026-10-13T09:00:00Z",
        "references": {"full": "group/backend-api!6"}
      }
    ]
    """#

    /// Neither `draft` nor `work_in_progress` — only the `"WIP:"` title prefix, as on the
    /// oldest GitLab instances.
    static let listItemTitlePrefixFallback = #"""
    [
      {
        "id": 505, "iid": 7, "project_id": 42, "title": "WIP: experiment",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/7",
        "source_branch": "wip/c", "target_branch": "main",
        "updated_at": "2026-10-13T09:00:00Z",
        "references": {"full": "group/backend-api!7"}
      }
    ]
    """#

    /// No `references` field at all — forces the `web_url`-derived project path fallback.
    static let listItemWithoutReferences = #"""
    [
      {
        "id": 506, "iid": 8, "project_id": 42, "title": "No references field",
        "web_url": "https://gitlab.example.com/group/backend-api/-/merge_requests/8",
        "source_branch": "feature/no-refs", "target_branch": "main",
        "draft": false, "updated_at": "2026-10-13T09:00:00Z"
      }
    ]
    """#

    // MARK: - /projects/:id/merge_requests/:iid (detail)

    /// Brand-new MR: no head pipeline yet.
    static let detailNoPipelineYet = #"""
    {
      "title": "New MR",
      "head_pipeline": null,
      "diverged_commits_count": 0,
      "detailed_merge_status": "mergeable",
      "has_conflicts": false,
      "blocking_discussions_resolved": true,
      "draft": false
    }
    """#

    /// A pipeline status this app doesn't know about yet (GitLab added one after this app
    /// was written). `diverged_commits_count` is omitted entirely.
    static let detailUnknownPipelineStatus = #"""
    {
      "title": "Future CI",
      "head_pipeline": {"status": "some_future_status"},
      "detailed_merge_status": "mergeable",
      "has_conflicts": false,
      "blocking_discussions_resolved": true,
      "draft": false
    }
    """#

    /// No `detailed_merge_status` — only the older `merge_status` field.
    static let detailMergeStatusFallback = #"""
    {
      "title": "Older instance MR",
      "head_pipeline": {"status": "success"},
      "diverged_commits_count": 1,
      "merge_status": "can_be_merged",
      "has_conflicts": false,
      "blocking_discussions_resolved": true,
      "draft": false
    }
    """#

    static let detailConflicting = #"""
    {
      "title": "Fix bug",
      "head_pipeline": {"status": "failed"},
      "diverged_commits_count": 5,
      "detailed_merge_status": "conflict",
      "has_conflicts": true,
      "blocking_discussions_resolved": false,
      "draft": false
    }
    """#

    // MARK: - /projects/:id/merge_requests/:iid/approvals

    static let approvalsZeroRequired = #"""
    {"approved": true, "approvals_left": 0, "approved_by": []}
    """#

    static let approvalsPending = #"""
    {
      "approved": false,
      "approvals_left": 2,
      "approved_by": [
        {"user": {"username": "alice"}},
        {"user": {"username": "bob"}}
      ]
    }
    """#
}
