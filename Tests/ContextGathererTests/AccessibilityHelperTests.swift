import XCTest
import ApplicationServices
import AppKit
@testable import ContextGatherer

final class AccessibilityHelperTests: XCTestCase {

    // MARK: - ANSI Escape Code Stripping Tests

    func testStrippingANSIEscapeCodes_PlainText() {
        let input = "Hello, World!"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Hello, World!")
    }

    func testStrippingANSIEscapeCodes_ColorCodes() {
        // Red text: \x1B[31m ... \x1B[0m
        let input = "\u{001B}[31mError:\u{001B}[0m Something went wrong"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Error: Something went wrong")
    }

    func testStrippingANSIEscapeCodes_BoldAndColors() {
        // Bold: \x1B[1m, Green: \x1B[32m, Reset: \x1B[0m
        let input = "\u{001B}[1m\u{001B}[32mSuccess\u{001B}[0m: Operation completed"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Success: Operation completed")
    }

    func testStrippingANSIEscapeCodes_CursorMovement() {
        // Cursor up: \x1B[2A, Cursor right: \x1B[5C
        let input = "Line 1\u{001B}[2A\u{001B}[5CLine 2"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Line 1Line 2")
    }

    func testStrippingANSIEscapeCodes_256Color() {
        // 256-color: \x1B[38;5;82m (foreground color 82)
        let input = "\u{001B}[38;5;82mGreen text\u{001B}[0m"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Green text")
    }

    func testStrippingANSIEscapeCodes_TrueColor() {
        // True color (24-bit): \x1B[38;2;255;128;0m (RGB)
        let input = "\u{001B}[38;2;255;128;0mOrange\u{001B}[0m"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Orange")
    }

    func testStrippingANSIEscapeCodes_EmptyString() {
        let input = ""
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "")
    }

    func testStrippingANSIEscapeCodes_OnlyEscapeCodes() {
        let input = "\u{001B}[31m\u{001B}[0m"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "")
    }

    func testStrippingANSIEscapeCodes_MultipleCodesInSequence() {
        // Multiple formatting codes
        let input = "\u{001B}[1;4;31mBold underline red\u{001B}[0m normal"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "Bold underline red normal")
    }

    func testStrippingANSIEscapeCodes_PreservesNonANSIBrackets() {
        let input = "array[0] = value[1]"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "array[0] = value[1]")
    }

    func testStrippingANSIEscapeCodes_MixedContent() {
        let input = "prefix \u{001B}[32m[INFO]\u{001B}[0m message with [brackets]"
        XCTAssertEqual(input.strippingANSIEscapeCodes(), "prefix [INFO] message with [brackets]")
    }

    // MARK: - AccessibilitySnapshot Tests

    func testAccessibilitySnapshot_HasContent_WithSelection() {
        let snapshot = AccessibilitySnapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: nil,
            selectedText: "Some selected text",
            documentURL: nil,
            timestamp: Date()
        )
        XCTAssertTrue(snapshot.hasContent)
    }

    func testAccessibilitySnapshot_HasContent_WithWindowTitle() {
        let snapshot = AccessibilitySnapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: "Window Title",
            selectedText: nil,
            documentURL: nil,
            timestamp: Date()
        )
        XCTAssertTrue(snapshot.hasContent)
    }

    func testAccessibilitySnapshot_HasContent_WithDocumentURL() {
        let snapshot = AccessibilitySnapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: nil,
            selectedText: nil,
            documentURL: "https://example.com",
            timestamp: Date()
        )
        XCTAssertTrue(snapshot.hasContent)
    }

    func testAccessibilitySnapshot_HasContent_AllNil() {
        let snapshot = AccessibilitySnapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: nil,
            selectedText: nil,
            documentURL: nil,
            timestamp: Date()
        )
        XCTAssertFalse(snapshot.hasContent)
    }

    func testAccessibilitySnapshot_HasContent_AllPresent() {
        let snapshot = AccessibilitySnapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: "Window",
            selectedText: "Text",
            documentURL: "https://example.com",
            timestamp: Date()
        )
        XCTAssertTrue(snapshot.hasContent)
    }

    // MARK: - Mock-based Protocol Tests

    func testMockAccessibilityProvider_CanBeCreated() {
        let mock = MockAccessibilityProvider()
        XCTAssertNotNil(mock)
    }

    func testMockAccessibilityProvider_ReturnsConfiguredValues() {
        let mock = MockAccessibilityProvider()
        mock.mockSelectedText = "Test selection"
        mock.mockWindowTitle = "Test Window"
        mock.mockIsAccessibilityTrusted = true

        // These would normally require an AXUIElement, but we're just testing
        // that the mock infrastructure works
        XCTAssertEqual(mock.mockSelectedText, "Test selection")
        XCTAssertEqual(mock.mockWindowTitle, "Test Window")
        XCTAssertTrue(mock.isAccessibilityTrusted())
    }

    // MARK: - Live AccessibilityHelper Tests (require accessibility permissions)
    // These tests interact with the real system and may fail without permissions
    // They are useful for manual testing but may be skipped in CI

    func testAccessibilityHelper_IsAccessibilityTrusted_ReturnsBoolean() {
        // This just verifies the method runs without crashing
        // The actual return value depends on system permissions
        let result = AccessibilityHelper.shared.isAccessibilityTrusted()
        XCTAssertTrue(result == true || result == false) // Always true, but documents the test
    }

    func testAccessibilityHelper_GetFrontmostApp_ReturnsAppOrNil() {
        // Should return an app when running in a GUI context
        // May return nil in headless CI
        let app = AccessibilityHelper.shared.getFrontmostApp()
        // Just verify it doesn't crash - the result depends on the test environment
        if let app = app {
            XCTAssertNotNil(app.bundleIdentifier)
        }
    }
}

// MARK: - Mock Implementation for Testing

/// Mock implementation of AccessibilityProviding for unit tests
final class MockAccessibilityProvider: AccessibilityProviding {

    var mockFocusedElement: AXUIElement?
    var mockSelectedText: String?
    var mockWindowTitle: String?
    var mockDocumentURL: String?
    var mockIsAccessibilityTrusted: Bool = true
    var mockFrontmostApp: NSRunningApplication?

    // Track method calls for verification
    var getFocusedElementCallCount = 0
    var getSelectedTextCallCount = 0
    var getWindowTitleCallCount = 0
    var getDocumentURLCallCount = 0

    func getFocusedElement() -> AXUIElement? {
        getFocusedElementCallCount += 1
        return mockFocusedElement
    }

    func getSelectedText(from element: AXUIElement) -> String? {
        getSelectedTextCallCount += 1
        return mockSelectedText
    }

    func getStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        // Return based on attribute for flexibility
        let titleAttr: String = kAXTitleAttribute
        let docAttr: String = kAXDocumentAttribute
        let selAttr: String = kAXSelectedTextAttribute

        switch attribute {
        case titleAttr:
            return mockWindowTitle
        case docAttr:
            return mockDocumentURL
        case selAttr:
            return mockSelectedText
        default:
            return nil
        }
    }

    func getWindowTitle(for app: NSRunningApplication) -> String? {
        getWindowTitleCallCount += 1
        return mockWindowTitle
    }

    func getDocumentURL(for app: NSRunningApplication) -> String? {
        getDocumentURLCallCount += 1
        return mockDocumentURL
    }

    func isAccessibilityTrusted() -> Bool {
        return mockIsAccessibilityTrusted
    }

    func getFrontmostApp() -> NSRunningApplication? {
        return mockFrontmostApp
    }
}
