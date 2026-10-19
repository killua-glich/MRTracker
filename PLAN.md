# GitLab MR Tracker — Plan

## Goal

Give a developer at a Java + Angular shop an always-visible, low-friction view of their
open merge requests on the company's self-hosted GitLab: pipeline status, how far behind
the target branch they are, approval state, mergeability, unresolved threads, draft state,
and conflicts — surfaced in a menu bar dropdown and a WidgetKit widget, so status can be
checked at a glance while working on other projects, without opening GitLab in a browser.

## Decisions

- **Polling only.** No server, no webhooks, no relay. The app polls the GitLab API on an
  interval.
- **Only a read token is required.** A Personal Access Token with scope `read_api` is the
  single thing the user provides (plus the GitLab base URL).
- **Developer role is enough.** Reading MRs, pipelines, approvals and diverged commit
  counts doesn't need Maintainer rights, so the app works across all projects the user can
  see, not only those they maintain.

## Scope

- macOS menu bar host app (SwiftUI `MenuBarExtra`, `LSUIElement`) that polls the GitLab
  REST API and stores results for the widget.
- WidgetKit widget (small/medium/large) showing the same MR data, deep-linking to GitLab
  in the browser.
- Shared data layer via App Group (host app writes, widget reads).
- Personal Access Token auth (scope `read_api`), stored in Keychain.
- Corporate network / VPN + corporate root CA support (CA is installed in macOS Keychain,
  so `URLSession` should trust it without extra app code — verify this holds, see Risks).

## Non-goals

- Webhooks, a relay service, or any server-side component.
- APNs / push-driven widget updates.
- iOS/iPadOS app or widget.
- Supporting multiple GitLab instances/accounts simultaneously (later candidate).
- Creating/merging/approving MRs from the app (read-only tracker).
- Offline-first history/analytics of past MRs.

## Architecture

```
GitLab (company) ◀──poll REST (read_api token)── macOS menu bar host app
                                                        │ write snapshot
                                                        ▼
                                                 App Group shared storage
                                                        │ WidgetCenter.reloadTimelines
                                                        ▼
                                                  WidgetKit widget
```

Widgets cannot run continuously — they render timeline snapshots and have a limited
daily reload budget. The host app owns all networking and decides when to write a new
snapshot and trigger a (debounced) widget reload.

## Components

### Host app (menu bar)
- SwiftUI `MenuBarExtra`, `LSUIElement = true` (no Dock icon, no main window required).
- Settings UI: GitLab base URL, Personal Access Token entry (→ Keychain), polling
  interval, which MRs to track (authored vs. reviewer).
- Polling scheduler: background `Task` loop using async/await (no Combine), configurable
  interval (default 60–120s), respects system sleep/wake.
- On each successful fetch: diff against last snapshot, write new snapshot to App Group
  container, call `WidgetCenter.shared.reloadTimelines(ofKind:)` (debounced and only on
  change, so the widget's reload budget isn't wasted).
- Menu bar dropdown renders the same `MergeRequestSnapshot` list used by the widget (shared
  SwiftUI views where possible).

### Menu bar popup (primary UI)
Clicking the menu bar icon opens a popup (`.menuBarExtraStyle(.window)`) with one row per
open MR:

```
┌──────────────────────────────────────────────────────────────────┐
│ backend-api     MR-03   [pipe]  [appr] approved       [beh] 2 behind      │
│ frontend-web    MR-17   [pipe]  [appr] approved       [ok]  up to date  • │
│ codefair        MR-08   [pipe]  [appr] not approved   [beh] 5 behind      │
├──────────────────────────────────────────────────────────────────┤
│ Updated 14:32 · Refresh now · Settings…                          │
└──────────────────────────────────────────────────────────────────┘
```

**Visual style: no emojis.** Only monochrome SF Symbols with semantic tint, system
font, native popup material. Clean and minimal, like system menu bar extras.

| Column | Content | SF Symbol (tint) |
| --- | --- | --- |
| Project | Project name (path, shortened), `.secondary` text | — |
| MR | `MR-<iid>`, monospaced digits | — |
| Pipeline | running / pending | `arrow.triangle.2.circlepath` (blue, rotating) |
| | success | `checkmark.circle` (green) |
| | failed | `xmark.circle` (red) |
| | none / canceled | `minus.circle` (secondary) |
| Approval | approved (`approved == true`) | `checkmark.seal` (green) + "approved" |
| | not approved | `seal` (secondary) + "not approved" |
| Behind | `diverged_commits_count` > 0 | `arrow.down.circle` (orange) + "N behind" |
| | up to date | `checkmark` (secondary) + "up to date" |
| Status dot | ready to merge (`detailed_merge_status == "mergeable"`) | green dot, see below |
| | anything else | no dot (empty slot keeps alignment) |

