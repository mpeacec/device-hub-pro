import XCTest
@testable import DeviceHubProKit

/// `MaestroClient` against a fake `maestro` replaying real CLI 2.11.0 output
/// (`Fixtures/maestro`, see its README: captured byte for byte, no edits).
final class MaestroClientTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/maestro", isDirectory: true)

    private static func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name)
    }

    private static let flow = """
    appId: com.example.app
    ---
    - launchApp
    - tapOn: "Sign in"
    """

    func testVersionIsTheLastLinePrinted() async throws {
        let fake = try FakeTool(name: "maestro", rules: [
            .init("--version", stdoutFile: Self.fixture("version.txt")),
        ])
        let client = MaestroClient(executableURL: fake.executableURL)
        let version = try await client.version()
        XCTAssertEqual(version, "2.11.0")
        XCTAssertEqual(fake.invocations, [["--version"]])
    }

    func testEveryCallRunsQuietlyWithTheJavaItWasGiven() {
        let client = MaestroClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            environment: ["JAVA_HOME": "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"]
        )
        XCTAssertEqual(client.environment["MAESTRO_CLI_NO_ANALYTICS"], "1")
        XCTAssertEqual(client.environment["MAESTRO_DISABLE_UPDATE_CHECK"], "1")
        XCTAssertEqual(client.environment["MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED"], "true")
        XCTAssertEqual(client.environment["JAVA_HOME"], "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home")
    }

    func testValidFlowChecksOK() async throws {
        let fake = try FakeTool(name: "maestro", rules: [
            .init("check-syntax -", stdoutFile: Self.fixture("check-syntax-ok.txt")),
        ])
        let result = try await MaestroClient(executableURL: fake.executableURL).checkSyntax(Self.flow)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(fake.invocations, [["check-syntax", "-"]])
    }

    func testSyntaxProblemsNameTheirLine() async throws {
        let cases: [(file: String, expected: String)] = [
            ("check-syntax-invalid-command.err.txt", "Invalid Command: tapOnn (line 4, column 9)"),
            ("check-syntax-misplaced-command.err.txt", "Invalid Command: launchApp - tapOn (line 3, column 3)"),
            ("check-syntax-empty.err.txt", "Maestro code is empty."),
        ]
        for (file, expected) in cases {
            let fake = try FakeTool(name: "maestro", rules: [
                .init("check-syntax -", stdoutFile: nil, stderrFile: Self.fixture(file), exitCode: 1),
            ])
            let result = try await MaestroClient(executableURL: fake.executableURL).checkSyntax(Self.flow)
            XCTAssertEqual(result, .problem(expected), file)
        }
    }

    func testRunArgumentsNameTheDeviceAndTheRunFolder() {
        let request = MaestroRunRequest(
            flowFile: URL(fileURLWithPath: "/Users/aqauser001/app/.maestro/login.yaml"),
            deviceID: "emulator-5554",
            outputDirectory: URL(fileURLWithPath: "/tmp/run-1", isDirectory: true),
            environment: [(key: "USER", value: "qa@example.com")],
            reinstallDriver: false
        )
        XCTAssertEqual(request.arguments, [
            "test", "--no-ansi",
            "--device", "emulator-5554",
            "--test-output-dir", "/tmp/run-1",
            "--no-reinstall-driver",
            "-e", "USER=qa@example.com",
            "/Users/aqauser001/app/.maestro/login.yaml",
        ])

        let fresh = MaestroRunRequest(
            flowFile: URL(fileURLWithPath: "/tmp/a.yaml"),
            deviceID: "425BD068-3D87-4F27-BE58-EB56A58B2C3A",
            outputDirectory: URL(fileURLWithPath: "/tmp/run-2", isDirectory: true)
        )
        XCTAssertFalse(fresh.arguments.contains("--no-reinstall-driver"))
        XCTAssertEqual(fresh.arguments.last, "/tmp/a.yaml")
    }

    /// A device that is not connected: the CLI's own message reaches the
    /// transcript and the exit status says it failed.
    func testRunOnAMissingDeviceReportsTheCLIsMessage() async throws {
        let fake = try FakeTool(name: "maestro", rules: [
            .init("test --no-ansi", stdoutFile: nil, stderrFile: Self.fixture("test-device-not-connected.err.txt"), exitCode: 1),
        ])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("maestro-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = MaestroRunRequest(
            flowFile: URL(fileURLWithPath: "/tmp/f.yaml"),
            deviceID: "emulator-5554",
            outputDirectory: folder
        )
        let lines = LockedLines()
        let status = try await MaestroClient(executableURL: fake.executableURL).test(request) { lines.add($0) }

        XCTAssertEqual(status, 1)
        var transcript = MaestroRunTranscript()
        for line in lines.all { transcript.append(line) }
        XCTAssertEqual(transcript.messages, ["Device emulator-5554 was requested, but it is not connected."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the run folder is made before the run")
    }

    /// The lines of a run as the CLI writes them: each step's start and its
    /// status on one line (SOURCE-DERIVED, see `MaestroOutputParserTests`).
    func testRunDeliversStepsLineByLine() async throws {
        let output = """
        Running on emulator-5554
         > Flow login
        Launch app "com.example.app"... COMPLETED
        Tap on "Sign in"... COMPLETED

        """
        let fake = try FakeTool(name: "maestro", rules: [.init("test --no-ansi", output: output)])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("maestro-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = LockedLines()
        let status = try await MaestroClient(executableURL: fake.executableURL).test(
            MaestroRunRequest(flowFile: URL(fileURLWithPath: "/tmp/login.yaml"), deviceID: "emulator-5554", outputDirectory: folder)
        ) { lines.add($0) }

        XCTAssertEqual(status, 0)
        var transcript = MaestroRunTranscript()
        for line in lines.all { transcript.append(line) }
        XCTAssertEqual(transcript.steps.map(\.title), [#"Launch app "com.example.app""#, #"Tap on "Sign in""#])
        XCTAssertEqual(transcript.steps.map(\.status), [.completed, .completed])
        XCTAssertEqual(transcript.device, "emulator-5554")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
