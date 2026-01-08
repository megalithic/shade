import XCTest
import Foundation
@preconcurrency import MessagePack
import MsgpackRpc

/// Unit tests for ShadeServer protocol and encoding
/// These tests verify the msgpack-rpc protocol without needing the full Shade app
final class ShadeServerProtocolTests: XCTestCase {
    
    // MARK: - Request Encoding Tests
    
    func testRequestEncoding() throws {
        let request = MsgpackRpc.Request(msgid: 1, method: "ping", params: [])
        let data = request.encode()
        
        XCTAssertGreaterThan(data.count, 0)
        
        // Decode it back
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.errors.count, 0)
        
        if case .request(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.msgid, 1)
            XCTAssertEqual(decoded.method, "ping")
            XCTAssertEqual(decoded.params, [])
        } else {
            XCTFail("Expected request message")
        }
    }
    
    func testRequestWithParams() throws {
        let request = MsgpackRpc.Request(
            msgid: 42,
            method: "test_method",
            params: [.string("arg1"), .int(123), .bool(true)]
        )
        let data = request.encode()
        
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 1)
        
        if case .request(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.msgid, 42)
            XCTAssertEqual(decoded.method, "test_method")
            XCTAssertEqual(decoded.params.count, 3)
            XCTAssertEqual(decoded.params[0], .string("arg1"))
            XCTAssertEqual(decoded.params[1], .int(123))
            XCTAssertEqual(decoded.params[2], .bool(true))
        } else {
            XCTFail("Expected request message")
        }
    }
    
    // MARK: - Response Encoding Tests
    
    func testSuccessResponseEncoding() throws {
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .string("pong"))
        let data = response.encode()
        
        XCTAssertGreaterThan(data.count, 0)
        
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 1)
        
        if case .response(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.msgid, 1)
            XCTAssertTrue(decoded.isSuccess)
            XCTAssertEqual(decoded.result, .string("pong"))
            XCTAssertEqual(decoded.error, .nil)
        } else {
            XCTFail("Expected response message")
        }
    }
    
    func testErrorResponseEncoding() throws {
        let response = MsgpackRpc.Response(
            msgid: 99,
            error: .string("Unknown method: foo"),
            result: .nil
        )
        let data = response.encode()
        
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 1)
        
        if case .response(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.msgid, 99)
            XCTAssertFalse(decoded.isSuccess)
            XCTAssertEqual(decoded.error, .string("Unknown method: foo"))
        } else {
            XCTFail("Expected response message")
        }
    }
    
    func testBoolResultResponse() throws {
        let response = MsgpackRpc.Response(msgid: 5, error: .nil, result: .bool(true))
        let data = response.encode()
        
        let result = MsgpackRpc.decodeAll(from: data)
        
        if case .response(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.result, .bool(true))
        } else {
            XCTFail("Expected response message")
        }
    }
    
    // MARK: - Notification Encoding Tests
    
    func testNotificationEncoding() throws {
        let notification = MsgpackRpc.Notification(method: "hide", params: [])
        let data = notification.encode()
        
        XCTAssertGreaterThan(data.count, 0)
        
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 1)
        
        if case .notification(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.method, "hide")
            XCTAssertEqual(decoded.params, [])
        } else {
            XCTFail("Expected notification message")
        }
    }
    
    func testNotificationWithParams() throws {
        let notification = MsgpackRpc.Notification(
            method: "redraw",
            params: [.array([.string("resize"), .int(80), .int(24)])]
        )
        let data = notification.encode()
        
        let result = MsgpackRpc.decodeAll(from: data)
        
        if case .notification(let decoded) = result.messages.first {
            XCTAssertEqual(decoded.method, "redraw")
            XCTAssertEqual(decoded.params.count, 1)
        } else {
            XCTFail("Expected notification message")
        }
    }
    
    // MARK: - Multiple Messages Tests
    
    func testDecodeMultipleMessages() throws {
        // Encode two messages back-to-back
        let request = MsgpackRpc.Request(msgid: 1, method: "ping", params: [])
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .string("pong"))
        
        var data = request.encode()
        data.append(response.encode())
        
        let result = MsgpackRpc.decodeAll(from: data)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.errors.count, 0)
        XCTAssertEqual(result.remainder.count, 0)
        
        if case .request(let req) = result.messages[0] {
            XCTAssertEqual(req.method, "ping")
        } else {
            XCTFail("Expected request as first message")
        }
        
        if case .response(let resp) = result.messages[1] {
            XCTAssertEqual(resp.result, .string("pong"))
        } else {
            XCTFail("Expected response as second message")
        }
    }
    
    func testDecodePartialMessage() throws {
        // Encode a message and truncate it
        let request = MsgpackRpc.Request(msgid: 1, method: "ping", params: [])
        let data = request.encode()
        
        // Only use first half of the data
        let partialData = data.prefix(data.count / 2)
        
        let result = MsgpackRpc.decodeAll(from: Data(partialData))
        
        // Should have remainder (the partial message)
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertGreaterThan(result.remainder.count, 0)
    }
    
    // MARK: - Empty Response Helper Tests
    
    func testEmptyResponse() {
        let response = MsgpackRpc.Response.empty(42)
        
        XCTAssertEqual(response.msgid, 42)
        XCTAssertEqual(response.error, .nil)
        XCTAssertEqual(response.result, .nil)
        XCTAssertTrue(response.isSuccess)
    }
}