**Status dot** — modeled on the camera-in-use indicator on Apple devices: a small solid
green circle (~6–7 pt, `Color.green` / systemGreen), with a soft glow of the same color
(`.shadow(color: .green.opacity(0.6), radius: 3)`). No border, no symbol. Either lit
(ready to merge) or absent — like the camera light, it only appears when it means
something.

- Clicking a row opens the MR in the browser.
- Rows sorted by urgency: failed pipeline → conflicts → behind → healthy.
- Menu bar icon shows an aggregate status (green = all fine, red badge with count of MRs
  needing attention).

### Widget (WidgetKit extension, optional / later)
- Small: count/summary of open MRs needing attention (red count badge).
- Medium: top N MRs with pipeline/approval/conflict icons.
- Large: fuller list, more detail per MR (title, branch, status icons, behind-count).
- Display-only — reads `MergeRequestSnapshot` list from App Group, no networking.
- `widgetURL` (small) / `Link` (medium/large, one per row) deep-links to the MR's GitLab
  web URL in the default browser.
- Explicit empty state ("No open MRs"), error state (last fetch failed — show age of last
  good snapshot), and stale state (snapshot older than N minutes — dim/annotate).

### Shared data layer
- App Group container (`group.<teamid>.gitlabmrtracker`), JSON file written by host app,
  read by widget and host app menu.
- Keychain holds the PAT; App Group store holds no secrets, only MR snapshot data +
  metadata (last fetch time, last error).

## Data model sketch

```swift
struct MergeRequestSnapshot: Codable, Identifiable {
    var id: String                  // "projectId-iid"
    var projectId: Int
    var projectPath: String         // "group/backend-api" — shown as the Project column in the popup
    var iid: Int
    var title: String
    var webURL: URL
    var sourceBranch: String
    var targetBranch: String
    var roles: Set<MRRole>          // .author and/or .reviewer — an MR can be both at once
    var isDraft: Bool
    var pipelineStatus: PipelineStatus?   // .running, .success, .failed, .canceled, .pending, .none
    var divergedCommitsCount: Int?        // commits behind target
    var approved: Bool
    var approvalsLeft: Int?
    var approvedBy: [String]
    var detailedMergeStatus: String?      // mergeable, conflict, need_rebase, ci_must_pass, draft_status, ...
    var hasConflicts: Bool
    var blockingDiscussionsResolved: Bool
    var updatedAt: Date
}

struct SnapshotStore: Codable {
    var mergeRequests: [MergeRequestSnapshot]
    var lastFetchedAt: Date
    var lastError: String?
}
```

**MRT-020 implementation notes (deviations from the sketch above):**
- Added `projectPath: String` — the original sketch forgot it, but the menu bar popup's
  Project column (see "Menu bar popup" below) needs it.
- `role: MRRole` became `roles: Set<MRRole>` — an MR can be both authored by the current
  user and have them as a reviewer at the same time, so a single role field would lose
  information. See the doc comment on `MRRole` for the full rationale.
- `PipelineStatus` covers all of GitLab's real pipeline statuses (`created`,
  `waiting_for_resource`, `preparing`, `pending`, `running`, `success`, `failed`,
  `canceled`, `skipped`, `manual`, `scheduled`) plus `.unknown(String)` so decoding never
  fails on a status this app doesn't know about yet. It also exposes a `displayBucket`
  computed property mapping to the 4 buckets used by the popup (running/pending, success,
  failed, none/canceled) — pure data, no SF Symbols/colors (MRT-054).
- `MergeRequestSnapshot` and `SnapshotStore` live in `Shared/` (compiled into both the host
  app and the widget target) along with a shared `JSONEncoder.snapshot` /
  `JSONDecoder.snapshot` factory pair (`.iso8601` date strategy) so MRT-030's App Group
  store and these models' tests encode/decode identically.

## GitLab API mapping

| Info | Source |
| --- | --- |
| Current user | `GET /user` (token validation + username for reviewer filter) |
| Own MRs (authored) | `GET /merge_requests?scope=created_by_me&state=opened` |
| Own MRs (reviewing) | `GET /merge_requests?scope=all&state=opened&reviewer_username=<me>` |
| Pipeline status | `head_pipeline.status` on `GET /projects/:id/merge_requests/:iid` |
| Commits behind target | `diverged_commits_count` via `?include_diverged_commits_count=true` |
| Approvals | `GET /projects/:id/merge_requests/:iid/approvals` → `approved`, `approvals_left`, `approved_by` |
| Mergeability | `detailed_merge_status` on MR detail (mergeable, conflict, need_rebase, ci_must_pass, discussions_not_resolved, draft_status, ...) |
| Unresolved threads | `blocking_discussions_resolved` on MR detail |
| Draft state | `draft` field (or title prefix on older instances) |
| Conflicts | `has_conflicts` on MR detail |

All of these work with a `read_api` token and Developer role.

GraphQL (`/api/graphql`) could batch all of the above into a single query (avoids N+1
REST calls). Field names must be verified against the running instance's schema via
`/-/graphql-explorer` first — a later optimization, not needed for the MVP.

## Security

