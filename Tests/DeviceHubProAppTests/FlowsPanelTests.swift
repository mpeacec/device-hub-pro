import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Flows panel: which devices get it, the open flow's edits, and what
/// stops a run before Maestro is set up. Runs themselves are covered by
/// `MaestroClientTests` against a fake CLI.
@MainActor
final class FlowsPanelTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowsPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testOnlyDevicesMaestroDrivesOfferFlows() {
        let model = AppModel.testing()
        let workspace = model.workspace

        workspace.deviceSelection = .device("emulator-5554")
        XCTAssertTrue(workspace.offersFlows)
        workspace.deviceSelection = .avd("Pixel_8_Pro")
        XCTAssertTrue(workspace.offersFlows)
        workspace.deviceSelection = .physicalApple("00000000-0000000000000000")
        XCTAssertFalse(workspace.offersFlows, "Maestro does not drive physical iPhones")
        workspace.deviceSelection = .simulator("425BD068-3D87-4F27-BE58-EB56A58B2C3A")
        XCTAssertFalse(workspace.offersFlows, "a simulator the inventory does not list is not one Maestro drives")
        workspace.deviceSelection = nil
        XCTAssertFalse(workspace.offersFlows)
    }

    /// A stopped device offers the panel but no target: Run waits for it.
    func testAStoppedDeviceHasNoTarget() {
        let model = AppModel.testing()
        model.workspace.deviceSelection = .avd("Pixel_8_Pro")
        XCTAssertNil(model.workspace.flowTarget)
    }

    func testTheFlowsTabOpensAndClosesLikeTheOthers() {
        let window = WindowState()
        window.showInspector = true
        window.inspectorTab = .controls
        window.selectInspectorTab(.flows)
        XCTAssertEqual(window.inspectorTab, .flows)
        XCTAssertTrue(window.isInspectorToolbarButtonActive(.flows))
        XCTAssertFalse(window.isInspectorToolbarButtonActive(.controls))
        window.selectInspectorTab(.flows)
        XCTAssertFalse(window.showInspector, "the active surface's button hides the inspector")
    }

    func testEditsAreSavedToTheFileAndCanBeReverted() throws {
        let file = scratch.appendingPathComponent("login.yaml")
        try Data("appId: a\n---\n- launchApp\n".utf8).write(to: file)
        let flow = MaestroFlowFile(url: file, relativePath: "login.yaml")
        let flows = FlowRunController()

        flows.open(flow)
        XCTAssertEqual(flows.text, "appId: a\n---\n- launchApp\n")
        XCTAssertFalse(flows.isDirty)

        flows.text += "- back\n"
        XCTAssertTrue(flows.isDirty)
        flows.revert()
        XCTAssertFalse(flows.isDirty)

        flows.text += "- back\n"
        XCTAssertTrue(flows.save())
        XCTAssertFalse(flows.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "appId: a\n---\n- launchApp\n- back\n")
    }

    /// Switching flows writes the edits of the one being left.
    func testSwitchingFlowsKeepsTheEdits() throws {
        let first = scratch.appendingPathComponent("a.yaml")
        let second = scratch.appendingPathComponent("b.yaml")
        try Data("appId: a\n".utf8).write(to: first)
        try Data("appId: b\n".utf8).write(to: second)
        let flows = FlowRunController()
        flows.open(MaestroFlowFile(url: first, relativePath: "a.yaml"))
        flows.text = "appId: a2\n"
        flows.open(MaestroFlowFile(url: second, relativePath: "b.yaml"))

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "appId: a2\n")
        XCTAssertEqual(flows.text, "appId: b\n")
    }

    func testADeletedFlowIsClosed() throws {
        let file = scratch.appendingPathComponent("a.yaml")
        try Data("appId: a\n".utf8).write(to: file)
        let flow = MaestroFlowFile(url: file, relativePath: "a.yaml")
        let flows = FlowRunController()
        flows.open(flow)
        flows.reconcile(with: [flow])
        XCTAssertEqual(flows.selectedFlow, flow)
        flows.reconcile(with: [])
        XCTAssertNil(flows.selectedFlow)
        XCTAssertEqual(flows.text, "")
    }

    /// A test environment has no Maestro: nothing is located, and Run says
    /// what is missing instead of running.
    func testWithoutMaestroRunSaysWhatIsMissing() async {
        let setup = MaestroSetupController(tooling: nil, preferences: AppPreferences(defaults: .scratch()))
        XCTAssertFalse(setup.isConfigured)
        await setup.refresh()
        XCTAssertEqual(setup.availability, .missing)
        XCTAssertNil(setup.client)

        let flows = FlowRunController()
        flows.setup = setup
        XCTAssertEqual(flows.runBlocker, "Set up Maestro in Settings to run flows.")
        flows.runSelected()
        XCTAssertEqual(flows.run, .idle)
    }

    func testTheTestingEnvironmentHasNoMaestro() {
        XCTAssertNil(AppEnvironment.testing().maestro)
        XCTAssertFalse(AppModel.testing().services.maestro.isConfigured)
    }

    func testRunFoldersSortByTime() throws {
        let flow = MaestroFlowFile(url: scratch.appendingPathComponent("login.yaml"), relativePath: "login.yaml")
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = 2026
        components.month = 10
        components.day = 11
        components.hour = 18
        components.minute = 47
        components.second = 6
        let date = try XCTUnwrap(components.date)
        XCTAssertEqual(FlowRunController.runFolderName(flow: flow, date: date), "2026-10-11 18.47.06 login")
    }
}
