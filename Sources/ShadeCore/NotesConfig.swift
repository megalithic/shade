import Foundation

/// Configuration for notes vault paths
/// Shade uses these to copy images to assets and know vault structure
public struct NotesConfig: Codable, Equatable {
    /// Root of the notes vault (e.g., ~/notes or ~/iclouddrive/Documents/_notes)
    public var home: String?

    /// Assets directory for images (defaults to {home}/assets)
    public var assetsDir: String?

    /// Captures directory for capture notes (defaults to {home}/captures)
    public var capturesDir: String?

    public init(home: String? = nil, assetsDir: String? = nil, capturesDir: String? = nil) {
        self.home = home
        self.assetsDir = assetsDir
        self.capturesDir = capturesDir
    }

    enum CodingKeys: String, CodingKey {
        case home
        case assetsDir = "assets_dir"
        case capturesDir = "captures_dir"
    }

    /// Resolve home path, checking environment and common locations
    /// - Parameter environment: Environment variables (injectable for testing)
    /// - Parameter fileExists: File existence checker (injectable for testing)
    public func resolvedHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        // 1. Use configured home if set
        if let home = home, !home.isEmpty {
            return (home as NSString).expandingTildeInPath
        }

        // 2. Check NOTES_HOME environment variable
        if let notesHome = environment["NOTES_HOME"] {
            return notesHome
        }

        // 3. Fallback to common locations
        let userHome = NSHomeDirectory()
        let iCloudPath = "\(userHome)/iclouddrive/Documents/_notes"
        if fileExists(iCloudPath) {
            return iCloudPath
        }

        return "\(userHome)/notes"
    }

    /// Resolve assets directory path
    public func resolvedAssetsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if let assetsDir = assetsDir, !assetsDir.isEmpty {
            return (assetsDir as NSString).expandingTildeInPath
        }
        return "\(resolvedHome(environment: environment, fileExists: fileExists))/assets"
    }

    /// Resolve captures directory path
    public func resolvedCapturesDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if let capturesDir = capturesDir, !capturesDir.isEmpty {
            return (capturesDir as NSString).expandingTildeInPath
        }
        return "\(resolvedHome(environment: environment, fileExists: fileExists))/captures"
    }
}
