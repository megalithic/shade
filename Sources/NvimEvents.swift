import Foundation
@preconcurrency import MessagePack

/// Nvim event subscription and routing system.
///
/// Handles subscribing to nvim events and routing them to registered handlers.
/// Works with `NvimSocketManager` to process incoming notifications.
///
/// ## Event Types
///
/// **RPC Notifications** (from nvim_buf_attach, autocmds, etc.):
/// - `nvim_buf_lines_event`: Buffer lines changed
/// - `nvim_buf_changedtick_event`: Buffer changedtick updated (no text change)
/// - `nvim_buf_detach_event`: Buffer detached
///
/// **Custom Events** (via nvim_exec_autocmds or rpcnotify):
/// - Any custom event name you define
///
/// ## Usage
///
/// ```swift
/// let events = NvimEvents()
///
/// // Subscribe to buffer changes
/// let sub = events.subscribe(to: "nvim_buf_lines_event") { params in
///     print("Buffer changed: \(params)")
/// }
///
/// // Process incoming messages from socket manager
/// for await message in socketManager.messageStream {
///     events.process(message)
/// }
///
/// // Unsubscribe when done
/// events.unsubscribe(sub)
/// ```
actor NvimEvents {
    
    // MARK: - Types
    
    /// Unique identifier for a subscription
    struct SubscriptionID: Hashable, Sendable {
        let id: UInt64
    }
    
    /// A registered event handler
    private struct Subscription {
        let id: SubscriptionID
        let eventName: String
        let handler: @Sendable ([MessagePackValue]) -> Void
    }
    
    /// Predefined nvim event names
    enum EventName {
        /// Buffer lines changed (from nvim_buf_attach)
        static let bufLinesEvent = "nvim_buf_lines_event"
        /// Buffer changedtick updated without text change
        static let bufChangedTickEvent = "nvim_buf_changedtick_event"
        /// Buffer was detached
        static let bufDetachEvent = "nvim_buf_detach_event"
        /// Redraw events (UI protocol)
        static let redraw = "redraw"
    }
    
    // MARK: - Properties
    
    /// All registered subscriptions, keyed by event name for fast lookup
    private var subscriptions: [String: [Subscription]] = [:]
    
    /// Next subscription ID
    private var nextSubscriptionID: UInt64 = 1
    
    /// Whether to log events (for debugging)
    var loggingEnabled: Bool = false
    
    // MARK: - Subscription Management
    
    /// Subscribe to a specific event type
    /// - Parameters:
    ///   - eventName: The event name to subscribe to (e.g., "nvim_buf_lines_event")
    ///   - handler: Callback invoked when the event is received. Params are the event parameters.
    /// - Returns: Subscription ID for later unsubscription
    func subscribe(
        to eventName: String,
        handler: @escaping @Sendable ([MessagePackValue]) -> Void
    ) -> SubscriptionID {
        let subID = SubscriptionID(id: nextSubscriptionID)
        nextSubscriptionID += 1
        
        let subscription = Subscription(id: subID, eventName: eventName, handler: handler)
        
        if subscriptions[eventName] == nil {
            subscriptions[eventName] = []
        }
        subscriptions[eventName]?.append(subscription)
        
        Log.debug("NvimEvents: Subscribed to '\(eventName)' (id: \(subID.id))")
        return subID
    }
    
    /// Subscribe to multiple event types with the same handler
    /// - Parameters:
    ///   - eventNames: Array of event names to subscribe to
    ///   - handler: Callback invoked when any of the events is received
    /// - Returns: Array of subscription IDs
    func subscribe(
        to eventNames: [String],
        handler: @escaping @Sendable (String, [MessagePackValue]) -> Void
    ) -> [SubscriptionID] {
        return eventNames.map { eventName in
            subscribe(to: eventName) { params in
                handler(eventName, params)
            }
        }
    }
    
    /// Unsubscribe from events
    /// - Parameter subscriptionID: The subscription ID returned from subscribe()
    func unsubscribe(_ subscriptionID: SubscriptionID) {
        for (eventName, subs) in subscriptions {
            if let index = subs.firstIndex(where: { $0.id == subscriptionID }) {
                subscriptions[eventName]?.remove(at: index)
                Log.debug("NvimEvents: Unsubscribed from '\(eventName)' (id: \(subscriptionID.id))")
                
                // Clean up empty arrays
                if subscriptions[eventName]?.isEmpty == true {
                    subscriptions.removeValue(forKey: eventName)
                }
                return
            }
        }
    }
    
    /// Unsubscribe from multiple subscriptions
    /// - Parameter subscriptionIDs: Array of subscription IDs to remove
    func unsubscribe(_ subscriptionIDs: [SubscriptionID]) {
        for subID in subscriptionIDs {
            unsubscribe(subID)
        }
    }
    
    /// Remove all subscriptions for a specific event
    /// - Parameter eventName: The event name to clear
    func unsubscribeAll(from eventName: String) {
        if let count = subscriptions[eventName]?.count {
            subscriptions.removeValue(forKey: eventName)
            Log.debug("NvimEvents: Removed all \(count) subscriptions from '\(eventName)'")
        }
    }
    
    /// Remove all subscriptions
    func unsubscribeAll() {
        let totalCount = subscriptions.values.reduce(0) { $0 + $1.count }
        subscriptions.removeAll()
        Log.debug("NvimEvents: Removed all \(totalCount) subscriptions")
    }
    
    // MARK: - Event Processing
    
    /// Process a message from the socket manager
    /// - Parameter message: The decoded msgpack-rpc message
    func process(_ message: MsgpackRpc.Message) {
        switch message {
        case .notification(let notification):
            dispatch(eventName: notification.method, params: notification.params)
            
        case .request(let request):
            // Requests from nvim could be treated as events too
            // (though typically they need a response)
            if loggingEnabled {
                Log.debug("NvimEvents: Received request '\(request.method)' (not dispatched as event)")
            }
            
        case .response:
            // Responses are handled by the socket manager's pending requests
            break
        }
    }
    
    /// Dispatch an event to all subscribers
    /// - Parameters:
    ///   - eventName: The event name
    ///   - params: Event parameters
    private func dispatch(eventName: String, params: [MessagePackValue]) {
        guard let subs = subscriptions[eventName], !subs.isEmpty else {
            if loggingEnabled {
                Log.debug("NvimEvents: No subscribers for '\(eventName)'")
            }
            return
        }
        
        if loggingEnabled {
            Log.debug("NvimEvents: Dispatching '\(eventName)' to \(subs.count) subscriber(s)")
        }
        
        for sub in subs {
            sub.handler(params)
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Check if there are any subscriptions for an event
    /// - Parameter eventName: The event name to check
    /// - Returns: True if there are active subscriptions
    func hasSubscribers(for eventName: String) -> Bool {
        return subscriptions[eventName]?.isEmpty == false
    }
    
    /// Get the count of active subscriptions
    var subscriptionCount: Int {
        subscriptions.values.reduce(0) { $0 + $1.count }
    }
    
    /// Get all event names with active subscriptions
    var subscribedEvents: [String] {
        Array(subscriptions.keys)
    }
}

// MARK: - Buffer Event Helpers

extension NvimEvents {
    
    /// Parsed buffer lines event
    struct BufferLinesEvent: Sendable {
        let buffer: Int64
        let changedtick: Int64?
        let firstLine: Int64
        let lastLine: Int64
        let lineData: [String]
        let more: Bool
    }
    
    /// Parsed buffer changedtick event
    struct BufferChangedTickEvent: Sendable {
        let buffer: Int64
        let changedtick: Int64
    }
    
    /// Parsed buffer detach event
    struct BufferDetachEvent: Sendable {
        let buffer: Int64
    }
    
    /// Subscribe to buffer line changes with parsed event data
    /// - Parameter handler: Callback with parsed BufferLinesEvent
    /// - Returns: Subscription ID
    func subscribeToBufferLines(
        handler: @escaping @Sendable (BufferLinesEvent) -> Void
    ) -> SubscriptionID {
        return subscribe(to: EventName.bufLinesEvent) { params in
            guard let event = Self.parseBufferLinesEvent(params) else {
                Log.error("NvimEvents: Failed to parse buffer lines event")
                return
            }
            handler(event)
        }
    }
    
    /// Subscribe to buffer changedtick events with parsed event data
    /// - Parameter handler: Callback with parsed BufferChangedTickEvent
    /// - Returns: Subscription ID
    func subscribeToBufferChangedTick(
        handler: @escaping @Sendable (BufferChangedTickEvent) -> Void
    ) -> SubscriptionID {
        return subscribe(to: EventName.bufChangedTickEvent) { params in
            guard let event = Self.parseBufferChangedTickEvent(params) else {
                Log.error("NvimEvents: Failed to parse buffer changedtick event")
                return
            }
            handler(event)
        }
    }
    
    /// Subscribe to buffer detach events with parsed event data
    /// - Parameter handler: Callback with parsed BufferDetachEvent
    /// - Returns: Subscription ID
    func subscribeToBufferDetach(
        handler: @escaping @Sendable (BufferDetachEvent) -> Void
    ) -> SubscriptionID {
        return subscribe(to: EventName.bufDetachEvent) { params in
            guard let event = Self.parseBufferDetachEvent(params) else {
                Log.error("NvimEvents: Failed to parse buffer detach event")
                return
            }
            handler(event)
        }
    }
    
    // MARK: - Event Parsing
    
    /// Parse nvim_buf_lines_event parameters
    /// Format: [buf, changedtick, firstline, lastline, linedata, more]
    private static func parseBufferLinesEvent(_ params: [MessagePackValue]) -> BufferLinesEvent? {
        guard params.count >= 6 else { return nil }
        
        guard let buffer = params[0].int64Value,
              let firstLine = params[2].int64Value,
              let lastLine = params[3].int64Value else {
            return nil
        }
        
        // changedtick can be nil for screen-only changes
        let changedtick = params[1].int64Value
        
        // linedata is an array of strings
        let lineData: [String]
        if let lines = params[4].arrayValue {
            lineData = lines.compactMap { $0.stringValue }
        } else {
            lineData = []
        }
        
        let more = params[5].boolValue ?? false
        
        return BufferLinesEvent(
            buffer: buffer,
            changedtick: changedtick,
            firstLine: firstLine,
            lastLine: lastLine,
            lineData: lineData,
            more: more
        )
    }
    
    /// Parse nvim_buf_changedtick_event parameters
    /// Format: [buf, changedtick]
    private static func parseBufferChangedTickEvent(_ params: [MessagePackValue]) -> BufferChangedTickEvent? {
        guard params.count >= 2,
              let buffer = params[0].int64Value,
              let changedtick = params[1].int64Value else {
            return nil
        }
        
        return BufferChangedTickEvent(buffer: buffer, changedtick: changedtick)
    }
    
    /// Parse nvim_buf_detach_event parameters
    /// Format: [buf]
    private static func parseBufferDetachEvent(_ params: [MessagePackValue]) -> BufferDetachEvent? {
        guard params.count >= 1,
              let buffer = params[0].int64Value else {
            return nil
        }
        
        return BufferDetachEvent(buffer: buffer)
    }
}
