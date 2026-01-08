import Foundation
import ContextGatherer

/// Manages XDG-compliant state directories for shade
/// Uses ~/.local/state/shade/ for runtime state files
enum StateDirectory {

    // MARK: - Paths

    /// Base state directory: ~/.local/state/shade/
    static var baseDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/state/shade")
    }

    /// Context file for capture context from Hammerspoon
    static var contextFile: URL {
        return baseDir.appendingPathComponent("context.json")
    }

    /// Nvim socket path for RPC communication
    static var nvimSocket: URL {
        return baseDir.appendingPathComponent("nvim.sock")
    }

    /// Nvim socket path as string (for command line)
    static var nvimSocketPath: String {
        return nvimSocket.path
    }

    /// PID file for process management
    static var pidFile: URL {
        return baseDir.appendingPathComponent("shade.pid")
    }

    // MARK: - Directory Management

    /// Ensure the state directory exists
    /// Call this at app launch
    static func ensureDirectoryExists() {
        let fileManager = FileManager.default
        let path = baseDir.path

        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(
                    at: baseDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                Log.debug("Created state directory: \(path)")
            } catch {
                Log.error("Failed to create state directory: \(error)")
            }
        }
    }

    /// Write PID file on launch
    static func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidString = String(pid)

        do {
            try pidString.write(to: pidFile, atomically: true, encoding: .utf8)
            Log.debug("Wrote PID file: \(pid)")
        } catch {
            Log.error("Failed to write PID file: \(error)")
        }
    }

    /// Remove PID file on shutdown
    static func removePIDFile() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: pidFile.path) {
            do {
                try fileManager.removeItem(at: pidFile)
                Log.debug("Removed PID file")
            } catch {
                Log.error("Failed to remove PID file: \(error)")
            }
        }
    }

    /// Remove stale nvim socket if it exists
    static func cleanupNvimSocket() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: nvimSocket.path) {
            do {
                try fileManager.removeItem(at: nvimSocket)
                Log.debug("Cleaned up stale nvim socket")
            } catch {
                Log.error("Failed to remove stale nvim socket: \(error)")
            }
        }
    }

    // MARK: - Context File

    /// Read capture context from JSON file
    /// Returns nil if file doesn't exist or can't be parsed
    static func readContext() -> CaptureContext? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: contextFile.path) else {
            Log.debug("No context file found")
            return nil
        }

        do {
            let data = try Data(contentsOf: contextFile)
            let context = try JSONDecoder().decode(CaptureContext.self, from: data)
            Log.debug("Read context: \(context.appType ?? "unknown") - \(context.appName ?? "unknown")")
            return context
        } catch {
            Log.error("Failed to read context file: \(error)")
            return nil
        }
    }

    /// Delete context file after reading (one-shot)
    static func deleteContextFile() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: contextFile.path) {
            do {
                try fileManager.removeItem(at: contextFile)
                Log.debug("Deleted context file")
            } catch {
                Log.error("Failed to delete context file: \(error)")
            }
        }
    }

    /// Write gathered context to JSON file
    /// Called by Shade after gathering context natively
    /// - Parameter context: The gathered context to write
    /// - Returns: true if successful
    @discardableResult
    static func writeContext(_ context: GatheredContext) -> Bool {
        ensureDirectoryExists()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(context)
            try data.write(to: contextFile, options: .atomic)
            Log.debug("Wrote context: \(context.appType ?? "unknown") - \(context.appName ?? "unknown")")
            return true
        } catch {
            Log.error("Failed to write context file: \(error)")
            return false
        }
    }

    /// Read gathered context from JSON file (new format)
    /// Returns nil if file doesn't exist or can't be parsed
    static func readGatheredContext() -> GatheredContext? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: contextFile.path) else {
            Log.debug("No context file found")
            return nil
        }

        do {
            let data = try Data(contentsOf: contextFile)
            let context = try JSONDecoder().decode(GatheredContext.self, from: data)
            Log.debug("Read gathered context: \(context.appType ?? "unknown") - \(context.appName ?? "unknown")")
            return context
        } catch {
            Log.error("Failed to read context file: \(error)")
            return nil
        }
    }
}

// MARK: - Capture Context

/// Context passed from Hammerspoon for quick capture
struct CaptureContext: Codable {
    var appType: String?         // "browser", "terminal", "neovim", "screenshot", "other"
    var appName: String?         // "Brave Browser", etc.
    var windowTitle: String?     // Window title
    var url: String?             // URL if browser
    var filePath: String?        // File path if editor
    var selection: String?       // Selected text
    var detectedLanguage: String? // Detected language for code
    var timestamp: String?       // ISO8601 timestamp
    var imageFilename: String?   // Image filename for clipper captures (e.g., "20260108-123456.png")

    enum CodingKeys: String, CodingKey {
        case appType = "appType"
        case appName = "appName"
        case windowTitle = "windowTitle"
        case url = "url"
        case filePath = "filePath"
        case selection = "selection"
        case detectedLanguage = "detectedLanguage"
        case timestamp = "timestamp"
        case imageFilename = "imageFilename"
    }

    /// Whether this is an image capture (from clipper)
    var isImageCapture: Bool {
        imageFilename != nil
    }
}
