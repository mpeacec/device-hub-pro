import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The device a flow runs on: the selected row's, by the id Maestro lists it
/// under.
enum FlowTarget: Equatable {
    case android(serial: String)
    case simulator(udid: String)

    /// `maestro test --device`.
    var deviceID: String {
        switch self {
        case .android(let serial): serial
        case .simulator(let udid): udid
        }
    }
}

/// One window's Flows panel: the open flow file and its edits, the syntax
/// check, and the run on the selected device with its live steps.
///
/// The flow files are the user's own (`MaestroSetupController.flowsFolder`);
/// edits are written back to the file before a run. A run belongs to the
/// device it started on: selecting another row does not stop it, and Run
/// stays unavailable until it ends.
@MainActor
@Observable
final class FlowRunController {
    enum SyntaxState: Equatable {
        case unchecked
        case checking
        case ok
        case problem(String)
    }

    enum RunState: Equatable {
        case idle
        case running(deviceName: String)
        case passed
        case failed(exitCode: Int32)
        case stopped
        /// The run could not start (no file written, the CLI missing…).
        case couldNotRun(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// The flow open in the editor.
    private(set) var selectedFlow: MaestroFlowFile?
    /// The editor's text.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleSyntaxCheck()
        }
    }
    /// The text as last read from or written to the file.
    private(set) var savedText = ""
    var isDirty: Bool { selectedFlow != nil && text != savedText }
    private(set) var fileError: String?

    private(set) var syntax: SyntaxState = .unchecked
    private(set) var run: RunState = .idle
    private(set) var transcript = MaestroRunTranscript()
    /// The last run's artifacts folder (screenshots, logs, commands.json).
    private(set) var lastRunFolder: URL?

    // Wired by the workspace.
    @ObservationIgnored var setup: MaestroSetupController?
    /// The selected row's device when a flow can run on it now.
    @ObservationIgnored var target: @MainActor () -> FlowTarget? = { nil }
    /// The name a device is shown under.
    @ObservationIgnored var deviceName: @MainActor (FlowTarget) -> String = { $0.deviceID }
    @ObservationIgnored var keepsDriver: @MainActor () -> Bool = { false }

    @ObservationIgnored private var syntaxTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var flusher: Task<Void, Never>?
    private let pending = FlowPendingLines()

    /// How long typing pauses before the text is checked.
    static let syntaxDelay: Duration = .milliseconds(700)

    // MARK: - Files

    /// Opens `flow` in the editor. Unsaved edits of the open flow are written
    /// first, so switching never loses them.
    func open(_ flow: MaestroFlowFile?) {
        guard flow != selectedFlow else { return }
        if isDirty { save() }
        selectedFlow = flow
        fileError = nil
        guard let flow else {
            savedText = ""
            text = ""
            syntax = .unchecked
            return
        }
        do {
            let contents = try String(contentsOf: flow.url, encoding: .utf8)
            savedText = contents
            text = contents
        } catch {
            savedText = ""
            text = ""
            fileError = "\(flow.relativePath) could not be read: \(error.localizedDescription)"
        }
        checkSyntaxNow()
    }

