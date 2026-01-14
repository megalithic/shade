import AppKit

// MARK: - Focus Border View

/// Custom NSView that draws a border stroke for focus indication
/// Used in a child window to render on top of Metal content
class FocusBorderView: NSView {
    let config: FocusBorderConfig

    init(frame: NSRect, config: FocusBorderConfig) {
        self.config = config
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Inset by half the stroke width so the stroke doesn't clip
        let inset = CGFloat(config.width) / 2
        let borderRect = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath(
            roundedRect: borderRect,
            xRadius: CGFloat(config.cornerRadius),
            yRadius: CGFloat(config.cornerRadius)
        )
        path.lineWidth = CGFloat(config.width)

        config.parsedColor().setStroke()
        path.stroke()
    }
}

/// A floating panel for the shade terminal
/// Behaves like a scratchpad - floats above other windows, doesn't steal focus
class ShadePanel: NSPanel {

    // MARK: - Properties

    /// Screen mode for positioning (injected from AppConfig)
    var screenMode: ScreenMode = .primary

    /// Focus border configuration (nil = disabled)
    var focusBorderConfig: FocusBorderConfig?

    /// The border layer for focus indication
    private var borderLayer: CALayer?

    /// Visual effect view wrapping the content (for vibrancy and border support)
    private var visualEffectView: NSVisualEffectView?

    // MARK: - Initialization

    init(contentRect: NSRect, screenMode: ScreenMode = .primary) {
        self.screenMode = screenMode
        // Style mask for a floating, non-activating panel
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .resizable,
            .fullSizeContentView,   // Content extends into titlebar area (no gap)
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

    /// Show the panel
    /// - Parameter skipPositioning: If true, don't reposition (used for sidebar mode where position is set beforehand)
    func show(skipPositioning: Bool = false) {
        Log.debug("Show called (skipPositioning: \(skipPositioning))")

        // Position before showing (unless caller already positioned, e.g., sidebar mode)
        if !skipPositioning {
            positionCentered()
        }

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

    // MARK: - Focus Border

    /// Configure focus border with the given settings
    /// Call this after setting up the content view
    func configureFocusBorder(config: FocusBorderConfig?) {
        Log.debug("configureFocusBorder called: config=\(config != nil ? "present" : "nil"), enabled=\(config?.enabled ?? false)")
        self.focusBorderConfig = config

        guard let config = config, config.enabled else {
            Log.debug("Focus border disabled or no config")
            // Remove existing border if disabled
            borderLayer?.removeFromSuperlayer()
            borderLayer = nil
            visualEffectView?.removeFromSuperview()
            visualEffectView = nil
            return
        }

        Log.debug("Setting up focus border: width=\(config.width), color=\(config.color), contentView=\(contentView != nil)")

        // Set up the visual effect view if not already present
        if visualEffectView == nil, let existingContent = contentView {
            setupVisualEffectWrapper(for: existingContent, config: config)
        }

        // Set up border layer
        setupBorderLayer(config: config)

        // Register for key window notifications
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKeyForBorder),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKeyForBorder),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        Log.debug("Configured focus border: width=\(config.width), color=\(config.color), radius=\(config.cornerRadius)")
    }

    /// Wrap existing content in NSVisualEffectView for vibrancy and border support
    private func setupVisualEffectWrapper(for existingContent: NSView, config: FocusBorderConfig) {
        let visualEffect = NSVisualEffectView(frame: existingContent.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true

        // Apply corner radius to visual effect view
        if config.cornerRadius > 0 {
            visualEffect.layer?.cornerRadius = CGFloat(config.cornerRadius)
            visualEffect.layer?.masksToBounds = true
        }

        self.visualEffectView = visualEffect

        // Note: We don't reparent the existing content view here
        // The terminal view should be added as a subview by the caller
        // This just prepares the visual effect layer for border rendering
    }

    /// Set up the CALayer for border rendering
    /// Uses a child window to ensure the border renders on top of Metal content
    private func setupBorderLayer(config: FocusBorderConfig) {
        // Remove existing border window
        borderWindow?.orderOut(nil)
        borderWindow = nil

        // Create a child window for the border (guaranteed to render on top of Metal)
        let borderWin = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        borderWin.isOpaque = false
        borderWin.backgroundColor = .clear
        borderWin.ignoresMouseEvents = true
        borderWin.level = level  // Same level as parent
        borderWin.hasShadow = false

        // Create border view
        let borderView = FocusBorderView(frame: borderWin.contentView!.bounds, config: config)
        borderView.autoresizingMask = [.width, .height]
        borderWin.contentView = borderView

        // Make it a child window
        addChildWindow(borderWin, ordered: .above)

        self.borderWindow = borderWin
        self.borderView = borderView

        // Initially hidden
        borderView.alphaValue = 0

        Log.debug("Border window setup: frame=\(frame), color=\(config.color)")
    }

    /// Child window for border rendering (above Metal content)
    private var borderWindow: NSWindow?

    /// The border view inside the child window
    private var borderView: FocusBorderView?

    /// Update border window frame when main window resizes
    func updateBorderFrame() {
        borderWindow?.setFrame(frame, display: true)
        borderView?.frame = borderWindow?.contentView?.bounds ?? .zero
        borderView?.needsDisplay = true
    }

    @objc private func windowDidBecomeKeyForBorder(_ notification: Notification) {
        showFocusBorder()
    }

    @objc private func windowDidResignKeyForBorder(_ notification: Notification) {
        hideFocusBorder()
    }

    /// Show the focus border (animate if configured)
    func showFocusBorder() {
        guard let config = focusBorderConfig, config.enabled, let borderView = borderView else { return }

        // Update border frame in case window was resized
        updateBorderFrame()

        if config.animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = config.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                borderView.animator().alphaValue = 1.0
            }
        } else {
            borderView.alphaValue = 1.0
        }

        Log.debug("Focus border shown")
    }

    /// Hide the focus border (animate if configured)
    func hideFocusBorder() {
        guard let config = focusBorderConfig, config.enabled, let borderView = borderView else { return }

        if config.animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = config.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                borderView.animator().alphaValue = 0.0
            }
        } else {
            borderView.alphaValue = 0.0
        }

        Log.debug("Focus border hidden")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
