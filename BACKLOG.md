# GitLab MR Tracker — Backlog

## Status (2026-10-19)

- **MVP complete:** MRT-001 … MRT-072 implemented. 260 unit tests pass on scheme `MyApp`.
  Verified by the owner: menu bar popup with live MRs from the company GitLab (corp TLS
  works), Settings sign-in, widget reads the shared App Group snapshot.
- **Open:** a few runtime-only checks, marked "(manual check)" below — mostly widget
  layouts/taps and the degraded menu bar icon. Also unchecked at runtime: sleep/wake
  polling (MRT-040).
- **Not started:** the later items (MRT-100 … MRT-105).
- Since the original plan: app renamed to "MR Tracker" with an app icon; app identity
  lives in `Config/App.xcconfig` (+ git-ignored `Config/Local.xcconfig`); move to the
  private machine and distribution: `SETUP_PRIVATE_MACHINE.md`.

Legend: `[x]` = verified (unit tests or by the owner in the running app); `[ ]` with a
note = implemented but still needs the noted check; plain `[ ]` = not done.

Scope: polling only — no server, no webhooks; a `read_api` token is all the user provides.

Ticket IDs: `MRT-###`. Estimates: S (≤ half day), M (1–2 days), L (3+ days).

## Epic: Project setup

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-001 | Create Xcode project + host app target | — | Done (fresh git repo: on private machine) |
| MRT-002 | Add widget extension target | MRT-001 | Done, manual check open |
| MRT-003 | Configure App Group + shared entitlements | MRT-001, MRT-002 | Done |
| MRT-004 | Set host app to `LSUIElement` (menu bar only) | MRT-001 | Done |

**MRT-001 — Create Xcode project + host app target** (S)
Create the macOS app project with a SwiftUI host app target, minimum deployment target
set appropriately for current WidgetKit APIs.
- [x] Project builds and runs an empty SwiftUI app
- [x] Deployment target and Swift version recorded in PLAN.md assumptions
- [ ] Git repo initialized with sensible `.gitignore` (`.gitignore` done; the fresh repo is created on the private machine, see SETUP_PRIVATE_MACHINE.md)

**MRT-002 — Add widget extension target** (S)
Add a WidgetKit extension target to the project.
- [x] Widget extension target builds and shows a placeholder widget in the widget gallery
- [ ] Widget scheme runs in Xcode's widget preview/simulator (manual check: the preview tool used here can't render widgets)

**MRT-003 — Configure App Group + shared entitlements** (S)
Create an App Group identifier, add the entitlement to both the host app and widget
extension targets, and verify a shared container is reachable from both.
- [x] App Group entitlement present on both targets
- [x] Host app can write a test file to the shared container and widget can read it
- [x] App Group ID documented in PLAN.md / README

**MRT-004 — Set host app to `LSUIElement` (menu bar only)** (S)
Configure the host app's Info.plist so it runs as a menu bar app with no Dock icon or
main window, using `MenuBarExtra`.
- [x] App launches with no Dock icon
- [x] `MenuBarExtra` icon appears and opens a dropdown
- [x] App remains running with no visible windows

## Epic: Keychain & settings

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-010 | Keychain wrapper for PAT storage | MRT-001 | Done |
| MRT-011 | Settings UI: GitLab URL + PAT entry | MRT-010 | Done |
| MRT-012 | Settings UI: polling interval + author/reviewer filter | MRT-011 | Done |

**MRT-010 — Keychain wrapper for PAT storage** (M)
Implement a small async/await-friendly Keychain wrapper (`kSecClassGenericPassword`) to
save/read/delete the Personal Access Token.
- [x] Token can be saved, read back, and deleted
- [x] No token value ever appears in logs
- [x] Unit tests cover save/read/delete/missing-token paths

**MRT-011 — Settings UI: GitLab URL + PAT entry** (M)
SwiftUI settings screen where the user enters the GitLab base URL and a PAT; validate by
calling a lightweight authenticated endpoint (e.g. `GET /user`).
- [x] Invalid URL or token shows a clear inline error
- [x] Successful validation shows the authenticated username
- [x] Token is written to Keychain only after successful validation

**MRT-012 — Settings UI: polling interval + author/reviewer filter** (S)
Add controls for polling interval (default 60–120s) and whether to include MRs where the
user is author, reviewer, or both.
- [x] Settings persist across app restarts (e.g. `UserDefaults` for non-secret prefs)
- [x] Changing interval takes effect without restarting the app

