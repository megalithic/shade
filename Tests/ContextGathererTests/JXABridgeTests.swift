import XCTest
@testable import ContextGatherer

final class JXABridgeTests: XCTestCase {

    // MARK: - BrowserContext Tests

    func testBrowserContext_Init_SetsAllProperties() {
        let context = BrowserContext(
            url: "https://example.com",
            title: "Example",
            selection: "selected text"
        )

        XCTAssertEqual(context.url, "https://example.com")
        XCTAssertEqual(context.title, "Example")
        XCTAssertEqual(context.selection, "selected text")
    }

    func testBrowserContext_Init_HandlesNilValues() {
        let context = BrowserContext(url: nil, title: nil, selection: nil)

        XCTAssertNil(context.url)
        XCTAssertNil(context.title)
        XCTAssertNil(context.selection)
    }

    func testBrowserContext_HasContent_TrueWithURL() {
        let context = BrowserContext(url: "https://example.com", title: nil, selection: nil)
        XCTAssertTrue(context.hasContent)
    }

    func testBrowserContext_HasContent_TrueWithTitle() {
        let context = BrowserContext(url: nil, title: "Some Title", selection: nil)
        XCTAssertTrue(context.hasContent)
    }

    func testBrowserContext_HasContent_TrueWithSelection() {
        let context = BrowserContext(url: nil, title: nil, selection: "selected")
        XCTAssertTrue(context.hasContent)
    }

    func testBrowserContext_HasContent_FalseWithEmptySelection() {
        let context = BrowserContext(url: nil, title: nil, selection: "")
        XCTAssertFalse(context.hasContent)
    }

    func testBrowserContext_HasContent_FalseWithAllNil() {
        let context = BrowserContext(url: nil, title: nil, selection: nil)
        XCTAssertFalse(context.hasContent)
    }

    func testBrowserContext_Equatable() {
        let context1 = BrowserContext(url: "https://example.com", title: "Test", selection: nil)
        let context2 = BrowserContext(url: "https://example.com", title: "Test", selection: nil)
        let context3 = BrowserContext(url: "https://other.com", title: "Test", selection: nil)

        XCTAssertEqual(context1, context2)
        XCTAssertNotEqual(context1, context3)
    }

    // MARK: - JXABridge Singleton Tests

