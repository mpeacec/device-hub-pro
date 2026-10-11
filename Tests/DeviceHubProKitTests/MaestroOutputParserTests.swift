import XCTest
@testable import DeviceHubProKit

/// `maestro test --no-ansi` lines into steps.
///
/// SOURCE-DERIVED: no device was available to capture a run, so the lines
/// below are built from Maestro CLI 2.11.0's `PlainTextResultView`
/// (maestro-cli/src/main/java/maestro/cli/runner/resultview/PlainTextResultView.kt,
/// mobile-dev-inc/maestro c73b120) and the command descriptions in
/// maestro-orchestra-models `Commands.kt` (`Launch app "<id>"`,
/// `Tap on "<text>"`, `Input text <text>`, `Assert that "<text>" is visible`,
/// `Run <file>` for a `runFlow`).
/// A simple command prints `<description>...` without a line break when it
/// starts and ` <STATUS>` plus a break when it ends; a composite command
/// prints its start on a line of its own; nesting indents two spaces.
final class MaestroOutputParserTests: XCTestCase {
    func testLinesOfAPlainTextRun() {
        XCTAssertEqual(MaestroOutputParser.parse("Running on emulator-5554"), .device("emulator-5554"))
        XCTAssertEqual(MaestroOutputParser.parse(" > Flow login"), .flow("login"))
        XCTAssertEqual(
            MaestroOutputParser.parse(#"Launch app "com.example.app"..."#),
            .stepStarted(title: #"Launch app "com.example.app""#, depth: 0)
        )
        XCTAssertEqual(MaestroOutputParser.parse(" COMPLETED"), .statusOnly(.completed))
        XCTAssertEqual(
            MaestroOutputParser.parse(#"Tap on "Sign in"... FAILED"#),
            .stepFinished(title: #"Tap on "Sign in""#, depth: 0, status: .failed)
        )
        XCTAssertEqual(
            MaestroOutputParser.parse("    Input text qa@example.com... SKIPPED"),
            .stepFinished(title: "Input text qa@example.com", depth: 2, status: .skipped)
        )
        XCTAssertEqual(MaestroOutputParser.parse("  > On Flow Start"), .structure)
        XCTAssertEqual(MaestroOutputParser.parse(""), .structure)
        XCTAssertEqual(
            MaestroOutputParser.parse("Device emulator-5554 was requested, but it is not connected."),
            .message("Device emulator-5554 was requested, but it is not connected.")
        )
    }

    func testOnlyAnUnfinishedStartIsHandedOverEarly() {
        XCTAssertTrue(MaestroOutputParser.isUnfinishedStep(#"Tap on "Sign in"..."#))
        XCTAssertFalse(MaestroOutputParser.isUnfinishedStep(#"Tap on "Sig"#))
        XCTAssertFalse(MaestroOutputParser.isUnfinishedStep("   "))
    }

    /// The order `MaestroClient.test` delivers a run in: each simple
    /// command's unfinished start, then its status on the same line, and a
    /// composite command's start and end lines around its indented steps.
    func testTranscriptFoldsARunIntoSteps() {
        var transcript = MaestroRunTranscript()
        for line in [
            "Running on Pixel_8_Pro",
            " > Flow login",
            #"Launch app "com.example.app"..."#,
            " COMPLETED",
            "Run signin.yaml...",
            #"  Tap on "Sign in"..."#,
            " COMPLETED",
            "  Input text qa@example.com... COMPLETED",
            "Run signin.yaml... COMPLETED",
            #"Assert that "Welcome" is visible..."#,
            " FAILED",
            #"Element not found: Text matching regex: Welcome"#,
        ] {
            transcript.append(line)
        }
        transcript.finish(stopped: false)

        XCTAssertEqual(transcript.device, "Pixel_8_Pro")
        XCTAssertEqual(transcript.flowName, "login")
        XCTAssertEqual(transcript.steps.map(\.title), [
            #"Launch app "com.example.app""#,
            "Run signin.yaml",
            #"Tap on "Sign in""#,
            "Input text qa@example.com",
            #"Assert that "Welcome" is visible"#,
        ])
        XCTAssertEqual(transcript.steps.map(\.depth), [0, 0, 1, 1, 0])
        XCTAssertEqual(transcript.steps.map(\.status), [.completed, .completed, .completed, .completed, .failed])
        XCTAssertEqual(transcript.messages, ["Element not found: Text matching regex: Welcome"])
        XCTAssertTrue(transcript.hasFailedStep)
        XCTAssertEqual(transcript.lines.count, 12)
    }

    func testAStoppedRunLeavesNoStepRunning() {
        var transcript = MaestroRunTranscript()
        transcript.append(#"Launch app "com.example.app"..."#)
        transcript.finish(stopped: true)
        XCTAssertEqual(transcript.steps.map(\.status), [.skipped])

        var ended = MaestroRunTranscript()
        ended.append(#"Launch app "com.example.app"..."#)
        ended.finish(stopped: false)
        XCTAssertEqual(ended.steps.map(\.status), [.failed])
    }
}
