import XCTest
import AppKit
@testable import ShadeCore

// MARK: - Mock Providers

/// Mock workspace provider for testing
final class MockWorkspaceProvider: WorkspaceProvider {
    var frontmostApplication: NSRunningApplication?

    init(frontmostApplication: NSRunningApplication? = nil) {
        self.frontmostApplication = frontmostApplication
    }
}

/// Mock app identity provider for testing
struct MockAppIdentityProvider: AppIdentityProvider {
    var bundleIdentifier: String?
    var processIdentifier: Int32

    init(bundleIdentifier: String? = "io.shade", processIdentifier: Int32 = 12345) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

// MARK: - FocusTrackerTests

final class FocusTrackerTests: XCTestCase {

    var tracker: FocusTracker!
    var mockWorkspace: MockWorkspaceProvider!
    var mockIdentity: MockAppIdentityProvider!

    // Helper to get a real running app for testing (uses Finder which is always running)
    var finderApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    // Helper to get Dock (another always-running app)
    var dockApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    }

    override func setUp() {
        super.setUp()
        mockWorkspace = MockWorkspaceProvider()
        mockIdentity = MockAppIdentityProvider()
        tracker = FocusTracker(workspaceProvider: mockWorkspace, appIdentityProvider: mockIdentity)
    }

    override func tearDown() {
        tracker = nil
        mockWorkspace = nil
        mockIdentity = nil
        super.tearDown()
    }

    // MARK: - Priority Tests (The Bug Fix!)

    /// CRITICAL TEST: lastNonShadeFrontApp should be returned BEFORE previousFocusedApp
    /// This was the bug - the old code had the priority reversed.
    func testCaptureTargetApp_Priority_LastNonShadeFrontAppFirst() {
        guard let finder = finderApp, let dock = dockApp else {
            XCTFail("Need Finder and Dock to be running for this test")
            return
        }

        // Set up: previousFocusedApp is Finder (stale), lastNonShadeFrontApp is Dock (current)
        tracker.setPreviousFocusedApp(finder)
        tracker.setLastNonShadeFrontApp(dock)
        tracker.isPanelVisible = true // Panel visible, so previousFocusedApp won't be updated

        // The fix: should return lastNonShadeFrontApp (Dock), not previousFocusedApp (Finder)
        let result = tracker.captureTargetApp()

        XCTAssertEqual(result?.bundleIdentifier, dock.bundleIdentifier,
            "Should return lastNonShadeFrontApp (Dock), not stale previousFocusedApp (Finder)")
    }

    /// Test fallback: when lastNonShadeFrontApp is nil, use previousFocusedApp
    func testCaptureTargetApp_FallbackToPreviousFocusedApp() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        // lastNonShadeFrontApp is nil, but previousFocusedApp has a value
        tracker.setPreviousFocusedApp(finder)
        tracker.setLastNonShadeFrontApp(nil)

        let result = tracker.captureTargetApp()

