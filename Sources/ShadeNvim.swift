import Foundation
import MsgpackRpc
@preconcurrency import MessagePack

/// Manages the nvim connection lifecycle and provides high-level note operations.
///
/// This replaces the shell-out approach in `NvimRPC` with native msgpack-rpc.
///
/// ## Usage
///
/// ```swift
/// let nvim = ShadeNvim.shared
///
/// // Connect when nvim starts (called after terminal surface is created)
/// await nvim.connect()
///
/// // Execute note commands
/// try await nvim.openDailyNote()
/// try await nvim.openNewCapture(context: ctx)
///
/// // Disconnect when done
/// await nvim.disconnect()
/// ```
actor ShadeNvim {
    
    // MARK: - Singleton
    
    /// Shared instance for app-wide access
    static let shared = ShadeNvim()
    
    // MARK: - Types
    
    /// Errors specific to ShadeNvim operations
    enum ShadeNvimError: Error, LocalizedError {
        case notConnected
        case connectionFailed(String)
        case commandFailed(String)
        case timeout
        
        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to nvim"
            case .connectionFailed(let msg):
                return "Connection failed: \(msg)"
            case .commandFailed(let msg):
                return "Command failed: \(msg)"
            case .timeout:
                return "Operation timed out"
            }
        }
    }
    
    /// Connection state for external observation
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    // MARK: - Properties
    
    /// The underlying socket manager
    private var socket: NvimSocketManager?
    
    /// The high-level API wrapper
    private var api: NvimAPI?
    
    /// Current connection state
    private(set) var state: ConnectionState = .disconnected
    
    /// Socket path
    private let socketPath: String
    
    /// Connection retry configuration
    private let maxRetries = 10
    private let retryDelay: UInt64 = 200_000_000 // 200ms in nanoseconds
    
    /// Whether we were intentionally disconnected (vs nvim crash)
    private var intentionalDisconnect = false
    
    // MARK: - Initialization
    
    private init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? StateDirectory.nvimSocketPath
    }
    
    // MARK: - Connection Management
    
    /// Check if connected to nvim
    var isConnected: Bool {
        state == .connected
    }
    
    /// Connect to the nvim socket.
    ///
    /// This will retry connection multiple times since nvim may still be starting up.
    /// Call this after the terminal surface is created.
    ///
    /// - Parameter timeout: Maximum time to wait for connection (default 5 seconds)
    /// - Throws: ShadeNvimError if connection fails after all retries
    func connect(timeout: TimeInterval = 5.0) async throws {
        guard state != .connected else {
            Log.debug("ShadeNvim: Already connected")
            return
        }
        
        state = .connecting
        Log.debug("ShadeNvim: Connecting to \(socketPath)")
        
        let socket = NvimSocketManager(socketPath: socketPath)
        self.socket = socket
        
        // Retry connection since nvim may still be starting
        var lastError: Error?
        let startTime = Date()
        
        for attempt in 1...maxRetries {
            // Check timeout
            if Date().timeIntervalSince(startTime) > timeout {
                break
            }
            
            do {
                try await socket.connect()
                
                // Set up disconnect handler for crash detection
                await socket.setOnDisconnect { [weak self] in
                    Task { await self?.handleUnexpectedDisconnect() }
                }
                
                // Success - create API wrapper
                self.api = NvimAPI(socket: socket)
                state = .connected
                intentionalDisconnect = false
                Log.info("ShadeNvim: Connected on attempt \(attempt)")
                return
                
            } catch {
                lastError = error
                Log.debug("ShadeNvim: Connection attempt \(attempt) failed: \(error.localizedDescription)")
                
                // Wait before retry (unless last attempt)
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: retryDelay)
                }
            }
        }
        
        // All retries exhausted
        let errorMsg = lastError?.localizedDescription ?? "timeout"
        state = .error(errorMsg)
        throw ShadeNvimError.connectionFailed(errorMsg)
    }
    
    /// Disconnect from nvim
    func disconnect() async {
        guard let socket = socket else { return }
        
        Log.debug("ShadeNvim: Disconnecting (intentional)")
        intentionalDisconnect = true
        await socket.disconnect()
        
        self.socket = nil
        self.api = nil
        state = .disconnected
    }
    
    /// Handle unexpected disconnection (nvim crash, socket closed)
    private func handleUnexpectedDisconnect() {
        guard !intentionalDisconnect else { return }
        
        Log.warn("ShadeNvim: Unexpected disconnection detected (nvim may have crashed)")
        
        // Clean up state
        self.socket = nil
        self.api = nil
        state = .disconnected
        
        // Note: We don't auto-reconnect here because nvim may not be running.
        // The next operation via connectAndPerform() will attempt to reconnect.
    }
    
    /// Force reset connection state (for recovery after errors)
    func reset() async {
        Log.debug("ShadeNvim: Resetting connection state")
        
        if let socket = socket {
            intentionalDisconnect = true
            await socket.disconnect()
        }
        
        self.socket = nil
        self.api = nil
        state = .disconnected
        intentionalDisconnect = false
    }
    
    /// Wait for connection to be established (with timeout)
    ///
    /// Use this when you need to ensure connection before executing commands.
    /// Unlike `connect()`, this doesn't initiate connection - just waits for it.
    ///
    /// - Parameter timeout: Maximum time to wait
    /// - Throws: ShadeNvimError.timeout if not connected within timeout
    func waitForConnection(timeout: TimeInterval = 5.0) async throws {
        let startTime = Date()
        
        while !isConnected {
            if Date().timeIntervalSince(startTime) > timeout {
                throw ShadeNvimError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    // MARK: - Note Operations
    
    /// Open today's daily note using ObsidianToday command
    ///
    /// - Returns: Path to the daily note (computed, not from nvim)
    /// - Throws: ShadeNvimError if not connected or command fails
    @discardableResult
    func openDailyNote() async throws -> String {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        Log.debug("ShadeNvim: Opening daily note")
        
        // Compute expected path (same logic as NvimRPC)
        let baseDir = ProcessInfo.processInfo.environment["NOTES_HOME"]
            ?? "\(NSHomeDirectory())/notes"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: Date())
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: Date())
        let filepath = "\(baseDir)/daily/\(year)/\(dateStr).md"
        
        // Execute ObsidianToday command
        do {
            try await api.command("ObsidianToday")
            Log.info("ShadeNvim: Opened daily note at \(filepath)")
            return filepath
        } catch let error as NvimAPI.APIError {
            // If ObsidianToday fails, fall back to direct file open
            Log.warn("ShadeNvim: ObsidianToday failed, falling back to direct open: \(error)")
            try await api.command("edit \(escapeVimPath(filepath))")
            return filepath
        }
    }
    
    /// Open a new capture note
    ///
    /// - Parameter context: Optional capture context (for future use with templates)
    /// - Returns: Path to the created capture file
    /// - Throws: ShadeNvimError if not connected or command fails
    @discardableResult
    func openNewCapture(context: CaptureContext? = nil) async throws -> String {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        Log.debug("ShadeNvim: Opening new capture")
        
        // Compute capture path (same logic as NvimRPC)
        let baseDir = ProcessInfo.processInfo.environment["NOTES_HOME"]
            ?? "\(NSHomeDirectory())/notes"
        let capturesDir = "\(baseDir)/captures"
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let timestamp = formatter.string(from: Date())
        let filename = "\(timestamp)-capture.md"
        let filepath = "\(capturesDir)/\(filename)"
        
        // Log context if provided
        if let ctx = context {
            Log.debug("ShadeNvim: Capture context - app: \(ctx.appName ?? "unknown"), type: \(ctx.appType ?? "unknown")")
        }
        
        // Open the file (nvim will create it on first save)
        do {
            try await api.command("edit \(escapeVimPath(filepath))")
            Log.info("ShadeNvim: Opened capture at \(filepath)")
            return filepath
        } catch let error as NvimAPI.APIError {
            throw ShadeNvimError.commandFailed(error.localizedDescription)
        }
    }
    
    // MARK: - General Commands
    
    /// Execute an Ex command in nvim
    ///
    /// - Parameter command: The command to execute (without leading colon)
    /// - Throws: ShadeNvimError if not connected or command fails
    func command(_ command: String) async throws {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        Log.debug("ShadeNvim: Executing command '\(command)'")
        
        do {
            try await api.command(command)
        } catch let error as NvimAPI.APIError {
            throw ShadeNvimError.commandFailed(error.localizedDescription)
        }
    }
    
    /// Evaluate a vimscript expression
    ///
    /// - Parameter expr: The expression to evaluate
    /// - Returns: Result as MessagePackValue
    /// - Throws: ShadeNvimError if not connected or evaluation fails
    func eval(_ expr: String) async throws -> MessagePackValue {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        return try await api.eval(expr)
    }
    
    /// Open a file in nvim
    ///
    /// - Parameter path: Path to the file
    /// - Throws: ShadeNvimError if not connected or command fails
    func openFile(_ path: String) async throws {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        Log.debug("ShadeNvim: Opening file '\(path)'")
        try await api.command("edit \(escapeVimPath(path))")
    }
    
    /// Get current buffer file path
    ///
    /// - Returns: Current file path, or empty string for unnamed buffer
    /// - Throws: ShadeNvimError if not connected
    func getCurrentFile() async throws -> String {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        return try await api.getCurrentFilePath()
    }
    
    /// Check if current buffer has unsaved changes
    ///
    /// - Returns: True if buffer is modified
    /// - Throws: ShadeNvimError if not connected
    func hasUnsavedChanges() async throws -> Bool {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        let buf = try await api.getCurrentBuffer()
        return try await api.isBufferModified(buf)
    }
    
    /// Save current buffer
    ///
    /// - Throws: ShadeNvimError if not connected or save fails
    func saveBuffer() async throws {
        try await command("write")
    }
    
    // MARK: - Private Helpers
    
    /// Escape a file path for use in vim commands
    private func escapeVimPath(_ path: String) -> String {
        // Escape spaces and special characters for vim command line
        return path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

// MARK: - Convenience for Non-Async Contexts

extension ShadeNvim {
    
    /// Execute a note operation from a non-async context (e.g., notification handlers)
    ///
    /// This handles the async bridging and error logging for you.
    ///
    /// - Parameters:
    ///   - operation: The async operation to perform
    ///   - onSuccess: Called on success with the result
    ///   - onError: Called on error with the error message
    nonisolated func perform<T: Sendable>(
        _ operation: @escaping @Sendable (isolated ShadeNvim) async throws -> T,
        onSuccess: (@Sendable (T) -> Void)? = nil,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        Task {
            do {
                let result = try await operation(self)
                if let onSuccess = onSuccess {
                    await MainActor.run { onSuccess(result) }
                }
            } catch {
                Log.error("ShadeNvim: Operation failed: \(error.localizedDescription)")
                if let onError = onError {
                    await MainActor.run { onError(error.localizedDescription) }
                }
            }
        }
    }
    
    /// Connect and execute an operation, with automatic retry
    ///
    /// Use this for operations that should auto-connect if not already connected.
    ///
    /// - Parameters:
    ///   - operation: The async operation to perform after connecting
    ///   - onSuccess: Called on success
    ///   - onError: Called on error
    nonisolated func connectAndPerform<T: Sendable>(
        _ operation: @escaping @Sendable (isolated ShadeNvim) async throws -> T,
        onSuccess: (@Sendable (T) -> Void)? = nil,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        Task {
            do {
                // Connect if needed
                if await !self.isConnected {
                    try await self.connect()
                }
                
                let result = try await operation(self)
                if let onSuccess = onSuccess {
                    await MainActor.run { onSuccess(result) }
                }
            } catch {
                Log.error("ShadeNvim: Connect and perform failed: \(error.localizedDescription)")
                if let onError = onError {
                    await MainActor.run { onError(error.localizedDescription) }
                }
            }
        }
    }
}
