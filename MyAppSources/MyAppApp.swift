import SwiftUI

/// Owns the sync coordinator so polling starts at launch (not when the popup first
/// opens — `MenuBarExtra` content is created lazily) and stops cleanly on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sync = SyncCoordinator.live()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sync.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sync.stop()
    }
}

@main
struct MyAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(sync: appDelegate.sync)
        } label: {
            MenuBarIcon(sync: appDelegate.sync)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(\.settingsDidChange, SettingsDidChangeAction { [sync = appDelegate.sync] in
                    sync.settingsDidChange()
                })
        }
    }
}

/// Menu bar icon reflecting aggregate status (PLAN.md: green = all fine, count of MRs
/// needing attention otherwise; MRT-062: degraded state on auth/network/TLS problems).
private struct MenuBarIcon: View {
    let sync: SyncCoordinator

    var body: some View {
        if sync.status.problem != nil {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel("GitLab MRs: sync problem")
        } else {
            let attention = sync.snapshot.mergeRequests.filter { $0.urgency != .healthy }.count
            if attention > 0 {
                // Menu bar extras render as template images; a count next to the icon
                // is the native way to badge them.
                Label("\(attention)", systemImage: "arrow.triangle.merge")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("GitLab MRs: \(attention) need attention")
            } else {
                Image(systemName: "arrow.triangle.merge")
                    .accessibilityLabel("GitLab MRs")
            }
        }
    }
}

/// The `MenuBarExtra` popup's content: the live MR list driven by `SyncCoordinator`.
private struct MenuBarPopoverView: View {
    let sync: SyncCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MergeRequestListPopup(
            snapshot: sync.snapshot,
            isRefreshing: sync.isRefreshing,
            statusMessage: statusMessage,
            onOpen: { NSWorkspace.shared.open($0) },
            onRefresh: { Task { await sync.refreshNow() } },
            onOpenSettings: {
                // `LSUIElement` apps aren't activated just by opening a window, so the
                // Settings window would otherwise appear behind other apps.
                NSApplication.shared.activate()
                openSettings()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    private var statusMessage: String? {
        switch sync.status {
        case .notConfigured:
            "Add your GitLab URL and access token in Settings."
        case .degraded(let problem):
            problem.message
        case .idle, .ok:
            nil
        }
    }
}
