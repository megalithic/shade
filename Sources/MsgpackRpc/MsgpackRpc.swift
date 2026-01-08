import Foundation
@preconcurrency import MessagePack

/// Msgpack-RPC protocol implementation for nvim communication.
///
/// Protocol spec: https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md
///
/// Message types:
/// - Request:      [0, msgid, method, params]
/// - Response:     [1, msgid, error, result]
/// - Notification: [2, method, params]
public enum MsgpackRpc {
    
    // MARK: - Message Types
    
    /// Message type identifiers per msgpack-rpc spec
    public enum MessageType: UInt64 {
        case request = 0
        case response = 1
        case notification = 2
    }
    
    /// A parsed msgpack-rpc message
    public enum Message: Sendable {
        case request(Request)
        case response(Response)
        case notification(Notification)
    }
    
    /// Request message: client -> server
    public struct Request: Sendable {
        public let msgid: UInt32
        public let method: String
        public let params: [MessagePackValue]
        
        public init(msgid: UInt32, method: String, params: [MessagePackValue]) {
            self.msgid = msgid
            self.method = method
            self.params = params
        }
        
        /// Encode to msgpack data
        public func encode() -> Data {
            let message: MessagePackValue = .array([
                .uint(UInt64(MessageType.request.rawValue)),
                .uint(UInt64(msgid)),
                .string(method),
                .array(params)
            ])
            return pack(message)
        }
    }
    
    /// Response message: server -> client
    public struct Response: Sendable {
        public let msgid: UInt32
        public let error: MessagePackValue
        public let result: MessagePackValue
        
        public var isSuccess: Bool { error.isNil }
        public var isError: Bool { !isSuccess }
        
        public init(msgid: UInt32, error: MessagePackValue, result: MessagePackValue) {
            self.msgid = msgid
            self.error = error
            self.result = result
        }
        
        /// Create an empty/nil response (used for timeouts, cancellation)
        public static func empty(_ msgid: UInt32) -> Response {
            Response(msgid: msgid, error: .nil, result: .nil)
        }
        
        /// Encode to msgpack data (for sending responses to nvim requests)
        public func encode() -> Data {
            let message: MessagePackValue = .array([
                .uint(UInt64(MessageType.response.rawValue)),
                .uint(UInt64(msgid)),
                error,
                result
            ])
            return pack(message)
        }
    }
    
    /// Notification message: either direction, no response expected
    public struct Notification: Sendable {
        public let method: String
        public let params: [MessagePackValue]
        
        public init(method: String, params: [MessagePackValue]) {
            self.method = method
            self.params = params
        }
        
        /// Encode to msgpack data
        public func encode() -> Data {
            let message: MessagePackValue = .array([
                .uint(UInt64(MessageType.notification.rawValue)),
                .string(method),
                .array(params)
            ])
            return pack(message)
        }
    }
    
    // MARK: - Decoding
    
    /// Errors during message decoding
    public enum DecodeError: Error, LocalizedError {
        case notAnArray
        case emptyArray
        case invalidMessageType(UInt64)
        case malformedRequest(String)
        case malformedResponse(String)
        case malformedNotification(String)
        
        public var errorDescription: String? {
            switch self {
            case .notAnArray:
                return "Message is not an array"
            case .emptyArray:
                return "Message array is empty"
            case .invalidMessageType(let type):
                return "Invalid message type: \(type)"
            case .malformedRequest(let reason):
                return "Malformed request: \(reason)"
            case .malformedResponse(let reason):
                return "Malformed response: \(reason)"
            case .malformedNotification(let reason):
                return "Malformed notification: \(reason)"
            }
        }
    }
    
    /// Decode a MessagePackValue into a typed Message
    /// - Parameter value: The unpacked msgpack value
    /// - Returns: A typed Message
    /// - Throws: DecodeError if the message format is invalid
    public static func decode(_ value: MessagePackValue) throws -> Message {
        guard let array = value.arrayValue else {
            throw DecodeError.notAnArray
        }
        
        guard !array.isEmpty else {
            throw DecodeError.emptyArray
        }
        
        guard let rawType = array[0].uint64Value else {
            throw DecodeError.invalidMessageType(0)
        }
        
        guard let type = MessageType(rawValue: rawType) else {
            throw DecodeError.invalidMessageType(rawType)
        }
        
        switch type {
        case .request:
            return .request(try decodeRequest(array))
        case .response:
            return .response(try decodeResponse(array))
        case .notification:
            return .notification(try decodeNotification(array))
        }
    }
    
