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
        
        // Darker variants for light mode (auto-adjusted)
        static func adjusted(_ color: NSColor) -> NSColor {
            // NSAppearance handles this for us with template images
            // For non-template, we could check effectiveAppearance
            return color
        }
    }
    
    // MARK: - Properties
    
    /// The status item in the menubar
    private var statusItem: NSStatusItem?
    
    /// Current icon state
    private(set) var state: IconState = .disconnected
    
    /// The menu attached to the status item
    private var menu: NSMenu?
    
    /// Callback for toggle action
    var onToggle: (() -> Void)?
    
    /// Callback for daily note action
    var onDailyNote: (() -> Void)?
    
    /// Callback for new capture action
    var onNewCapture: (() -> Void)?
    
    /// Callback for quit action
    var onQuit: (() -> Void)?
    
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
        updateIcon(for: newState)
        Log.debug("MenuBarManager: State changed to \(newState)")
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
    
    private func updateIcon(for state: IconState) {
        guard let button = statusItem?.button else { return }
        
        let filled: Bool
        let tintColor: NSColor?
        let showBadge: Bool
        
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
        
        // Create the ghost icon
        button.image = createGhostIcon(filled: filled, tintColor: tintColor, showBadge: showBadge)
        
        // Update status text in menu
        updateStatusText(for: state)
    }
    
    /// Create the ghost "shade" icon
    /// Uses Phosphor Icons "ghost-thin" - a lighter, more ethereal ghost than Ghostty's
    private func createGhostIcon(filled: Bool, tintColor: NSColor?, showBadge: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            
            // The ghost path from Phosphor thin variant (viewBox 0 0 256 256)
            // Scaled to fit in 18x18 with some padding
            let scale: CGFloat = 16.0 / 256.0  // Scale to ~16pt within 18pt frame
            let offsetX: CGFloat = (rect.width - 256 * scale) / 2
            let offsetY: CGFloat = (rect.height - 256 * scale) / 2
            
            let transform = NSAffineTransform()
            transform.translateX(by: offsetX, yBy: offsetY)
            transform.scale(by: scale)
            
            // Create the ghost path
            let ghostPath = NSBezierPath()
            
            if filled {
                // Filled ghost - outer shape only
                self.addFilledGhostPath(to: ghostPath)
            } else {
                // Outline ghost - the thin stroke version
                self.addOutlineGhostPath(to: ghostPath)
            }
            
            ghostPath.transform(using: transform as AffineTransform)
            
            // Draw the ghost
            if let color = tintColor {
                color.setFill()
            } else {
                NSColor.black.setFill()  // Will be templated
            }
            ghostPath.fill()
            
            // Draw badge if needed
            if showBadge {
                let badgeSize: CGFloat = 5
                let badgeRect = NSRect(
                    x: rect.width - badgeSize - 1,
                    y: rect.height - badgeSize - 1,
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
        image.isTemplate = (tintColor == nil)
        
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
    
    /// Add the outline ghost shape (thin stroke look, rendered as fill)
    private func addOutlineGhostPath(to path: NSBezierPath) {
        // For the outline version, we draw the stroke path
        // This is the Phosphor thin ghost path data (stroke width ~8pt in original 256x256 viewBox)
        
        // Outer edge
        let outer = NSBezierPath()
        outer.move(to: NSPoint(x: 36, y: 256 - 216))
        outer.line(to: NSPoint(x: 36, y: 256 - 120))
        outer.appendArc(withCenter: NSPoint(x: 128, y: 256 - 120),
                        radius: 92,
                        startAngle: 180,
                        endAngle: 0,
                        clockwise: true)
        outer.line(to: NSPoint(x: 220, y: 256 - 216))
        outer.line(to: NSPoint(x: 186.67, y: 256 - 197.17))
        outer.line(to: NSPoint(x: 159.87, y: 256 - 219.1))
        outer.line(to: NSPoint(x: 128, y: 256 - 197.17))
        outer.line(to: NSPoint(x: 96.13, y: 256 - 219.1))
        outer.line(to: NSPoint(x: 69.33, y: 256 - 197.17))
        outer.close()
        
        // Inner edge (offset inward)
        let inner = NSBezierPath()
        inner.move(to: NSPoint(x: 44, y: 256 - 207.56))
        inner.line(to: NSPoint(x: 44, y: 256 - 120))
        inner.appendArc(withCenter: NSPoint(x: 128, y: 256 - 120),
                        radius: 84,
                        startAngle: 180,
                        endAngle: 0,
                        clockwise: true)
        inner.line(to: NSPoint(x: 212, y: 256 - 207.56))
        inner.line(to: NSPoint(x: 186.67, y: 256 - 188.9))
        inner.line(to: NSPoint(x: 159.87, y: 256 - 210.83))
        inner.line(to: NSPoint(x: 128, y: 256 - 188.9))
        inner.line(to: NSPoint(x: 96.13, y: 256 - 210.83))
        inner.line(to: NSPoint(x: 69.33, y: 256 - 188.9))
        inner.close()
        
        // Use even-odd rule to create the outline effect
        path.append(outer)
        path.append(inner.reversed)
        path.windingRule = .evenOdd
        
        // Add eyes
        addEyePaths(to: path)
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
