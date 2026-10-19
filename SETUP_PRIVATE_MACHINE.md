# Runbook: move MR Tracker to a private machine, sign, notarize, distribute

Written for a coding agent (or a human) working on the **private** Mac. Follow the steps
in order; each has a verification command. Stop and ask the owner where a step says
**ASK** — those are decisions or credentials only they have.

Goal: the project builds and runs on the private Mac under the owner's **personal** Apple
Developer account, with no identifiers from the original (company) machine left, and can
be exported as a notarized Developer ID app that others can download and open.

## 0. Facts about this project (read first)

- macOS 26+ menu bar app (`LSUIElement`) + WidgetKit extension, Swift 6, SwiftUI.
- Xcode project: `Untitled Project.xcodeproj`. Targets: `MyApp` (host app, product name
  comes from config), `MRTrackerWidgetExtension`, `MyAppTests` (Swift Testing, hosted in
  the app). Scheme for building/testing: `MyApp`.
- **All identity lives in `Config/App.xcconfig`** — the project's base configuration:
  `APP_DISPLAY_NAME`, `APP_BUNDLE_ID`, `APP_GROUP_ID`, `APP_DEVELOPMENT_TEAM`. Targets,
  both `.entitlements` files and both Info.plists (`AppGroupIdentifier`) reference these;
  Swift reads them at runtime (`Shared/AppGroup.swift`). Do not hardcode IDs anywhere else.
- Source folders are file-system-synchronized groups (`MyAppSources/`, `Shared/`,
  `MRTrackerWidget/`, `MyAppTests/`): new files placed there join the target automatically.
- App target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; non-UI types are marked
  `nonisolated`.
- Running the tests launches the app as test host and replaces a running copy — relaunch
  the app afterwards.
- After rebuilding the widget, the old widget extension process keeps rendering old code
  until it's killed (`pkill -f MRTrackerWidgetExtension`) or the widget is re-added.

## 1. Copy the project — without the company repo's history

The folder currently lives inside a larger company-machine git repo. Do **not** clone or
copy that parent repo. Copy only this folder, then start a fresh repository:

```sh
# on the private Mac, after copying the gitlab-mr-tracker folder over (AirDrop/USB/zip):
cd gitlab-mr-tracker
rm -rf "Untitled Project.xcodeproj/xcuserdata" "Untitled Project.xcodeproj/project.xcworkspace/xcuserdata"
git init && git add . && git status   # review: no DerivedData, no xcuserdata, no build/
```

Verify: `git log` is empty (fresh repo) and `.gitignore` is present.
**ASK** before the first commit / before adding a remote (owner chooses where to push).

## 2. Set the owner's identity in `Config/App.xcconfig`