    /// Writes the editor's text to the open file.
    @discardableResult
    func save() -> Bool {
        guard let flow = selectedFlow else { return false }
        do {
            try Data(text.utf8).write(to: flow.url, options: .atomic)
            savedText = text
            fileError = nil
            return true
        } catch {
            fileError = "\(flow.relativePath) could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Puts the file's text back in the editor.
    func revert() {
        text = savedText
    }

    /// The open file was deleted or renamed outside the app: close it.
    func reconcile(with flows: [MaestroFlowFile]) {
        guard let flow = selectedFlow, !flows.contains(flow) else { return }
        selectedFlow = nil
        savedText = ""
        text = ""
        syntax = .unchecked
    }

    // MARK: - Syntax

    private func scheduleSyntaxCheck() {
        syntaxTask?.cancel()
        guard selectedFlow != nil else { return }
        syntaxTask = Task { [weak self] in
            try? await Task.sleep(for: Self.syntaxDelay)
            guard !Task.isCancelled else { return }
            await self?.checkSyntax()
        }
    }

    func checkSyntaxNow() {
        syntaxTask?.cancel()
        syntaxTask = Task { [weak self] in await self?.checkSyntax() }
    }

    private func checkSyntax() async {
        guard let client = setup?.client else {
            syntax = .unchecked
            return
        }
        let yaml = text
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            syntax = .problem("The flow is empty.")
            return
        }
        syntax = .checking
        let result: MaestroSyntaxResult
        do {
            result = try await client.checkSyntax(yaml)
        } catch is CancellationError {
            return
        } catch {
            if text == yaml { syntax = .unchecked }
            return
        }
        // A check for text that has changed since says nothing.
        guard text == yaml, !Task.isCancelled else { return }
        switch result {
        case .ok: syntax = .ok
        case .problem(let message): syntax = .problem(message)
        }
    }

    // MARK: - Running

    /// Why Run is unavailable right now, nil when it can run.
    var runBlocker: String? {
        if run.isRunning { return nil }
        guard let setup else { return "Maestro is not set up." }
        guard setup.client != nil else { return "Set up Maestro in Settings to run flows." }
        guard selectedFlow != nil else { return "Choose a flow to run." }
        guard target() != nil else { return "Start the device to run flows on it." }
        return nil
    }

    /// Saves the flow and runs it on the selected row's device.
    func runSelected() {
        guard !run.isRunning, let setup, let client = setup.client, let flow = selectedFlow else { return }
        guard let target = target() else {
            run = .couldNotRun("Start the device to run flows on it.")
            return
        }
        if isDirty, !save() {
            run = .couldNotRun(fileError ?? "The flow could not be saved.")
            return
        }
        guard let runs = setup.runsFolder else { return }
        let folder = runs.appendingPathComponent(Self.runFolderName(flow: flow, date: Date()), isDirectory: true)
        let request = MaestroRunRequest(
            flowFile: flow.url,
            deviceID: target.deviceID,
            outputDirectory: folder,
            reinstallDriver: !keepsDriver()
        )
        transcript = MaestroRunTranscript()
        lastRunFolder = folder
        run = .running(deviceName: deviceName(target))
        _ = pending.drain()
        let pending = pending
        flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.flush()
            }
        }
        runTask = Task { [weak self] in
            let outcome: RunState
            do {
                let status = try await client.test(request) { pending.add($0) }
                outcome = status == 0 ? .passed : .failed(exitCode: status)
            } catch is CancellationError {
                outcome = .stopped
            } catch {
                outcome = .couldNotRun(String(describing: error))
            }
            self?.finish(outcome)
        }
    }

    /// Stops the running flow (Maestro gets SIGINT, as Ctrl-C).
    func stop() {
        runTask?.cancel()
    }

    func revealLastRun() {
        guard let folder = lastRunFolder, FileManager.default.fileExists(atPath: folder.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func flush() {
        for line in pending.drain() { transcript.append(line) }
    }

    private func finish(_ outcome: RunState) {
        flusher?.cancel()
        flusher = nil
        runTask = nil
        flush()
        transcript.finish(stopped: outcome == .stopped)
        // Exit 0 with a failed step cannot happen; a failed step under an
        // exit status that says otherwise is still a failure.
        if outcome == .passed, transcript.hasFailedStep {
            run = .failed(exitCode: 0)
        } else {
            run = outcome
        }
    }

    /// "2026-10-11 18.47.06 login": sortable, readable in Finder.
    static func runFolderName(flow: MaestroFlowFile, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = flow.name.replacingOccurrences(of: "/", with: "-")
        return "\(formatter.string(from: date)) \(name)"
    }
}

/// Lines from the CLI's reader threads, applied to the transcript in batches.
private final class FlowPendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > MaestroRunTranscript.lineLimit {
            lines.removeFirst(lines.count - MaestroRunTranscript.lineLimit)
        }
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = lines
        lines.removeAll(keepingCapacity: true)
        return taken
    }
}

extension DeviceWorkspace {
    /// Whether the selected row's device is one Maestro drives: an Android
    /// emulator or phone, or an iPhone or iPad simulator. Physical iPhones
    /// (Maestro 2.11 refuses them), and Apple TV, Watch and Vision
    /// simulators get no Flows panel.
    var offersFlows: Bool {
        switch deviceSelection {
        case .avd?, .device?, .pixel?:
            return true
        case .simulator(let udid)?:
            guard let entry = services.simulators.entry(udid: udid) else { return false }
            let family = ControlsFamily.simulator(platform: entry.platform, productFamily: entry.productFamily)
            return family == .iPhone || family == .iPad
        case .physicalApple?, nil:
            return false
        }
    }

    /// The device a flow runs on now: the selected row's, when it is running
    /// (an Android device by `menuTargetSerial`, a simulator once booted).
    var flowTarget: FlowTarget? {
        guard offersFlows else { return nil }
        if let serial = menuTargetSerial { return .android(serial: serial) }
        if case .simulator(let udid)? = deviceSelection, services.simulatorLifecycle.isReady(udid) {
            return .simulator(udid: udid)
        }
        return nil
    }

    func flowDeviceName(_ target: FlowTarget) -> String {
        switch target {
        case .android(let serial):
            return services.displayName(of: .android(serial))
        case .simulator(let udid):
            return services.simulators.entry(udid: udid)?.name ?? udid
        }
    }
}
