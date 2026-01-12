import Foundation

/// Protocol for logging abstraction
/// Allows ShadeCore to be used in tests with mock logging
public protocol ShadeLogger {
    func debug(_ message: String)
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

/// Default no-op logger for testing
public struct NullLogger: ShadeLogger {
    public init() {}
    public func debug(_ message: String) {}
    public func info(_ message: String) {}
    public func warn(_ message: String) {}
    public func error(_ message: String) {}
}

/// Print-based logger for debugging
public struct PrintLogger: ShadeLogger {
    public init() {}
    public func debug(_ message: String) { print("[DEBUG] \(message)") }
    public func info(_ message: String) { print("[INFO] \(message)") }
    public func warn(_ message: String) { print("[WARN] \(message)") }
    public func error(_ message: String) { print("[ERROR] \(message)") }
}

/// Global logger instance - can be swapped for testing
public var shadeLogger: ShadeLogger = NullLogger()
