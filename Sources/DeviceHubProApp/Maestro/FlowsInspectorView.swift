import SwiftUI
import DeviceHubProKit

/// The inspector's Flows panel: pick a Maestro flow from the flows folder,
/// edit it, and run it on the selected device while its steps tick by.
struct FlowsInspectorView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @State private var isNamingFlow = false
    @State private var newFlowName = ""
    @State private var createError: String?

    var body: some View {
        let setup = workspace.services.maestro
        let flows = workspace.flows
        VStack(alignment: .leading, spacing: 10) {
            MaestroAvailabilityBanner(setup: setup)
            folderRow(setup: setup, flows: flows)
            if flows.selectedFlow != nil {
                FlowEditorSection(flows: flows)
                FlowRunSection(flows: flows)
            } else if setup.flows.isEmpty {
                emptyFolder
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if setup.availability == .unknown { await setup.refresh() }
            setup.reloadFlows()
            if flows.selectedFlow == nil, let first = setup.flows.first { flows.open(first) }
        }
        .onChange(of: setup.flows) { _, list in flows.reconcile(with: list) }
        .onChange(of: setup.availability) { _, _ in
            if flows.selectedFlow != nil { flows.checkSyntaxNow() }
        }
        .alert("New Flow", isPresented: $isNamingFlow) {
            TextField("Name", text: $newFlowName)
            Button("Create") { createFlow(setup: setup, flows: flows) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new .yaml file in \(setup.flowsFolder.lastPathComponent).")
        }
        .alert("The flow could not be created", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
    }

    private func folderRow(setup: MaestroSetupController, flows: FlowRunController) -> some View {
        HStack(spacing: 6) {
            Picker("Flow", selection: Binding(
                get: { flows.selectedFlow },
                set: { flows.open($0) }
            )) {
                if flows.selectedFlow == nil {
                    Text("No Flow").tag(MaestroFlowFile?.none)
                }
                ForEach(setup.flows) { flow in
                    Text(flow.relativePath).tag(Optional(flow))
                }
            }
            .labelsHidden()
            .disabled(setup.flows.isEmpty)
            .accessibilityLabel("Flow")

            Button {
                newFlowName = ""
                isNamingFlow = true
            } label: {
                Image(systemName: "plus")
            }
            .help("New Flow")
            .accessibilityLabel("New Flow")

            Menu {
                Section(setup.flowsFolder.path) {
                    Button("Choose Folder\u{2026}") { setup.chooseFlowsFolder() }
                    Button("Show in Finder") { setup.revealFlowsFolder() }
                    Button("Reload") { setup.reloadFlows() }
                    if !workspace.services.preferences.maestroFlowsFolderPath.isEmpty {
                        Divider()
                        Button("Use Default Folder") { setup.useDefaultFlowsFolder() }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Flows folder: \(setup.flowsFolder.path)")
            .accessibilityLabel("Flows Folder")
        }
    }

    private var emptyFolder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No flows in this folder yet.")
                .font(.callout)
            Text("Create one with +, or choose the folder that holds your Maestro flows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func createFlow(setup: MaestroSetupController, flows: FlowRunController) {
        let name = newFlowName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let file = try setup.createFlow(named: name.isEmpty ? "Flow" : name, appID: nil)
            flows.open(file)
        } catch {
            createError = error.localizedDescription
        }
    }
}

/// What is missing before a flow can run, with the way to fix it; nothing
/// when Maestro is ready.
private struct MaestroAvailabilityBanner: View {
    let setup: MaestroSetupController

    var body: some View {
        switch setup.availability {
        case .ready:
            EmptyView()
        case .unknown, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for Maestro\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        case .missing:
            card(
                "Maestro is not installed.",
                detail: "Device Hub Pro can install Maestro \(setup.pinnedVersion) in its own folder. It needs Java 17 or newer."
            ) {
                if setup.isConfigured {
                    if setup.isInstalling {
                        installProgress
                    } else {
                        Button("Install Maestro") { setup.install() }
                    }
                }
                SettingsLink { Text("Settings\u{2026}") }
            }
        case .needsJava:
            card(
                "Maestro needs Java 17 or newer.",
                detail: "Install a Java runtime (Install Android Tools\u{2026} sets one up), then check again."
            ) {
                Button("Check Again") { Task { await setup.refresh() } }
            }
        case .broken(_, let message):
            card("Maestro did not start.", detail: message) {
                Button("Check Again") { Task { await setup.refresh() } }
                SettingsLink { Text("Settings\u{2026}") }
            }
        }
    }

    private var installProgress: some View {
        HStack(spacing: 6) {
            if let fraction = setup.installProgress ?? nil {
                ProgressView(value: fraction).frame(maxWidth: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { setup.cancelInstall() }
        }
    }

    private func card<Actions: View>(
        _ title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = setup.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}

/// The open flow's text, its syntax state and Save / Revert.
private struct FlowEditorSection: View {
    @Bindable var flows: FlowRunController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlainCodeEditor(text: $flows.text)
                .modifier(CodeEditorWell(height: 200))
                .accessibilityLabel("Flow YAML")
            HStack(alignment: .top, spacing: 6) {
                syntaxLine
                Spacer(minLength: 4)
                if flows.isDirty {
                    Button("Revert") { flows.revert() }
                    Button("Save") { flows.save() }
                }
            }
            .controlSize(.small)
            if let error = flows.fileError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var syntaxLine: some View {
        switch flows.syntax {
        case .unchecked:
            EmptyView()
        case .checking:
            Label("Checking\u{2026}", systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ok:
            Label("Syntax OK", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .problem(let message):
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}

/// Run / Stop, the run's state and its steps.
private struct FlowRunSection: View {
    let flows: FlowRunController
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if flows.run.isRunning {
                    Button {
                        flows.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        flows.runSelected()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(flows.runBlocker != nil)
                }
                runStateLine
                Spacer(minLength: 0)
            }
            if !flows.run.isRunning, let blocker = flows.runBlocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !flows.transcript.steps.isEmpty || !flows.transcript.messages.isEmpty {
                FlowStepsList(transcript: flows.transcript)
            }
            if flows.lastRunFolder != nil, !flows.run.isRunning, flows.run != .idle {
                HStack(spacing: 8) {
                    Button("Show Run Folder") { flows.revealLastRun() }
                    Toggle("Output", isOn: $showsOutput)
                        .toggleStyle(.button)
                }
                .controlSize(.small)
            }
            if showsOutput, !flows.transcript.lines.isEmpty {
                ScrollView {
                    Text(flows.transcript.lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .modifier(CodeEditorWell(height: 160))
            }
        }
    }

    @ViewBuilder
    private var runStateLine: some View {
        switch flows.run {
        case .idle:
            EmptyView()
        case .running(let deviceName):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running on \(deviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .passed:
            Label("Passed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .couldNotRun(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The run's steps (indented by nesting) and the CLI's own messages.
private struct FlowStepsList: View {
    let transcript: MaestroRunTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(transcript.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            statusIcon(step.status)
                                .frame(width: 12)
                            Text(step.title)
                                .font(.system(size: 11))
                                .foregroundStyle(step.status == .skipped ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, CGFloat(step.depth) * 12)
                        .id(step.id)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(Array(transcript.messages.suffix(20).enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .onChange(of: transcript.steps.count) { _, _ in
                if let last = transcript.steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: MaestroStep.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 10, weight: .bold))
        case .failed:
            Image(systemName: "xmark").foregroundStyle(.red).font(.system(size: 10, weight: .bold))
        case .skipped:
            Image(systemName: "minus").foregroundStyle(.secondary).font(.system(size: 10))
        case .warned:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 10))
        }
    }
}
