import AppKit

/// A floating panel for the shade terminal
/// Behaves like a scratchpad - floats above other windows, doesn't steal focus
class ShadePanel: NSPanel {

    // MARK: - Properties

    /// Screen mode for positioning (injected from AppConfig)
    var screenMode: ScreenMode = .primary

    // MARK: - Initialization

    init(contentRect: NSRect, screenMode: ScreenMode = .primary) {
        self.screenMode = screenMode
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

    /// Get the target screen based on screen mode
    /// - .primary: Always use primary screen (the one with menu bar)
    /// - .focused: Use screen with keyboard focus
    private var targetScreen: NSScreen? {
        switch screenMode {
        case .primary:
            // Primary screen is always first in the array (the one with menu bar)
            return NSScreen.screens.first
        case .focused:
            // NSScreen.main is the screen containing the window with keyboard focus
            return NSScreen.main ?? NSScreen.screens.first
        }
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

    /// Position panel at screen edge for sidebar mode
    /// - Parameters:
    ///   - mode: The sidebar mode (.sidebarLeft or .sidebarRight)
    ///   - width: Width as percentage (0.0-1.0) or pixels (> 1.0)
    func positionSidebar(mode: PanelMode, width: Double) {
        guard let screen = targetScreen else {
            Log.warn("No screen found for sidebar positioning")
            return
        }

        let screenFrame = screen.visibleFrame

        // Calculate sidebar width
        let sidebarWidth: CGFloat
        if width <= 1.0 {
            sidebarWidth = screenFrame.width * CGFloat(width)
        } else {
            sidebarWidth = CGFloat(width)
        }

        // Full screen height
        let sidebarHeight = screenFrame.height

        // Position based on mode
        let x: CGFloat
        switch mode {
        case .sidebarLeft:
            x = screenFrame.origin.x
        case .sidebarRight:
            x = screenFrame.origin.x + screenFrame.width - sidebarWidth
        case .floating:
            // Shouldn't call this for floating mode, but handle gracefully
            positionCentered()
            return
        }

        let y = screenFrame.origin.y

        // Set frame (position + size in one call)
        let newFrame = NSRect(x: x, y: y, width: sidebarWidth, height: sidebarHeight)
        setFrame(newFrame, display: true)

        Log.debug("Positioned panel as \(mode.rawValue) at (\(Int(x)), \(Int(y))) size \(Int(sidebarWidth))x\(Int(sidebarHeight))")
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

    /// Resize panel to specified dimensions and re-center
    /// - Parameters:
    ///   - width: Width as percentage (0.0-1.0) or pixels (> 1.0)
    ///   - height: Height as percentage (0.0-1.0) or pixels (> 1.0)
    func resize(width: Double, height: Double) {
        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame

        let newWidth: CGFloat
        if width <= 1.0 {
            newWidth = screenFrame.width * CGFloat(width)
        } else {
            newWidth = CGFloat(width)
        }

        let newHeight: CGFloat
        if height <= 1.0 {
            newHeight = screenFrame.height * CGFloat(height)
        } else {
            newHeight = CGFloat(height)
        }

        let newSize = NSSize(width: newWidth, height: newHeight)
        setContentSize(newSize)

        // Re-center after resize
        positionCentered()

        Log.debug("Resized panel to \(Int(newWidth))x\(Int(newHeight))")
    }
}