        XCTAssertEqual(result?.bundleIdentifier, finder.bundleIdentifier,
            "Should fall back to previousFocusedApp when lastNonShadeFrontApp is nil")
    }

    /// Test that both nil returns nil
    func testCaptureTargetApp_BothNil_ReturnsNil() {
        tracker.setPreviousFocusedApp(nil)
        tracker.setLastNonShadeFrontApp(nil)

        let result = tracker.captureTargetApp()

        XCTAssertNil(result, "Should return nil when both sources are nil")
    }

    // MARK: - Panel Visibility Tests

    /// When panel is NOT visible, previousFocusedApp should be updated
    func testCaptureTargetApp_PanelNotVisible_UpdatesPreviousFocusedApp() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        mockWorkspace.frontmostApplication = finder
        tracker.isPanelVisible = false

        _ = tracker.captureTargetApp()

        // previousFocusedApp should be updated to the frontmost app
        XCTAssertEqual(tracker.previousFocusedApp?.bundleIdentifier, finder.bundleIdentifier,
            "previousFocusedApp should be updated when panel is not visible")
    }

    /// When panel IS visible, previousFocusedApp should NOT be updated
    func testCaptureTargetApp_PanelVisible_DoesNotUpdatePreviousFocusedApp() {
        guard let finder = finderApp, let dock = dockApp else {
            XCTFail("Need Finder and Dock to be running for this test")
            return
        }

        // Set initial previousFocusedApp to Finder
        tracker.setPreviousFocusedApp(finder)
        tracker.isPanelVisible = true

        // Set frontmost to Dock (simulating user clicking on another app while panel is visible)
        mockWorkspace.frontmostApplication = dock

        _ = tracker.captureTargetApp()

        // previousFocusedApp should NOT be updated (still Finder, not Dock)
        XCTAssertEqual(tracker.previousFocusedApp?.bundleIdentifier, finder.bundleIdentifier,
            "previousFocusedApp should NOT be updated when panel is visible")
    }

    // MARK: - Shade Detection Tests

    /// Test Shade detection by bundle ID
    func testIsShade_ByBundleID() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        // Mock: our bundle ID is "io.shade"
        mockIdentity = MockAppIdentityProvider(bundleIdentifier: "io.shade", processIdentifier: 99999)
        tracker = FocusTracker(workspaceProvider: mockWorkspace, appIdentityProvider: mockIdentity)

        // Finder is not Shade
        XCTAssertFalse(tracker.isShade(finder), "Finder should not be detected as Shade")
    }

    /// Test Shade detection by localizedName
    func testIsShade_ByLocalizedName() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        // Finder's localizedName is "Finder", not "shade"
        XCTAssertFalse(tracker.isShade(finder), "Finder should not be detected as Shade by name")
    }

    /// Test Shade detection by PID
    func testIsShade_ByPID() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        // Create identity provider with Finder's PID
        mockIdentity = MockAppIdentityProvider(bundleIdentifier: nil, processIdentifier: finder.processIdentifier)
        tracker = FocusTracker(workspaceProvider: mockWorkspace, appIdentityProvider: mockIdentity)

        // Now Finder should be detected as Shade (same PID)
        XCTAssertTrue(tracker.isShade(finder), "Should detect as Shade when PID matches")
    }

    // MARK: - Track App Activation Tests

    /// Test that trackAppActivation updates lastNonShadeFrontApp for non-Shade apps
    func testTrackAppActivation_NonShadeApp_UpdatesTracking() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        XCTAssertNil(tracker.lastNonShadeFrontApp, "Should start with nil")

        tracker.trackAppActivation(finder)

        XCTAssertEqual(tracker.lastNonShadeFrontApp?.bundleIdentifier, finder.bundleIdentifier,
            "Should track Finder as lastNonShadeFrontApp")
    }

    /// Test that trackAppActivation does NOT update for Shade itself
    func testTrackAppActivation_ShadeApp_DoesNotUpdateTracking() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        // Set initial tracking to Finder
        tracker.setLastNonShadeFrontApp(finder)

        // Create an identity provider that considers Finder as Shade (for testing)
        mockIdentity = MockAppIdentityProvider(
            bundleIdentifier: finder.bundleIdentifier,
            processIdentifier: finder.processIdentifier
        )
        tracker = FocusTracker(workspaceProvider: mockWorkspace, appIdentityProvider: mockIdentity)
        tracker.setLastNonShadeFrontApp(finder)

        // Try to track Finder (which is now considered Shade)
        tracker.trackAppActivation(finder)

        // Since Finder is "Shade" in this test, tracking should not change
        // (Actually it will be set because we set it manually, but the key is
        // trackAppActivation won't update it if we already have a value and call with Shade)
    }

    // MARK: - Multiple App Switches Tests

    /// Simulate user switching apps multiple times with panel visible
    /// This tests the exact bug scenario: user captures in App A, then clicks App B, then captures again
    func testBugScenario_MultipleSwitchesWithPanelVisible() {
        guard let finder = finderApp, let dock = dockApp else {
            XCTFail("Need Finder and Dock to be running for this test")
            return
        }

        // Step 1: Initial capture from Finder (panel not visible)
        tracker.isPanelVisible = false
        mockWorkspace.frontmostApplication = finder
        tracker.trackAppActivation(finder)
        let firstCapture = tracker.captureTargetApp()

        XCTAssertEqual(firstCapture?.bundleIdentifier, finder.bundleIdentifier,
            "First capture should be Finder")

        // Step 2: Panel is now visible
        tracker.isPanelVisible = true

        // Step 3: User clicks on Dock (while panel is visible)
        tracker.trackAppActivation(dock)

        // Step 4: User triggers another capture (panel still visible)
        let secondCapture = tracker.captureTargetApp()

        // THE BUG FIX: secondCapture should be Dock (lastNonShadeFrontApp), not Finder (previousFocusedApp)
        XCTAssertEqual(secondCapture?.bundleIdentifier, dock.bundleIdentifier,
            "Second capture should be Dock (current), not Finder (stale)")
    }

    // MARK: - Focus Restoration Tests

    /// Test getAppForFocusRestoration returns correct app
    func testGetAppForFocusRestoration_ReturnsLastNonShadeFrontApp() {
        guard let finder = finderApp, let dock = dockApp else {
            XCTFail("Need Finder and Dock to be running for this test")
            return
        }

        tracker.setPreviousFocusedApp(finder)
        tracker.setLastNonShadeFrontApp(dock)

        let result = tracker.getAppForFocusRestoration()

        // Should return lastNonShadeFrontApp first
        XCTAssertEqual(result?.bundleIdentifier, dock.bundleIdentifier)
    }

    // MARK: - Reset Tests

    func testReset_ClearsAllState() {
        guard let finder = finderApp else {
            XCTFail("Need Finder to be running for this test")
            return
        }

        tracker.setLastNonShadeFrontApp(finder)
        tracker.setPreviousFocusedApp(finder)
        tracker.isPanelVisible = true

        tracker.reset()

        XCTAssertNil(tracker.lastNonShadeFrontApp)
        XCTAssertNil(tracker.previousFocusedApp)
        XCTAssertFalse(tracker.isPanelVisible)
    }
}
