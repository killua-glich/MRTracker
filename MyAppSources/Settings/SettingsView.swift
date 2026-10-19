//
//  SettingsView.swift
//  MyApp
//
//  Settings UI: GitLab base URL + PAT entry (MRT-011), backed by
//  `GitLabAccountSettingsModel`; polling interval + author/reviewer filter (MRT-012),
//  backed by `PollingSettingsModel`. Opened via the `Settings` scene in MyAppApp.swift.
//

import SwiftUI

/// Called after any saved settings change; the app wires this to the poller. A struct
/// (rather than a bare closure) so the environment value is Equatable — set once at
/// launch, it never needs to invalidate dependents.
struct SettingsDidChangeAction: Equatable {
    private let id = UUID()
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void = {}) {
        self.action = action
    }

    @MainActor func callAsFunction() { action() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var settingsDidChange = SettingsDidChangeAction()
}

struct SettingsView: View {
    @State private var model = GitLabAccountSettingsModel()
    @State private var pollingModel = PollingSettingsModel()
    @Environment(\.settingsDidChange) private var settingsDidChange

    /// Fixed form width so the window doesn't stretch to fit the segmented "Track"
    /// control or shrink to fit the shortest field — comfortably within 460–520pt.
    private static let formWidth: CGFloat = 480

    var body: some View {
        Form {
            Section {
                TextField(
                    "GitLab URL",
                    text: $model.baseURLText,
                    prompt: Text("https://gitlab.example.com")
                )
                .textContentType(.URL)
                .autocorrectionDisabled()

                SecureField(
                    "Personal Access Token",
                    text: $model.tokenText,
                    prompt: Text(model.hasStoredToken ? "Stored in Keychain" : "glpat-…")
                )
            } footer: {
                statusView
                    .padding(.top, 4)
            }

            Section {
                HStack {
                    Button("Verify & Save") {
                        Task { await model.verifyAndSave() }
                    }
                    .disabled(model.isValidating || model.baseURLText.isEmpty)

                    if model.hasStoredToken {
                        Button("Remove Token", role: .destructive) {
                            model.removeToken()
                        }
                    }
                }
            }

            Section("Polling") {
                Picker("Check every", selection: $pollingModel.intervalSeconds) {
                    ForEach(PollingIntervalPreset.all) { preset in
                        Text(preset.label).tag(preset.seconds)
                    }
                }

                Picker("Track", selection: $pollingModel.trackSelection) {
                    ForEach(TrackSelection.allCases, id: \.self) { selection in
                        Text(selection.label).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        // Tell the poller about saved changes so they apply right away (account) or on
        // the next cycle (interval/roles) — see `SyncCoordinator.settingsDidChange()`.
        .onChange(of: model.status) { _, newStatus in
            if case .success = newStatus { settingsDidChange() }
        }
        .onChange(of: model.hasStoredToken) { settingsDidChange() }
        .onChange(of: pollingModel.intervalSeconds) { settingsDidChange() }
        .onChange(of: pollingModel.trackSelection) { settingsDidChange() }
        .frame(width: Self.formWidth)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("GitLab Account")
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying…")
            }
        case .success(let message):
            Text(message)
        case .failure(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    SettingsView()
}
