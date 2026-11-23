import HarborKit
import SwiftUI

/// Harbor > Settings…: what is installed and whether it is current. Updates need no decisions (the app through
/// Sparkle, Windows support by itself), so this shows state and offers a check; it has no versions to pick.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var automaticChecks = Updates.shared.automaticallyChecks

    var body: some View {
        Form {
            Section("Harbor") {
                LabeledContent {
                    Button("Check Now") { Updates.shared.checkForUpdates() }
                        .disabled(!Updates.shared.isAvailable)
                } label: {
                    Text("Version \(appVersion)")
                    if !Updates.shared.isAvailable {
                        Text("This development build doesn’t update itself.")
                    }
                }
                Toggle("Automatically check for updates", isOn: $automaticChecks)
                    .disabled(!Updates.shared.isAvailable)
                    .onChange(of: automaticChecks) { _, on in Updates.shared.automaticallyChecks = on }
            }
            Section {
                LabeledContent {
                    Button(runtimeButton) { model.checkForRuntimeUpdate(userAsked: true) }
                        .disabled(model.runtimeVersions == nil || !model.canDownloadRuntime || model.runtimeUpdate.isBusy)
                } label: {
                    Text(runtimeTitle)
                    Text(runtimeDetail)
                }
                if case .downloading(let fraction) = model.runtimeUpdate {
                    ProgressView(value: fraction)
                }
            } header: {
                Text("Windows Support")
            } footer: {
                Text("Updates download in the background and are installed once no Windows program is running.")
            }
            if let versions = model.runtimeVersions {
                Section("Graphics") {
                    LabeledContent("D3DMetal (games)", value: versions.d3dmetal ?? "Not installed")
                    LabeledContent("DXMT (other Direct3D 10 and 11 programs)", value: versions.dxmt ?? "Not installed")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "(development)" }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }

    /// The same call does all three: it checks, or retries, or switches to a downloaded update if nothing runs.
    private var runtimeButton: String {
        switch model.runtimeUpdate {
        case .failed: "Try Again"
        case .ready: "Install Now"
        default: "Check Now"
        }
    }

    private var runtimeTitle: String {
        guard let versions = model.runtimeVersions else { return "Not installed" }
        return versions.wine.map { "Version \($0)" } ?? "This checkout’s own build"
    }

    private var runtimeDetail: String {
        switch model.runtimeUpdate {
        case .checking:
            return "Checking for updates…"
        case .downloading(let fraction):
            return "Downloading an update… \(Int(fraction * 100))%"
        case .ready:
            return "An update is ready. Quit your Windows programs to install it."
        case .needsNewerApp:
            return "A newer version needs a newer Harbor. Update Harbor first."
        case .failed(let message):
            return "Couldn’t update. \(message)"
        case .idle:
            guard let versions = model.runtimeVersions else { return "Harbor’s main window offers the download." }
            if let checked = model.runtimeLastChecked {
                return "Up to date. Checked \(checked.formatted(.relative(presentation: .named)))."
            }
            if let installed = versions.installed {
                return "Installed \(installed.formatted(date: .abbreviated, time: .shortened))."
            }
            return versions.wine == nil ? "Built by scripts/build-wine.sh; not updated by Harbor." : ""
        }
    }
}
