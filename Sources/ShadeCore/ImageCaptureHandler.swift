import Foundation

/// Errors that can occur during image capture processing
public enum ImageCaptureError: Error, LocalizedError, Equatable {
    case tempFileNotFound(String)
    case assetsDirectoryCreationFailed(String)
    case pathExistsButIsFile(String)
    case copyFailed(String, String)
    case deletionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .tempFileNotFound(let path):
            return "Temporary image file not found: \(path)"
        case .assetsDirectoryCreationFailed(let path):
            return "Failed to create assets directory: \(path)"
        case .pathExistsButIsFile(let path):
            return "Path exists but is a file, not a directory: \(path)"
        case .copyFailed(let src, let dest):
            return "Failed to copy '\(src)' to '\(dest)'"
        case .deletionDenied(let path):
            return "Deletion denied for path outside temp directories: \(path)"
        }
    }
}

/// Protocol for file system operations (injectable for testing)
public protocol FileSystemProvider {
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool
    func createDirectory(atPath path: String) throws
    func copyItem(atPath src: String, toPath dest: String) throws
    func removeItem(atPath path: String) throws
}

/// Default file system provider using FileManager
public struct DefaultFileSystemProvider: FileSystemProvider {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        isDirectory = isDir.boolValue
        return exists
    }

    public func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func copyItem(atPath src: String, toPath dest: String) throws {
        try FileManager.default.copyItem(atPath: src, toPath: dest)
    }

    public func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Handles image capture operations: copying to vault assets, cleanup
/// Centralizes image file management so Shade owns the entire image lifecycle
public struct ImageCaptureProcessor {

    /// Allowed temp directory prefixes for deletion safety
    public static let allowedTempPrefixes: [String] = [
        "/_screenshots/",
        "/tmp/",
    ]

    private let fileSystem: FileSystemProvider
    private let dateProvider: () -> Date

    public init(
        fileSystem: FileSystemProvider = DefaultFileSystemProvider(),
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.dateProvider = dateProvider
    }

    /// Process an image capture from a temp file path
    /// - Parameters:
    ///   - tempPath: Path to temporary image file (from Hammerspoon clipper)
    ///   - assetsDir: Directory to copy the image to
    /// - Returns: Result with asset filename on success, or error on failure
    public func processCapture(tempPath: String, assetsDir: String) -> Result<String, ImageCaptureError> {
        // Validate temp file exists
        guard fileSystem.fileExists(atPath: tempPath) else {
            shadeLogger.error("ImageCapture: temp file not found: \(tempPath)")
            return .failure(.tempFileNotFound(tempPath))
        }

        // Ensure assets directory exists
        do {
            try ensureDirectory(assetsDir)
        } catch let error as ImageCaptureError {
            return .failure(error)
        } catch {
            shadeLogger.error("ImageCapture: failed to create assets dir: \(error)")
            return .failure(.assetsDirectoryCreationFailed(assetsDir))
        }

        // Generate timestamped filename
        let filename = generateTimestampFilename()
        let destPath = (assetsDir as NSString).appendingPathComponent(filename)

        // Copy image to assets
        do {
            try fileSystem.copyItem(atPath: tempPath, toPath: destPath)
            shadeLogger.info("ImageCapture: copied to assets: \(filename)")
        } catch {
            shadeLogger.error("ImageCapture: failed to copy image: \(error)")
            return .failure(.copyFailed(tempPath, destPath))
        }

        return .success(filename)
    }

    /// Generate a timestamped filename for the image
    /// Format: YYYYMMDD-HHMMSS.png (matches zettel style)
    public func generateTimestampFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: dateProvider())).png"
    }

    /// Check if a path is safe to delete (in allowed temp directories)
    public func isSafeToDelete(_ path: String) -> Bool {
        let homeDir = NSHomeDirectory()
        let normalizedPath = path.hasPrefix("~")
            ? (path as NSString).expandingTildeInPath
            : path

        for prefix in Self.allowedTempPrefixes {
            // Check both absolute and relative to home
            if normalizedPath.contains(prefix) {
                return true
            }
            let absolutePrefix = homeDir + prefix
            if normalizedPath.hasPrefix(absolutePrefix) {
                return true
            }
        }

        // Also allow NSTemporaryDirectory
        if normalizedPath.hasPrefix(NSTemporaryDirectory()) {
            return true
        }

        return false
    }

    /// Delete a temp file (only from allowed locations)
    /// - Returns: Result indicating success or error
    public func deleteTempFile(_ path: String) -> Result<Void, ImageCaptureError> {
        guard isSafeToDelete(path) else {
            shadeLogger.warn("ImageCapture: refusing to delete file outside temp dirs: \(path)")
            return .failure(.deletionDenied(path))
        }

        do {
            try fileSystem.removeItem(atPath: path)
            shadeLogger.debug("ImageCapture: deleted temp file: \(path)")
            return .success(())
        } catch {
            shadeLogger.warn("ImageCapture: failed to delete temp file: \(error)")
            // Return success anyway - deletion failure is non-fatal
            return .success(())
        }
    }

    // MARK: - Private Helpers

    private func ensureDirectory(_ path: String) throws {
        var isDir = false
        if fileSystem.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir {
                return // Already exists and is a directory
            }
            throw ImageCaptureError.pathExistsButIsFile(path)
        }
        try fileSystem.createDirectory(atPath: path)
        shadeLogger.debug("ImageCapture: created directory: \(path)")
    }
}
