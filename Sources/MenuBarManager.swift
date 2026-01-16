import AppKit

/// Manages the menubar status item with focus state indicator.
///
/// ## Icon States
/// - **Unfocused**: Ghost outline in white/system color
/// - **Focused**: Ghost outline in Everforest orange
///
/// Uses a "shade" ghost icon (thinner/lighter than Ghostty's ghost) from Phosphor Icons.
@MainActor
final class MenuBarManager {
    
    // MARK: - Colors

    private enum Colors {
        // Unfocused: white (will be templated for light/dark adaptation)
        static let unfocused = NSColor.white

        // Focused: Everforest orange - overridden by config if present
        static let focusedDefault = NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.35, alpha: 1.0) // #E68C59
    }

    // MARK: - Version Info

    /// Build context prefix (debug/release/none for installed)
    private static let buildPrefix: String? = {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains(".build/debug") {
            return "debug"
        } else if bundlePath.contains(".build/release") {
            return "release"
        }
        // Installed binary (via just install, flake, or release) - no prefix
        return nil
    }()

    /// Git SHA of HEAD (8 chars), fetched at startup
    private static let gitSHA: String = {
        // Try to get the SHA from the shade repo
        // This runs git to get HEAD's commit SHA
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short=8", "HEAD"]

        // Find the shade repo - check common locations
        let possiblePaths = [
            NSHomeDirectory() + "/code/shade",
            NSHomeDirectory() + "/.local/share/shade",
            Bundle.main.bundlePath  // In case running from built app
        ]

        for path in possiblePaths {
            let gitDir = path + "/.git"
            if FileManager.default.fileExists(atPath: gitDir) {
                process.currentDirectoryURL = URL(fileURLWithPath: path)
                break
            }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !sha.isEmpty {
                    return sha
                }
            }
        } catch {
            // Silently fail - version just won't show
        }

        return "unknown"
    }()

    /// Formatted version string for display
    private static let versionString: String = {
        if let prefix = buildPrefix {
            return "\(prefix)-\(gitSHA)"
        } else {
            return gitSHA
        }
    }()

    /// Get the focused stroke color from config, or use default
    private var focusedColor: NSColor {
        if let config = ShadeConfig.shared.window?.focusBorder {
            return config.parsedMenubarStrokeColor()
        }
        return Colors.focusedDefault
    }
    
    // MARK: - Background Activity State

    /// State of the LLM model
    enum ModelState: Equatable {
        case disabled
        case idle
        case loading
        case downloading(progress: Double)
        case ready
        case error(String)

        var displayString: String {
            switch self {
            case .disabled:
                return "LLM: Disabled"
            case .idle:
                return "LLM: Not loaded"
            case .loading:
                return "LLM: Loading..."
            case .downloading(let progress):
                return "LLM: Downloading (\(Int(progress * 100))%)"
            case .ready:
                return "LLM: Ready"
            case .error(let msg):
                return "LLM: Error - \(msg)"
            }
        }
    }

    // MARK: - UserDefaults Keys

    private enum DefaultsKeys {
        static let autoTrackCompanion = "shade.autoTrackCompanion"
        static let autoResizeCompanion = "shade.autoResizeCompanion"
    }

    // MARK: - Properties

    /// The status item in the menubar
    private var statusItem: NSStatusItem?

    /// Whether the panel is currently focused
    private(set) var isFocused: Bool = false

    /// The menu attached to the status item
    private var menu: NSMenu?

    /// Menu items for toggles (for updating checkmarks)
    private var autoTrackMenuItem: NSMenuItem?
    private var autoResizeMenuItem: NSMenuItem?

    /// Menu items for background activity status (for dynamic updates)
    private var modelStatusMenuItem: NSMenuItem?
    private var enrichmentStatusMenuItem: NSMenuItem?

    /// Current model state
    private(set) var modelState: ModelState = .idle {
        didSet {
            updateModelStatusMenuItem()
        }
    }

    /// Current pending enrichment count
    private(set) var pendingEnrichments: Int = 0 {
        didSet {
            updateEnrichmentStatusMenuItem()
        }
    }

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
        
        // Set initial icon (unfocused)
        updateIcon(focused: false)
        
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

    /// Update the focused state (changes stroke color to orange when focused)
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateIcon(focused: focused)
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

        // Background Activity section
        let activityHeader = NSMenuItem(title: "Background Activity", action: nil, keyEquivalent: "")
        activityHeader.isEnabled = false
        menu.addItem(activityHeader)

        // Model status (dynamically updated)
        let modelItem = NSMenuItem(title: modelState.displayString, action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        self.modelStatusMenuItem = modelItem

        // Enrichment status (dynamically updated, hidden when 0)
        let enrichmentItem = NSMenuItem(title: "Enrichments: 0 pending", action: nil, keyEquivalent: "")
        enrichmentItem.isEnabled = false
        enrichmentItem.isHidden = true  // Hidden until there are pending enrichments
        menu.addItem(enrichmentItem)
        self.enrichmentStatusMenuItem = enrichmentItem

        menu.addItem(NSMenuItem.separator())

        // Show Logs action
        let logsItem = NSMenuItem(title: "Show Logs...", action: #selector(handleShowLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

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

        // Version info (build context + git SHA from HEAD)
        let versionItem = NSMenuItem(title: Self.versionString, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Shade", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        self.statusItem?.menu = menu
    }
    
    private func updateIcon(focused: Bool) {
        guard let button = statusItem?.button else { return }

        let strokeColor = focused ? focusedColor : Colors.unfocused
        button.image = createGhostIcon(strokeColor: strokeColor, useTemplate: !focused)
    }
    
    /// Create the ghost "shade" icon
    /// Uses Phosphor Icons "ghost-thin" - a lighter, more ethereal ghost than Ghostty's
    /// - Parameters:
    ///   - strokeColor: Color for the outline stroke
    ///   - useTemplate: Whether to use template mode (adapts to light/dark menubar)
    private func createGhostIcon(strokeColor: NSColor, useTemplate: Bool) -> NSImage {
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

            // Draw outline ghost
            let ghostPath = NSBezierPath()
            self.addGhostOutlinePath(to: ghostPath)
            ghostPath.transform(using: transform as AffineTransform)

            // Stroke weight: ~1.6pt at final size (24pt in 256 viewBox × 18/256 scale ≈ 1.7pt)
            ghostPath.lineWidth = 24 * scale
            ghostPath.lineCapStyle = .round
            ghostPath.lineJoinStyle = .round
            strokeColor.setStroke()
            ghostPath.stroke()

            // Draw eyes as filled circles (same color as stroke)
            let eyePath = NSBezierPath()
            self.addEyePaths(to: eyePath)
            eyePath.transform(using: transform as AffineTransform)
            strokeColor.setFill()
            eyePath.fill()

            return true
        }

        // Template mode for unfocused (adapts to light/dark menubar)
        // Non-template for focused so orange color shows
        image.isTemplate = useTemplate
        
        return image
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

    @objc private func handleShowLogs() {
        // Open Console.app with a predicate to filter for Shade's subsystem
        // The predicate filters for process name "shade" or subsystem "io.shade"
        let script = """
            tell application "Console"
                activate
            end tell
            """

        // First, open Console
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                Log.warn("MenuBarManager: Failed to open Console: \(error)")
            }
        }

        // The user can then use the search field to filter by "shade"
        // Unfortunately, Console.app doesn't have good AppleScript support for setting predicates
        Log.debug("MenuBarManager: Opened Console.app - filter by 'shade' in search")
    }

    // MARK: - Background Activity Updates

    /// Update model status from external source
    func setModelState(_ state: ModelState) {
        modelState = state
    }

    /// Update pending enrichment count from external source
    func setEnrichmentCount(_ count: Int) {
        pendingEnrichments = count
    }

    /// Update model status menu item
    private func updateModelStatusMenuItem() {
        modelStatusMenuItem?.title = modelState.displayString
        Log.debug("MenuBarManager: Model status = \(modelState.displayString)")
    }

    /// Update enrichment status menu item
    private func updateEnrichmentStatusMenuItem() {
        if pendingEnrichments > 0 {
            let plural = pendingEnrichments == 1 ? "" : "s"
            enrichmentStatusMenuItem?.title = "Enrichment\(plural): \(pendingEnrichments) pending"
            enrichmentStatusMenuItem?.isHidden = false
        } else {
            enrichmentStatusMenuItem?.isHidden = true
        }
        Log.debug("MenuBarManager: Pending enrichments = \(pendingEnrichments)")
    }
}
