import Foundation

/// Handles image capture operations: copying to vault assets, cleanup
/// Centralizes image file management so Shade owns the entire image lifecycle
enum ImageCaptureHandler {

    // MARK: - Public API

    /// Process an image capture from a temp file path
    /// - Parameter tempPath: Path to temporary image file (from Hammerspoon clipper)
    /// - Returns: Result with asset filename on success, or error on failure
    static func processCapture(tempPath: String) -> Result<String, ImageCaptureError> {
        // Validate temp file exists
        guard FileManager.default.fileExists(atPath: tempPath) else {
            Log.error("ImageCapture: temp file not found: \(tempPath)")
            return .failure(.tempFileNotFound(tempPath))
        }

        // Get notes config (or use defaults)
        let notesConfig = ShadeConfig.shared.notes ?? NotesConfig()
        let assetsDir = notesConfig.resolvedAssetsDir()

        // Ensure assets directory exists
        do {
            try ensureDirectory(assetsDir)
        } catch {
            Log.error("ImageCapture: failed to create assets dir: \(error)")
            return .failure(.assetsDirectoryCreationFailed(assetsDir, error))
        }

        // Generate timestamped filename
        let filename = generateTimestampFilename()
        let destPath = (assetsDir as NSString).appendingPathComponent(filename)

        // Copy image to assets
        do {
            try FileManager.default.copyItem(atPath: tempPath, toPath: destPath)
            Log.info("ImageCapture: copied to assets: \(filename)")
        } catch {
            Log.error("ImageCapture: failed to copy image: \(error)")
            return .failure(.copyFailed(tempPath, destPath, error))
        }

        // Delete temp file (best effort, don't fail if cleanup fails)
        deleteTempFile(tempPath)

        return .success(filename)
    }

    /// Generate a timestamped filename for the image
    /// Format: YYYYMMDD-HHMMSS.png (matches zettel style)
    static func generateTimestampFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date())).png"
    }

    /// Delete a temp file (best effort, logs but doesn't throw)
    static func deleteTempFile(_ path: String) {
        // Safety check: only delete from known temp locations
        let allowedPrefixes = [
            NSHomeDirectory() + "/_screenshots/",
            "/tmp/",
            NSTemporaryDirectory()
        ]

        let isAllowed = allowedPrefixes.contains { path.hasPrefix($0) }
        guard isAllowed else {
            Log.warn("ImageCapture: refusing to delete file outside temp dirs: \(path)")
            return
        }

        do {
            try FileManager.default.removeItem(atPath: path)
            Log.debug("ImageCapture: deleted temp file: \(path)")
        } catch {
            Log.warn("ImageCapture: failed to delete temp file: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// Ensure a directory exists, creating it if necessary
    private static func ensureDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                return // Already exists and is a directory
            }
            throw ImageCaptureError.pathExistsButIsFile(path)
        }
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        Log.debug("ImageCapture: created directory: \(path)")
    }
}

// MARK: - Errors

enum ImageCaptureError: Error, LocalizedError {
    case tempFileNotFound(String)
    case assetsDirectoryCreationFailed(String, Error)
    case pathExistsButIsFile(String)
    case copyFailed(String, String, Error)

    var errorDescription: String? {
        switch self {
        case .tempFileNotFound(let path):
            return "Temporary image file not found: \(path)"
        case .assetsDirectoryCreationFailed(let path, let underlying):
            return "Failed to create assets directory '\(path)': \(underlying.localizedDescription)"
        case .pathExistsButIsFile(let path):
            return "Path exists but is a file, not a directory: \(path)"
        case .copyFailed(let src, let dest, let underlying):
            return "Failed to copy '\(src)' to '\(dest)': \(underlying.localizedDescription)"
        }
    }
}
