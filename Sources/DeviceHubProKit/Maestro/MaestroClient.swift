import Foundation

/// What the user asked `maestro test` to do: one flow file on one device.
public struct MaestroRunRequest: Equatable, Sendable {
    /// The flow (`.yaml`) to run.
    public let flowFile: URL
    /// The device's id as Maestro lists it: an adb serial or a simulator UDID.
    /// Always passed, so Maestro never asks which device to use.
    public let deviceID: String
    /// The run's own folder: `manifest.json`, `commands.json`, `logs/`, screenshots.
    public let outputDirectory: URL
    /// `-e KEY=VALUE` pairs, in order.
    public let environment: [(key: String, value: String)]
    /// false adds `--no-reinstall-driver`: a repeat run keeps the driver
    /// Maestro installed on the device last time and starts faster.
    public let reinstallDriver: Bool

    public init(
        flowFile: URL,
        deviceID: String,
        outputDirectory: URL,
        environment: [(key: String, value: String)] = [],
        reinstallDriver: Bool = true
    ) {
        self.flowFile = flowFile
        self.deviceID = deviceID
        self.outputDirectory = outputDirectory
        self.environment = environment
        self.reinstallDriver = reinstallDriver
    }

    public static func == (lhs: MaestroRunRequest, rhs: MaestroRunRequest) -> Bool {
        lhs.flowFile == rhs.flowFile
            && lhs.deviceID == rhs.deviceID
            && lhs.outputDirectory == rhs.outputDirectory
            && lhs.environment.map(\.key) == rhs.environment.map(\.key)
            && lhs.environment.map(\.value) == rhs.environment.map(\.value)
            && lhs.reinstallDriver == rhs.reinstallDriver
    }

    /// `maestro test` argv. SOURCE-DERIVED: Maestro CLI 2.11.0
    /// (maestro-cli `TestCommand.kt`, `DisableAnsiMixin.kt`, mobile-dev-inc/maestro c73b120):
    /// `--no-ansi` selects the plain-text view `MaestroOutputParser` reads,
    /// `--device` names the device, `--test-output-dir` puts the run's
    /// artifacts in the run's folder.
    public var arguments: [String] {
        var arguments = [
            "test",
            "--no-ansi",
            "--device", deviceID,
            "--test-output-dir", outputDirectory.path,
        ]
        if !reinstallDriver { arguments.append("--no-reinstall-driver") }
        for (key, value) in environment {
            arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        arguments.append(flowFile.path)
        return arguments
    }
}

/// What `maestro check-syntax` said about a flow.
public enum MaestroSyntaxResult: Equatable, Sendable {
    case ok
    /// The CLI's message, with its `/syntax-checker:<line>:<column>` place
    /// spelled out as "(line L, column C)".
    case problem(String)
}

public enum MaestroClientError: Error, Equatable, CustomStringConvertible {
    /// The CLI ran but did not do what was asked; its own message.
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

/// Runs the `maestro` CLI. Every call runs with analytics, the update check
/// and the promotion banner off (`quietEnvironment`), a `JAVA_HOME` when the
/// app found one, and standard input closed or fed, never a terminal, so the
/// CLI cannot stop at an interactive prompt.
public struct MaestroClient: Sendable {
    public let executableURL: URL
    /// Added to the app's environment for every call.
    public let environment: [String: String]

    /// Maestro's own switches, read by the CLI at start
    /// (maestro-cli `Analytics.kt`, `UpdateChecker`, `PromotionStateManager`, 2.11.0).
    public static let quietEnvironment: [String: String] = [
        "MAESTRO_CLI_NO_ANALYTICS": "1",
        "MAESTRO_DISABLE_UPDATE_CHECK": "1",
        "MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED": "true",
    ]

    public init(executableURL: URL, environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.environment = Self.quietEnvironment.merging(environment) { _, extra in extra }
    }

    /// `maestro --version`: the last line it prints ("2.11.0").
    public func version(timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: executableURL,
            arguments: ["--version"],
            environment: environment,
            timeout: timeout
        )
        let lines = result.standardOutputText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard result.exitCode == 0, let version = lines.last else {
            throw MaestroClientError.failed(Self.message(result) ?? "maestro --version exited with \(result.exitCode)")
        }
        return version
    }

    /// `maestro check-syntax -` with `yaml` on standard input.
    public func checkSyntax(_ yaml: String, timeout: Duration = .seconds(60)) async throws -> MaestroSyntaxResult {
        let result = try await ProcessRunner.run(
            executable: executableURL,
            arguments: ["check-syntax", "-"],
            standardInput: Data(yaml.utf8),
            environment: environment,
            timeout: timeout
        )
        if result.exitCode == 0 {
            return .ok
        }
        let message = Self.message(result) ?? "maestro check-syntax exited with \(result.exitCode)"
        return .problem(Self.spellingOutPlace(message))
    }

    /// `maestro test` for `request`, its output delivered line by line
    /// (stdout and stderr interleaved, as a terminal shows them) to `onLine`
    /// on a background thread. A command's unfinished `<description>...`
    /// line is delivered as soon as it is printed. Returns the exit status
    /// (0 when the flow passed). Cancelling the task interrupts the CLI
    /// (SIGINT, as Ctrl-C in a terminal, so it can stop its driver) and
    /// throws `CancellationError` once it has exited.
    public func test(
        _ request: MaestroRunRequest,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        return try await ProcessRunner.stream(
            executable: executableURL,
            arguments: request.arguments,
            environment: environment,
            stopSignal: .interrupt,
            partialLineHandler: { MaestroOutputParser.isUnfinishedStep($0) },
            onLine: onLine
        )
    }

    /// stderr, else stdout, trimmed; nil when both are empty.
    static func message(_ result: ProcessResult) -> String? {
        for text in [result.standardErrorText, result.standardOutputText] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// "Invalid Command: tapOnn at /syntax-checker:4:9" →
    /// "Invalid Command: tapOnn (line 4, column 9)". Maestro names standard
    /// input `/syntax-checker` (captured, CLI 2.11.0).
    static func spellingOutPlace(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #" at /syntax-checker:(\d+):(\d+)"#) else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, range: range, withTemplate: " (line $1, column $2)")
    }
}
