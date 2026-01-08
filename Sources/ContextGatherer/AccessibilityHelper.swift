import ApplicationServices
import AppKit
import Foundation
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "io.shade", category: "ContextGatherer")

// MARK: - Protocol for Testability

/// Protocol for accessibility operations, enabling mock implementations in tests
public protocol AccessibilityProviding {
    /// Get the currently focused UI element
    func getFocusedElement() -> AXUIElement?

    /// Get selected text from an element
    func getSelectedText(from element: AXUIElement) -> String?

    /// Get a string attribute from an element
    func getStringAttribute(_ attribute: String, from element: AXUIElement) -> String?

    /// Get the window title for an application
    func getWindowTitle(for app: NSRunningApplication) -> String?

    /// Get the document URL from the focused window (browsers expose this via AXDocument)
    func getDocumentURL(for app: NSRunningApplication) -> String?

    /// Check if accessibility permissions are granted
    func isAccessibilityTrusted() -> Bool

    /// Get the frontmost application
    func getFrontmostApp() -> NSRunningApplication?
}

// MARK: - Live Implementation

/// Native macOS Accessibility API helper for context gathering
/// Uses AXUIElement to query focused elements, selected text, and window info
public final class AccessibilityHelper: AccessibilityProviding {

    public static let shared = AccessibilityHelper()

    private init() {}

    // MARK: - AccessibilityProviding

    public func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success else {
            logger.debug("Failed to get focused element: \(result.rawValue)")
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    public func getSelectedText(from element: AXUIElement) -> String? {
        var selectedText: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard result == .success,
              let text = selectedText as? String,
              !text.isEmpty else {
            return nil
        }

        // Strip ANSI escape codes that may leak from terminal apps
        return text.strippingANSIEscapeCodes()
    }

    public func getStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard result == .success, let stringValue = value as? String else {
            return nil
        }

        return stringValue
    }

    public func getWindowTitle(for app: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Try focused window first
        if let title = getWindowTitleFromFocusedWindow(appElement) {
            return title
        }

        // Fallback to main window
        return getWindowTitleFromMainWindow(appElement)
    }

    public func getDocumentURL(for app: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard result == .success, let window = focusedWindow else {
            return nil
        }

        // AXDocument attribute contains the URL for browsers
        return getStringAttribute(kAXDocumentAttribute as String, from: window as! AXUIElement)
    }

    public func isAccessibilityTrusted() -> Bool {
        // Don't prompt - just check
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func getFrontmostApp() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Private Helpers

    private func getWindowTitleFromFocusedWindow(_ appElement: AXUIElement) -> String? {
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard result == .success, let window = focusedWindow else {
            return nil
        }

        return getStringAttribute(kAXTitleAttribute as String, from: window as! AXUIElement)
    }

    private func getWindowTitleFromMainWindow(_ appElement: AXUIElement) -> String? {
        var mainWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            &mainWindow
        )

        guard result == .success, let window = mainWindow else {
            return nil
        }

        return getStringAttribute(kAXTitleAttribute as String, from: window as! AXUIElement)
    }
}

// MARK: - Convenience Context Snapshot

/// Snapshot of accessibility context from the frontmost app
public struct AccessibilitySnapshot {
    public let bundleID: String?
    public let appName: String?
    public let windowTitle: String?
    public let selectedText: String?
    public let documentURL: String?
    public let timestamp: Date

    /// Whether any meaningful context was captured
    public var hasContent: Bool {
        selectedText != nil || windowTitle != nil || documentURL != nil
    }

    public init(
        bundleID: String?,
        appName: String?,
        windowTitle: String?,
        selectedText: String?,
        documentURL: String?,
        timestamp: Date
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.documentURL = documentURL
        self.timestamp = timestamp
    }
}

extension AccessibilityHelper {

    /// Capture a snapshot of the current accessibility context
    /// This is a convenience method that gathers all available info in one call
    public func captureSnapshot() -> AccessibilitySnapshot? {
        guard isAccessibilityTrusted() else {
            logger.warning("Accessibility not trusted")
            return nil
        }

        guard let app = getFrontmostApp() else {
            logger.warning("No frontmost app")
            return nil
        }

        let focusedElement = getFocusedElement()
        let selectedText: String?
        if let element = focusedElement {
            selectedText = getSelectedText(from: element)
        } else {
            selectedText = nil
        }

        return AccessibilitySnapshot(
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            windowTitle: getWindowTitle(for: app),
            selectedText: selectedText,
            documentURL: getDocumentURL(for: app),
            timestamp: Date()
        )
    }
}

// MARK: - String Extension for ANSI Stripping

extension String {

    /// Strip ANSI escape codes from the string
    /// These can leak from terminal apps when queried via Accessibility API
    public func strippingANSIEscapeCodes() -> String {
        // ANSI escape code pattern: ESC [ ... m (and other sequences)
        // ESC is \u{001B} or \x1B
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }

        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
    }
}