/// Integration tests that require Shade to be running
/// These will be skipped if the shade.sock doesn't exist
final class ShadeServerIntegrationTests: XCTestCase {
    
    let socketPath = NSHomeDirectory() + "/.local/state/shade/shade.sock"
    
    func testPingPong() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "ping", params: [])
        
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.result, .string("pong"))
    }
    
    func testHideMethod() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "hide", params: [])
        
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.result, .bool(true))
    }
    
    func testShowMethod() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "show", params: [])
        
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.result, .bool(true))
    }
    
    func testToggleMethod() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "toggle", params: [])
        
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.result, .bool(true))
    }
    
    func testGetContextMethod() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "get_context", params: [])
        
        XCTAssertTrue(response.isSuccess)
        // Result should be a map (possibly empty) or nil
        if case .map = response.result {
            // OK - got a context map
        } else if response.result == .nil {
            // OK - no context available
        } else {
            XCTFail("Expected map or nil result, got: \(response.result)")
        }
    }
    
    func testUnknownMethod() async throws {
        try skipIfServerNotRunning()
        
        let response = try await sendRequest(method: "nonexistent_method_xyz", params: [])
        
        XCTAssertFalse(response.isSuccess)
        if case .string(let errorMsg) = response.error {
            XCTAssertTrue(errorMsg.contains("Unknown method"), "Error should mention unknown method: \(errorMsg)")
        } else {
            XCTFail("Expected string error message")
        }
    }
    
    // MARK: - Helpers
    
    private func skipIfServerNotRunning() throws {
        let fileType = FileManager.default.fileExists(atPath: socketPath)
        if !fileType {
            throw XCTSkip("Shade server not running - skipping integration test")
        }
    }
    
    private func sendRequest(method: String, params: [MessagePackValue]) async throws -> MsgpackRpc.Response {
        // Create Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "ShadeServerTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"
            ])
        }
        defer { close(fd) }
        
        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { ptr in
                socketPath.withCString { pathCStr in
                    let pathLen = min(socketPath.utf8.count, sunPathSize - 1)
                    memcpy(ptr, pathCStr, pathLen)
                    ptr[pathLen] = 0
                }
            }
        }
        
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else {
            throw NSError(domain: "ShadeServerTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "connect() failed: \(String(cString: strerror(errno)))"
            ])
        }
        
        // Send request
        let request = MsgpackRpc.Request(msgid: 1, method: method, params: params)
        let requestData = request.encode()
        
        _ = requestData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
        
        // Read response with timeout
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 5000) // 5 second timeout
        
        guard pollResult > 0 else {
            throw NSError(domain: "ShadeServerTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: pollResult == 0 ? "Timeout waiting for response" : "poll() failed"
            ])
        }
        
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(fd, &buffer, buffer.count)
        
        guard bytesRead > 0 else {
            throw NSError(domain: "ShadeServerTests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "No response received"
            ])
        }
        
        let responseData = Data(bytes: buffer, count: bytesRead)
        let result = MsgpackRpc.decodeAll(from: responseData)
        
        guard let message = result.messages.first, case .response(let response) = message else {
            throw NSError(domain: "ShadeServerTests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response format"
            ])
        }
        
        return response
    }
}