- PAT stored in Keychain (`kSecClassGenericPassword`); only the host app reads it — the
  widget never touches the network or the token.
- Token scope limited to `read_api` (read-only, no write access).
- Corporate root CA is installed in the macOS system Keychain, so `URLSession` with
  default `URLSessionConfiguration` should trust the corp-signed GitLab TLS cert with no
  extra code. Add an explicit check that fails loudly with a clear error if TLS validation
  fails, rather than silently retrying.
- No PAT ever stored in App Group shared storage or logs.

## Refresh strategy & widget budget

- Host app polls on a timer (configurable, default 60–120s) while running.
- Widget reloads are triggered only by the host app calling
  `WidgetCenter.shared.reloadTimelines`, and only when the snapshot actually changed
  (diff old vs. new) — avoids wasting the limited daily reload budget on no-op polls.
- Reload calls are debounced (collapse bursts within a few seconds into one reload).
- Each widget timeline entry carries an explicit "as of" timestamp so the UI can show
  staleness even between reloads.
- The menu bar dropdown has no budget limit and always shows the latest poll result.

## Phases

1. **MVP** — Menu bar app polls every 1–2 min (configurable); widget and dropdown display
   the data. Only a `read_api` token needed.
2. **Later** — Local notifications (pipeline failed, MR approved, needs rebase); GraphQL
   batching to replace per-MR REST calls; AppIntent-based widget configuration (pick
   project, filter author vs. reviewer); multiple GitLab accounts/instances.

## Risks

- Corp TLS: assumption that the installed root CA "just works" with `URLSession` needs
  verification on first run against the real instance.
- GitLab version drift: field names (`detailed_merge_status`, `draft`) vary across
  versions; confirm against the actual instance, not GitLab.com behavior.
- Polling latency: status can lag by up to one interval. Acceptable for "glance while
  working"; manual "Refresh now" covers the impatient case.
- Widget reload budget is modest; a buggy debounce could silently stop the widget from
  updating (show last-reload timestamp in settings for debugging).
- Rate limits on the self-hosted instance are unknown; N MRs × 2 detail calls per poll
  should stay small, but keep concurrency bounded.
- VPN/off-network periods: app should degrade gracefully (show "unreachable" state) rather
  than wiping the last good snapshot.

## Open questions

- GitLab version and tier (Free vs. Premium) — affects whether `approvals_left` reflects
  approval rules or just the basic approval count.
- Are `reviewer_username` and `detailed_merge_status` present on this instance's version,
  or does the MVP need a fallback (e.g. `merge_status` + `has_conflicts`)?
- Instance API rate limits.

## Tech stack

- Swift, SwiftUI, WidgetKit, async/await throughout (no Combine).
- Swift Testing for unit tests (mocked `URLProtocol` for API client tests).

## Assumptions

- **App identity is configured in one file:** `Config/App.xcconfig` (`APP_DISPLAY_NAME`,
  `APP_BUNDLE_ID`, `APP_GROUP_ID`, `APP_DEVELOPMENT_TEAM`). It is the project's base
  configuration; targets, entitlements and Info.plists (`AppGroupIdentifier`) reference
  these settings, and the code reads them at runtime (`Shared/AppGroup.swift`). Values
  below that name concrete IDs describe the defaults in that file.
- **Deployment target:** macOS 26.0 (set at the target level for both `MyApp` and
  `MRTrackerWidgetExtension`; project-level default was left at the Xcode-generated
  26.7.1 since the project-setup tools used here only expose target-level overrides —
  target-level wins, so both build configs resolve to 26.0 either way).
- **Swift version:** 6.0, for both targets.
- **Bundle IDs:** host app `dev.diegopandolfo.MRTracker`; widget extension
  `dev.diegopandolfo.MRTracker.MRTrackerWidget` (auto-derived from the host's
  bundle ID + target name, per Xcode's `<host>.<extension>` convention).
- **App Group ID:** `group.dev.diegopandolfo.mrtracker`. Apple's current
  guidance (see "Accessing app group containers in your existing macOS app") is that
  macOS app groups should use the `group.<name>` form; the `<Developer team
  ID>.<group name>` form is only "supported with limitations" (notably: it doesn't
  work as a Keychain Access Group and isn't supported on other Apple platforms at
  all). Since this project may eventually want Keychain-based sharing too, the
  `group.`-prefixed form was chosen over the team-ID-prefixed form mentioned in the
  original plan sketch.
- **Host app source folder naming:** the ticket suggested a synchronized source
  folder named `MyApp/`. The Xcode automation tooling used for this setup
  (fileSystemSynchronizedGroups via the xcode-tools MCP server) got stuck in a broken
  state for a path literally named `MyApp` after an earlier failed attempt (repeated
  "User intent 'move' not in allowed file actions" errors), so the host app's SwiftUI
  source lives in `MyAppSources/MyAppApp.swift` instead. Functionally identical to
  `MyApp/`, just a different folder name on disk.
