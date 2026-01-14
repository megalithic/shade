import AppKit

/// Manages the menubar status item with connection state indicators.
///
/// ## Icon States
/// - **Disconnected**: Ghost outline (template) - Shade running, nvim not connected
/// - **Connected**: Filled ghost with muted green tint - Connected to nvim
/// - **Editing Notes**: Filled ghost with muted aqua tint - Editing in $NOTES_HOME
/// - **Modified**: Same as above + small orange dot - Unsaved changes
///
/// Uses a "shade" ghost icon (thinner/lighter than Ghostty's ghost) from Phosphor Icons.
/// Everforest-inspired muted colors that work in both light and dark mode.
@MainActor
final class MenuBarManager {
    
    // MARK: - Types
    
    /// Current state of the menubar icon
    enum IconState: Equatable {
        case disconnected
        case connected
        case editingNotes
        case modified
    }
    
    // MARK: - Everforest Colors (muted variants)

    /// Muted Everforest-inspired palette
    /// These are desaturated to work well in the menubar without being garish
    private enum Colors {
        // Base grays (for disconnected state, works with template)
        static let disconnected = NSColor.secondaryLabelColor

        // Muted green - connected (Everforest green, desaturated)
        static let connected = NSColor(calibratedRed: 0.565, green: 0.675, blue: 0.510, alpha: 1.0) // #90AC82

        // Muted aqua/teal - editing notes (Everforest aqua, desaturated)
        static let editingNotes = NSColor(calibratedRed: 0.514, green: 0.647, blue: 0.596, alpha: 1.0) // #83A598

        // Muted orange/yellow - modified indicator (Everforest yellow, desaturated)
        static let modified = NSColor(calibratedRed: 0.816, green: 0.706, blue: 0.467, alpha: 1.0) // #D0B477

        // Default focused color (Everforest orange) - overridden by config if present
        static let focusedDefault = NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.35, alpha: 1.0) // #E68C59

