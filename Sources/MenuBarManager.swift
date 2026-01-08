import AppKit

/// Manages the menubar status item with connection state indicators.
///
/// ## Icon States
/// - **Disconnected**: Outline pin (template) - Shade running, nvim not connected
/// - **Connected**: Filled pin with muted green tint - Connected to nvim
/// - **Editing Notes**: Filled pin with muted aqua tint - Editing in $NOTES_HOME
/// - **Modified**: Same as above + small orange dot - Unsaved changes
///
/// Uses Everforest-inspired muted colors that work in both light and dark mode.
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
        
        // Base symbol - rotated 45 degrees
        let symbolName: String
        let tintColor: NSColor?
        let showBadge: Bool
        
        switch state {
        case .disconnected:
            symbolName = "pin"
            tintColor = nil // Use template (adapts to light/dark)
            showBadge = false
            
        case .connected:
            symbolName = "pin.fill"
            tintColor = Colors.connected
            showBadge = false
            
        case .editingNotes:
            symbolName = "pin.fill"
            tintColor = Colors.editingNotes
            showBadge = false
            
        case .modified:
            symbolName = "pin.fill"
            tintColor = Colors.editingNotes
            showBadge = true
        }
        
        // Create the icon
        if let image = createIcon(symbolName: symbolName, tintColor: tintColor, showBadge: showBadge) {
            button.image = image
        }
        
        // Update status text in menu
        updateStatusText(for: state)
    }
    
    private func createIcon(symbolName: String, tintColor: NSColor?, showBadge: Bool) -> NSImage? {
        // Get the SF Symbol
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Shade") else {
            Log.error("MenuBarManager: Failed to load SF Symbol '\(symbolName)'")
            return nil
        }
        
        // Configure for menubar size
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let configuredImage = baseImage.withSymbolConfiguration(config) else {
            return baseImage
        }
        
        // Create a new image to draw into (for rotation and badge)
        let size = NSSize(width: 18, height: 18)
        let finalImage = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            
            // Save graphics state
            NSGraphicsContext.saveGraphicsState()
            
            // Move origin to center, rotate 45 degrees, move back
            let transform = NSAffineTransform()
            transform.translateX(by: rect.width / 2, yBy: rect.height / 2)
            transform.rotate(byDegrees: 45)
            transform.translateX(by: -rect.width / 2, yBy: -rect.height / 2)
            transform.concat()
            
            // Draw the symbol
            let imageRect = NSRect(
                x: (rect.width - configuredImage.size.width) / 2,
                y: (rect.height - configuredImage.size.height) / 2,
                width: configuredImage.size.width,
                height: configuredImage.size.height
            )
            
            if let tintColor = tintColor {
                // Draw tinted (non-template)
                let tintedImage = configuredImage.tinted(with: tintColor)
                tintedImage.draw(in: imageRect)
            } else {
                // Draw as template (adapts to menubar appearance)
                configuredImage.draw(in: imageRect)
            }
            
            // Restore graphics state (removes rotation for badge)
            NSGraphicsContext.restoreGraphicsState()
            
            // Draw badge if needed (not rotated)
            if showBadge {
                let badgeSize: CGFloat = 6
                let badgeRect = NSRect(
                    x: rect.width - badgeSize - 1,
                    y: rect.height - badgeSize - 1,
                    width: badgeSize,
                    height: badgeSize
                )
                
                // Badge background (slightly darker for contrast)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
                
                // Badge dot
                Colors.modified.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            
            return true
        }
        
        // Set as template only for disconnected state (no tint)
        finalImage.isTemplate = (tintColor == nil)
        
        return finalImage
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