    func testJXABridge_Shared_ReturnsSameInstance() {
        let instance1 = JXABridge.shared
        let instance2 = JXABridge.shared
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Unknown Bundle ID Tests

    func testGetBrowserContext_UnknownBundleID_ReturnsNil() async {
        let context = await JXABridge.shared.getBrowserContext(
            forBundleID: "com.example.unknown",
            timeout: .milliseconds(100)
        )
        XCTAssertNil(context)
    }

    func testGetBrowserContext_NonBrowserBundleID_ReturnsNil() async {
        // Ghostty is a terminal, not a browser
        let context = await JXABridge.shared.getBrowserContext(
            forBundleID: "com.mitchellh.ghostty",
            timeout: .milliseconds(100)
        )
        XCTAssertNil(context)
    }

    // MARK: - BrowserInfo Integration Tests

    func testGetBrowserContext_ForBrowserInfo_KnownBrowsersHaveInfo() {
        // Verify all browsers in the JXA info map are properly configured
        let knownBrowsers = [
            "com.apple.Safari",
            "com.brave.Browser",
            "com.brave.Browser.nightly",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
        ]

        for bundleID in knownBrowsers {
            let info = AppTypeDetector.browserInfo(for: bundleID)
            XCTAssertNotNil(info, "Expected BrowserInfo for \(bundleID)")
            XCTAssertFalse(info!.jxaName.isEmpty, "JXA name should not be empty for \(bundleID)")
        }
    }

    func testGetBrowserContext_Safari_IsSafariFlag() {
        let safariInfo = AppTypeDetector.browserInfo(for: "com.apple.Safari")
        XCTAssertNotNil(safariInfo)
        XCTAssertTrue(safariInfo!.isSafari)

        // Chrome should NOT have isSafari flag
        let chromeInfo = AppTypeDetector.browserInfo(for: "com.google.Chrome")
        XCTAssertNotNil(chromeInfo)
        XCTAssertFalse(chromeInfo!.isSafari)
    }

    // MARK: - Timeout Tests

    func testGetBrowserContext_Timeout_ReturnsNilQuickly() async {
        // Test with a browser that's not running - should timeout quickly
        let start = Date()
        let context = await JXABridge.shared.getBrowserContext(
            for: BrowserInfo(jxaName: "NonExistent Browser That Will Never Exist"),
            timeout: .milliseconds(500)
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(context)
        // Should complete within roughly the timeout period (give some slack for process overhead)
        XCTAssertLessThan(elapsed, 2.0, "Should timeout within reasonable time")
    }

    // MARK: - Script Content Tests (indirectly via behavior)

    // Note: We can't directly test the private script generation methods,
    // but we can verify the JXA bridge handles different browser types correctly
    // by checking that known browsers don't crash and unknown ones return nil.

    func testGetBrowserContext_FirefoxInfo_HasCorrectName() {
        let info = AppTypeDetector.browserInfo(for: "org.mozilla.firefox")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Firefox")
        XCTAssertFalse(info?.isSafari ?? true)
    }

    func testGetBrowserContext_ArcInfo_HasCorrectName() {
        let info = AppTypeDetector.browserInfo(for: "company.thebrowser.Browser")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Arc")
    }

    func testGetBrowserContext_EdgeInfo_HasCorrectName() {
        let info = AppTypeDetector.browserInfo(for: "com.microsoft.edgemac")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Microsoft Edge")
    }

    // MARK: - Sendable Conformance Tests

    func testBrowserContext_IsSendable() {
        // This test verifies at compile time that BrowserContext is Sendable
        let context = BrowserContext(url: "https://test.com", title: "Test", selection: nil)

        Task {
            // If BrowserContext weren't Sendable, this would fail to compile
            let _ = context.url
        }
    }

    func testJXABridge_IsSendable() {
        // Verify JXABridge can be used across actor boundaries
        let bridge = JXABridge.shared

        Task {
            // If JXABridge weren't Sendable, this would fail to compile
            let _ = await bridge.getBrowserContext(forBundleID: "test", timeout: .milliseconds(1))
        }
    }
}

// MARK: - Live Integration Tests

/// These tests require actual browsers to be running and are skipped by default.
/// Run them manually with: swift test --filter JXABridgeLiveTests
final class JXABridgeLiveTests: XCTestCase {

    // Skip these tests in CI - they require real browsers
    override func setUpWithError() throws {
        // Check if we're in CI environment
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping live tests in CI environment")
        }
    }

    /// Test with Brave Browser (if running)
    /// Run manually: swift test --filter testLive_BraveBrowser
    func testLive_BraveBrowser() async throws {
        let bundleID = "com.brave.Browser.nightly"

        // Check if Brave is running
        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier == bundleID }) else {
            throw XCTSkip("Brave Browser Nightly is not running")
        }

        let context = await JXABridge.shared.getBrowserContext(
            forBundleID: bundleID,
            timeout: .seconds(5)
        )

        XCTAssertNotNil(context, "Should get context from running Brave")
        // URL should be present if browser is open
        if context?.url != nil {
            XCTAssertTrue(context!.url!.hasPrefix("http"), "URL should start with http")
        }
    }

    /// Test with Safari (if running)
    /// Run manually: swift test --filter testLive_Safari
    func testLive_Safari() async throws {
        let bundleID = "com.apple.Safari"

        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier == bundleID }) else {
            throw XCTSkip("Safari is not running")
        }

        let context = await JXABridge.shared.getBrowserContext(
            forBundleID: bundleID,
            timeout: .seconds(5)
        )

        XCTAssertNotNil(context, "Should get context from running Safari")
    }

    /// Test with Chrome (if running)
    /// Run manually: swift test --filter testLive_Chrome
    func testLive_Chrome() async throws {
        let bundleID = "com.google.Chrome"

        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier == bundleID }) else {
            throw XCTSkip("Chrome is not running")
        }

        let context = await JXABridge.shared.getBrowserContext(
            forBundleID: bundleID,
            timeout: .seconds(5)
        )

        XCTAssertNotNil(context, "Should get context from running Chrome")
    }
}