## Epic: GitLab API client

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-020 | Define `MergeRequestSnapshot` + related models | MRT-001 | Done |
| MRT-021 | API client: list MRs (authored / reviewer) | MRT-020, MRT-010 | Done |
| MRT-022 | API client: MR detail incl. diverged commits count | MRT-021 | Done |
| MRT-023 | API client: approvals endpoint | MRT-021 | Done |
| MRT-024 | Merge detail + approvals into full snapshot | MRT-022, MRT-023 | Done |
| MRT-025 | Corp TLS sanity check on first run | MRT-021 | Done |

**MRT-020 — Define `MergeRequestSnapshot` + related models** (S)
Implement the `MergeRequestSnapshot`, `SnapshotStore`, `PipelineStatus`, `MRRole`
`Codable` types per PLAN.md's data model sketch.
- [x] Models compile and round-trip through `JSONEncoder`/`JSONDecoder` in a test
- [x] Fields match the GitLab API mapping table in PLAN.md

**MRT-021 — API client: list MRs (authored / reviewer)** (M)
Implement `GET /merge_requests?scope=created_by_me&state=opened` and the
`reviewer_username=` variant, using async/await `URLSession`.
- [x] Returns typed, decoded MR list for both authored and reviewer scopes
- [x] Handles pagination (`Link` header or `page`/`per_page`) if MR count exceeds one page
- [x] Non-2xx responses surface a typed error, not a silent empty list

**MRT-022 — API client: MR detail incl. diverged commits count** (M)
Implement `GET /projects/:id/merge_requests/:iid?include_diverged_commits_count=true` and
decode `head_pipeline.status`, `diverged_commits_count`, `detailed_merge_status`,
`has_conflicts`, `blocking_discussions_resolved`, `draft`.
- [x] All listed fields decode correctly against a sample fixture response
- [x] Missing/null fields (e.g. no pipeline yet) don't crash decoding

**MRT-023 — API client: approvals endpoint** (S)
Implement `GET /projects/:id/merge_requests/:iid/approvals` and decode `approved`,
`approvals_left`, `approved_by`.
- [x] Decodes correctly against a sample fixture response
- [x] Handles the case of zero required approvals

**MRT-024 — Merge detail + approvals into full snapshot** (M)
Orchestrate list → detail → approvals calls (sequentially or concurrently via
`async let`) into one `MergeRequestSnapshot` per MR.
- [x] Produces a complete `[MergeRequestSnapshot]` for a mixed authored+reviewer fetch
- [x] Partial failure on one MR's detail/approvals call doesn't abort the whole batch
- [x] Concurrency is bounded (no unbounded fan-out on large MR counts)

**MRT-025 — Corp TLS sanity check on first run** (S)
On first launch (or first failed request), perform a test request and surface a clear,
actionable error if TLS validation fails, instead of a generic network error.
- [x] Simulated TLS failure produces a user-readable message pointing at the corp CA
- [x] Successful corp TLS handshake is silent (no extra UI noise)

## Epic: Shared storage & snapshot

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-030 | App Group snapshot store (write/read) | MRT-003, MRT-020 | Done |
| MRT-031 | Diffing: detect snapshot changes to gate widget reload | MRT-030 | Done |

**MRT-030 — App Group snapshot store (write/read)** (M)
Implement a store that serializes `SnapshotStore` to JSON in the App Group container, with
atomic writes (write-to-temp + rename) so the widget never reads a half-written file.
- [x] Host app write is atomic and safe against concurrent widget reads
- [x] Widget can read the latest snapshot via the same store type
- [x] Corrupted/missing file falls back to an empty-but-valid state, not a crash

**MRT-031 — Diffing: detect snapshot changes to gate widget reload** (S)
Compare newly fetched snapshot to the previously stored one; only write + trigger reload
if something user-visible changed.
- [x] No-op poll (nothing changed) does not call `reloadTimelines`
- [x] Any changed field (pipeline, approval, conflicts, etc.) is detected as a change
- [x] Unit tests cover equal vs. differing snapshots

## Epic: Polling & reload scheduling

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-040 | Polling scheduler (async/await timer loop) | MRT-024, MRT-012 | Done |
| MRT-041 | Debounced widget reload trigger | MRT-031, MRT-040 | Done |

