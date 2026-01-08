import Foundation
@preconcurrency import MessagePack
import MsgpackRpc

/// RPC server that allows nvim (and other clients) to send commands to Shade.
/// Listens on ~/.local/state/shade/shade.sock
///
/// This is the reverse direction from NvimSocketManager:
/// - NvimSocketManager: Shade connects to nvim's socket (client)
/// - ShadeServer: Shade listens on its own socket (server)
///
/// ## Supported Methods
/// - `hide()` - Hide the Shade panel
/// - `show()` - Show the Shade panel
/// - `toggle()` - Toggle panel visibility
/// - `get_context()` - Get current capture context
///
/// ## Usage from nvim
/// ```lua
/// local shade = require('shade')
/// shade.hide()  -- Hide panel after :wq
/// ```
actor ShadeServer {
    
    // MARK: - Singleton
    
    static let shared = ShadeServer()
    
    // MARK: - Types
    
    enum ServerError: Error, LocalizedError {
        case bindFailed(String)
        case listenFailed(String)
        case acceptFailed(String)
        case notRunning
        
        var errorDescription: String? {
            switch self {
            case .bindFailed(let msg): return "Bind failed: \(msg)"
            case .listenFailed(let msg): return "Listen failed: \(msg)"
            case .acceptFailed(let msg): return "Accept failed: \(msg)"
            case .notRunning: return "Server not running"
            }
        }
    }
    
    /// Handler for RPC methods - must be Sendable
    typealias MethodHandler = @Sendable (MessagePackValue) async -> MessagePackValue
    
    // MARK: - Properties
    
    /// Socket path
    private let socketPath: String
    
    /// Listening socket file descriptor
    private var listenFD: Int32?
    
    /// Dispatch source for accepting connections
    private var acceptSource: DispatchSourceRead?
    
    /// Queue for socket I/O
    private let ioQueue = DispatchQueue(label: "io.shade.server", qos: .userInitiated)
    
    /// Connected clients (fd -> read source)
    private var clients: [Int32: DispatchSourceRead] = [:]
    
    /// Read buffers per client
    private var clientBuffers: [Int32: Data] = [:]
    
    /// Registered method handlers
    private var handlers: [String: MethodHandler] = [:]
    
    /// Whether server is running
    private(set) var isRunning = false
    
    // MARK: - Callbacks (set by ShadeAppDelegate)
    // These are nonisolated and use @Sendable closures
    
    nonisolated(unsafe) var onHide: (@Sendable @MainActor () -> Void)?
    nonisolated(unsafe) var onShow: (@Sendable @MainActor () -> Void)?
    nonisolated(unsafe) var onToggle: (@Sendable @MainActor () -> Void)?
    nonisolated(unsafe) var onGetContext: (@Sendable () async -> [String: Any])?
    
    // MARK: - Initialization
    
    private init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? (StateDirectory.baseDir.path + "/shade.sock")
    }
    
    /// Register default handlers - call after setting callbacks
    func registerDefaultHandlers() {
        // hide() - Hide the panel
        handlers["hide"] = { [weak self] _ in
            if let onHide = self?.onHide {
                await MainActor.run { onHide() }
            }
            return .bool(true)
        }
        
        // show() - Show the panel
        handlers["show"] = { [weak self] _ in
            if let onShow = self?.onShow {
                await MainActor.run { onShow() }
            }
            return .bool(true)
        }
        
        // toggle() - Toggle panel visibility
        handlers["toggle"] = { [weak self] _ in
            if let onToggle = self?.onToggle {
                await MainActor.run { onToggle() }
            }
            return .bool(true)
        }
        
        // get_context() - Get current capture context
        handlers["get_context"] = { [weak self] _ in
            if let getContext = self?.onGetContext {
                let ctx = await getContext()
                return Self.dictToMessagePack(ctx)
            }
            return .nil
        }
        
        // ping() - Simple connectivity test
        handlers["ping"] = { _ in
            return .string("pong")
        }
    }
    
    // MARK: - Server Lifecycle
    
    /// Start the RPC server
    func start() throws {
        guard !isRunning else {
            Log.debug("ShadeServer: Already running")
            return
        }
        
        Log.debug("ShadeServer: Starting on \(socketPath)")
        
        // Remove existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.bindFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        
        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        
        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let pathLen = min(socketPath.utf8.count, sunPathSize - 1)
        
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { ptr in
                socketPath.withCString { pathCStr in
                    memcpy(ptr, pathCStr, pathLen)
                    ptr[pathLen] = 0
                }
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, addrLen)
            }
        }
        
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed("bind() failed: \(String(cString: strerror(errno)))")
        }
        
        // Listen for connections
        guard listen(fd, 5) == 0 else {
            close(fd)
            throw ServerError.listenFailed("listen() failed: \(String(cString: strerror(errno)))")
        }
        
        self.listenFD = fd
        startAccepting()
        isRunning = true
        
        Log.info("ShadeServer: Listening on \(socketPath)")
    }
    
    /// Stop the RPC server
    func stop() {
        guard isRunning else { return }
        
        Log.debug("ShadeServer: Stopping")
        
        // Cancel accept source
        acceptSource?.cancel()
        acceptSource = nil
        
        // Close all client connections
        for (clientFD, source) in clients {
            source.cancel()
            close(clientFD)
        }
        clients.removeAll()
        clientBuffers.removeAll()
        
        // Close listening socket
        if let fd = listenFD {
            close(fd)
            listenFD = nil
        }
        
        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        isRunning = false
        Log.info("ShadeServer: Stopped")
    }
    
    // MARK: - Method Registration
    
    /// Register a method handler
    func registerHandler(_ method: String, handler: @escaping MethodHandler) {
        handlers[method] = handler
    }
    
    // MARK: - Private Methods
    
    /// Start accepting connections
    private func startAccepting() {
        guard let fd = listenFD else { return }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(fd, sockaddrPtr, &clientAddrLen)
                }
            }
            
            if clientFD >= 0 {
                // Set non-blocking
                let flags = fcntl(clientFD, F_GETFL)
                _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
                
                Task { await self.handleNewClient(clientFD) }
            }
        }
        
        acceptSource = source
        source.resume()
    }
    
    /// Handle a new client connection
    private func handleNewClient(_ clientFD: Int32) {
        Log.debug("ShadeServer: Client connected (fd=\(clientFD))")
        
        clientBuffers[clientFD] = Data()
        
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: ioQueue)
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            var buffer = [UInt8](repeating: 0, count: 65536)
            let bytesRead = read(clientFD, &buffer, buffer.count)
            
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                Task { await self.handleClientData(clientFD, data: data) }
            } else if bytesRead == 0 {
                // Client disconnected
                Task { await self.handleClientDisconnect(clientFD) }
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                // Read error
                Log.error("ShadeServer: Read error from client \(clientFD): \(String(cString: strerror(errno)))")
                Task { await self.handleClientDisconnect(clientFD) }
            }
        }
        
        source.setCancelHandler { [weak self] in
            Task { await self?.cleanupClient(clientFD) }
        }
        
        clients[clientFD] = source
        source.resume()
    }
    
    /// Handle data from a client
    private func handleClientData(_ clientFD: Int32, data: Data) {
        clientBuffers[clientFD, default: Data()].append(data)
        
        guard var buffer = clientBuffers[clientFD] else { return }
        
        // Decode all complete messages
        let result = MsgpackRpc.decodeAll(from: buffer)
        clientBuffers[clientFD] = result.remainder
        
        // Process each message
        for message in result.messages {
            Task { await processClientMessage(clientFD, message: message) }
        }
    }
    
    /// Process a message from a client
    private func processClientMessage(_ clientFD: Int32, message: MsgpackRpc.Message) async {
        switch message {
        case .request(let request):
            Log.debug("ShadeServer: Request <- \(request.method) (msgid=\(request.msgid))")
            
            // Look up handler
            if let handler = handlers[request.method] {
                let params = request.params.first ?? .nil
                let result = await handler(params)
                
                // Send response
                let response = MsgpackRpc.Response(msgid: request.msgid, error: .nil, result: result)
                sendToClient(clientFD, data: response.encode())
            } else {
                // Unknown method
                Log.warn("ShadeServer: Unknown method: \(request.method)")
                let response = MsgpackRpc.Response(
                    msgid: request.msgid,
                    error: .string("Unknown method: \(request.method)"),
                    result: .nil
                )
                sendToClient(clientFD, data: response.encode())
            }
            
        case .notification(let notification):
            Log.debug("ShadeServer: Notification <- \(notification.method)")
            
            // Fire-and-forget handler
            if let handler = handlers[notification.method] {
                let params = notification.params.first ?? .nil
                _ = await handler(params)
            }
            
        case .response:
            // We don't send requests, so ignore responses
            Log.warn("ShadeServer: Unexpected response from client")
        }
    }
    
    /// Send data to a client
    private func sendToClient(_ clientFD: Int32, data: Data) {
        ioQueue.async {
            var totalWritten = 0
            data.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                
                while totalWritten < data.count {
                    let remaining = data.count - totalWritten
                    let writePtr = baseAddress.advanced(by: totalWritten)
                    let written = write(clientFD, writePtr, remaining)
                    
                    if written < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            usleep(1000)
                            continue
                        }
                        Log.error("ShadeServer: Write error to client \(clientFD): \(String(cString: strerror(errno)))")
                        return
                    }
                    
                    totalWritten += written
                }
            }
        }
    }
    
    /// Handle client disconnect
    private func handleClientDisconnect(_ clientFD: Int32) {
        Log.debug("ShadeServer: Client disconnected (fd=\(clientFD))")
        
        clients[clientFD]?.cancel()
        clients.removeValue(forKey: clientFD)
        clientBuffers.removeValue(forKey: clientFD)
        close(clientFD)
    }
    
    /// Clean up client resources
    private func cleanupClient(_ clientFD: Int32) {
        clients.removeValue(forKey: clientFD)
        clientBuffers.removeValue(forKey: clientFD)
    }
    
    // MARK: - Static Helpers
    
    /// Convert Swift dictionary to MessagePackValue
    private static func dictToMessagePack(_ dict: [String: Any]) -> MessagePackValue {
        var result: [MessagePackValue: MessagePackValue] = [:]
        
        for (key, value) in dict {
            let mpKey = MessagePackValue.string(key)
            let mpValue: MessagePackValue
            
            switch value {
            case let s as String:
                mpValue = .string(s)
            case let i as Int:
                mpValue = .int(Int64(i))
            case let b as Bool:
                mpValue = .bool(b)
            case let d as [String: Any]:
                mpValue = dictToMessagePack(d)
            case let a as [Any]:
                mpValue = .array(a.map { anyToMessagePack($0) })
            default:
                mpValue = .nil
            }
            
            result[mpKey] = mpValue
        }
        
        return .map(result)
    }
    
    /// Convert Any to MessagePackValue
    private static func anyToMessagePack(_ value: Any) -> MessagePackValue {
        switch value {
        case let s as String:
            return .string(s)
        case let i as Int:
            return .int(Int64(i))
        case let b as Bool:
            return .bool(b)
        case let d as [String: Any]:
            return dictToMessagePack(d)
        case let a as [Any]:
            return .array(a.map { anyToMessagePack($0) })
        default:
            return .nil
        }
    }
}
