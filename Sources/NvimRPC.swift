import Foundation

/// Simple nvim RPC client using `nvim --server --remote-send`
/// This is Option A: shell out to nvim for commands
/// Future: Option B would be native msgpack-rpc over Unix socket
enum NvimRPC {

    // MARK: - Configuration

    /// Default socket path (XDG state directory)
    static var socketPath: String {
        return StateDirectory.nvimSocketPath
    }

    // MARK: - Connection Check

    /// Check if nvim server is running at the socket path
    static func isServerRunning(socket: String? = nil) -> Bool {
        let sock = socket ?? socketPath
        let fileManager = FileManager.default

        // Check if socket file exists
        guard fileManager.fileExists(atPath: sock) else {
            return false
        }

        // Try to send a no-op command to verify connection
        // Using --remote-expr with a simple expression
        let result = runNvimCommand(
            socket: sock,
            args: ["--remote-expr", "1"]
        )

        return result.success
    }

    // MARK: - Commands

    /// Send keys to nvim (like typing)
    /// - Parameters:
    ///   - keys: Key sequence (e.g., "<Esc>:edit file.md<CR>")
    ///   - socket: Optional socket path override
    /// - Returns: Success status
    @discardableResult
    static func sendKeys(_ keys: String, socket: String? = nil) -> Bool {
        let sock = socket ?? socketPath
        Log.debug("NvimRPC: sendKeys '\(keys)' to \(sock)")

        let result = runNvimCommand(
            socket: sock,
            args: ["--remote-send", keys]
        )

        if !result.success {
            Log.error("NvimRPC: sendKeys failed: \(result.error ?? "unknown")")
        }

        return result.success
    }

    /// Open a file in nvim
    /// - Parameters:
    ///   - path: File path to open
    ///   - socket: Optional socket path override
    /// - Returns: Success status
    @discardableResult
    static func openFile(_ path: String, socket: String? = nil) -> Bool {
        // Escape to normal mode, then edit the file
        let escapedPath = path.replacingOccurrences(of: " ", with: "\\ ")
        let keys = "<C-\\><C-n>:edit \(escapedPath)<CR>"
        return sendKeys(keys, socket: socket)
    }

    /// Execute a vim command
    /// - Parameters:
    ///   - command: Vim command without leading colon (e.g., "ObsidianToday")
    ///   - socket: Optional socket path override
    /// - Returns: Success status
    @discardableResult
    static func executeCommand(_ command: String, socket: String? = nil) -> Bool {
        // Escape to normal mode, then run command
        let keys = "<C-\\><C-n>:\(command)<CR>"
        return sendKeys(keys, socket: socket)
    }

    /// Evaluate a vim expression and return result
    /// - Parameters:
    ///   - expr: Vim expression (e.g., "expand('%')")
    ///   - socket: Optional socket path override
    /// - Returns: Result string or nil on failure
    static func evaluate(_ expr: String, socket: String? = nil) -> String? {
        let sock = socket ?? socketPath
        Log.debug("NvimRPC: evaluate '\(expr)'")

        let result = runNvimCommand(
            socket: sock,
            args: ["--remote-expr", expr]
        )

        if result.success {
            return result.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            Log.error("NvimRPC: evaluate failed: \(result.error ?? "unknown")")
            return nil
        }
    }

    /// Get current buffer file path
    static func getCurrentFile(socket: String? = nil) -> String? {
        return evaluate("expand('%:p')", socket: socket)
    }

    /// Check if current buffer has unsaved changes
    static func hasUnsavedChanges(socket: String? = nil) -> Bool {
        let result = evaluate("&modified", socket: socket)
        return result == "1"
    }

    /// Save current buffer
    @discardableResult
    static func saveBuffer(socket: String? = nil) -> Bool {
        return executeCommand("write", socket: socket)
    }

    // MARK: - Private Helpers

    private struct CommandResult {
        var success: Bool
        var output: String?
        var error: String?
    }

    private static func runNvimCommand(socket: String, args: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["nvim", "--server", socket] + args
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8)
            let error = String(data: errorData, encoding: .utf8)

            let success = process.terminationStatus == 0

            return CommandResult(
                success: success,
                output: output,
                error: error
            )
        } catch {
            return CommandResult(
                success: false,
                output: nil,
                error: error.localizedDescription
            )
        }
    }
}

// MARK: - Note-Specific Commands

extension NvimRPC {

    /// Open a new capture note file
    /// Creates file with timestamp-based name in captures directory
    /// - Parameters:
    ///   - context: Optional capture context for frontmatter
    ///   - notesDir: Base notes directory (defaults to $NOTES_HOME or ~/notes)
    /// - Returns: Path to the created file, or nil on failure
    static func openNewCapture(context: CaptureContext? = nil, notesDir: String? = nil) -> String? {
        let baseDir = notesDir ?? ProcessInfo.processInfo.environment["NOTES_HOME"] ?? "\(NSHomeDirectory())/notes"
        let capturesDir = "\(baseDir)/captures"

        // Generate filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)-capture.md"
        let filepath = "\(capturesDir)/\(filename)"

        Log.debug("NvimRPC: Opening new capture at \(filepath)")

        // Use ObsidianNew if available, otherwise just open the file
        // The file will be created by nvim on first save
        if openFile(filepath) {
            return filepath
        }
        return nil
    }

    /// Open today's daily note
    /// Uses ObsidianToday command if available, otherwise computes path
    /// - Parameter notesDir: Base notes directory
    /// - Returns: Path to the daily note, or nil on failure
    static func openDailyNote(notesDir: String? = nil) -> String? {
        let baseDir = notesDir ?? ProcessInfo.processInfo.environment["NOTES_HOME"] ?? "\(NSHomeDirectory())/notes"

        // Compute daily note path: daily/YYYY/YYYYMMDD.md
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: Date())
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: Date())

        let filepath = "\(baseDir)/daily/\(year)/\(dateStr).md"

        Log.debug("NvimRPC: Opening daily note at \(filepath)")

        // Try ObsidianToday first (handles template creation)
        // Fall back to direct file open if that fails
        if executeCommand("ObsidianToday") {
            return filepath
        }

        // Fallback: just open the file directly
        if openFile(filepath) {
            return filepath
        }

        return nil
    }
}
