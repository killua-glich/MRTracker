# MR Tracker

A macOS menu bar app and widget that shows your open GitLab merge requests at a glance:
pipeline status, commits behind the target branch, approvals, mergeability, unresolved
threads, drafts and conflicts — without opening GitLab in a browser.

Works with gitlab.com and self-hosted GitLab. Read-only: it never changes anything in
GitLab.

<img width="725" height="326" alt="image" src="https://github.com/user-attachments/assets/7c6492d8-4129-4e50-9aa6-cc266fcdff25" />


## Download

Get the latest `MR-Tracker-x.y.zip` from
[Releases](https://github.com/killua-glich/MRTracker/releases/latest), unzip it and move
**MR Tracker.app** to `/Applications`. The app is signed with a Developer ID and notarized
by Apple, so it opens without Gatekeeper warnings.

Requires **macOS 26** or later.

## Setup

1. Create a GitLab Personal Access Token with the **`read_api`** scope
   (GitLab → Preferences → Access Tokens). Developer role on your projects is enough.
2. Open MR Tracker from the menu bar → **Settings**, enter your GitLab URL
   (e.g. `https://gitlab.example.com`) and the token. The token is stored in your Keychain.
3. Pick how often to check (30 sec – 5 min) and what to track: MRs **authored by me**,
   ones I'm **reviewing**, or **both**.
4. Optional: add the widget (small, medium or large) from the desktop or Notification
   Center widget gallery. Clicking an MR opens it in your browser.

The app polls the GitLab REST API directly — no server, webhooks or third-party service.
Corporate root CAs installed in the macOS Keychain are trusted automatically.

## Building from source

Requires Xcode 26 and an Apple Developer account.

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set APP_DEVELOPMENT_TEAM
open "Untitled Project.xcodeproj"                         # scheme: MyApp
```

App name, bundle ID and App Group are set in [`Config/App.xcconfig`](Config/App.xcconfig);
override them in `Config/Local.xcconfig` if the defaults are registered to another team.

Run the tests:

```sh
xcodebuild test -project "Untitled Project.xcodeproj" -scheme MyApp -destination 'platform=macOS'
```