        // Darker variants for light mode (auto-adjusted)
        static func adjusted(_ color: NSColor) -> NSColor {
            // NSAppearance handles this for us with template images
            // For non-template, we could check effectiveAppearance
            return color
        }
    }

    /// Get the focused stroke color from config, or use default
    private var focusedColor: NSColor {
        if let config = ShadeConfig.shared.window?.focusBorder {
            return config.parsedMenubarStrokeColor()
        }
        return Colors.focusedDefault
    }
    
    // MARK: - UserDefaults Keys

    private enum DefaultsKeys {
        static let autoTrackCompanion = "shade.autoTrackCompanion"
        static let autoResizeCompanion = "shade.autoResizeCompanion"
    }

    // MARK: - Properties

    /// The status item in the menubar
    private var statusItem: NSStatusItem?

    /// Current icon state
    private(set) var state: IconState = .disconnected

    /// Whether the panel is currently focused (overlays on top of other states)
    private(set) var isFocused: Bool = false

    /// The menu attached to the status item
    private var menu: NSMenu?

    /// Menu items for toggles (for updating checkmarks)
    private var autoTrackMenuItem: NSMenuItem?
    private var autoResizeMenuItem: NSMenuItem?

    /// Callback for toggle action
    var onToggle: (() -> Void)?

    /// Callback for daily note action
    var onDailyNote: (() -> Void)?

    /// Callback for new capture action
    var onNewCapture: (() -> Void)?

    /// Callback for quit action
    var onQuit: (() -> Void)?

    /// Callback when experimental settings change
    var onSettingsChanged: ((_ autoTrack: Bool, _ autoResize: Bool) -> Void)?

    // MARK: - Experimental Settings (persisted)

    /// Whether to auto-track the focused non-Shade app as potential companion
    var autoTrackCompanion: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.autoTrackCompanion) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKeys.autoTrackCompanion)
            autoTrackMenuItem?.state = newValue ? .on : .off
            notifySettingsChanged()
        }
    }

    /// Whether to auto-resize companion when Shade is in sidebar mode and focused
    var autoResizeCompanion: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.autoResizeCompanion) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKeys.autoResizeCompanion)
            autoResizeMenuItem?.state = newValue ? .on : .off
            notifySettingsChanged()
        }
    }

    private func notifySettingsChanged() {
        onSettingsChanged?(autoTrackCompanion, autoResizeCompanion)
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Setup
    
    /// Create and show the menubar item
    func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        
        // Create the menu
        setupMenu()
        
        // Set initial icon
        updateIcon(for: .disconnected)
        
        // Configure button
        if let button = statusItem.button {
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        Log.debug("MenuBarManager: Status item created")
    }
    
    /// Remove the menubar item
    func teardown() {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        Log.debug("MenuBarManager: Status item removed")
    }
    
    // MARK: - State Management
    
    /// Update the icon state
    func setState(_ newState: IconState) {
        guard newState != state else { return }
        state = newState
        updateIcon(for: newState, focused: isFocused)
        Log.debug("MenuBarManager: State changed to \(newState)")
    }

    /// Update the focused state (changes stroke color to orange when focused)
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateIcon(for: state, focused: focused)
        Log.debug("MenuBarManager: Focus changed to \(focused)")
    }
    
    // MARK: - Private Methods
    
    private func setupMenu() {
        let menu = NSMenu()

        // Toggle visibility
        let toggleItem = NSMenuItem(title: "Toggle Shade", action: #selector(handleToggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Note actions
        let dailyItem = NSMenuItem(title: "Open Daily Note", action: #selector(handleDailyNote), keyEquivalent: "")
        dailyItem.target = self
        menu.addItem(dailyItem)

        let captureItem = NSMenuItem(title: "New Capture", action: #selector(handleNewCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(NSMenuItem.separator())

        // Experimental settings section
        let settingsHeader = NSMenuItem(title: "Sidebar Experiments", action: nil, keyEquivalent: "")
        settingsHeader.isEnabled = false
        menu.addItem(settingsHeader)

        // Auto-track companion toggle
        let autoTrackItem = NSMenuItem(
            title: "Auto-track companion",
            action: #selector(handleAutoTrackToggle),
            keyEquivalent: ""
        )
        autoTrackItem.target = self
        autoTrackItem.state = autoTrackCompanion ? .on : .off
        autoTrackItem.toolTip = "Track focused app as potential companion for sidebar mode"
        menu.addItem(autoTrackItem)
        self.autoTrackMenuItem = autoTrackItem

        // Auto-resize companion toggle
        let autoResizeItem = NSMenuItem(
            title: "Auto-resize companion",
            action: #selector(handleAutoResizeToggle),
            keyEquivalent: ""
        )
        autoResizeItem.target = self
        autoResizeItem.state = autoResizeCompanion ? .on : .off
        autoResizeItem.toolTip = "Automatically resize companion when switching apps in sidebar mode"
        menu.addItem(autoResizeItem)
        self.autoResizeMenuItem = autoResizeItem

        menu.addItem(NSMenuItem.separator())

        // Status indicator (non-clickable)
        let statusItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 100 // Tag for updating later
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Shade", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        self.statusItem?.menu = menu
    }
    
    private func updateIcon(for state: IconState, focused: Bool = false) {
        guard let button = statusItem?.button else { return }

        let filled: Bool
        let tintColor: NSColor?
        let showBadge: Bool
        // Stroke color from config when focused (only affects outline/stroke rendering)
        let strokeColor: NSColor? = focused ? focusedColor : nil

        switch state {
        case .disconnected:
            filled = false
            tintColor = nil // Use template (adapts to light/dark)
            showBadge = false

        case .connected:
            filled = true
            tintColor = Colors.connected
            showBadge = false

        case .editingNotes:
            filled = true
            tintColor = Colors.editingNotes
            showBadge = false

        case .modified:
            filled = true
            tintColor = Colors.editingNotes
            showBadge = true
        }

        // Create the ghost icon (strokeColor overrides for outline when focused)
        button.image = createGhostIcon(filled: filled, tintColor: tintColor, showBadge: showBadge, strokeColor: strokeColor)
        
        // Update status text in menu
        updateStatusText(for: state)
    }
    
    /// Create the ghost "shade" icon
    /// Uses Phosphor Icons "ghost-thin" - a lighter, more ethereal ghost than Ghostty's
    /// - Parameters:
    ///   - filled: Whether to draw filled (solid) or outline (stroke)
    ///   - tintColor: Color for filled icons (nil = template/system)
    ///   - showBadge: Whether to show the modification badge
    ///   - strokeColor: Override color for stroke when focused (orange)
    private func createGhostIcon(filled: Bool, tintColor: NSColor?, showBadge: Bool, strokeColor: NSColor? = nil) -> NSImage {
        // Standard menu bar icon size (matches system icons like Bluetooth, etc.)
        let size = NSSize(width: 22, height: 22)

        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high

            // The ghost path from Phosphor thin variant (viewBox 0 0 256 256)
            // Scaled to fill the frame properly (18pt ghost in 22pt frame)
            let scale: CGFloat = 18.0 / 256.0  // Scale to ~18pt within 22pt frame
            let offsetX: CGFloat = (rect.width - 256 * scale) / 2
            let offsetY: CGFloat = (rect.height - 256 * scale) / 2

            let transform = NSAffineTransform()
            transform.translateX(by: offsetX, yBy: offsetY)
            transform.scale(by: scale)

            // Set the color - strokeColor overrides for outline mode when focused
            let drawColor = tintColor ?? NSColor.black  // Black will be templated
            let outlineColor = strokeColor ?? drawColor  // Use strokeColor for outline if provided

            if filled {
                // Filled ghost - solid shape
                let ghostPath = NSBezierPath()
                self.addFilledGhostPath(to: ghostPath)
                ghostPath.transform(using: transform as AffineTransform)
                drawColor.setFill()
                ghostPath.fill()
            } else {
                // Outline ghost - use stroke for cleaner, thicker lines
                // Uses outlineColor which can be orange when focused
                let ghostPath = NSBezierPath()
                self.addGhostOutlinePath(to: ghostPath)
                ghostPath.transform(using: transform as AffineTransform)

                // Stroke weight: ~1.6pt at final size (24pt in 256 viewBox × 18/256 scale ≈ 1.7pt)
                ghostPath.lineWidth = 24 * scale
                ghostPath.lineCapStyle = .round
                ghostPath.lineJoinStyle = .round
                outlineColor.setStroke()
                ghostPath.stroke()

                // Draw eyes as filled circles (same color as stroke)
                let eyePath = NSBezierPath()
                self.addEyePaths(to: eyePath)
                eyePath.transform(using: transform as AffineTransform)
                outlineColor.setFill()
                eyePath.fill()
            }
            
            // Draw badge if needed
            if showBadge {
                let badgeSize: CGFloat = 6
                let badgeRect = NSRect(
                    x: rect.width - badgeSize - 2,
                    y: rect.height - badgeSize - 2,
                    width: badgeSize,
                    height: badgeSize
                )

                // Badge background for contrast
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.5, dy: -0.5)).fill()

                // Badge dot
                Colors.modified.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }

            return true
        }

        // Template for disconnected state (auto light/dark)
        // BUT: if strokeColor is set (focused), disable template so color shows
        image.isTemplate = (tintColor == nil && strokeColor == nil)
        
        return image
    }
    
    /// Add the filled ghost shape (solid silhouette)
    private func addFilledGhostPath(to path: NSBezierPath) {
        // Ghost body - outer contour
        // Top arc (head) - 92pt radius circle centered at (128, 120)
        // Note: NSBezierPath Y is flipped from SVG
        
        // Start at bottom left tail point
        path.move(to: NSPoint(x: 36, y: 256 - 216))
        
        // Left edge up to the arc
        path.line(to: NSPoint(x: 36, y: 256 - 120))
        
        // The head arc (92pt radius)
        path.appendArc(withCenter: NSPoint(x: 128, y: 256 - 120),
                       radius: 92,
                       startAngle: 180,
                       endAngle: 0,
                       clockwise: true)
        
        // Right edge down
        path.line(to: NSPoint(x: 220, y: 256 - 216))
        
        // Bottom wavy tail (simplified)
        // The ghost has 3 "waves" at the bottom
        path.line(to: NSPoint(x: 186.67, y: 256 - 197.17))
        path.line(to: NSPoint(x: 159.87, y: 256 - 219.1))
        path.line(to: NSPoint(x: 128, y: 256 - 197.17))
        path.line(to: NSPoint(x: 96.13, y: 256 - 219.1))
        path.line(to: NSPoint(x: 69.33, y: 256 - 197.17))
        path.line(to: NSPoint(x: 36, y: 256 - 216))
        
        path.close()
        
        // Eyes (subtract them by drawing in opposite direction - or just skip for filled)
        // For a true "filled" look, we'll add the eyes as separate unfilled areas
        // Actually, let's keep eyes as part of the design
        addEyePaths(to: path)
    }
    
    /// Add the ghost outline path for stroking (not fill)
    /// This creates the ghost shape as a single open/closed path for stroke rendering
    private func addGhostOutlinePath(to path: NSBezierPath) {
        // Ghost body outline - center line of the stroke
        // Start at bottom left, go up, around the head, down, and along the wavy bottom

        // Start at bottom left
        path.move(to: NSPoint(x: 36, y: 256 - 216))

        // Left edge up to the head
        path.line(to: NSPoint(x: 36, y: 256 - 120))

        // Head arc (92pt radius centered at 128, 120)
        path.appendArc(withCenter: NSPoint(x: 128, y: 256 - 120),
                       radius: 92,
                       startAngle: 180,
                       endAngle: 0,
                       clockwise: true)

        // Right edge down
        path.line(to: NSPoint(x: 220, y: 256 - 216))

        // Bottom wavy tail (3 peaks)
        path.line(to: NSPoint(x: 186.67, y: 256 - 197.17))
        path.line(to: NSPoint(x: 159.87, y: 256 - 219.1))
        path.line(to: NSPoint(x: 128, y: 256 - 197.17))
        path.line(to: NSPoint(x: 96.13, y: 256 - 219.1))
        path.line(to: NSPoint(x: 69.33, y: 256 - 197.17))

        // Close back to start
        path.close()
    }
    
    /// Add the eye circles to the ghost
    private func addEyePaths(to path: NSBezierPath) {
        // Left eye - circle at (100, 116) with radius 8
        let leftEye = NSBezierPath(ovalIn: NSRect(
            x: 100 - 8, y: 256 - 116 - 8,
            width: 16, height: 16
        ))
        path.append(leftEye)
        
        // Right eye - circle at (156, 116) with radius 8  
        let rightEye = NSBezierPath(ovalIn: NSRect(
            x: 156 - 8, y: 256 - 116 - 8,
            width: 16, height: 16
        ))
        path.append(rightEye)
    }
    
    private func updateStatusText(for state: IconState) {
        guard let menu = menu,
              let statusItem = menu.item(withTag: 100) else { return }
        
        switch state {
        case .disconnected:
            statusItem.title = "Disconnected"
        case .connected:
            statusItem.title = "Connected"
        case .editingNotes:
            statusItem.title = "Editing Notes"
        case .modified:
            statusItem.title = "Editing Notes (modified)"
        }
    }
    
    // MARK: - Actions
    
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Right-click shows menu (already handled by NSStatusItem)
        } else {
            // Left-click toggles panel
            onToggle?()
        }
    }
    
    @objc private func handleToggle() {
        onToggle?()
    }
    
    @objc private func handleDailyNote() {
        onDailyNote?()
    }
    
    @objc private func handleNewCapture() {
        onNewCapture?()
    }
    
    @objc private func handleQuit() {
        onQuit?()
    }

    @objc private func handleAutoTrackToggle() {
        autoTrackCompanion.toggle()
        Log.debug("MenuBarManager: Auto-track companion = \(autoTrackCompanion)")
    }

    @objc private func handleAutoResizeToggle() {
        autoResizeCompanion.toggle()
        Log.debug("MenuBarManager: Auto-resize companion = \(autoResizeCompanion)")
    }
}

// MARK: - NSImage Tinting Extension

private extension NSImage {
    /// Create a tinted copy of the image
    func tinted(with color: NSColor) -> NSImage {
        let tinted = self.copy() as! NSImage
        tinted.lockFocus()
        
        color.set()
        let imageRect = NSRect(origin: .zero, size: self.size)
        imageRect.fill(using: .sourceAtop)
        
        tinted.unlockFocus()
        tinted.isTemplate = false
        
        return tinted
    }
}
