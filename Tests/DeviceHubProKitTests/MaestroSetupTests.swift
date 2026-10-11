import XCTest
@testable import DeviceHubProKit

/// Finding Maestro, installing the pinned release, and the flows folder.
final class MaestroSetupTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaestroSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeExecutable(_ relative: String) throws -> URL {
        let url = scratch.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Locator

    func testCandidatesInOrder() {
        let home = URL(fileURLWithPath: "/Users/aqauser001", isDirectory: true)
        let managed = URL(fileURLWithPath: "/Users/aqauser001/Library/Application Support/DeviceHubPro/maestro", isDirectory: true)
        let candidates = MaestroLocator.candidates(
            customPath: "/opt/tools/maestro",
            environment: ["DHP_MAESTRO": "/x/maestro", "PATH": "/usr/bin:/Users/aqauser001/bin"],
            managedDirectory: managed,
            home: home
        )
        XCTAssertEqual(candidates, [
            "/opt/tools/maestro",
            "/x/maestro",
            "/Users/aqauser001/Library/Application Support/DeviceHubPro/maestro/maestro/bin/maestro",
            "/Users/aqauser001/.maestro/bin/maestro",
            "/usr/bin/maestro",
            "/Users/aqauser001/bin/maestro",
            "/opt/homebrew/bin/maestro",
            "/usr/local/bin/maestro",
        ])
    }

    func testTheAppsOwnCopyWinsOverTheUsersInstall() throws {
        let managed = scratch.appendingPathComponent("managed", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let users = try makeExecutable("home/.maestro/bin/maestro")
        XCTAssertEqual(
            MaestroLocator.locate(environment: [:], managedDirectory: managed, home: home)?.path,
            users.path
        )
        let own = try makeExecutable("managed/maestro/bin/maestro")
        XCTAssertEqual(
            MaestroLocator.locate(environment: [:], managedDirectory: managed, home: home)?.path,
            own.path
        )
    }

    // MARK: - Installer

    func testInstallVerifiesUnpacksAndReturnsTheLauncher() async throws {
        let payload = Data("not really a zip".utf8)
        let digest = try sha256(payload)
        let release = MaestroRelease(
            version: "2.11.0",
            url: URL(string: "https://example.invalid/maestro.zip")!,
            sha256: digest,
            size: Int64(payload.count)
        )
        let directory = scratch.appendingPathComponent("managed", isDirectory: true)
        let installer = MaestroInstaller(
            release: release,
            directory: directory,
            downloader: FakeDownloader(payload: payload),
            extractor: FakeExtractor()
        )
        let launcher = try await installer.install()
        XCTAssertEqual(launcher.path, directory.appendingPathComponent("maestro/bin/maestro").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("downloads/maestro-2.11.0.zip").path),
                       "the archive is removed once unpacked")
    }

    func testAChecksumMismatchDeletesTheDownload() async throws {
        let release = MaestroRelease(
            version: "2.11.0",
            url: URL(string: "https://example.invalid/maestro.zip")!,
            sha256: String(repeating: "0", count: 64),
            size: 4
        )
        let directory = scratch.appendingPathComponent("managed", isDirectory: true)
        let installer = MaestroInstaller(
            release: release,
            directory: directory,
            downloader: FakeDownloader(payload: Data("evil".utf8)),
            extractor: FakeExtractor()
        )
        do {
            _ = try await installer.install()
            XCTFail("a mismatching download must not install")
        } catch let error as MaestroInstallError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("downloads").path)) ?? []
        XCTAssertEqual(leftovers, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("maestro").path))
    }

    func testThePinnedReleaseIsTheMeasuredOne() {
        XCTAssertEqual(MaestroRelease.pinned.version, "2.11.0")
        XCTAssertEqual(
            MaestroRelease.pinned.url.absoluteString,
            "https://github.com/mobile-dev-inc/maestro/releases/download/cli-2.11.0/maestro.zip"
        )
        XCTAssertEqual(MaestroRelease.pinned.sha256.count, 64)
    }

    // MARK: - Flows folder

    func testFlowsAreTheYamlFilesBelowTheFolder() throws {
        let folder = MaestroFlowFolder(url: scratch)
        for (path, text) in [
            ("login.yaml", "appId: a\n---\n- launchApp\n"),
            ("checkout/pay.yml", "appId: a\n---\n- launchApp\n"),
            ("config.yaml", "flows:\n  - '*'\n"),
            (".hidden/secret.yaml", "x"),
            ("notes.txt", "x"),
        ] {
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        XCTAssertEqual(folder.flows().map(\.relativePath), ["checkout/pay.yml", "login.yaml"])
        XCTAssertEqual(folder.flows().map(\.name), ["pay", "login"])
    }

    func testANewFlowGetsAFreeNameAndTheTemplate() throws {
        let folder = MaestroFlowFolder(url: scratch.appendingPathComponent("flows", isDirectory: true))
        let first = try folder.createFlow(named: "Login", appID: "com.example.shop")
        let second = try folder.createFlow(named: "Login", appID: nil)
        let odd = try folder.createFlow(named: "../a/b:c", appID: nil)
        XCTAssertEqual(first.relativePath, "Login.yaml")
        XCTAssertEqual(second.relativePath, "Login 2.yaml")
        XCTAssertEqual(odd.relativePath, "-a-b-c.yaml")
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), """
        appId: com.example.shop
        ---
        - launchApp
        # - tapOn: "Sign in"
        # - inputText: "qa@example.com"
        # - assertVisible: "Welcome"

        """)
        XCTAssertTrue(try String(contentsOf: second.url, encoding: .utf8).hasPrefix("appId: com.example.app\n"))
    }

    private func sha256(_ data: Data) throws -> String {
        let file = scratch.appendingPathComponent("digest-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try FileChecksum.hexDigest(of: file, algorithm: .sha256)
    }
}

private struct FakeDownloader: FileDownloading {
    let payload: Data

    func download(_ url: URL, to partial: URL, onProgress: @Sendable @escaping (Int64, Int64?) -> Void) async throws {
        try payload.write(to: partial)
        onProgress(Int64(payload.count), Int64(payload.count))
    }

    func data(from url: URL) async throws -> Data { payload }
}

/// Unpacks any archive into the layout of a Maestro release.
private struct FakeExtractor: ArchiveExtracting {
    func extractZip(_ archive: URL, to directory: URL) async throws {
        let launcher = directory.appendingPathComponent("maestro/bin/maestro")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 2.11.0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    }

    func extractTarGz(_ archive: URL, to directory: URL) async throws {}
}
