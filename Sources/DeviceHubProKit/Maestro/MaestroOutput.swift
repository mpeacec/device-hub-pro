import Foundation

/// One step of a running flow, as `maestro test --no-ansi` reports it.
public struct MaestroStep: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case running
        case completed
        case failed
        case skipped
        case warned
    }

    public let id: Int
    /// The command's description ("Tap on \"Sign in\"", "Launch app \"com.example\"").
    public let title: String
    /// 0 for a flow's own commands, one more inside each `runFlow`, `repeat`
    /// or `retry` (two spaces of indent per level in the output).
    public let depth: Int
    public var status: Status

    public init(id: Int, title: String, depth: Int, status: Status) {
        self.id = id
        self.title = title
        self.depth = depth
        self.status = status
    }
}

/// What one line of `maestro test --no-ansi` says.
public enum MaestroOutputLine: Equatable, Sendable {
    /// `Running on <device>`.
    case device(String)
    /// ` > Flow <name>`.
    case flow(String)
    /// `<description>...`: a command started (a simple command's line is
    /// delivered unfinished, a composite command's start ends there).
    case stepStarted(title: String, depth: Int)
    /// `<description>... COMPLETED` (or FAILED, SKIPPED, WARNED).
    case stepFinished(title: String, depth: Int, status: MaestroStep.Status)
    /// ` COMPLETED` alone: the end of the unfinished line before it.
    case statusOnly(MaestroStep.Status)
    /// `> On Flow Start` / `> On Flow Complete`, blank lines.
    case structure
    /// Anything else: an error, an insight, the debug output path.
    case message(String)
}

/// Reads `maestro test --no-ansi` output into steps.
///
/// SOURCE-DERIVED: Maestro CLI 2.11.0 `PlainTextResultView`
/// (maestro-cli/src/main/java/maestro/cli/runner/resultview/PlainTextResultView.kt,
/// mobile-dev-inc/maestro c73b120). Without ANSI the CLI prints
/// `Running on <device>` once, ` > Flow <name>` once, and per command
/// `<indent><description>...` when it starts, followed on the same line by
/// ` COMPLETED|FAILED|SKIPPED|WARNED` when it ends; a composite command
/// (`runFlow`, `repeat`, `retry`) prints its start on a line of its own and
/// `<description>... <STATUS>` again when it ends. Indent is two spaces per
/// nesting level. The start of a simple command has no line break, so
/// `MaestroClient.test` delivers that unfinished line as soon as it ends in
/// `...` (`ProcessRunner.stream`'s partial-line hook).
public enum MaestroOutputParser {
    static let statuses: [(word: String, status: MaestroStep.Status)] = [
        ("COMPLETED", .completed),
        ("FAILED", .failed),
        ("SKIPPED", .skipped),
        ("WARNED", .warned),
    ]

    public static func parse(_ line: String) -> MaestroOutputLine {
        let trimmedEnd = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        if trimmedEnd.isEmpty { return .structure }

        if trimmedEnd.hasPrefix("Running on ") {
            return .device(String(trimmedEnd.dropFirst("Running on ".count)))
        }
        let content = trimmedEnd.drop(while: { $0 == " " })
        if content.hasPrefix("> Flow ") {
            return .flow(String(content.dropFirst("> Flow ".count)))
        }
        if content == "> On Flow Start" || content == "> On Flow Complete" {
            return .structure
        }
        for (word, status) in statuses where content == word {
            return .statusOnly(status)
        }

        let indent = trimmedEnd.count - content.count
        let depth = indent / 2
        for (word, status) in statuses {
            let suffix = "... " + word
            if content.hasSuffix(suffix) {
                let title = String(content.dropLast(suffix.count))
                guard !title.isEmpty else { break }
                return .stepFinished(title: title, depth: depth, status: status)
            }
        }
        if content.hasSuffix("...") {
            let title = String(content.dropLast(3))
            if !title.isEmpty { return .stepStarted(title: title, depth: depth) }
        }
        return .message(trimmedEnd)
    }

    /// Whether an unfinished line is a command's start, which the reader
    /// should hand over before its line break arrives.
    public static func isUnfinishedStep(_ partial: String) -> Bool {
        partial.hasSuffix("...") && !partial.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The steps and messages of one run, folded from its output lines.
public struct MaestroRunTranscript: Equatable, Sendable {
    public private(set) var device: String?
    public private(set) var flowName: String?
    public private(set) var steps: [MaestroStep] = []
    /// Lines that are not steps (errors, warnings, the debug output path).
    public private(set) var messages: [String] = []
    /// Every line, as delivered, for the raw log.
    public private(set) var lines: [String] = []
    /// The cap on `lines` and `messages`; the oldest go first.
    public static let lineLimit = 5_000

    public init() {}

    public var hasFailedStep: Bool { steps.contains { $0.status == .failed } }

    public mutating func append(_ line: String) {
        Self.appendCapped(line, to: &lines)
        switch MaestroOutputParser.parse(line) {
        case .device(let name):
            device = name
        case .flow(let name):
            flowName = name
        case .stepStarted(let title, let depth):
            steps.append(MaestroStep(id: steps.count, title: title, depth: depth, status: .running))
        case .stepFinished(let title, let depth, let status):
            if let index = steps.lastIndex(where: { $0.status == .running && $0.title == title && $0.depth == depth }) {
                steps[index].status = status
            } else {
                steps.append(MaestroStep(id: steps.count, title: title, depth: depth, status: status))
            }
        case .statusOnly(let status):
            if let index = steps.lastIndex(where: { $0.status == .running }) {
                steps[index].status = status
            }
        case .structure:
            break
        case .message(let text):
            Self.appendCapped(text, to: &messages)
        }
    }

    /// A run that ended (or was stopped) leaves no step running.
    public mutating func finish(stopped: Bool) {
        for index in steps.indices where steps[index].status == .running {
            steps[index].status = stopped ? .skipped : .failed
        }
    }

    private static func appendCapped(_ line: String, to list: inout [String]) {
        list.append(line)
        if list.count > lineLimit { list.removeFirst(list.count - lineLimit) }
    }
}
