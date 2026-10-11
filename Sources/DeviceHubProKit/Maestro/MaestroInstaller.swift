import Foundation

/// The Maestro release Device Hub Pro installs, pinned so the output it reads
/// (`MaestroOutputParser`) is the output it was written against.
public struct MaestroRelease: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String
    public let size: Int64

    /// mobile-dev-inc/maestro `cli-2.11.0` (29 Sep 2026): `maestro.zip`,
    /// measured when this pin was set.
    public static let pinned = MaestroRelease(
        version: "2.11.0",
        url: URL(string: "https://github.com/mobile-dev-inc/maestro/releases/download/cli-2.11.0/maestro.zip")!,
        sha256: "5384593cb4e7a106489e75a821d157dd43f4e438df6bc308b72e82c685e1283a",
        size: 314_886_578
    )
}

public enum MaestroInstallError: Error, Equatable, CustomStringConvertible {
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)
    case launcherMissing

    public var description: String {
        switch self {
        case .downloadFailed(let detail):
            "Maestro could not be downloaded: \(detail)"
        case .checksumMismatch:
            "The downloaded Maestro did not match the expected checksum and was deleted. Try again."
        case .extractionFailed(let detail):
            "Maestro could not be unpacked: \(detail)"
        case .launcherMissing:
            "The Maestro download did not contain maestro/bin/maestro."
        }
    }
}

/// Downloads the pinned Maestro release into the app's own folder
/// (`MaestroLocator.managedDirectory`), without administrator rights and
/// without touching the user's shell profile: the zip is verified, unpacked
/// to a temporary folder, and its `maestro` folder swapped in.
public struct MaestroInstaller: Sendable {
    public let release: MaestroRelease
    public let directory: URL
    private let downloader: any FileDownloading
    private let extractor: any ArchiveExtracting

    public init(
        release: MaestroRelease = .pinned,
        directory: URL = MaestroLocator.managedDirectory,
        downloader: any FileDownloading = URLSessionFileDownloader(),
        extractor: any ArchiveExtracting = SystemArchiveExtractor()
    ) {
        self.release = release
        self.directory = directory
        self.downloader = downloader
        self.extractor = extractor
    }

    /// Installs the release and returns its launcher. `onProgress` gets the
    /// downloaded fraction (nil when the size is unknown), then 1 while it
    /// verifies and unpacks. Cancelling stops the download and leaves the
    /// partial file to be continued next time.
    public func install(onProgress: @Sendable @escaping (Double?) -> Void = { _ in }) async throws -> URL {
        let manager = FileManager.default
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let archive = downloads.appendingPathComponent("maestro-\(release.version).zip")

        if !(manager.fileExists(atPath: archive.path)
            && FileChecksum.matches(archive, algorithm: .sha256, expected: release.sha256)) {
            try? manager.removeItem(at: archive)
            let partial = archive.appendingPathExtension("partial")
            let size = release.size
            do {
                try await downloader.download(release.url, to: partial) { done, total in
                    let total = total ?? (size > 0 ? size : nil)
                    onProgress(total.map { $0 > 0 ? min(1, Double(done) / Double($0)) : 0 })
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MaestroInstallError.downloadFailed(String(describing: error))
            }
            try Task.checkCancellation()
            onProgress(1)
            guard FileChecksum.matches(partial, algorithm: .sha256, expected: release.sha256) else {
                try? manager.removeItem(at: partial)
                throw MaestroInstallError.checksumMismatch
            }
            try manager.moveItem(at: partial, to: archive)
        }
        onProgress(1)

        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        do {
            try await extractor.extractZip(archive, to: staging)
        } catch {
            throw MaestroInstallError.extractionFailed(String(describing: error))
        }
        let unpacked = staging.appendingPathComponent("maestro", isDirectory: true)
        guard manager.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/maestro").path) else {
            throw MaestroInstallError.launcherMissing
        }
        let destination = directory.appendingPathComponent("maestro", isDirectory: true)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: unpacked, to: destination)
        try? manager.removeItem(at: archive)
        return MaestroLocator.managedExecutable(in: directory)
    }
}
