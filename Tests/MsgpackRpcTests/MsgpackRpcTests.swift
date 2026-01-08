import XCTest
import MessagePack
@testable import MsgpackRpc

final class MsgpackRpcTests: XCTestCase {
    
    // MARK: - Request Encoding Tests
    
    func testRequestEncode() throws {
        let request = MsgpackRpc.Request(
            msgid: 42,
            method: "nvim_eval",
            params: [.string("1+1")]
        )
        
        let data = request.encode()
        let (value, _) = try unpack(data)
        
        guard let array = value.arrayValue else {
            XCTFail("Encoded request should be an array")
            return
        }
        
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array[0].uint64Value, 0) // Request type
        XCTAssertEqual(array[1].uint64Value, 42) // msgid
        XCTAssertEqual(array[2].stringValue, "nvim_eval") // method
        XCTAssertEqual(array[3].arrayValue?.first?.stringValue, "1+1") // params
    }
    
    func testRequestEncodeEmptyParams() throws {
        let request = MsgpackRpc.Request(
            msgid: 1,
            method: "nvim_get_current_buf",
            params: []
        )
        
        let data = request.encode()
        let (value, _) = try unpack(data)
        
        guard let array = value.arrayValue else {
            XCTFail("Encoded request should be an array")
            return
        }
        
        XCTAssertEqual(array[3].arrayValue?.count, 0)
    }
    
    // MARK: - Response Encoding Tests
    
    func testResponseEncodeSuccess() throws {
        let response = MsgpackRpc.Response(
            msgid: 42,
            error: .nil,
            result: .string("hello")
        )
        
        let data = response.encode()
        let (value, _) = try unpack(data)
        
        guard let array = value.arrayValue else {
            XCTFail("Encoded response should be an array")
            return
        }
        
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array[0].uint64Value, 1) // Response type
        XCTAssertEqual(array[1].uint64Value, 42) // msgid
        XCTAssertTrue(array[2].isNil) // error
        XCTAssertEqual(array[3].stringValue, "hello") // result
    }
    
    func testResponseEncodeError() throws {
        let response = MsgpackRpc.Response(
            msgid: 42,
            error: .array([.int(1), .string("Something went wrong")]),
            result: .nil
        )
        
        let data = response.encode()
        let (value, _) = try unpack(data)
        
        guard let array = value.arrayValue else {
            XCTFail("Encoded response should be an array")
            return
        }
        
        XCTAssertFalse(array[2].isNil) // error is not nil
        XCTAssertTrue(array[3].isNil) // result is nil
    }
    
    // MARK: - Notification Encoding Tests
    
    func testNotificationEncode() throws {
        let notification = MsgpackRpc.Notification(
            method: "nvim_buf_lines_event",
            params: [.int(1), .int(100)]
        )
        
        let data = notification.encode()
        let (value, _) = try unpack(data)
        
        guard let array = value.arrayValue else {
            XCTFail("Encoded notification should be an array")
            return
        }
        
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0].uint64Value, 2) // Notification type
        XCTAssertEqual(array[1].stringValue, "nvim_buf_lines_event") // method
        XCTAssertEqual(array[2].arrayValue?.count, 2) // params
    }
    
    // MARK: - Decode Tests
    
    func testDecodeRequest() throws {
        let value: MessagePackValue = .array([
            .uint(0), // request
            .uint(123),
            .string("nvim_command"),
            .array([.string("echo 'hi'")])
        ])
        
        let message = try MsgpackRpc.decode(value)
        
        guard case .request(let request) = message else {
            XCTFail("Should decode as request")
            return
        }
        
        XCTAssertEqual(request.msgid, 123)
        XCTAssertEqual(request.method, "nvim_command")
        XCTAssertEqual(request.params.count, 1)
        XCTAssertEqual(request.params[0].stringValue, "echo 'hi'")
    }
    
    func testDecodeResponse() throws {
        let value: MessagePackValue = .array([
            .uint(1), // response
            .uint(456),
            .nil,
            .int(42)
        ])
        
        let message = try MsgpackRpc.decode(value)
        
        guard case .response(let response) = message else {
            XCTFail("Should decode as response")
            return
        }
        
        XCTAssertEqual(response.msgid, 456)
        XCTAssertTrue(response.isSuccess)
        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.intResult, 42)
    }
    
    func testDecodeResponseWithError() throws {
        let value: MessagePackValue = .array([
            .uint(1), // response
            .uint(789),
            .array([.int(1), .string("E492: Not an editor command")]),
            .nil
        ])
        
        let message = try MsgpackRpc.decode(value)
        
        guard case .response(let response) = message else {
            XCTFail("Should decode as response")
            return
        }
        
        XCTAssertEqual(response.msgid, 789)
        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.isSuccess)
        XCTAssertEqual(response.errorMessage, "E492: Not an editor command")
    }
    
    func testDecodeNotification() throws {
        let value: MessagePackValue = .array([
            .uint(2), // notification
            .string("redraw"),
            .array([.string("flush")])
        ])
        
        let message = try MsgpackRpc.decode(value)
        
        guard case .notification(let notification) = message else {
            XCTFail("Should decode as notification")
            return
        }
        
        XCTAssertEqual(notification.method, "redraw")
        XCTAssertEqual(notification.params.count, 1)
    }
    
    // MARK: - Decode Error Tests
    
    func testDecodeNotAnArray() {
        let value: MessagePackValue = .string("not an array")
        
        XCTAssertThrowsError(try MsgpackRpc.decode(value)) { error in
            guard let decodeError = error as? MsgpackRpc.DecodeError else {
                XCTFail("Should throw DecodeError")
                return
            }
            guard case .notAnArray = decodeError else {
                XCTFail("Should be notAnArray error")
                return
            }
        }
    }
    
    func testDecodeEmptyArray() {
        let value: MessagePackValue = .array([])
        
        XCTAssertThrowsError(try MsgpackRpc.decode(value)) { error in
            guard let decodeError = error as? MsgpackRpc.DecodeError else {
                XCTFail("Should throw DecodeError")
                return
            }
            guard case .emptyArray = decodeError else {
                XCTFail("Should be emptyArray error")
                return
            }
        }
    }
    
    func testDecodeInvalidMessageType() {
        let value: MessagePackValue = .array([.uint(99)])
        
        XCTAssertThrowsError(try MsgpackRpc.decode(value)) { error in
            guard let decodeError = error as? MsgpackRpc.DecodeError else {
                XCTFail("Should throw DecodeError")
                return
            }
            guard case .invalidMessageType(99) = decodeError else {
                XCTFail("Should be invalidMessageType(99) error")
                return
            }
        }
    }
    
    func testDecodeMalformedRequest() {
        // Missing params
        let value: MessagePackValue = .array([
            .uint(0),
            .uint(1),
            .string("method")
            // missing params
        ])
        
        XCTAssertThrowsError(try MsgpackRpc.decode(value)) { error in
            guard let decodeError = error as? MsgpackRpc.DecodeError else {
                XCTFail("Should throw DecodeError")
                return
            }
            guard case .malformedRequest = decodeError else {
                XCTFail("Should be malformedRequest error")
                return
            }
        }
    }
    
    // MARK: - Response Convenience Tests
    
    func testResponseStringResult() {
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .string("test"))
        XCTAssertEqual(response.stringResult, "test")
        XCTAssertNil(response.intResult)
    }
    
    func testResponseIntResult() {
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .int(42))
        XCTAssertEqual(response.intResult, 42)
        XCTAssertNil(response.stringResult)
    }
    
    func testResponseBoolResult() {
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .bool(true))
        XCTAssertEqual(response.boolResult, true)
    }
    
    func testResponseArrayResult() {
        let response = MsgpackRpc.Response(msgid: 1, error: .nil, result: .array([.int(1), .int(2)]))
        XCTAssertEqual(response.arrayResult?.count, 2)
    }
    
    func testEmptyResponse() {
        let response = MsgpackRpc.Response.empty(42)
        XCTAssertEqual(response.msgid, 42)
        XCTAssertTrue(response.isSuccess)
        XCTAssertTrue(response.result.isNil)
    }
    
    // MARK: - Stream Decoding Tests
    
    func testDecodeAllSingleMessage() throws {
        let request = MsgpackRpc.Request(msgid: 1, method: "test", params: [])
        let data = request.encode()
        
        let result = MsgpackRpc.decodeAll(from: data)
        
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertTrue(result.remainder.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        
        guard case .request(let decoded) = result.messages[0] else {
            XCTFail("Should decode as request")
            return
        }
        XCTAssertEqual(decoded.msgid, 1)
    }
    
    func testDecodeAllMultipleMessages() throws {
        let request1 = MsgpackRpc.Request(msgid: 1, method: "test1", params: [])
        let request2 = MsgpackRpc.Request(msgid: 2, method: "test2", params: [])
        var data = request1.encode()
        data.append(request2.encode())
        
        let result = MsgpackRpc.decodeAll(from: data)
        
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.remainder.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }
    
    func testDecodeAllPartialMessage() throws {
        let request = MsgpackRpc.Request(msgid: 1, method: "test", params: [])
        var data = request.encode()
        
        // Append partial data for next message
        let partial = Data([0x94, 0x00, 0x01]) // Start of msgpack array
        data.append(partial)
        
        let result = MsgpackRpc.decodeAll(from: data)
        
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.remainder.count, partial.count)
        XCTAssertTrue(result.errors.isEmpty)
    }
    
    func testDecodeAllEmptyData() {
        let result = MsgpackRpc.decodeAll(from: Data())
        
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertTrue(result.remainder.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }
    
    // MARK: - Round-Trip Tests
    
    func testRequestRoundTrip() throws {
        let original = MsgpackRpc.Request(
            msgid: 12345,
            method: "nvim_buf_get_lines",
            params: [.int(0), .int(0), .int(-1), .bool(false)]
        )
        
        let data = original.encode()
        let (value, _) = try unpack(data)
        let message = try MsgpackRpc.decode(value)
        
        guard case .request(let decoded) = message else {
            XCTFail("Should decode as request")
            return
        }
        
        XCTAssertEqual(decoded.msgid, original.msgid)
        XCTAssertEqual(decoded.method, original.method)
        XCTAssertEqual(decoded.params.count, original.params.count)
    }
    
    func testResponseRoundTrip() throws {
        let original = MsgpackRpc.Response(
            msgid: 54321,
            error: .nil,
            result: .array([.string("line 1"), .string("line 2")])
        )
        
        let data = original.encode()
        let (value, _) = try unpack(data)
        let message = try MsgpackRpc.decode(value)
        
        guard case .response(let decoded) = message else {
            XCTFail("Should decode as response")
            return
        }
        
        XCTAssertEqual(decoded.msgid, original.msgid)
        XCTAssertTrue(decoded.isSuccess)
        XCTAssertEqual(decoded.arrayResult?.count, 2)
    }
    
    func testNotificationRoundTrip() throws {
        let original = MsgpackRpc.Notification(
            method: "nvim_buf_lines_event",
            params: [.int(1), .int(100), .int(0), .int(1), .array([.string("new line")]), .bool(false)]
        )
        
        let data = original.encode()
        let (value, _) = try unpack(data)
        let message = try MsgpackRpc.decode(value)
        
        guard case .notification(let decoded) = message else {
            XCTFail("Should decode as notification")
            return
        }
        
        XCTAssertEqual(decoded.method, original.method)
        XCTAssertEqual(decoded.params.count, original.params.count)
    }
}
