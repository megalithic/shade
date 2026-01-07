import Foundation
@preconcurrency import MessagePack

/// Native Unix socket connection manager for nvim msgpack-rpc communication.
/// This is Option B: persistent socket connection (vs Option A: shell out per command in NvimRPC.swift)
///
/// Protocol: msgpack-rpc over Unix domain socket
/// - Request:      [0, msgid, method, params]
/// - Response:     [1, msgid, error, result]
/// - Notification: [2, method, params]
actor NvimSocketManager {
    
    // MARK: - Types
    
    /// Connection state
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    /// msgpack-rpc message types
    enum MessageType: UInt64 {
        case request = 0
        case response = 1
        case notification = 2
    }
    
    /// Parsed incoming message
    enum Message: Sendable {
        case response(msgid: UInt32, error: MessagePackValue, result: MessagePackValue)
        case notification(method: String, params: [MessagePackValue])
        case request(msgid: UInt32, method: String, params: [MessagePackValue])
    }
    
    /// Response from nvim
    struct Response: Sendable {
        let msgid: UInt32
        let error: MessagePackValue
        let result: MessagePackValue
        
        var isSuccess: Bool { error.isNil }
        
        static func empty(_ msgid: UInt32) -> Response {
            Response(msgid: msgid, error: .nil, result: .nil)
        }
    }
    
    /// Errors from socket manager
    enum SocketError: Error, LocalizedError {
        case notConnected
        case connectionFailed(String)
        case socketCreationFailed
        case writeFailed(String)
        case readFailed(String)
        case invalidMessage(String)
        case timeout
        
        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to nvim socket"
            case .connectionFailed(let msg):
                return "Connection failed: \(msg)"
            case .socketCreationFailed:
                return "Failed to create Unix socket"
            case .writeFailed(let msg):
                return "Write failed: \(msg)"
            case .readFailed(let msg):
                return "Read failed: \(msg)"
            case .invalidMessage(let msg):
                return "Invalid message: \(msg)"
            case .timeout:
                return "Request timed out"
            }
        }
    }
    
    // MARK: - Properties
    
    /// Current connection state
    private(set) var state: ConnectionState = .disconnected
    
    /// Socket path (defaults to XDG state directory)
    private let socketPath: String
    
    /// File descriptor for the connected socket
    private var socketFD: Int32?
    
    /// Dispatch source for reading
    private var readSource: DispatchSourceRead?
    
    /// Queue for socket I/O
    private let ioQueue = DispatchQueue(label: "io.shade.nvim.socket", qos: .userInitiated)
    
    /// Buffer for incoming data (partial reads)
    private var readBuffer = Data()
    
    /// Next msgid for requests
    private var nextMsgid: UInt32 = 1
    
    /// Pending request continuations, keyed by msgid
    private var pendingRequests: [UInt32: CheckedContinuation<Response, Error>] = [:]
    
    /// Stream for incoming notifications
    let notificationStream: AsyncStream<Message>
    private let notificationContinuation: AsyncStream<Message>.Continuation
    
    /// Callback for state changes
    var onStateChange: ((ConnectionState) -> Void)?
    
    // MARK: - Initialization
    
    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? StateDirectory.nvimSocketPath
        (self.notificationStream, self.notificationContinuation) = AsyncStream.makeStream()
    }
    
    deinit {
        // Cleanup handled by disconnect()
    }
    
    // MARK: - Connection Management
    
    /// Connect to the nvim socket
    func connect() async throws {
        guard state == .disconnected || state.isError else {
            Log.debug("NvimSocketManager: Already connected or connecting")
            return
        }
        
        setState(.connecting)
        Log.debug("NvimSocketManager: Connecting to \(socketPath)")
        
        // Verify socket file exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            let error = "Socket file does not exist: \(socketPath)"
            setState(.error(error))
            throw SocketError.connectionFailed(error)
        }
        
        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let error = "socket() failed: \(String(cString: strerror(errno)))"
            setState(.error(error))
            throw SocketError.socketCreationFailed
        }
        
        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        // Connect to the Unix socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Copy path into sun_path (null-terminated)
        // Note: sun_path is a fixed-size tuple of CChars
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let pathLen = min(socketPath.utf8.count, sunPathSize - 1)
        
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { ptr in
                socketPath.withCString { pathCStr in
                    memcpy(ptr, pathCStr, pathLen)
                    ptr[pathLen] = 0 // Null terminate
                }
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        
        // Non-blocking connect may return EINPROGRESS
        if connectResult < 0 && errno != EINPROGRESS {
            close(fd)
            let error = "connect() failed: \(String(cString: strerror(errno)))"
            setState(.error(error))
            throw SocketError.connectionFailed(error)
        }
        
        // Wait for connection to complete if EINPROGRESS
        if connectResult < 0 && errno == EINPROGRESS {
            try await waitForConnection(fd: fd)
        }
        
        self.socketFD = fd
        startReading()
        setState(.connected)
        Log.info("NvimSocketManager: Connected to nvim at \(socketPath)")
    }
    
    /// Disconnect from the nvim socket
    func disconnect() {
        Log.debug("NvimSocketManager: Disconnecting")
        
        // Cancel read source
        readSource?.cancel()
        readSource = nil
        
        // Close socket
        if let fd = socketFD {
            close(fd)
            socketFD = nil
        }
        
        // Clear buffers
        readBuffer.removeAll()
        
        // Cancel pending requests
        for (msgid, continuation) in pendingRequests {
            continuation.resume(returning: Response.empty(msgid))
        }
        pendingRequests.removeAll()
        
        // Finish notification stream
        notificationContinuation.finish()
        
        setState(.disconnected)
        Log.info("NvimSocketManager: Disconnected")
    }
    
    /// Check if connected
    var isConnected: Bool {
        state == .connected && socketFD != nil
    }
    
    // MARK: - Request/Response
    
    /// Send a request to nvim and wait for response
    /// - Parameters:
    ///   - method: API method name (e.g., "nvim_eval")
    ///   - params: Method parameters
    ///   - timeout: Request timeout in seconds (default 5.0)
    /// - Returns: Response from nvim
    func request(
        method: String,
        params: [MessagePackValue] = [],
        timeout: TimeInterval = 5.0
    ) async throws -> Response {
        guard isConnected, let fd = socketFD else {
            throw SocketError.notConnected
        }
        
        let msgid = nextMsgid
        nextMsgid += 1
        
        // Pack request: [0, msgid, method, params]
        let message: MessagePackValue = .array([
            .uint(MessageType.request.rawValue),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params)
        ])
        
        let packed = pack(message)
        
        Log.debug("NvimSocketManager: Request \(msgid) -> \(method)")
        
        // Write to socket
        try writeData(packed, to: fd)
        
        // Wait for response with timeout
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.storeContinuation(continuation, for: msgid) }
                }
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SocketError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// Send a notification (no response expected)
    /// - Parameters:
    ///   - method: API method name
    ///   - params: Method parameters
    func notify(method: String, params: [MessagePackValue] = []) throws {
        guard isConnected, let fd = socketFD else {
            throw SocketError.notConnected
        }
        
        // Pack notification: [2, method, params]
        let message: MessagePackValue = .array([
            .uint(MessageType.notification.rawValue),
            .string(method),
            .array(params)
        ])
        
        let packed = pack(message)
        
        Log.debug("NvimSocketManager: Notify -> \(method)")
        
        try writeData(packed, to: fd)
    }
    
    // MARK: - Private Helpers
    
    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }
    
    private func storeContinuation(_ continuation: CheckedContinuation<Response, Error>, for msgid: UInt32) {
        pendingRequests[msgid] = continuation
    }
    
    /// Wait for non-blocking connect to complete
    private func waitForConnection(fd: Int32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
            
            source.setEventHandler {
                source.cancel()
                
                // Check for connection error
                var error: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len)
                
                if error != 0 {
                    continuation.resume(throwing: SocketError.connectionFailed(String(cString: strerror(error))))
                } else {
                    continuation.resume()
                }
            }
            
            source.setCancelHandler {
                // Cleanup if needed
            }
            
            source.resume()
        }
    }
    
    /// Start reading from the socket
    private func startReading() {
        guard let fd = socketFD else { return }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            var buffer = [UInt8](repeating: 0, count: 65536)
            let bytesRead = read(fd, &buffer, buffer.count)
            
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                Task { await self.handleIncomingData(data) }
            } else if bytesRead == 0 {
                // EOF - connection closed
                Log.info("NvimSocketManager: Connection closed by nvim")
                Task { await self.disconnect() }
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                // Read error
                Log.error("NvimSocketManager: Read error: \(String(cString: strerror(errno)))")
                Task { await self.disconnect() }
            }
        }
        
        source.setCancelHandler { [weak self] in
            Log.debug("NvimSocketManager: Read source cancelled")
            Task { await self?.handleReadSourceCancelled() }
        }
        
        readSource = source
        source.resume()
    }
    
    private func handleReadSourceCancelled() {
        // No-op for now, disconnect handles cleanup
    }
    
    /// Handle incoming data from socket
    private func handleIncomingData(_ data: Data) {
        readBuffer.append(data)
        
        // Try to unpack complete messages
        while !readBuffer.isEmpty {
            do {
                let (value, remainder) = try unpack(readBuffer)
                
                // Update buffer with remainder (unpack(Data) returns Data directly)
                readBuffer = remainder
                
                processMessage(value)
            } catch MessagePackError.insufficientData {
                // Need more data, wait for next read
                break
            } catch {
                Log.error("NvimSocketManager: Unpack error: \(error)")
                readBuffer.removeAll()
                break
            }
        }
    }
    
    /// Process a complete msgpack-rpc message
    private func processMessage(_ value: MessagePackValue) {
        guard let array = value.arrayValue, !array.isEmpty else {
            Log.error("NvimSocketManager: Invalid message format")
            return
        }
        
        guard let rawType = array[0].uint64Value,
              let type = MessageType(rawValue: rawType) else {
            Log.error("NvimSocketManager: Unknown message type")
            return
        }
        
        switch type {
        case .response:
            guard array.count == 4,
                  let msgid = array[1].uint64Value else {
                Log.error("NvimSocketManager: Invalid response format")
                return
            }
            
            let response = Response(
                msgid: UInt32(msgid),
                error: array[2],
                result: array[3]
            )
            
            Log.debug("NvimSocketManager: Response \(msgid) <- \(response.isSuccess ? "success" : "error")")
            
            if let continuation = pendingRequests.removeValue(forKey: UInt32(msgid)) {
                continuation.resume(returning: response)
            }
            
        case .notification:
            guard array.count == 3,
                  let method = array[1].stringValue,
                  let params = array[2].arrayValue else {
                Log.error("NvimSocketManager: Invalid notification format")
                return
            }
            
            Log.debug("NvimSocketManager: Notification <- \(method)")
            notificationContinuation.yield(.notification(method: method, params: params))
            
        case .request:
            // Nvim requesting something from us (rare, but possible with UI attach)
            guard array.count == 4,
                  let msgid = array[1].uint64Value,
                  let method = array[2].stringValue,
                  let params = array[3].arrayValue else {
                Log.error("NvimSocketManager: Invalid request format")
                return
            }
            
            Log.debug("NvimSocketManager: Request <- \(method)")
            notificationContinuation.yield(.request(
                msgid: UInt32(msgid),
                method: method,
                params: params
            ))
        }
    }
    
    /// Write data to socket
    private func writeData(_ data: Data, to fd: Int32) throws {
        var totalWritten = 0
        let bytes = [UInt8](data)
        
        while totalWritten < bytes.count {
            let written = write(fd, bytes, bytes.count - totalWritten)
            
            if written < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Would block, try again
                    continue
                }
                throw SocketError.writeFailed(String(cString: strerror(errno)))
            }
            
            totalWritten += written
        }
    }
}

// MARK: - ConnectionState Extension

extension NvimSocketManager.ConnectionState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
