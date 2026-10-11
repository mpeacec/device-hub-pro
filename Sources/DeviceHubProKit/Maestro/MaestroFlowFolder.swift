import Foundation

/// One flow file in the user's flows folder.
public struct MaestroFlowFile: Equatable, Hashable, Sendable, Identifiable {
    public let url: URL
    /// The path below the folder ("login.yaml", "checkout/pay.yaml").
    public let relativePath: String

    public var id: String { relativePath }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}

/// The folder the Flows panel reads and writes: plain `.yaml` files the user
/// can keep in a repository next to the app they test. Device Hub Pro keeps
/// no copy of its own; the files on disk are the flows.
public struct MaestroFlowFolder: Sendable {
    public let url: URL

    /// How deep `flows()` looks below the folder.
    public static let maximumDepth = 4
    /// A workspace's `config.yaml` (Maestro's `flows:` / tags settings) is
    /// not a flow.
    static let configNames: Set<String> = ["config.yaml", "config.yml"]

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/DeviceHubPro/Flows`, the folder used
    /// until the user picks one.
    public static var defaultURL: URL {
        LibraryFile.applicationSupportFolder.appendingPathComponent("Flows", isDirectory: true)
    }

    /// Every `.yaml` / `.yml` file below the folder (hidden files and
    /// folders and `config.yaml` left out), sorted by path.
    public func flows() -> [MaestroFlowFile] {
        let manager = FileManager.default
        let root = url.standardizedFileURL
        // `/var` and `/private/var` name one folder; compare resolved paths.
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [MaestroFlowFile] = []
        for case let file as URL in enumerator {
            if enumerator.level > Self.maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            let ext = file.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml",
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let relative = Self.relativePath(of: file.resolvingSymlinksInPath(), in: resolvedRoot)
            if Self.configNames.contains(relative.lowercased()) { continue }
            result.append(MaestroFlowFile(url: file, relativePath: relative))
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Creates the folder when it does not exist yet.
    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A new flow file named after `name` ("Login" → `Login.yaml`; a taken
    /// name gets " 2", " 3"…), holding `MaestroFlowTemplate.text(appID:)`.
    public func createFlow(named name: String, appID: String?) throws -> MaestroFlowFile {
        try ensureExists()
        let base = Self.fileSafe(name).isEmpty ? "Flow" : Self.fileSafe(name)
        var candidate = base
        var counter = 2
        let manager = FileManager.default
        while manager.fileExists(atPath: url.appendingPathComponent(candidate + ".yaml").path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        let file = url.appendingPathComponent(candidate + ".yaml")
        try Data(MaestroFlowTemplate.text(appID: appID).utf8).write(to: file, options: .withoutOverwriting)
        return MaestroFlowFile(url: file, relativePath: candidate + ".yaml")
    }

    static func relativePath(of file: URL, in root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = file.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : file.lastPathComponent
    }

    /// A name with the characters a file name cannot hold (`/`, `:`) and
    /// leading dots removed.
    static func fileSafe(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.drop(while: { $0 == "." }))
    }
}

/// The starting text of a new flow.
public enum MaestroFlowTemplate {
    /// A flow that launches `appID` (a placeholder id when there is none) and
    /// shows the shape of the common commands as comments.
    public static func text(appID: String?) -> String {
        let id = appID?.isEmpty == false ? appID! : "com.example.app"
        return """
        appId: \(id)
        ---
        - launchApp
        # - tapOn: "Sign in"
        # - inputText: "qa@example.com"
        # - assertVisible: "Welcome"

        """
    }
}
