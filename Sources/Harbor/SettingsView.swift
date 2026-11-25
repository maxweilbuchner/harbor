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
                    Text("Version \(Bundle.main.harborVersion)")
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
                        .disabled(model.runtimeVersions == nil || !model.canDownloadRuntime || model.runtimeUpdate.isBusy
                                  // Installing waits for Windows programs to quit; the line below says so.
                                  || (model.runtimeUpdate == .ready && !model.running.isEmpty))
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
            Section {
                Toggle("Share anonymous statistics", isOn: Binding(get: { model.sharesStatistics == true },
                                                                   set: { model.shareStatistics($0) }))
                if model.sharesStatistics == true {
                    LabeledContent("Sent next") {
                        // Exactly the bytes of the next request.
                        Text(model.nextStatistics ?? String(localized: "Nothing yet. Harbor counts from the next program you open."))
                            .font(model.nextStatistics == nil ? .body : .caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("At most once a day: how many programs ran and how many didn’t, by cause. No program names, nothing that identifies you.") + Text(" ") + Text(privacyLink)
            }
            if let versions = model.runtimeVersions {
                Section("Graphics") {
                    LabeledContent("D3DMetal (games)", value: versions.d3dmetal ?? String(localized: "Not installed"))
                    LabeledContent("DXMT (other Direct3D 10 and 11 programs)", value: versions.dxmt ?? String(localized: "Not installed"))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "What Harbor sends", leading to the website's privacy page.
    private var privacyLink: AttributedString {
        var link = AttributedString(String(localized: "What Harbor sends"))
        link.link = HarborService.privacyPage
        return link
    }

    /// The same call does all three: it checks, or retries, or switches to a downloaded update if nothing runs.
    private var runtimeButton: String {
        switch model.runtimeUpdate {
        case .failed: String(localized: "Try Again")
        case .ready: String(localized: "Install Now")
        default: String(localized: "Check Now")
        }
    }

    private var runtimeTitle: String {
        guard let versions = model.runtimeVersions else { return String(localized: "Not installed") }
        return versions.wine.map { String(localized: "Version \($0)") } ?? String(localized: "This checkout’s own build")
    }

    private var runtimeDetail: String {
        switch model.runtimeUpdate {
        case .checking:
            return String(localized: "Checking for updates…")
        case .downloading(let fraction):
            return String(localized: "Downloading an update… \(Int(fraction * 100))%")
        case .ready:
            return String(localized: "An update is ready. Quit your Windows programs to install it.")
        case .needsNewerApp:
            return String(localized: "A newer version needs a newer Harbor. Update Harbor first.")
        case .failedBefore:
            return String(localized: "The newest version didn’t start on this Mac, so this one was kept. Harbor tries the next one published.")
        case .failed(let message):
            return String(localized: "Couldn’t update. \(message)")
        case .idle:
            guard let versions = model.runtimeVersions else { return String(localized: "Harbor’s main window offers the download.") }
            if let checked = model.runtimeLastChecked {
                // A clock time, not "5 minutes ago": nothing redraws this while the window stays open.
                let time = checked.formatted(date: Calendar.current.isDateInToday(checked) ? .omitted : .abbreviated, time: .shortened)
                return Calendar.current.isDateInToday(checked) ? String(localized: "Up to date. Checked at \(time).")
                                                               : String(localized: "Up to date. Checked \(time).")
            }
            if let installed = versions.installed {
                return String(localized: "Installed \(installed.formatted(date: .abbreviated, time: .shortened)).")
            }
            return versions.wine == nil ? String(localized: "Built by \("scripts/build-wine.sh"); not updated by Harbor.") : ""
        }
    }
}
