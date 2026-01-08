import Foundation
@preconcurrency import MessagePack
import MsgpackRpc

/// High-level typed wrapper around nvim's msgpack-rpc API.
///
/// Provides convenient Swift methods for common nvim operations with proper
/// type conversions and error handling.
///
/// ## Usage
///
/// ```swift
/// let socket = NvimSocketManager()
/// try await socket.connect()
///
/// let api = NvimAPI(socket: socket)
///
/// // Evaluate expression
/// let cwd = try await api.eval("getcwd()")
///
/// // Execute command
/// try await api.command("write")
///
/// // Get buffer content
/// let buf = try await api.getCurrentBuffer()
/// let lines = try await api.getBufferLines(buf)
/// ```
actor NvimAPI {
    
    // MARK: - Types
    
    /// Errors from the NvimAPI wrapper
    enum APIError: Error, LocalizedError {
        case nvimError(String)
        case unexpectedResultType(expected: String, got: String)
        case notConnected
        
        var errorDescription: String? {
            switch self {
            case .nvimError(let msg):
                return "Nvim error: \(msg)"
            case .unexpectedResultType(let expected, let got):
                return "Expected \(expected), got \(got)"
            case .notConnected:
                return "Not connected to nvim"
            }
        }
    }
    
    /// Nvim buffer handle (opaque integer ID)
    struct Buffer: Hashable, Sendable {
        let id: Int64
        
        init(_ id: Int64) { self.id = id }
        
        var messagePackValue: MessagePackValue { .int(id) }
    }
    
    /// Nvim window handle (opaque integer ID)
    struct Window: Hashable, Sendable {
        let id: Int64
        
        init(_ id: Int64) { self.id = id }
        
        var messagePackValue: MessagePackValue { .int(id) }
    }
    
    /// Nvim tabpage handle (opaque integer ID)
    struct Tabpage: Hashable, Sendable {
        let id: Int64
        
        init(_ id: Int64) { self.id = id }
        
        var messagePackValue: MessagePackValue { .int(id) }
    }
    
    // MARK: - Properties
    
    /// The underlying socket manager
    private let socket: NvimSocketManager
    
    /// Request timeout
    var timeout: TimeInterval = 5.0
    
    // MARK: - Initialization
    
    init(socket: NvimSocketManager) {
        self.socket = socket
    }
    
    // MARK: - General API
    
    /// Evaluate a vimscript expression
    /// - Parameter expr: The expression to evaluate
    /// - Returns: The result as a MessagePackValue
    func eval(_ expr: String) async throws -> MessagePackValue {
        let response = try await socket.request(
            method: "nvim_eval",
            params: [.string(expr)],
            timeout: timeout
        )
        try checkError(response)
        return response.result
    }
    
    /// Evaluate a vimscript expression and return as String
    /// - Parameter expr: The expression to evaluate
    /// - Returns: The result as a String
    func evalString(_ expr: String) async throws -> String {
        let result = try await eval(expr)
        guard let str = result.stringValue else {
            throw APIError.unexpectedResultType(expected: "String", got: describe(result))
        }
        return str
    }
    
    /// Evaluate a vimscript expression and return as Int
    /// - Parameter expr: The expression to evaluate
    /// - Returns: The result as an Int64
    func evalInt(_ expr: String) async throws -> Int64 {
        let result = try await eval(expr)
        guard let int = result.int64Value else {
            throw APIError.unexpectedResultType(expected: "Int", got: describe(result))
        }
        return int
    }
    
    /// Execute an Ex command
    /// - Parameter cmd: The command to execute (e.g., "write", "quit")
    func command(_ cmd: String) async throws {
        let response = try await socket.request(
            method: "nvim_command",
            params: [.string(cmd)],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Execute vimscript and optionally capture output
    /// - Parameters:
    ///   - src: Vimscript source code
    ///   - output: Whether to capture output
    /// - Returns: Output string if output=true, nil otherwise
    func exec(_ src: String, output: Bool = false) async throws -> String? {
        // nvim_exec2 returns a dict with "output" key if output=true
        let response = try await socket.request(
            method: "nvim_exec2",
            params: [
                .string(src),
                .map([.string("output"): .bool(output)])
            ],
            timeout: timeout
        )
        try checkError(response)
        
        if output, let dict = response.result.dictionaryValue {
            return dict[.string("output")]?.stringValue
        }
        return nil
    }
    
    /// Execute Lua code
    /// - Parameters:
    ///   - code: Lua code to execute
    ///   - args: Arguments passed to the Lua code (accessible as `...`)
    /// - Returns: The result of the Lua code
    func execLua(_ code: String, args: [MessagePackValue] = []) async throws -> MessagePackValue {
        let response = try await socket.request(
            method: "nvim_exec_lua",
            params: [.string(code), .array(args)],
            timeout: timeout
        )
        try checkError(response)
        return response.result
    }
    
    // MARK: - Buffer API
    
    /// Get the current buffer
    /// - Returns: Current buffer handle
    func getCurrentBuffer() async throws -> Buffer {
        let response = try await socket.request(
            method: "nvim_get_current_buf",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let id = response.result.int64Value else {
            throw APIError.unexpectedResultType(expected: "Buffer", got: describe(response.result))
        }
        return Buffer(id)
    }
    
    /// Set the current buffer
    /// - Parameter buffer: Buffer to make current
    func setCurrentBuffer(_ buffer: Buffer) async throws {
        let response = try await socket.request(
            method: "nvim_set_current_buf",
            params: [buffer.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Get buffer name (file path)
    /// - Parameter buffer: Buffer handle
    /// - Returns: Buffer name/path
    func getBufferName(_ buffer: Buffer) async throws -> String {
        let response = try await socket.request(
            method: "nvim_buf_get_name",
            params: [buffer.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
        
        guard let name = response.result.stringValue else {
            throw APIError.unexpectedResultType(expected: "String", got: describe(response.result))
        }
        return name
    }
    
    /// Set buffer name (file path)
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - name: New buffer name
    func setBufferName(_ buffer: Buffer, name: String) async throws {
        let response = try await socket.request(
            method: "nvim_buf_set_name",
            params: [buffer.messagePackValue, .string(name)],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Get buffer lines
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - start: Start line (0-indexed, inclusive)
    ///   - end: End line (0-indexed, exclusive, -1 for end of buffer)
    ///   - strictIndexing: Whether out-of-bounds is an error
    /// - Returns: Array of line strings
    func getBufferLines(
        _ buffer: Buffer,
        start: Int = 0,
        end: Int = -1,
        strictIndexing: Bool = false
    ) async throws -> [String] {
        let response = try await socket.request(
            method: "nvim_buf_get_lines",
            params: [
                buffer.messagePackValue,
                .int(Int64(start)),
                .int(Int64(end)),
                .bool(strictIndexing)
            ],
            timeout: timeout
        )
        try checkError(response)
        
        guard let array = response.result.arrayValue else {
            throw APIError.unexpectedResultType(expected: "Array", got: describe(response.result))
        }
        
        return array.compactMap { $0.stringValue }
    }
    
    /// Set buffer lines
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - start: Start line (0-indexed, inclusive)
    ///   - end: End line (0-indexed, exclusive, -1 for end of buffer)
    ///   - lines: New lines to set
    ///   - strictIndexing: Whether out-of-bounds is an error
    func setBufferLines(
        _ buffer: Buffer,
        start: Int,
        end: Int,
        lines: [String],
        strictIndexing: Bool = false
    ) async throws {
        let response = try await socket.request(
            method: "nvim_buf_set_lines",
            params: [
                buffer.messagePackValue,
                .int(Int64(start)),
                .int(Int64(end)),
                .bool(strictIndexing),
                .array(lines.map { .string($0) })
            ],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Append lines to buffer
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - lines: Lines to append
    func appendBufferLines(_ buffer: Buffer, lines: [String]) async throws {
        try await setBufferLines(buffer, start: -1, end: -1, lines: lines)
    }
    
    /// Get buffer text (more flexible than lines)
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - startRow: Start row (0-indexed)
    ///   - startCol: Start column (0-indexed)
    ///   - endRow: End row (0-indexed)
    ///   - endCol: End column (0-indexed)
    /// - Returns: Array of text chunks
    func getBufferText(
        _ buffer: Buffer,
        startRow: Int,
        startCol: Int,
        endRow: Int,
        endCol: Int
    ) async throws -> [String] {
        let response = try await socket.request(
            method: "nvim_buf_get_text",
            params: [
                buffer.messagePackValue,
                .int(Int64(startRow)),
                .int(Int64(startCol)),
                .int(Int64(endRow)),
                .int(Int64(endCol)),
                .map([:])  // opts (empty)
            ],
            timeout: timeout
        )
        try checkError(response)
        
        guard let array = response.result.arrayValue else {
            throw APIError.unexpectedResultType(expected: "Array", got: describe(response.result))
        }
        
        return array.compactMap { $0.stringValue }
    }
    
    /// Get buffer variable
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - name: Variable name (without b: prefix)
    /// - Returns: Variable value
    func getBufferVar(_ buffer: Buffer, name: String) async throws -> MessagePackValue {
        let response = try await socket.request(
            method: "nvim_buf_get_var",
            params: [buffer.messagePackValue, .string(name)],
            timeout: timeout
        )
        try checkError(response)
        return response.result
    }
    
    /// Set buffer variable
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - name: Variable name (without b: prefix)
    ///   - value: Variable value
    func setBufferVar(_ buffer: Buffer, name: String, value: MessagePackValue) async throws {
        let response = try await socket.request(
            method: "nvim_buf_set_var",
            params: [buffer.messagePackValue, .string(name), value],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Get buffer changedtick
    /// - Parameter buffer: Buffer handle
    /// - Returns: Current changedtick value
    func getBufferChangedtick(_ buffer: Buffer) async throws -> Int64 {
        let response = try await socket.request(
            method: "nvim_buf_get_changedtick",
            params: [buffer.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
        
        guard let tick = response.result.int64Value else {
            throw APIError.unexpectedResultType(expected: "Int", got: describe(response.result))
        }
        return tick
    }
    
    /// Attach to buffer for change notifications
    /// - Parameters:
    ///   - buffer: Buffer handle
    ///   - sendBuffer: Whether to send initial buffer content
    /// - Returns: Whether attach succeeded
    func attachBuffer(_ buffer: Buffer, sendBuffer: Bool = false) async throws -> Bool {
        let response = try await socket.request(
            method: "nvim_buf_attach",
            params: [
                buffer.messagePackValue,
                .bool(sendBuffer),
                .map([:])  // opts
            ],
            timeout: timeout
        )
        try checkError(response)
        return response.result.boolValue ?? false
    }
    
    /// Detach from buffer
    /// - Parameter buffer: Buffer handle
    /// - Returns: Whether detach succeeded
    func detachBuffer(_ buffer: Buffer) async throws -> Bool {
        let response = try await socket.request(
            method: "nvim_buf_detach",
            params: [buffer.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
        return response.result.boolValue ?? false
    }
    
    /// List all buffers
    /// - Returns: Array of buffer handles
    func listBuffers() async throws -> [Buffer] {
        let response = try await socket.request(
            method: "nvim_list_bufs",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let array = response.result.arrayValue else {
            throw APIError.unexpectedResultType(expected: "Array", got: describe(response.result))
        }
        
        return array.compactMap { $0.int64Value }.map { Buffer($0) }
    }
    
    // MARK: - Window API
    
    /// Get the current window
    /// - Returns: Current window handle
    func getCurrentWindow() async throws -> Window {
        let response = try await socket.request(
            method: "nvim_get_current_win",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let id = response.result.int64Value else {
            throw APIError.unexpectedResultType(expected: "Window", got: describe(response.result))
        }
        return Window(id)
    }
    
    /// Set the current window
    /// - Parameter window: Window to make current
    func setCurrentWindow(_ window: Window) async throws {
        let response = try await socket.request(
            method: "nvim_set_current_win",
            params: [window.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Get window buffer
    /// - Parameter window: Window handle
    /// - Returns: Buffer displayed in window
    func getWindowBuffer(_ window: Window) async throws -> Buffer {
        let response = try await socket.request(
            method: "nvim_win_get_buf",
            params: [window.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
        
        guard let id = response.result.int64Value else {
            throw APIError.unexpectedResultType(expected: "Buffer", got: describe(response.result))
        }
        return Buffer(id)
    }
    
    /// Get window cursor position
    /// - Parameter window: Window handle
    /// - Returns: (row, col) tuple (1-indexed row, 0-indexed col)
    func getWindowCursor(_ window: Window) async throws -> (row: Int, col: Int) {
        let response = try await socket.request(
            method: "nvim_win_get_cursor",
            params: [window.messagePackValue],
            timeout: timeout
        )
        try checkError(response)
        
        guard let array = response.result.arrayValue,
              array.count == 2,
              let row = array[0].int64Value,
              let col = array[1].int64Value else {
            throw APIError.unexpectedResultType(expected: "[row, col]", got: describe(response.result))
        }
        return (row: Int(row), col: Int(col))
    }
    
    /// Set window cursor position
    /// - Parameters:
    ///   - window: Window handle
    ///   - row: Row (1-indexed)
    ///   - col: Column (0-indexed)
    func setWindowCursor(_ window: Window, row: Int, col: Int) async throws {
        let response = try await socket.request(
            method: "nvim_win_set_cursor",
            params: [
                window.messagePackValue,
                .array([.int(Int64(row)), .int(Int64(col))])
            ],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// List all windows
    /// - Returns: Array of window handles
    func listWindows() async throws -> [Window] {
        let response = try await socket.request(
            method: "nvim_list_wins",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let array = response.result.arrayValue else {
            throw APIError.unexpectedResultType(expected: "Array", got: describe(response.result))
        }
        
        return array.compactMap { $0.int64Value }.map { Window($0) }
    }
    
    // MARK: - Mode & State
    
    /// Get current mode
    /// - Returns: Mode info dictionary
    func getMode() async throws -> (mode: String, blocking: Bool) {
        let response = try await socket.request(
            method: "nvim_get_mode",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let dict = response.result.dictionaryValue,
              let mode = dict[.string("mode")]?.stringValue else {
            throw APIError.unexpectedResultType(expected: "Mode dict", got: describe(response.result))
        }
        
        let blocking = dict[.string("blocking")]?.boolValue ?? false
        return (mode: mode, blocking: blocking)
    }
    
    /// Get current line
    /// - Returns: Current line text
    func getCurrentLine() async throws -> String {
        let response = try await socket.request(
            method: "nvim_get_current_line",
            params: [],
            timeout: timeout
        )
        try checkError(response)
        
        guard let line = response.result.stringValue else {
            throw APIError.unexpectedResultType(expected: "String", got: describe(response.result))
        }
        return line
    }
    
    /// Set current line
    /// - Parameter line: New line text
    func setCurrentLine(_ line: String) async throws {
        let response = try await socket.request(
            method: "nvim_set_current_line",
            params: [.string(line)],
            timeout: timeout
        )
        try checkError(response)
    }
    
    // MARK: - Variables
    
    /// Get global variable
    /// - Parameter name: Variable name (without g: prefix)
    /// - Returns: Variable value
    func getVar(_ name: String) async throws -> MessagePackValue {
        let response = try await socket.request(
            method: "nvim_get_var",
            params: [.string(name)],
            timeout: timeout
        )
        try checkError(response)
        return response.result
    }
    
    /// Set global variable
    /// - Parameters:
    ///   - name: Variable name (without g: prefix)
    ///   - value: Variable value
    func setVar(_ name: String, value: MessagePackValue) async throws {
        let response = try await socket.request(
            method: "nvim_set_var",
            params: [.string(name), value],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Delete global variable
    /// - Parameter name: Variable name (without g: prefix)
    func delVar(_ name: String) async throws {
        let response = try await socket.request(
            method: "nvim_del_var",
            params: [.string(name)],
            timeout: timeout
        )
        try checkError(response)
    }
    
    /// Get vim variable (v:)
    /// - Parameter name: Variable name (without v: prefix)
    /// - Returns: Variable value
    func getVvar(_ name: String) async throws -> MessagePackValue {
        let response = try await socket.request(
            method: "nvim_get_vvar",
            params: [.string(name)],
            timeout: timeout
        )
        try checkError(response)
        return response.result
    }
    
    // MARK: - Input
    
    /// Send input keys to nvim
    /// - Parameters:
    ///   - keys: Key sequence (e.g., "<Esc>", "iHello<Esc>")
    ///   - mode: Input mode ("m"=remap, "t"=typed, "n"=no-remap, etc.)
    ///   - escape_ks: Escape K_SPECIAL bytes
    func input(_ keys: String, mode: String = "", escapeKs: Bool = true) async throws -> Int {
        let response = try await socket.request(
            method: "nvim_input",
            params: [.string(keys)],
            timeout: timeout
        )
        try checkError(response)
        
        return Int(response.result.int64Value ?? 0)
    }
    
    /// Feed keys to nvim (more control than input)
    /// - Parameters:
    ///   - keys: Key sequence
    ///   - mode: Mode string
    ///   - escapeKs: Escape K_SPECIAL
    func feedkeys(_ keys: String, mode: String = "n", escapeKs: Bool = true) async throws {
        let response = try await socket.request(
            method: "nvim_feedkeys",
            params: [.string(keys), .string(mode), .bool(escapeKs)],
            timeout: timeout
        )
        try checkError(response)
    }
    
    // MARK: - Convenience Methods
    
    /// Get current working directory
    /// - Returns: Current working directory path
    func getCwd() async throws -> String {
        return try await evalString("getcwd()")
    }
    
    /// Get current file path
    /// - Returns: Current file path (may be empty for unnamed buffer)
    func getCurrentFilePath() async throws -> String {
        let buf = try await getCurrentBuffer()
        return try await getBufferName(buf)
    }
    
    /// Check if buffer is modified
    /// - Parameter buffer: Buffer handle
    /// - Returns: True if buffer has unsaved changes
    func isBufferModified(_ buffer: Buffer) async throws -> Bool {
        let result = try await eval("getbufvar(\(buffer.id), '&modified')")
        return result.int64Value == 1
    }
    
    /// Get buffer filetype
    /// - Parameter buffer: Buffer handle
    /// - Returns: Filetype string
    func getBufferFiletype(_ buffer: Buffer) async throws -> String {
        let result = try await eval("getbufvar(\(buffer.id), '&filetype')")
        return result.stringValue ?? ""
    }
    
    // MARK: - Private Helpers
    
    /// Check response for errors and throw if present
    private func checkError(_ response: MsgpackRpc.Response) throws {
        if response.isError {
            throw APIError.nvimError(response.errorMessage ?? "Unknown error")
        }
    }
    
    /// Get a string description of a MessagePackValue type
    private func describe(_ value: MessagePackValue) -> String {
        switch value {
        case .nil: return "nil"
        case .bool: return "Bool"
        case .int: return "Int"
        case .uint: return "UInt"
        case .float: return "Float"
        case .double: return "Double"
        case .string: return "String"
        case .binary: return "Binary"
        case .array: return "Array"
        case .map: return "Map"
        case .extended: return "Extended"
        }
    }
}