**ASK** the owner for:
1. App name (`APP_DISPLAY_NAME`, default `MR Tracker`).
2. Their personal Apple Developer **Team ID** (developer.apple.com → Account → Membership,
   or Xcode → Settings → Accounts → team). It must NOT be `P44SA62BTF` (that's the company
   machine's team).
3. A reverse-DNS prefix they own (e.g. `dev.theirname`). Use it for both IDs:

In `Config/App.xcconfig` (tracked in git):

```
APP_DISPLAY_NAME     = <name>
APP_BUNDLE_ID        = <prefix>.MRTracker
APP_GROUP_ID         = group.<prefix>.mrtracker      // must start with "group."
APP_DEVELOPMENT_TEAM =                               // stays empty in the repo
```

The team goes into `Config/Local.xcconfig` (git-ignored, included by `App.xcconfig`).
Delete any copied-over `Local.xcconfig` (it holds the company team) and recreate it from
the example:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then set: APP_DEVELOPMENT_TEAM = <TEAMID>
git check-ignore Config/Local.xcconfig   # must print the path (i.e. it is ignored)
```

Verify nothing else carries old identifiers:

```sh
grep -rnI -E "P44SA62BTF|com\.pandolfodiego|group\.com\.pandolfodiego" \
  --exclude-dir=xcuserdata --exclude-dir=DerivedData . 
```

Expected: only historical mentions in `PLAN.md` → update those lines in the
"Assumptions" section to the new values (or replace them with "see Config/App.xcconfig").

## 3. Signing in Xcode

1. Open `Untitled Project.xcodeproj` in Xcode, sign in with the personal Apple ID
   (Xcode → Settings → Accounts).
2. For targets `MyApp` and `MRTrackerWidgetExtension`: Signing & Capabilities →
   "Automatically manage signing" ON. The Team should already show the xcconfig team; if
   Xcode shows a different/none team, pick the personal team (do not type a team
   override into the target — keep it coming from the xcconfig).
3. Confirm the App Groups capability on both targets lists the new `APP_GROUP_ID`
   (it's expanded from `$(APP_GROUP_ID)`); let Xcode register it if prompted.
4. Product → Clean Build Folder, then build scheme `MyApp` (destination My Mac).

Verify the built product (path from Xcode's Products / DerivedData):

```sh
APP="$(ls -d ~/Library/Developer/Xcode/DerivedData/Untitled_Project-*/Build/Products/Debug/*.app | head -1)"
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleIdentifier|CFBundleName|AppGroupIdentifier"
codesign -d --entitlements - --xml "$APP" | plutil -p - | grep -A2 application-groups
codesign -d --entitlements - --xml "$APP/Contents/PlugIns/MRTrackerWidgetExtension.appex" | plutil -p - | grep -A2 application-groups
```

All values must be the new ones, and app + widget must list the same App Group.

## 4. Run tests and the app

- Run all tests on scheme `MyApp` (Xcode ⌘U or `xcodebuild test -scheme MyApp -destination 'platform=macOS'`).
  Expect all green; `MyAppTests/appGroupIdentifierComesFromConfigAndResolves` proves the
  App Group from the xcconfig reaches the code and the container resolves.
- Run the app (⌘R). Owner checks: menu bar icon appears, Settings… opens, entering their
  GitLab URL + `read_api` token shows "Signed in as …", MRs appear in the popup, widget
  (right-click desktop → Edit Widgets → app name) shows the same data.

Note: the GitLab token, settings and snapshot are per machine and per bundle ID — nothing
carries over from the company machine; the owner enters URL + token again.

## 5. Prepare for distribution (Developer ID, outside the App Store)

Requires a **paid** Apple Developer Program membership on the personal account.

1. **Hardened Runtime** (required for notarization) — add to `Config/App.xcconfig`:
   ```
   ENABLE_HARDENED_RUNTIME = YES
   ```
   Build + run again to confirm nothing breaks (the app needs no runtime exceptions).
2. **Version**: set `MARKETING_VERSION` (e.g. `1.0.0`) and `CURRENT_PROJECT_VERSION` on
   the `MyApp` and widget targets (keep them equal) — or move both into the xcconfig.
3. **Developer ID certificate**: Xcode → Settings → Accounts → Manage Certificates → `+`
   → "Developer ID Application" (automatic signing creates it during export if missing).

## 6. Archive, notarize, export

Xcode UI (simplest):
1. Scheme `MyApp`, destination "Any Mac". Product → Archive.
2. Organizer → Distribute App → **Direct Distribution** → Upload (Xcode notarizes with
   Apple and staples the ticket) → Export to a folder.

CLI alternative (for automation): `xcodebuild archive -scheme MyApp -archivePath build/MRTracker.xcarchive`,
then `xcodebuild -exportArchive` with an ExportOptions.plist using
`method = developer-id`, then `xcrun notarytool submit <zip> --keychain-profile <profile> --wait`
and `xcrun stapler staple "<App>.app"`. **ASK** the owner to create the notarytool
keychain profile themselves (`xcrun notarytool store-credentials`) — never handle their
Apple ID password or app-specific password in files or logs.

Verify the exported app:

```sh
codesign -dv --verbose=2 "<App>.app" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime"
spctl -a -vvv -t exec "<App>.app"          # expect: accepted, source=Notarized Developer ID
xcrun stapler validate "<App>.app"         # expect: The validate action worked!
```

Package for download: `ditto -c -k --keepParent "<App>.app" "<App>.zip"` (or a DMG).
Users install by moving the app to /Applications; first launch shows the standard
"downloaded from the internet" prompt only.

## 7. Optional cleanup

- Rename `Untitled Project.xcodeproj` → e.g. `MRTracker.xcodeproj`: close Xcode first,
  rename the folder in Finder, reopen. Schemes are auto-generated, nothing else references
  the project file name. Rebuild and re-run tests afterwards.
- Don't rename the targets (`MyApp`, …) without also updating `PRODUCT_MODULE_NAME`,
  `@testable import MyApp` in tests and `TEST_HOST`; the visible app name already comes
  from `APP_DISPLAY_NAME`.
- Regenerate the icon after design tweaks: `swift Design/make_app_icon.swift`.

## Done when

- [ ] Fresh git repo, no company history, no `P44SA62BTF` / old IDs left
- [ ] Builds, all tests pass, app + widget work with the owner's GitLab
- [ ] Hardened Runtime on, archive exported as Developer ID, notarized and stapled
- [ ] `spctl` reports "accepted, source=Notarized Developer ID"
