import AppKit

/// A floating panel for the shade terminal
/// Behaves like a scratchpad - floats above other windows, doesn't steal focus
class ShadePanel: NSPanel {

    // MARK: - Initialization

    init(contentRect: NSRect) {
        // Style mask for a floating, non-activating panel
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .resizable,
            .nonactivatingPanel,    // Don't activate app when clicking
            .utilityWindow          // Utility window styling
        ]

        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        configurePanel()
    }

    private func configurePanel() {
        // Panel behavior
        title = "shade"
        isFloatingPanel = true                    // Float above normal windows
        becomesKeyOnlyIfNeeded = true            // Only become key if needed
        hidesOnDeactivate = false                // Stay visible when app loses focus
        level = .floating                         // Floating window level
        collectionBehavior = [
            .canJoinAllSpaces,                   // Visible on all spaces
            .fullScreenAuxiliary                 // Can appear over fullscreen apps
        ]

        // Visual styling
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Hide window buttons (traffic lights)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Animation
        animationBehavior = .utilityWindow

        // Position centered on screen
        positionCentered()
    }

    // MARK: - Positioning

    /// Get the focused screen (where keyboard focus is)
    /// Falls back to primary if no focused screen
    private var targetScreen: NSScreen? {
        // NSScreen.main is the screen containing the window with keyboard focus
        // Falls back to primary screen (screens[0]) if none focused
        return NSScreen.main ?? NSScreen.screens.first
    }

    func positionAtTopCenter() {
        positionCentered()
    }

    func positionCentered() {
        // Use focused screen (where keyboard focus is)
        guard let screen = targetScreen else {
            Log.warn("No screen found")
            return
        }

        let screenFrame = screen.visibleFrame
        let panelWidth = frame.width
        let panelHeight = frame.height

        // Center both horizontally and vertically
        let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
        let y = screenFrame.origin.y + (screenFrame.height - panelHeight) / 2

        setFrameOrigin(NSPoint(x: x, y: y))
        Log.debug("Positioned panel centered at (\(Int(x)), \(Int(y)))")
    }

    // MARK: - Key Window Behavior

    // Allow the panel to become key (for keyboard input) even though it's non-activating
    override var canBecomeKey: Bool {
        return true
    }

    // Don't become main window
    override var canBecomeMain: Bool {
        return false
    }

    // MARK: - Toggle Visibility

    func toggle() {
        Log.debug("Toggle called, isVisible=\(isVisible)")
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        Log.debug("Show called")
        // Position before showing
        positionCentered()

        // Make visible and key
        makeKeyAndOrderFront(nil)

        // Activate the app to bring window to front
        NSApp.activate(ignoringOtherApps: true)

        // Request focus for the content view (terminal)
        if let terminalView = contentView {
            makeFirstResponder(terminalView)
        }
        Log.debug("Panel shown")
    }

    func hide() {
        Log.debug("Hide called")
        orderOut(nil)
        Log.debug("Panel hidden")
    }
}
