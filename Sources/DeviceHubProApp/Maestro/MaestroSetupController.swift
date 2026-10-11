import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// How the app finds Maestro and the Java it runs on. Only
/// `AppEnvironment.live()` builds one (`live()`); every other environment has
/// none, so a test model never locates, runs or downloads Maestro.
struct MaestroTooling: Sendable {
    /// The CLI for a Settings path ("" = search the usual places).
    var locate: @Sendable (_ customPath: String) -> URL?
    /// `JAVA_HOME` for the CLI (`[:]` = the inherited one is fine), nil when
    /// no Java 17+ runtime is on the Mac.
    var javaEnvironment: @Sendable () async -> [String: String]?
    /// Downloads the pinned release into the app's own folder.
    var installer: MaestroInstaller
    /// The flows folder until the user picks one.
    var defaultFlowsFolder: URL
    /// Where each run's artifacts go (one subfolder per run).
    var runsFolder: URL

    static func live() -> MaestroTooling {
        MaestroTooling(
            locate: { MaestroLocator.locate(customPath: $0) },
            javaEnvironment: { await AvdmanagerLocator.javaHomeEnvironment() },
            installer: MaestroInstaller(),
            defaultFlowsFolder: MaestroFlowFolder.defaultURL,
            runsFolder: LibraryFile.applicationSupportFolder.appendingPathComponent("Flow Runs", isDirectory: true)
        )
    }
}

/// Maestro for the whole app: whether the CLI and a Java runtime are there,
/// the in-app install, and the flows folder with its files. Every window's
/// Flows panel (`FlowRunController`) reads it; Settings ▸ Maestro drives it.
@MainActor
@Observable
final class MaestroSetupController {
    enum Availability: Equatable {
        /// Not looked for yet.
        case unknown
        case checking
        /// No `maestro` found.
        case missing
        /// Found, but no Java 17+ runtime to run it.
        case needsJava(executable: URL)
        case ready(executable: URL, version: String)
        /// Found, but `maestro --version` failed.
        case broken(executable: URL, message: String)
    }

    private let tooling: MaestroTooling?
    private let preferences: AppPreferences

    private(set) var availability: Availability = .unknown
    /// The `JAVA_HOME` the CLI runs with, once `refresh` found a runtime.
    private var javaEnvironment: [String: String] = [:]
    /// The download's fraction while "Install Maestro" runs (nil inside it
    /// when the size is unknown); nil when no install runs.
    private(set) var installProgress: Double??
    private(set) var installError: String?
    private var installTask: Task<Void, Never>?
    /// The flow files of `flowsFolder`, as last read.
    private(set) var flows: [MaestroFlowFile] = []

    init(tooling: MaestroTooling?, preferences: AppPreferences) {
        self.tooling = tooling
        self.preferences = preferences
    }

    /// Whether this app can look for Maestro at all (false in tests).
    var isConfigured: Bool { tooling != nil }
    var isInstalling: Bool { installProgress != nil }
    var pinnedVersion: String { tooling?.installer.release.version ?? MaestroRelease.pinned.version }

    /// A client for the CLI, when it and Java are both there.
    var client: MaestroClient? {
        guard case .ready(let executable, _) = availability else { return nil }
        return MaestroClient(executableURL: executable, environment: javaEnvironment)
    }

    var flowsFolder: URL {
        if !preferences.maestroFlowsFolderPath.isEmpty {
            return URL(fileURLWithPath: preferences.maestroFlowsFolderPath, isDirectory: true)
        }
        return tooling?.defaultFlowsFolder ?? MaestroFlowFolder.defaultURL
    }

    var runsFolder: URL? { tooling?.runsFolder }

    /// Looks for the CLI and Java again and asks the CLI its version.
    func refresh() async {
        guard let tooling else {
            availability = .missing
            return
        }
        if availability == .checking { return }
        availability = .checking
        let customPath = preferences.maestroPath
        let executable = await Task.detached { tooling.locate(customPath) }.value
        guard let executable else {
            availability = .missing
            return
        }
        guard let java = await tooling.javaEnvironment() else {
            availability = .needsJava(executable: executable)
            return
        }
        javaEnvironment = java
        do {
            let version = try await MaestroClient(executableURL: executable, environment: java).version()
            availability = .ready(executable: executable, version: version)
        } catch {
            availability = .broken(executable: executable, message: String(describing: error))
        }
    }

    /// Settings ▸ Maestro ▸ Install: downloads the pinned release into the
    /// app's folder, then uses it.
    func install() {
        guard let tooling, installTask == nil else { return }
        installError = nil
        installProgress = .some(nil)
        let installer = tooling.installer
        installTask = Task { [weak self] in
            do {
                _ = try await installer.install { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.installProgress != nil else { return }
                        self.installProgress = .some(fraction)
                    }
                }
                guard let self else { return }
                self.finishInstall(error: nil)
                // The app's own copy is found before ~/.maestro and PATH,
                // but a path chosen in Settings would still win.
                self.preferences.setMaestroPath("")
                await self.refresh()
            } catch is CancellationError {
                self?.finishInstall(error: nil)
            } catch {
                self?.finishInstall(error: String(describing: error))
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func finishInstall(error: String?) {
        installTask = nil
        installProgress = nil
        installError = error
    }

    /// Settings ▸ Maestro ▸ Locate…: a `maestro` launcher the user picks.
    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose the maestro command-line tool (maestro/bin/maestro)."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.setMaestroPath(url.path)
        Task { await refresh() }
    }

    func useAutomaticExecutable() {
        preferences.setMaestroPath("")
        Task { await refresh() }
    }

    // MARK: - Flows folder

    /// Reads the folder's flow files again (creating the default folder the
    /// first time, so it can be opened in Finder).
    func reloadFlows() {
        let folder = MaestroFlowFolder(url: flowsFolder)
        if preferences.maestroFlowsFolderPath.isEmpty, tooling != nil {
            try? folder.ensureExists()
        }
        let url = flowsFolder
        flows = MaestroFlowFolder(url: url).flows()
    }

    /// "Choose Folder…": the flows folder becomes one the user picks (for
    /// example the `.maestro` folder of the app's repository).
    func chooseFlowsFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your Maestro flows (.yaml files)."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = flowsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.setMaestroFlowsFolderPath(url.path)
        reloadFlows()
    }

    func useDefaultFlowsFolder() {
        preferences.setMaestroFlowsFolderPath("")
        reloadFlows()
    }

    func revealFlowsFolder() {
        let folder = MaestroFlowFolder(url: flowsFolder)
        try? folder.ensureExists()
        NSWorkspace.shared.activateFileViewerSelecting([flowsFolder])
    }

    /// A new flow file in the folder, named after `name`.
    func createFlow(named name: String, appID: String?) throws -> MaestroFlowFile {
        let file = try MaestroFlowFolder(url: flowsFolder).createFlow(named: name, appID: appID)
        reloadFlows()
        return file
    }
}