**MRT-040 — Polling scheduler (async/await timer loop)** (M)
Background `Task` that fetches on the configured interval, respecting app lifecycle
(pause when system is asleep, resume on wake).
- [x] Polling starts on app launch and stops cleanly on quit
- [x] Interval change from settings takes effect on the next cycle without restart
- [x] A failed fetch records `lastError`/timestamp without crashing the loop

**MRT-041 — Debounced widget reload trigger** (S)
Wrap `WidgetCenter.shared.reloadTimelines` calls in a debounce (e.g. collapse calls within
a short window into one) to protect the daily reload budget.
- [x] Rapid repeated "snapshot changed" signals result in a single reload call
- [x] Reload still happens promptly for an isolated single change

## Epic: Widget UI (optional — menu bar popup is the primary UI)

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-050 | Timeline provider reading shared snapshot | MRT-030 | Done |
| MRT-051 | Small widget: summary/count view | MRT-050 | Done, manual check open |
| MRT-052 | Medium widget: top-N MR list with status icons | MRT-050 | Done |
| MRT-053 | Large widget: full MR list with detail | MRT-050 | Done, manual check open |
| MRT-054 | Status icon set (pipeline, approval, conflict, draft, behind-count) | MRT-020 | Done |
| MRT-055 | Deep links to GitLab MR pages | MRT-051, MRT-052, MRT-053 | Done, manual check open |
| MRT-056 | Empty / error / stale states in widget | MRT-050 | Done, manual check open |

**MRT-050 — Timeline provider reading shared snapshot** (M)
Implement `TimelineProvider`/`AppIntentTimelineProvider` reading from the App Group store,
with no networking in the widget process.
- [x] `getTimeline` returns entries built only from the on-disk snapshot
- [x] Widget never performs a network call directly