    /// Decode a request message array
    private static func decodeRequest(_ array: [MessagePackValue]) throws -> Request {
        // [0, msgid, method, params]
        guard array.count == 4 else {
            throw DecodeError.malformedRequest("expected 4 elements, got \(array.count)")
        }
        
        guard let msgid = array[1].uint64Value else {
            throw DecodeError.malformedRequest("msgid is not a uint")
        }
        
        guard let method = array[2].stringValue else {
            throw DecodeError.malformedRequest("method is not a string")
        }
        
        guard let params = array[3].arrayValue else {
            throw DecodeError.malformedRequest("params is not an array")
        }
        
        return Request(msgid: UInt32(msgid), method: method, params: params)
    }
    
    /// Decode a response message array
    private static func decodeResponse(_ array: [MessagePackValue]) throws -> Response {
        // [1, msgid, error, result]
        guard array.count == 4 else {
            throw DecodeError.malformedResponse("expected 4 elements, got \(array.count)")
        }
        
        guard let msgid = array[1].uint64Value else {
            throw DecodeError.malformedResponse("msgid is not a uint")
        }
        
        // error and result can be any type (including nil)
        return Response(msgid: UInt32(msgid), error: array[2], result: array[3])
    }
    
    /// Decode a notification message array
    private static func decodeNotification(_ array: [MessagePackValue]) throws -> Notification {
        // [2, method, params]
        guard array.count == 3 else {
            throw DecodeError.malformedNotification("expected 3 elements, got \(array.count)")
        }
        
        guard let method = array[1].stringValue else {
            throw DecodeError.malformedNotification("method is not a string")
        }
        
        guard let params = array[2].arrayValue else {
            throw DecodeError.malformedNotification("params is not an array")
        }
        
        return Notification(method: method, params: params)
    }
    
    // MARK: - Stream Decoding
    
    /// Result of attempting to decode from a data buffer
    public struct DecodeResult {
        /// Successfully decoded messages
        public let messages: [Message]
        /// Remaining data (incomplete message)
        public let remainder: Data
        /// Any decode errors encountered (non-fatal, logged)
        public let errors: [Error]
        
        public init(messages: [Message], remainder: Data, errors: [Error]) {
            self.messages = messages
            self.remainder = remainder
            self.errors = errors
        }
    }
    
    /// Decode all complete messages from a data buffer
    /// - Parameter data: Raw data buffer (may contain multiple messages or partial messages)
    /// - Returns: Decoded messages and any remaining data
    public static func decodeAll(from data: Data) -> DecodeResult {
        var messages: [Message] = []
        var errors: [Error] = []
        var remainder = data
        
        while !remainder.isEmpty {
            do {
                let (value, rest) = try unpack(remainder)
                remainder = rest
                
                do {
                    let message = try decode(value)
                    messages.append(message)
                } catch {
                    // Decode error - log but continue
                    errors.append(error)
                }
            } catch MessagePackError.insufficientData {
                // Incomplete message - return remainder for next read
                break
            } catch {
                // Unpack error - data is corrupted, clear buffer
                errors.append(error)
                remainder.removeAll()
                break
            }
        }
        
        return DecodeResult(messages: messages, remainder: remainder, errors: errors)
    }
}

// MARK: - Convenience Extensions

extension MsgpackRpc.Response {
    /// Extract result as a string, if possible
    public var stringResult: String? {
        result.stringValue
    }
    
    /// Extract result as an integer, if possible
    public var intResult: Int64? {
        result.int64Value
    }
    
    /// Extract result as a boolean, if possible
    public var boolResult: Bool? {
        result.boolValue
    }
    
    /// Extract result as an array, if possible
    public var arrayResult: [MessagePackValue]? {
        result.arrayValue
    }
    
    /// Extract error message as a string, if present
    public var errorMessage: String? {
        if isError {
            // nvim errors are typically [type, message] arrays
            if let arr = error.arrayValue, arr.count >= 2 {
                return arr[1].stringValue
            }
            return error.stringValue ?? String(describing: error)
        }
        return nil
    }
}
