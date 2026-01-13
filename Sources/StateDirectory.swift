import Foundation
import ContextGatherer
import ShadeCore

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

    /// Write capture context to JSON file
    /// Used for image captures where Shade processes the image and writes final context
    /// - Parameter context: The capture context to write
    /// - Returns: true if successful
    @discardableResult
    static func writeCaptureContext(_ context: CaptureContext) -> Bool {
        ensureDirectoryExists()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(context)
            try data.write(to: contextFile, options: .atomic)
            Log.debug("Wrote capture context: imageFilename=\(context.imageFilename ?? "nil")")
            return true
        } catch {
            Log.error("Failed to write capture context: \(error)")
            return false
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
// CaptureContext is now defined in ShadeCore module
// Imported via `import ShadeCore` at top of file
