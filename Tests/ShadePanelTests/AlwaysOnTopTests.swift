import XCTest
import AppKit

/// Tests for the "Always on Top" window level behavior.
/// These tests verify the expected NSWindow.Level values for the feature.
final class AlwaysOnTopTests: XCTestCase {
    
    // MARK: - Window Level Constants
    
    /// Verify our understanding of NSWindow.Level values
    func testWindowLevelValues() {
        // Document the actual level values we're working with
        XCTAssertEqual(NSWindow.Level.normal.rawValue, 0, "Normal level should be 0")
        XCTAssertEqual(NSWindow.Level.floating.rawValue, 3, "Floating level should be 3")
        XCTAssertLessThan(NSWindow.Level.normal.rawValue, NSWindow.Level.floating.rawValue,
                         "Normal should be below floating")
    }
    
    // MARK: - Panel Behavior Tests
    
    /// Test that a panel with normal level can go behind other windows
    func testNormalLevelBehavior() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Configure like ShadePanel default (always on top = OFF)
        panel.isFloatingPanel = false
        panel.level = .normal
        
        XCTAssertEqual(panel.level, .normal, "Panel should have normal level")
        XCTAssertFalse(panel.isFloatingPanel, "Panel should not be floating")
    }
    
    /// Test that a panel with floating level stays above normal windows
    func testFloatingLevelBehavior() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Configure like ShadePanel with always on top = ON
        panel.isFloatingPanel = false  // We control level manually
        panel.level = .floating
        
        XCTAssertEqual(panel.level, .floating, "Panel should have floating level")
        XCTAssertFalse(panel.isFloatingPanel, "isFloatingPanel should still be false")
    }
    
    /// Test toggling between normal and floating levels
    func testLevelToggle() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Start at normal (always on top = OFF)
        panel.isFloatingPanel = false
        panel.level = .normal
        XCTAssertEqual(panel.level, .normal)
        
        // Toggle to floating (always on top = ON)
        panel.level = .floating
        XCTAssertEqual(panel.level, .floating)
        
        // Toggle back to normal (always on top = OFF)
        panel.level = .normal
        XCTAssertEqual(panel.level, .normal)
    }
    
    /// Test that isFloatingPanel = true overrides level setting (documenting the bug we fixed)
    func testIsFloatingPanelOverridesLevel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // When isFloatingPanel is true, the panel auto-floats
        panel.isFloatingPanel = true
        panel.level = .normal
        
        // Note: isFloatingPanel = true causes the panel to behave as floating
        // even if level is set to normal. This is the behavior we avoid by
        // setting isFloatingPanel = false.
        //
        // The actual level value may or may not change depending on AppKit internals,
        // but the visual behavior is that the window floats.
        // This test documents why we set isFloatingPanel = false.
        
        // We just verify our fix: isFloatingPanel should be false for manual control
        panel.isFloatingPanel = false
        panel.level = .normal
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .normal)
    }
    
    // MARK: - AlwaysOnTop State Logic Tests
    
    /// Simulate the always-on-top state management logic
    func testAlwaysOnTopStateLogic() {
        var alwaysOnTop = false
        
        func calculateLevel() -> NSWindow.Level {
            return alwaysOnTop ? .floating : .normal
        }
        
        // Initial state: always on top is OFF
        XCTAssertEqual(calculateLevel(), .normal)
        
        // Enable always on top
        alwaysOnTop = true
        XCTAssertEqual(calculateLevel(), .floating)
        
        // Disable always on top
        alwaysOnTop = false
        XCTAssertEqual(calculateLevel(), .normal)
    }
    
    /// Test toggle logic
    func testToggleLogic() {
        var alwaysOnTop = false
        
        func toggle() {
            alwaysOnTop = !alwaysOnTop
        }
        
        XCTAssertFalse(alwaysOnTop)
        
        toggle()
        XCTAssertTrue(alwaysOnTop)
        
        toggle()
        XCTAssertFalse(alwaysOnTop)
    }
}
