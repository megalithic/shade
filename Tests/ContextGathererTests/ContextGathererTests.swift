import XCTest
import AppKit
@testable import ContextGatherer

final class ContextGathererTests: XCTestCase {

    // MARK: - GatheredContext Tests

    func testGatheredContext_Init_SetsAllProperties() {
        let context = GatheredContext(
            appType: "browser",
            appName: "Brave Browser",
            bundleID: "com.brave.Browser",
            windowTitle: "GitHub",
            url: "https://github.com",
            filePath: nil,
            filetype: nil,
            selection: "selected text",
            detectedLanguage: "swift",
            line: nil,
            col: nil,
            timestamp: "2026-01-08T12:00:00Z"
        )

        XCTAssertEqual(context.appType, "browser")
        XCTAssertEqual(context.appName, "Brave Browser")
        XCTAssertEqual(context.bundleID, "com.brave.Browser")
        XCTAssertEqual(context.windowTitle, "GitHub")
        XCTAssertEqual(context.url, "https://github.com")
        XCTAssertNil(context.filePath)
        XCTAssertNil(context.filetype)
        XCTAssertEqual(context.selection, "selected text")
        XCTAssertEqual(context.detectedLanguage, "swift")
        XCTAssertNil(context.line)
        XCTAssertNil(context.col)
        XCTAssertEqual(context.timestamp, "2026-01-08T12:00:00Z")
    }

    func testGatheredContext_HasContent_TrueWithSelection() {
        let context = GatheredContext(selection: "some text")
        XCTAssertTrue(context.hasContent)
    }

    func testGatheredContext_HasContent_TrueWithURL() {
        let context = GatheredContext(url: "https://example.com")
        XCTAssertTrue(context.hasContent)
    }

    func testGatheredContext_HasContent_TrueWithFilePath() {
        let context = GatheredContext(filePath: "/path/to/file.swift")
        XCTAssertTrue(context.hasContent)
    }

    func testGatheredContext_HasContent_TrueWithWindowTitle() {
        let context = GatheredContext(windowTitle: "Some Window")
        XCTAssertTrue(context.hasContent)
    }

    func testGatheredContext_HasContent_FalseWhenEmpty() {
        let context = GatheredContext()
        XCTAssertFalse(context.hasContent)
    }

    func testGatheredContext_Equatable() {
        let context1 = GatheredContext(appType: "browser", url: "https://example.com")
        let context2 = GatheredContext(appType: "browser", url: "https://example.com")
        let context3 = GatheredContext(appType: "terminal", url: nil)

        XCTAssertEqual(context1, context2)
        XCTAssertNotEqual(context1, context3)
    }

    func testGatheredContext_Codable_RoundTrip() throws {
        let original = GatheredContext(
            appType: "browser",
            appName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Apple",
            url: "https://apple.com",
            filePath: nil,
            filetype: nil,
            selection: "some selected text",
            detectedLanguage: "html",
            line: nil,
            col: nil,
            timestamp: "2026-01-08T12:00:00Z"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(GatheredContext.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testGatheredContext_Codable_JSONFormat() throws {
        let context = GatheredContext(
            appType: "neovim",
            appName: "Ghostty",
            bundleID: "com.mitchellh.ghostty",
            windowTitle: "nvim",
            filePath: "/path/to/file.swift",
            filetype: "swift",
            selection: "func test()",
            line: 42,
            col: 5
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(context)
        let json = String(data: data, encoding: .utf8)!

        // Decode it back and verify values match
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GatheredContext.self, from: data)

        XCTAssertEqual(decoded.appType, "neovim")
        XCTAssertEqual(decoded.filePath, "/path/to/file.swift")
        XCTAssertEqual(decoded.line, 42)
        XCTAssertEqual(decoded.col, 5)

        // Just verify it's valid JSON
        XCTAssertFalse(json.isEmpty)
    }

    // MARK: - ContextGatherer Singleton

    func testContextGatherer_Shared_ReturnsSameInstance() {
        let instance1 = ContextGatherer.shared
        let instance2 = ContextGatherer.shared
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Integration with AppTypeDetector

    func testGatheredContext_AppType_MatchesDetectorTypes() {
        // Verify all AppType cases can be stored in GatheredContext
        let types = AppType.allCases

        for appType in types {
            let context = GatheredContext(appType: appType.rawValue)
            XCTAssertEqual(context.appType, appType.rawValue)
        }
    }
}

// Note: MockAccessibilityProvider is defined in AccessibilityHelperTests.swift
// and is used by these tests as well.

// MARK: - Live Integration Tests

/// These tests require actual apps to be running and are skipped by default.
/// Run them manually with: swift test --filter ContextGathererLiveTests
final class ContextGathererLiveTests: XCTestCase {

    override func setUpWithError() throws {
        // Skip in CI environment
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping live tests in CI environment")
        }
    }

    /// Test gathering context from the current frontmost app
    func testLive_GatherFromFrontmostApp() async throws {
        let context = await ContextGatherer.shared.gather()

        // Should at least have app info
        XCTAssertNotNil(context.appName)
        XCTAssertNotNil(context.appType)
        XCTAssertNotNil(context.timestamp)

        print("Live context gathered:")
        print("  App: \(context.appName ?? "nil")")
        print("  Type: \(context.appType ?? "nil")")
        print("  Window: \(context.windowTitle ?? "nil")")
        print("  URL: \(context.url ?? "nil")")
        print("  Selection: \(context.selection?.prefix(50) ?? "nil")")
        print("  Language: \(context.detectedLanguage ?? "nil")")
    }

    /// Test gathering from Brave Browser (if running)
    func testLive_GatherFromBrave() async throws {
        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier?.contains("brave") == true }) else {
            throw XCTSkip("Brave Browser is not running")
        }

        // This test would need to switch to Brave first, which is disruptive
        // Just verify we can gather without crashing
        let context = await ContextGatherer.shared.gather()
        XCTAssertNotNil(context.timestamp)
    }
}
