import Foundation

/// Finds the `maestro` command-line tool (mobile.dev's UI test runner) and
/// knows where the app keeps a copy it installed itself.
///
/// The CLI is a launcher script over a JVM: the zip a release publishes
/// unpacks to `maestro/bin/maestro` and `maestro/lib/*.jar`, which is what
/// both its own installer (into `~/.maestro`) and `MaestroInstaller` (into
/// `managedDirectory`) leave on disk.
public enum MaestroLocator {
    /// Where a copy installed by Device Hub Pro lives.
    public static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceHubPro/maestro", isDirectory: true)
    }

    /// `<directory>/maestro/bin/maestro`, the launcher of an unpacked release.
    public static func managedExecutable(in directory: URL = managedDirectory) -> URL {
        directory.appendingPathComponent("maestro/bin/maestro")
    }

    /// The paths worth trying, best first: the path chosen in Settings,
    /// `DHP_MAESTRO`, the app's own copy, the official installer's
    /// `~/.maestro/bin`, the `PATH`, then Homebrew's two prefixes.
    public static func candidates(
        customPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedDirectory: URL = MaestroLocator.managedDirectory,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var paths: [String] = []
        if !customPath.isEmpty { paths.append(customPath) }
        if let explicit = environment["DHP_MAESTRO"], !explicit.isEmpty { paths.append(explicit) }
        paths.append(managedExecutable(in: managedDirectory).path)
        if let maestroDir = environment["MAESTRO_DIR"], !maestroDir.isEmpty {
            paths.append(maestroDir + "/bin/maestro")
        }
        paths.append(home.appendingPathComponent(".maestro/bin/maestro").path)
        if let path = environment["PATH"] {
            for component in path.split(separator: ":") where !component.isEmpty {
                paths.append(String(component) + "/maestro")
            }
        }
        paths.append("/opt/homebrew/bin/maestro")
        paths.append("/usr/local/bin/maestro")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The first candidate that is an executable file, nil when none is.
    public static func locate(
        customPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedDirectory: URL = MaestroLocator.managedDirectory,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let manager = FileManager.default
        return candidates(customPath: customPath, environment: environment, managedDirectory: managedDirectory, home: home)
            .first { manager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
