import SwiftUI
import DeviceHubProKit

/// Settings ▸ Maestro: where the CLI is, its version and Java, the in-app
/// install, the flows folder and how runs treat Maestro's driver.
struct MaestroSettingsSection: View {
    let setup: MaestroSetupController
    let preferences: AppPreferences

    var body: some View {
        LabeledContent("Maestro", value: statusText)
        if let path = executablePath {
            LabeledContent("Command-line tool", value: path)
        }
        HStack {
            Button("Locate\u{2026}") { setup.chooseExecutable() }
            if !preferences.maestroPath.isEmpty {
                Button("Find Automatically") { setup.useAutomaticExecutable() }
            }
            if setup.isConfigured {
                if setup.isInstalling {
                    if let fraction = setup.installProgress ?? nil {
                        ProgressView(value: fraction).frame(maxWidth: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { setup.cancelInstall() }
                } else {
                    Button(isPinnedInstalled ? "Reinstall Maestro \(setup.pinnedVersion)" : "Install Maestro \(setup.pinnedVersion)") {
                        setup.install()
                    }
                }
            }
            Button("Check Again") { Task { await setup.refresh() } }
                .disabled(setup.availability == .checking)
        }
        if let error = setup.installError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        LabeledContent("Flows folder", value: setup.flowsFolder.path)
        HStack {
            Button("Choose Folder\u{2026}") { setup.chooseFlowsFolder() }
            Button("Show in Finder") { setup.revealFlowsFolder() }
            if !preferences.maestroFlowsFolderPath.isEmpty {
                Button("Use Default Folder") { setup.useDefaultFlowsFolder() }
            }
        }
        Toggle("Keep Maestro\u{2019}s driver on the device between runs", isOn: Binding(
            get: { preferences.maestroKeepsDriver },
            set: { preferences.setMaestroKeepsDriver($0) }
        ))
        Text("Maestro installs a small driver app on the device for each run and removes it afterwards. Keeping it makes repeat runs start faster. Flows run on the selected Android device or iPhone and iPad simulator; Maestro does not support physical iPhones. Maestro\u{2019}s usage analytics are turned off for every run.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                if setup.availability == .unknown { await setup.refresh() }
            }
    }

    private var statusText: String {
        switch setup.availability {
        case .unknown, .checking: "Looking\u{2026}"
        case .missing: "Not installed"
        case .needsJava: "Needs Java 17 or newer"
        case .ready(_, let version): "Version \(version)"
        case .broken: "Does not start"
        }
    }

    private var executablePath: String? {
        switch setup.availability {
        case .ready(let url, _), .needsJava(let url), .broken(let url, _): return url.path
        case .unknown, .checking, .missing: return nil
        }
    }

    /// The app's own copy is the one in use.
    private var isPinnedInstalled: Bool {
        guard case .ready(let url, let version) = setup.availability else { return false }
        return version == setup.pinnedVersion
            && url.standardizedFileURL == MaestroLocator.managedExecutable().standardizedFileURL
    }
}
