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
    
    /// Event routing system
    private let events = NvimEvents()
    
    /// Task for processing incoming messages
    private var messageProcessingTask: Task<Void, Never>?
    
    /// Current connection state
    private(set) var state: ConnectionState = .disconnected
    
    /// Socket path
    private let socketPath: String

    // MARK: - Context Gathering Types

    /// Context gathered from nvim for capture notes
    public struct NvimContext: Sendable {
        /// Full path to the current file
        public let filePath: String?

        /// Just the filename (without path)
        public let fileName: String?

        /// Detected filetype (from treesitter/vim)
        public let filetype: String?

        /// Whether buffer has unsaved changes
        public let modified: Bool

        /// Current line number (1-indexed)
        public let line: Int

        /// Current column number (1-indexed)
        public let col: Int

        /// Visual selection text (if in/just exited visual mode)
        public let selection: String?

        /// Whether any meaningful context was captured
        public var hasContent: Bool {
            filePath != nil || selection != nil
        }
    }
    
    /// Connection retry configuration
    private let maxRetries = 10
    private let retryDelay: UInt64 = 200_000_000 // 200ms in nanoseconds
    
    /// Whether we were intentionally disconnected (vs nvim crash)
    private var intentionalDisconnect = false
    
    /// Set of attached buffer IDs (for cleanup on disconnect)
    private var attachedBuffers: Set<Int64> = []
    
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
                
                // Success - create API wrapper and start message processing
                self.api = NvimAPI(socket: socket)
                state = .connected
                intentionalDisconnect = false
                
                // Start processing incoming messages (notifications, requests)
                startMessageProcessing(socket: socket)
                
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
        
        // Stop message processing
        messageProcessingTask?.cancel()
        messageProcessingTask = nil
        
        // Clear event subscriptions
        await events.unsubscribeAll()
        attachedBuffers.removeAll()
        
        await socket.disconnect()
        
        self.socket = nil
        self.api = nil
        state = .disconnected
    }
    
    /// Handle unexpected disconnection (nvim crash, socket closed)
    private func handleUnexpectedDisconnect() {
        guard !intentionalDisconnect else { return }
        
        Log.warn("ShadeNvim: Unexpected disconnection detected (nvim may have crashed)")
        
        // Stop message processing
        messageProcessingTask?.cancel()
        messageProcessingTask = nil
        
        // Clear attached buffers (they're gone with nvim)
        attachedBuffers.removeAll()
        
        // Clean up state
        self.socket = nil
        self.api = nil
        state = .disconnected
        
        // Note: We don't auto-reconnect here because nvim may not be running.
        // The next operation via connectAndPerform() will attempt to reconnect.
        // Event subscriptions are kept - they'll work again after reconnect.
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
    
    /// Open a new text capture note
    ///
    /// Uses obsidian.nvim template which reads context.json for substitution
    /// (title, source URL, selection, etc.)
    ///
    /// - Parameter context: Capture context (already written to context.json by caller)
    /// - Returns: Description of the created capture
    /// - Throws: ShadeNvimError if not connected or command fails
    @discardableResult
    func openNewCapture(context: CaptureContext? = nil) async throws -> String {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        Log.debug("ShadeNvim: Opening new text capture")
        
        // Log context if provided
        if let ctx = context {
            Log.debug("ShadeNvim: Capture context - app: \(ctx.appName ?? "unknown"), type: \(ctx.appType ?? "unknown")")
        }
        
        // Use obsidian.nvim to create note from capture-text template
        // The template reads context.json (written by ContextGatherer before this call)
        do {
            try await api.command("Obsidian new_from_template capture capture-text")
            Log.info("ShadeNvim: Created text capture via obsidian.nvim")
            return "text capture created"
        } catch let error as NvimAPI.APIError {
            throw ShadeNvimError.commandFailed(error.localizedDescription)
        }
    }
    
    /// Open an image capture note (from clipper)
    ///
    /// Uses obsidian.nvim template with imageFilename from context
    ///
    /// - Parameter context: Capture context with imageFilename
    /// - Returns: Description of the created capture
    /// - Throws: ShadeNvimError if not connected or command fails
    @discardableResult
    func openImageCapture(context: CaptureContext? = nil) async throws -> String {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }

        Log.debug("ShadeNvim: Opening image capture")

        // Log context if provided
        if let ctx = context {
            Log.debug("ShadeNvim: Image capture context - imageFilename: \(ctx.imageFilename ?? "nil")")
        }

        // Use obsidian.nvim to create note from capture-image template
        // The template reads context.json (which clipper.lua writes with imageFilename)
        do {
            try await api.command("Obsidian new_from_template capture capture-image")
            Log.info("ShadeNvim: Created image capture via obsidian.nvim")
            return "image capture created"
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

    // MARK: - Context Gathering

    /// Gather context from the current nvim buffer for capture notes
    ///
    /// This collects file path, filetype, cursor position, and visual selection.
    /// Used by ContextGatherer when the frontmost app is a terminal running nvim.
    ///
    /// - Returns: NvimContext with gathered information
    /// - Throws: ShadeNvimError if not connected
    func getContext() async throws -> NvimContext {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }

        Log.debug("ShadeNvim: Gathering context")

        // Get current buffer and window
        let buffer = try await api.getCurrentBuffer()
        let window = try await api.getCurrentWindow()

        // Get file path
        let filePath = try await api.getBufferName(buffer)
        let hasPath = !filePath.isEmpty

        // Get filename (just the name, not the path)
        let fileName: String?
        if hasPath {
            fileName = try? await api.evalString("expand('%:t')")
        } else {
            fileName = nil
        }

        // Get filetype
        let filetype = try await api.getBufferFiletype(buffer)

        // Get modified status
        let modified = try await api.isBufferModified(buffer)

        // Get cursor position (nvim returns 1-indexed row, 0-indexed col)
        let cursor = try await api.getWindowCursor(window)
        let line = cursor.row  // Already 1-indexed
        let col = cursor.col + 1  // Convert to 1-indexed

        // Try to get visual selection
        let selection = try? await getVisualSelection(api: api, buffer: buffer)

        let context = NvimContext(
            filePath: hasPath ? filePath : nil,
            fileName: fileName,
            filetype: filetype.isEmpty ? nil : filetype,
            modified: modified,
            line: line,
            col: col,
            selection: selection
        )

        Log.debug("ShadeNvim: Context gathered - file: \(context.filePath ?? "none"), ft: \(context.filetype ?? "none"), sel: \(context.selection != nil)")

        return context
    }

    /// Get visual selection text from nvim
    ///
    /// This uses the '< and '> marks which are set when exiting visual mode.
    /// Only works if user was recently in visual mode.
    ///
    /// - Parameters:
    ///   - api: The NvimAPI instance
    ///   - buffer: The current buffer
    /// - Returns: Selected text or nil if no selection
    private func getVisualSelection(api: NvimAPI, buffer: NvimAPI.Buffer) async throws -> String? {
        // Execute Lua to get visual selection using '< and '> marks
        // This is more reliable than using getpos() from vimscript
        let luaCode = """
            local start_pos = vim.api.nvim_buf_get_mark(0, '<')
            local end_pos = vim.api.nvim_buf_get_mark(0, '>')

            -- Marks are (row, col), 1-indexed row, 0-indexed col
            local start_row, start_col = start_pos[1], start_pos[2]
            local end_row, end_col = end_pos[1], end_pos[2]

            -- If marks are invalid (0,0), no selection
            if start_row == 0 and start_col == 0 then
                return nil
            end

            -- Get the lines in the selection range
            local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)

            if #lines == 0 then
                return nil
            end

            -- Adjust for partial line selection
            if #lines == 1 then
                -- Single line selection
                lines[1] = string.sub(lines[1], start_col + 1, end_col + 1)
            else
                -- Multi-line selection
                lines[1] = string.sub(lines[1], start_col + 1)
                lines[#lines] = string.sub(lines[#lines], 1, end_col + 1)
            end

            return table.concat(lines, '\\n')
            """

        let result = try await api.execLua(luaCode)

        // Result is nil or string
        if result.isNil {
            return nil
        }

        guard let selection = result.stringValue, !selection.isEmpty else {
            return nil
        }

        return selection
    }
    
    // MARK: - Message Processing
    
    /// Start the background task that processes incoming messages from nvim
    private func startMessageProcessing(socket: NvimSocketManager) {
        messageProcessingTask = Task { [weak self] in
            Log.debug("ShadeNvim: Starting message processing loop")
            
            for await message in socket.messageStream {
                guard let self = self else { break }
                guard !Task.isCancelled else { break }
                
                await self.events.process(message)
            }
            
            Log.debug("ShadeNvim: Message processing loop ended")
        }
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

// MARK: - Buffer Change Notifications

extension ShadeNvim {
    
    /// Attach to current buffer for change notifications
    ///
    /// After attaching, you'll receive notifications when the buffer content changes.
    /// Use `onBufferLines`, `onBufferChangedTick`, or `onBufferDetach` to subscribe.
    ///
    /// - Parameter sendBuffer: If true, sends full buffer content on first event
    /// - Returns: Buffer ID that was attached
    /// - Throws: ShadeNvimError if not connected or attach fails
    @discardableResult
    func attachCurrentBuffer(sendBuffer: Bool = false) async throws -> Int64 {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        let buffer = try await api.getCurrentBuffer()
        let success = try await api.attachBuffer(buffer, sendBuffer: sendBuffer)
        
        if success {
            attachedBuffers.insert(buffer.id)
            Log.info("ShadeNvim: Attached to buffer \(buffer.id)")
        } else {
            Log.warn("ShadeNvim: Failed to attach to buffer \(buffer.id)")
        }
        
        return buffer.id
    }
    
    /// Attach to a specific buffer for change notifications
    ///
    /// - Parameters:
    ///   - bufferId: The buffer ID to attach to
    ///   - sendBuffer: If true, sends full buffer content on first event
    /// - Returns: True if attach succeeded
    /// - Throws: ShadeNvimError if not connected
    @discardableResult
    func attachBuffer(_ bufferId: Int64, sendBuffer: Bool = false) async throws -> Bool {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        let buffer = NvimAPI.Buffer(bufferId)
        let success = try await api.attachBuffer(buffer, sendBuffer: sendBuffer)
        
        if success {
            attachedBuffers.insert(bufferId)
            Log.info("ShadeNvim: Attached to buffer \(bufferId)")
        }
        
        return success
    }
    
    /// Detach from a buffer (stop receiving notifications)
    ///
    /// - Parameter bufferId: The buffer ID to detach from
    /// - Returns: True if detach succeeded
    /// - Throws: ShadeNvimError if not connected
    @discardableResult
    func detachBuffer(_ bufferId: Int64) async throws -> Bool {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        let buffer = NvimAPI.Buffer(bufferId)
        let success = try await api.detachBuffer(buffer)
        
        if success {
            attachedBuffers.remove(bufferId)
            Log.info("ShadeNvim: Detached from buffer \(bufferId)")
        }
        
        return success
    }
    
    /// Detach from all attached buffers
    func detachAllBuffers() async throws {
        guard let api = api, isConnected else {
            throw ShadeNvimError.notConnected
        }
        
        for bufferId in attachedBuffers {
            let buffer = NvimAPI.Buffer(bufferId)
            _ = try? await api.detachBuffer(buffer)
        }
        
        let count = attachedBuffers.count
        attachedBuffers.removeAll()
        Log.info("ShadeNvim: Detached from \(count) buffer(s)")
    }
    
    /// Get the set of currently attached buffer IDs
    var attachedBufferIds: Set<Int64> {
        attachedBuffers
    }
    
    // MARK: - Event Subscriptions
    
    /// Subscribe to buffer line change events
    ///
    /// Called when lines in an attached buffer change.
    ///
    /// - Parameter handler: Callback with parsed event data
    /// - Returns: Subscription ID for later unsubscription
    func onBufferLines(
        handler: @escaping @Sendable (NvimEvents.BufferLinesEvent) -> Void
    ) async -> NvimEvents.SubscriptionID {
        return await events.subscribeToBufferLines(handler: handler)
    }
    
    /// Subscribe to buffer changedtick events
    ///
    /// Called when buffer changedtick updates (may not include line changes).
    ///
    /// - Parameter handler: Callback with parsed event data
    /// - Returns: Subscription ID for later unsubscription
    func onBufferChangedTick(
        handler: @escaping @Sendable (NvimEvents.BufferChangedTickEvent) -> Void
    ) async -> NvimEvents.SubscriptionID {
        return await events.subscribeToBufferChangedTick(handler: handler)
    }
    
    /// Subscribe to buffer detach events
    ///
    /// Called when nvim detaches from a buffer (e.g., buffer deleted).
    ///
    /// - Parameter handler: Callback with parsed event data
    /// - Returns: Subscription ID for later unsubscription
    func onBufferDetach(
        handler: @escaping @Sendable (NvimEvents.BufferDetachEvent) -> Void
    ) async -> NvimEvents.SubscriptionID {
        return await events.subscribeToBufferDetach(handler: handler)
    }
    
    /// Subscribe to any nvim notification event by name
    ///
    /// - Parameters:
    ///   - eventName: The event name (e.g., "nvim_buf_lines_event")
    ///   - handler: Callback with raw event parameters
    /// - Returns: Subscription ID for later unsubscription
    func onEvent(
        _ eventName: String,
        handler: @escaping @Sendable ([MessagePackValue]) -> Void
    ) async -> NvimEvents.SubscriptionID {
        return await events.subscribe(to: eventName, handler: handler)
    }
    
    /// Unsubscribe from an event
    ///
    /// - Parameter subscriptionId: The subscription ID from onBufferLines, etc.
    func unsubscribe(_ subscriptionId: NvimEvents.SubscriptionID) async {
        await events.unsubscribe(subscriptionId)
    }
    
    /// Enable/disable event logging for debugging
    func setEventLogging(_ enabled: Bool) async {
        await events.setLoggingEnabled(enabled)
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
