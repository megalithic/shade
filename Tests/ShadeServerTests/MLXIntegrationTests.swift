import XCTest
import Foundation
@preconcurrency import MessagePack
import MsgpackRpc

/// Integration tests for MLX inference functionality
///
/// These tests verify the MLX inference features through the ShadeServer RPC interface.
/// Tests are skipped if:
/// - Shade server is not running
/// - MLX RPC commands are not yet implemented (shade-ahf.7)
///
/// ## Test Strategy
///
/// MLXInferenceEngine is tested via RPC because:
/// 1. It's part of the shade target which depends on GhosttyKit
/// 2. It requires actor isolation that's managed by ShadeAppDelegate
/// 3. Model downloads and inference require the full runtime
///
/// ## Future Tests (once shade-ahf.7 is complete)
///
/// - `testMLXStatus`: Verify model status reporting
/// - `testMLXSummarize`: Test summarization with different styles
/// - `testMLXSummarizeEmptyInput`: Verify empty input error
/// - `testMLXUnload`: Test model unloading
///
final class MLXIntegrationTests: XCTestCase {

    let socketPath = NSHomeDirectory() + "/.local/state/shade/shade.sock"

    // MARK: - Unit Tests (No server required)

    func testMLXInferenceEngine_SharedInstanceExists() {
        // Verify the shared singleton pattern works
        // This doesn't load the model, just tests the instance exists
        // The actual inference tests require the server to be running
        // since MLXInferenceEngine is in the shade target with GhosttyKit dependency

        // Note: We can't directly test MLXInferenceEngine.shared here because
        // it's in the shade executable target, not a testable library target.
        // This test documents the expected behavior.
        // Real testing happens via RPC integration tests below.
    }

    // MARK: - RPC Integration Tests (Server required, shade-ahf.7)

    func testMLXStatusMethod() async throws {
        try skipIfServerNotRunning()

        let response = try await sendRequest(method: "mlx.status", params: [])

        // TODO: Enable once shade-ahf.7 (MLX RPC commands) is implemented
        // Currently expecting "Unknown method" since RPC isn't wired up
        if response.isSuccess {
            // MLX RPC is implemented - verify response format
            if case .map(let status) = response.result {
                XCTAssertNotNil(status["loaded"], "Status should include 'loaded' field")
            } else {
                XCTFail("Expected map result for mlx.status")
            }
        } else {
            // Expected until shade-ahf.7 is complete
            if case .string(let error) = response.error {
                if error.contains("Unknown method") {
                    throw XCTSkip("MLX RPC not yet implemented (shade-ahf.7)")
                }
            }
            XCTFail("Unexpected error: \(response.error)")
        }
    }

    func testMLXSummarizeMethod() async throws {
        try skipIfServerNotRunning()

        let testText = "Swift is a powerful programming language developed by Apple."
        let params: [MessagePackValue] = [
            .map([
                "text": .string(testText),
                "style": .string("concise")
            ])
        ]

        let response = try await sendRequest(method: "mlx.summarize", params: params)

        if response.isSuccess {
            // MLX RPC is implemented - verify response
            if case .string(let summary) = response.result {
                XCTAssertFalse(summary.isEmpty, "Summary should not be empty")
            } else if case .map(let result) = response.result {
                XCTAssertNotNil(result["summary"], "Result should contain summary")
            } else {
                XCTFail("Expected string or map result")
            }
        } else {
            if case .string(let error) = response.error {
                if error.contains("Unknown method") {
                    throw XCTSkip("MLX RPC not yet implemented (shade-ahf.7)")
                }
            }
            XCTFail("Unexpected error: \(response.error)")
        }
    }

    // MARK: - Helpers

    private func skipIfServerNotRunning() throws {
        let fileExists = FileManager.default.fileExists(atPath: socketPath)
        if !fileExists {
            throw XCTSkip("Shade server not running - skipping integration test")
        }
    }

    private func sendRequest(method: String, params: [MessagePackValue]) async throws -> MsgpackRpc.Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "MLXIntegrationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"
            ])
        }
        defer { close(fd) }

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
            throw NSError(domain: "MLXIntegrationTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "connect() failed: \(String(cString: strerror(errno)))"
            ])
        }

        let request = MsgpackRpc.Request(msgid: 1, method: method, params: params)
        let requestData = request.encode()

        _ = requestData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }

        // Longer timeout for MLX operations (model loading can be slow)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 30000) // 30 second timeout

        guard pollResult > 0 else {
            throw NSError(domain: "MLXIntegrationTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: pollResult == 0 ? "Timeout waiting for MLX response" : "poll() failed"
            ])
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(fd, &buffer, buffer.count)

        guard bytesRead > 0 else {
            throw NSError(domain: "MLXIntegrationTests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "No response received"
            ])
        }

        let responseData = Data(bytes: buffer, count: bytesRead)
        let result = MsgpackRpc.decodeAll(from: responseData)

        guard let message = result.messages.first, case .response(let response) = message else {
            throw NSError(domain: "MLXIntegrationTests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response format"
            ])
        }

        return response
    }
}