**MRT-051 — Small widget: summary/count view** (S)
Show a compact count of open MRs needing attention (e.g. failed pipeline, conflicts, or
awaiting the user's review), with a badge-style indicator.
- [ ] Renders correctly with 0, 1, and many MRs (logic unit-tested; visual check of the new layout open)
- [ ] Tapping opens the app or the most relevant MR via `widgetURL` (manual check)

**MRT-052 — Medium widget: top-N MR list with status icons** (M)
List the top N (e.g. 3–4) MRs sorted by urgency, each with pipeline/approval/conflict
icons.
- [x] Sort order prioritizes failed pipelines / conflicts / needs-review over healthy MRs
- [x] Truncates gracefully when there are more MRs than fit

**MRT-053 — Large widget: full MR list with detail** (M)
Fuller list view: title, branches, behind-count, and all status icons per row.
- [ ] Scales to a reasonable max row count without visual overflow (manual check)
- [x] Shares row view code with the menu bar dropdown where practical

**MRT-054 — Status icon set (pipeline, approval, conflict, draft, behind-count)** (S)
Define a small reusable set of SF Symbols + colors mapping to pipeline status, approval
state, conflict/mergeability, draft flag, and "N commits behind."
- [x] Each state in the data model maps to an unambiguous icon/color
- [x] Icons are shared between widget and menu bar views (single source of truth)

**MRT-055 — Deep links to GitLab MR pages** (S)
Wire `widgetURL` (small) and per-row `Link` (medium/large) to each MR's `web_url`.
- [ ] Tapping a row opens that specific MR in the default browser (manual check)
- [ ] Small widget's single tap target opens a sensible default (e.g. most urgent MR) (logic unit-tested; manual check open)

**MRT-056 — Empty / error / stale states in widget** (S)
Explicit widget rendering for: no open MRs, last fetch failed, and snapshot older than a
configurable staleness threshold.
- [ ] Empty state shows a friendly "No open MRs" message (implemented; manual check)
- [ ] Error state surfaces that data may be out of date, without a raw error dump (implemented; manual check)
- [ ] Stale snapshot is visually distinguished (e.g. dimmed, timestamp shown) (implemented; manual check)

## Epic: Menu bar UI

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-060 | Menu bar dropdown MR list | MRT-030, MRT-054 | Done, manual check open |
| MRT-061 | Menu bar: manual refresh action | MRT-040, MRT-060 | Done |
| MRT-062 | Menu bar: settings entry point | MRT-011, MRT-060 | Done, manual check open |

**MRT-060 — Menu bar dropdown MR list** (M)
Render the current snapshot's MRs in a `MenuBarExtra` popup (`.menuBarExtraStyle(.window)`)
using the row layout from PLAN.md → "Menu bar popup":
`[ project  MR-03  pipeline  approved/not approved  behind-or-clean  status dot ]`.
- [x] Each row shows project, `MR-<iid>`, pipeline icon, approved / not approved
- [x] Behind column shows `arrow.down.circle` + "N behind", or `checkmark` + "up to date" when 0
- [x] No emojis anywhere — only monochrome SF Symbols with semantic tint (per PLAN.md table)
- [x] Status dot: small solid green circle with soft glow (camera-indicator style), shown only
      when `detailed_merge_status == "mergeable"`, empty slot otherwise (alignment kept)
- [x] Rows sorted by urgency (failed → conflicts → behind → healthy)
- [x] Footer shows last update time, "Refresh now", "Settings…"
- [ ] Clicking a row opens that MR in the browser (manual check)

**MRT-061 — Menu bar: manual refresh action** (S)
Add a "Refresh now" action that triggers an out-of-cycle fetch.
- [x] Manual refresh respects the same error handling as the scheduled poll
- [x] UI shows a brief in-progress indicator during manual refresh

**MRT-062 — Menu bar: settings entry point** (S)
Add a menu item opening the settings UI (MRT-011/MRT-012).
- [x] Settings window opens from the dropdown
- [ ] Menu bar icon reflects degraded state (e.g. auth error, unreachable) when relevant (implemented; manual check)

## Epic: Testing

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-070 | Mocked `URLProtocol` test harness | MRT-021 | Done |
| MRT-071 | Unit tests: API client decoding + error paths | MRT-070, MRT-024 | Done |
| MRT-072 | Unit tests: snapshot diffing + store | MRT-031, MRT-030 | Done |

**MRT-070 — Mocked `URLProtocol` test harness** (M)
Build a reusable `URLProtocol` subclass + `URLSession` factory for injecting canned
responses/errors in tests, per Swift Testing conventions.
- [x] Harness can stub a response by request matcher (path/method)
- [x] Harness can simulate network errors and non-2xx status codes

**MRT-071 — Unit tests: API client decoding + error paths** (M)
Swift Testing tests covering list/detail/approvals decoding against fixture JSON, plus
pagination and error handling.
- [x] Fixtures cover at least: no pipeline yet, draft MR, conflicting MR, fully approved MR
- [x] Error responses (401, 404, 429, 500) each produce a distinct typed error

**MRT-072 — Unit tests: snapshot diffing + store** (S)
Tests for MRT-031's diff logic and MRT-030's atomic read/write behavior.
- [x] Diff tests cover every field that should trigger a reload
- [x] Store tests cover corrupted-file and missing-file recovery

## Epic: Later items

| ID | Title | Dependencies | Status |
| --- | --- | --- | --- |
| MRT-100 | Local notifications (pipeline failed, approved, needs rebase) | MRT-031 | Not started |
| MRT-101 | GraphQL batching to replace per-MR REST calls | MRT-024 | Not started |
| MRT-102 | AppIntent widget configuration (project / author vs reviewer filter) | MRT-050 | Not started |
| MRT-104 | Multiple GitLab accounts/instances | MRT-010, MRT-030 | Not started |
| MRT-105 | GitHub pull request support (github.com + GitHub Enterprise) | MRT-024, MRT-104 (recommended) | Not started |

**MRT-100 — Local notifications (pipeline failed, approved, needs rebase)** (M)
Fire a local notification when the diff (MRT-031) detects specific transitions (e.g.
pipeline success → failed, approval granted, became out of date).
- [ ] Each notable transition type has a distinct, clear notification
- [ ] Notifications are not duplicated across consecutive polls for the same transition

**MRT-101 — GraphQL batching to replace per-MR REST calls** (L)
Replace the list→detail→approvals REST sequence with a single (or few) GraphQL query/queries,
after verifying field availability via `/-/graphql-explorer` on the real instance.
- [ ] One GraphQL round trip returns everything MRT-024 currently assembles from 3 calls
- [ ] Falls back to REST client if GraphQL schema lacks a needed field on this instance

**MRT-102 — AppIntent widget configuration (project / author vs reviewer filter)** (M)
Let the user configure each widget instance (via `AppIntentConfiguration`) to filter by
project and/or author vs. reviewer role.
- [ ] Widget configuration UI lets the user pick project(s) and role filter
- [ ] Different widget instances on the desktop can show different filtered views

**MRT-104 — Multiple GitLab accounts/instances** (L)
Support tracking MRs across more than one GitLab instance or account simultaneously.
- [ ] Settings UI supports adding/removing multiple accounts
- [ ] Snapshot model and widget UI disambiguate MRs by account/instance

**MRT-105 — GitHub pull request support (github.com + GitHub Enterprise)** (L)
Track open GitHub pull requests (authored + review requested) alongside or instead of
GitLab MRs, in the same popup and widget. Same principles as GitLab: polling only, one
read-only token, no server.

Approach: add a GitHub fetcher that produces the existing `MergeRequestSnapshot`, so the
snapshot store, diffing, polling, popup, widget and status icons are reused unchanged.
`SnapshotAssembler` already depends on a fetch protocol (`GitLabFetching`); generalize it
to a provider-neutral protocol (e.g. `MergeRequestProvider`) with GitLab and GitHub
implementations. Prefer one GraphQL query (`/graphql`, or `<host>/api/graphql` for
Enterprise) over per-PR REST calls.

Field mapping (verify against the GitHub GraphQL schema before implementing):

| Snapshot field | GitHub source |
| --- | --- |
| list (author / reviewer) | `search(type: ISSUE, query: "is:pr is:open author:@me")` / `"review-requested:@me"` |
| `projectPath` | `repository.nameWithOwner` |
| `iid`, `title`, `webURL` | `number`, `title`, `url` |
| `sourceBranch` / `targetBranch` | `headRefName` / `baseRefName` |
| `isDraft` | `isDraft` |
| `pipelineStatus` | `commits(last: 1) { commit { statusCheckRollup { state } } }` → SUCCESS / FAILURE·ERROR / PENDING·EXPECTED / none |
| `approved` | `reviewDecision == APPROVED` |
| `approvalsLeft` | n/a → `nil` (GitHub exposes no "approvals left") |
| `approvedBy` | `latestReviews(states: APPROVED) { author { login } }` |
| `divergedCommitsCount` | REST compare `GET /repos/{o}/{r}/compare/{head}...{base}` → `behind_by` (GraphQL has no behind count; fetch with bounded concurrency, or leave `nil` = "unknown") |
| `detailedMergeStatus` / ready dot | `mergeStateStatus`: `CLEAN` → "mergeable" (dot), `DIRTY` → conflict, `BEHIND`, `BLOCKED`, `UNSTABLE`, `DRAFT` |
| `hasConflicts` | `mergeable == CONFLICTING` |
| `blockingDiscussionsResolved` | `reviewThreads(first: 100) { nodes { isResolved } }` → all resolved |
| `updatedAt` | `updatedAt` |

Scope / tasks:
- Provider-neutral fetch protocol; GitLab client conforms without behavior change.
- `GitHubClient` (GraphQL + the compare call), typed errors mapped like `GitLabAPIError`
  (401, 403 incl. secondary rate limit, `X-RateLimit-Remaining` / `Retry-After`), TLS
  diagnostics reused for Enterprise hosts behind a corporate CA.
- Settings: provider choice (GitLab / GitHub), base URL (default `https://api.github.com`,
  editable for Enterprise), token entry validated via `viewer { login name }`. Token
  stored in Keychain under its host like the GitLab token.
- Token guidance in Settings: fine-grained PAT with read-only *Pull requests*, *Commit
  statuses* / *Checks* and *Metadata* permissions (or classic `repo` for private repos —
  explain the trade-off).
- UI labels by provider: `PR #12` vs `MR-12`; widget and popup otherwise unchanged.
- Snapshot ids stay unique across providers (e.g. prefix `gh-`/`gl-`) — required if both
  run at once (MRT-104).
- Tests: `MockURLProtocol` fixtures for the GraphQL response (draft PR, conflicting PR,
  approved PR, failing checks, no checks), mapping table above, error paths.

Acceptance criteria:
- [ ] With a GitHub token configured, authored and review-requested PRs appear in the
      popup and widget with pipeline, approval, behind, draft, conflict and ready states
- [ ] Works against github.com and a GitHub Enterprise Server base URL
- [ ] One poll costs one GraphQL request plus at most N bounded compare calls; rate-limit
      responses back off instead of hammering
- [ ] GitLab behavior unchanged (all existing tests pass)
- [ ] Combined with MRT-104: GitLab and GitHub accounts can be tracked at the same time,
      rows show which provider they come from

Suggested model split: Opus for the provider abstraction + GraphQL client and mapping;
Sonnet for settings UI, labels and fixtures.
