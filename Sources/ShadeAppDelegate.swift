import AppKit
import ApplicationServices
import ContextGatherer
import GhosttyKit
import ShadeCore

/// Main application delegate that manages the ghostty app and terminal panel
class ShadeAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton for C callback access

    static var shared: ShadeAppDelegate?

    // MARK: - Properties

    /// App configuration from CLI args
    private let appConfig: AppConfig

    /// The ghostty configuration
    private var ghosttyConfig: ghostty_config_t?

    /// The ghostty app instance
    private var ghosttyApp: ghostty_app_t?

    /// The floating panel containing the terminal
    private var panel: ShadePanel?

    /// The terminal view
    private var terminalView: TerminalView?

    /// Timer for the ghostty event loop
    private var tickTimer: Timer?

    /// Flag to prevent multiple termination attempts
    private var isTerminating = false

    /// Flag to track if we're in backgrounded state (surface destroyed, awaiting new command)
    private var isBackgrounded = false

    /// Current panel display mode (floating, sidebar-left, sidebar-right)
    private var currentMode: PanelMode = .floating

    /// Bundle ID of companion app when in sidebar mode (for restoration)
    private var companionBundleID: String?

    /// Original frame of companion window (for restoration when exiting sidebar)
    private var companionOriginalFrame: CGRect?

    /// Previously focused app (to restore focus when hiding)
    private var previousFocusedApp: NSRunningApplication?

    /// Last known non-Shade frontmost app (tracked proactively via workspace notifications)
    /// This is updated whenever ANY app becomes frontmost, ensuring we always have a valid
    /// context target even if the panel is already visible when capture is triggered.
    private var lastNonShadeFrontApp: NSRunningApplication?

    /// Workspace notification observer token
    private var workspaceObserver: NSObjectProtocol?

    /// Menubar status item manager
    private var menuBarManager: MenuBarManager?

    // MARK: - Initialization

    init(config: AppConfig) {
        self.appConfig = config
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShadeAppDelegate.shared = self
        Log.debug("Starting...")
        Log.debug("Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")

        // Make this a background app (no dock icon, no menu bar when hidden)
        NSApp.setActivationPolicy(.accessory)

        // Setup XDG state directory
        StateDirectory.ensureDirectoryExists()
        StateDirectory.writePIDFile()
        StateDirectory.cleanupNvimSocket()

        // Initialize ghostty
        guard initializeGhostty() else {
            Log.error("Failed to initialize ghostty")
            NSApp.terminate(nil)
            return
        }

        // Create the floating panel
        createPanel()

        // Setup minimal menu bar for Cmd+Q support
        setupMenuBar()

        // Register emergency escape hotkey (Cmd+Escape)
        setupEmergencyHotkey()

        // Start the event loop timer
        startTickTimer()

        // Listen for toggle notifications from Hammerspoon
        setupNotificationListener()

        // Setup workspace observer to track frontmost app proactively
        setupWorkspaceObserver()

        // Setup menubar status item
        setupMenuBarItem()

        // Start RPC server for nvim-to-shade communication
        setupRPCServer()

        Log.debug("Ready")
        Log.debug("State directory: \(StateDirectory.baseDir.path)")
    }

    // MARK: - Menu Bar (for Cmd+Q support)

    private func setupMenuBar() {
        // Create a minimal menu bar so Cmd+Q works even in accessory mode
        let mainMenu = NSMenu()

        // App menu (required for Cmd+Q)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        // Quit item with Cmd+Q shortcut
        let quitItem = NSMenuItem(
            title: "Quit shade",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
        Log.debug("Menu bar configured (Cmd+Q enabled)")
    }

    // MARK: - Menubar Status Item

    private func setupMenuBarItem() {
        // Setup on main actor since MenuBarManager is @MainActor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let manager = MenuBarManager()
            self.menuBarManager = manager

            // Wire up actions
            manager.onToggle = { [weak self] in
                if self?.isPanelVisible == true {
                    self?.hidePanel()
                } else {
                    self?.showPanelWithSurface()
                }
            }

            manager.onDailyNote = { [weak self] in
                self?.showPanelWithSurface()
                ShadeNvim.shared.connectAndPerform(
                    { nvim in try await nvim.openDailyNote() },
                    onSuccess: { _ in },
                    onError: { error in Log.error("Failed to open daily note: \(error)") }
                )
            }

            manager.onNewCapture = { [weak self] in
                self?.showPanelWithSurface()
                ShadeNvim.shared.connectAndPerform(
                    { nvim in try await nvim.openNewCapture() },
                    onSuccess: { _ in },
                    onError: { error in Log.error("Failed to open capture: \(error)") }
                )
            }

            manager.onQuit = {
                NSApp.terminate(nil)
            }

            // Wire up experimental settings callback
            manager.onSettingsChanged = { [weak self] autoTrack, autoResize in
                guard self != nil else { return }
                Log.debug("Experimental settings changed: autoTrack=\(autoTrack), autoResize=\(autoResize)")
                // Settings are read directly from UserDefaults when needed
                // No additional wiring required - the workspace observer checks these values
            }

            manager.setup()

            // Wire up MLX callbacks to menu bar
            // Note: MLXInferenceEngine is an actor, so we use @Sendable closures
            Task {
                // Download progress
                await MLXInferenceEngine.shared.setDownloadProgressHandler { @Sendable progress in
                    Task { @MainActor in
                        manager.setModelState(.downloading(progress: progress))
                    }
                }

                // Load state changes (started, completed, failed)
                await MLXInferenceEngine.shared.setLoadStateHandler { @Sendable isCompleted, error in
                    Task { @MainActor in
                        if let error = error {
                            manager.setModelState(.error(error))
                        } else if isCompleted {
                            manager.setModelState(.ready)
                        } else {
                            manager.setModelState(.loading)
                        }
                    }
                }

                // Enrichment count changes
                await AsyncEnrichmentManager.shared.setCountChangedHandler { @Sendable count in
                    Task { @MainActor in
                        manager.setEnrichmentCount(count)
                    }
                }
            }

            // Set initial model state based on config
            if let llmConfig = ShadeConfig.shared.llm, llmConfig.enabled {
                manager.setModelState(.idle)
            } else {
                manager.setModelState(.disabled)
            }

            // Log initial experimental settings
            Log.debug("Experimental settings: autoTrack=\(manager.autoTrackCompanion), autoResize=\(manager.autoResizeCompanion)")
        }
    }





    // MARK: - Emergency Hotkey (Cmd+Escape)

    private func setupEmergencyHotkey() {
        GlobalHotkey.shared.onEscapePressed = { [weak self] in
            Log.debug("Emergency escape: hiding panel")
            self?.hidePanel()
        }

        if GlobalHotkey.shared.register() {
            Log.debug("Emergency hotkey registered (Cmd+Escape to hide)")
        } else {
            Log.warn("Emergency hotkey registration failed - Accessibility permissions may be needed")
        }
    }

    // MARK: - RPC Server (for nvim-to-shade communication)

    private func setupRPCServer() {
        Task {
            // Wire up callbacks
            ShadeServer.shared.onHide = { [weak self] in
                self?.hidePanel()
            }
            ShadeServer.shared.onShow = { [weak self] in
                self?.showPanelWithSurface()
            }
            ShadeServer.shared.onToggle = { [weak self] in
                if self?.isPanelVisible == true {
                    self?.hidePanel()
                } else {
                    self?.showPanelWithSurface()
                }
            }
            ShadeServer.shared.onGetContext = {
                // Return the last gathered context as a dictionary
                if let ctx = StateDirectory.readGatheredContext() {
                    return [
                        "appType": ctx.appType ?? "",
                        "appName": ctx.appName ?? "",
                        "bundleID": ctx.bundleID ?? "",
                        "windowTitle": ctx.windowTitle ?? "",
                        "url": ctx.url ?? "",
                        "filePath": ctx.filePath ?? "",
                        "filetype": ctx.filetype ?? "",
                        "selection": ctx.selection ?? "",
                        "detectedLanguage": ctx.detectedLanguage ?? "",
                        "line": ctx.line ?? 0,
                        "col": ctx.col ?? 0
                    ]
                }
                return [:]
            }

            // Register handlers and start server
            await ShadeServer.shared.registerDefaultHandlers()
            do {
                try await ShadeServer.shared.start()
            } catch {
                Log.error("Failed to start RPC server: \(error)")
            }
        }
    }

    // MARK: - Workspace Observer (for proactive app tracking)

    /// Setup workspace observer to track frontmost app changes
    /// This proactively tracks the last non-Shade app, solving timing issues with context capture
    private func setupWorkspaceObserver() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        workspaceObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            // Get the app that just became frontmost
            guard let userInfo = notification.userInfo,
                  let app = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            // Track it if it's not Shade
            // Check both bundle ID (for .app bundles) and process name (for bare executables in dev)
            let isShade = app.bundleIdentifier == Bundle.main.bundleIdentifier ||
                          app.localizedName == "shade" ||
                          app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if !isShade {
                self.lastNonShadeFrontApp = app
                Log.debug("Tracked frontmost app: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")

                // Experimental: Dynamic companion tracking in sidebar mode
                self.handlePotentialCompanionChange(app)
            } else {
                Log.debug("Skipping Shade from tracking (bundle: \(app.bundleIdentifier ?? "?"), our bundle: \(Bundle.main.bundleIdentifier ?? "?"))")
            }
        }

        // Initialize with current frontmost app (if not Shade)
        if let frontApp = workspace.frontmostApplication {
            let isShade = frontApp.bundleIdentifier == Bundle.main.bundleIdentifier ||
                          frontApp.localizedName == "shade" ||
                          frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if !isShade {
                lastNonShadeFrontApp = frontApp
                Log.debug("Initial frontmost app: \(frontApp.localizedName ?? "unknown")")
            }
        }

        Log.debug("Workspace observer configured")
    }

    // MARK: - Notification Listener (for Hammerspoon integration)

    private func setupNotificationListener() {
        // Listen for distributed notifications from Hammerspoon or other apps
        let center = DistributedNotificationCenter.default()

        // Toggle notification
        center.addObserver(
            self,
            selector: #selector(handleToggleNotification),
            name: NSNotification.Name("io.shade.toggle"),
            object: nil
        )

        // Show notification
        center.addObserver(
            self,
            selector: #selector(handleShowNotification),
            name: NSNotification.Name("io.shade.show"),
            object: nil
        )

        // Hide notification
        center.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("io.shade.hide"),
            object: nil
        )

        // Quit notification - actually terminate the app
        center.addObserver(
            self,
            selector: #selector(handleQuitNotification),
            name: NSNotification.Name("io.shade.quit"),
            object: nil
        )

        // Note capture notification
        center.addObserver(
            self,
            selector: #selector(handleNoteCaptureNotification),
            name: NSNotification.Name("io.shade.note.capture"),
            object: nil
        )

        // Daily note notification
        center.addObserver(
            self,
            selector: #selector(handleDailyNoteNotification),
            name: NSNotification.Name("io.shade.note.daily"),
            object: nil
        )

        // Image capture notification (from clipper)
        center.addObserver(
            self,
            selector: #selector(handleImageCaptureNotification),
            name: NSNotification.Name("io.shade.note.capture.image"),
            object: nil
        )

        // Sidebar mode notifications (separate names to avoid userInfo issues)
        center.addObserver(
            self,
            selector: #selector(handleModeFloatingNotification),
            name: NSNotification.Name("io.shade.mode.floating"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleModeSidebarLeftNotification),
            name: NSNotification.Name("io.shade.mode.sidebar-left"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleModeSidebarRightNotification),
            name: NSNotification.Name("io.shade.mode.sidebar-right"),
            object: nil
        )

        // Legacy mode.set notification (in case old Hammerspoon config is used)
        center.addObserver(
            self,
            selector: #selector(handleModeSetNotification),
            name: NSNotification.Name("io.shade.mode.set"),
            object: nil
        )

        Log.debug("Listening for IPC notifications")
    }

    @objc private func handleToggleNotification(_ notification: Notification) {
        Log.debug("IPC: toggle (visible=\(isPanelVisible), focused=\(isShadeFocused))")

        if isPanelVisible {
            if isShadeFocused {
                // Visible and focused → hide
                hidePanel()
            } else {
                // Visible but not focused → focus (bring to front)
                Log.debug("Focusing panel (was visible but not focused)")
                panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // Hidden → show and focus
            // Reset to floating mode when showing from hidden state
            // Sidebar mode is only valid when actively set via io.shade.mode.sidebar-*
            if currentMode != .floating {
                Log.debug("Resetting to floating mode (was \(currentMode.rawValue))")
                currentMode = .floating
                companionBundleID = nil
                companionOriginalFrame = nil
                panel?.resize(width: appConfig.width, height: appConfig.height)
            }
            capturePreviousFocusedApp()
            showPanelWithSurface()
        }
    }

    @objc private func handleShowNotification(_ notification: Notification) {
        Log.debug("IPC: show")
        // Reset to floating mode when showing from hidden state
        if currentMode != .floating {
            Log.debug("Resetting to floating mode (was \(currentMode.rawValue))")
            currentMode = .floating
            companionBundleID = nil
            companionOriginalFrame = nil
            panel?.resize(width: appConfig.width, height: appConfig.height)
        }
        capturePreviousFocusedApp()
        showPanelWithSurface()
    }

    @objc private func handleHideNotification(_ notification: Notification) {
        Log.debug("IPC: hide")
        hidePanel()
    }

    // MARK: - Panel Focus Handlers (for menubar icon)

    @objc private func panelDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            menuBarManager?.setFocused(true)
        }
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            menuBarManager?.setFocused(false)
        }
    }

    @objc private func handleQuitNotification(_ notification: Notification) {
        Log.debug("IPC: quit")
        isTerminating = true
        NSApp.terminate(nil)
    }

    @objc private func handleModeFloatingNotification(_ notification: Notification) {
        Log.debug("IPC: mode.floating")
        exitSidebarMode()
        // Resize panel back to default floating dimensions
        panel?.resize(width: appConfig.width, height: appConfig.height)
        showPanelWithSurface()
    }

    @objc private func handleModeSidebarLeftNotification(_ notification: Notification) {
        Log.debug("IPC: mode.sidebar-left")
        enterSidebarMode(.sidebarLeft)
    }

    @objc private func handleModeSidebarRightNotification(_ notification: Notification) {
        Log.debug("IPC: mode.sidebar-right")
        enterSidebarMode(.sidebarRight)
    }

    @objc private func handleModeSetNotification(_ notification: Notification) {
        // Legacy handler for old Hammerspoon configs that use userInfo
        guard let userInfo = notification.userInfo,
              let modeStr = userInfo["mode"] as? String,
              let mode = PanelMode(rawValue: modeStr) else {
            Log.warn("IPC: mode.set - invalid or missing mode parameter (use io.shade.mode.<name> instead)")
            return
        }

        Log.debug("IPC: mode.set to \(mode.rawValue) (legacy)")

        if mode == .floating {
            exitSidebarMode()
            showPanelWithSurface()
        } else {
            enterSidebarMode(mode)
        }
    }

    // MARK: - Sidebar Mode

    /// Handle a potential companion change (experimental feature)
    /// Called when a non-Shade app becomes frontmost while in sidebar mode
    private func handlePotentialCompanionChange(_ app: NSRunningApplication) {
        // Only relevant in sidebar mode
        guard currentMode != .floating else { return }

        // Read settings directly from UserDefaults (thread-safe, avoids MainActor issues)
        let autoTrack = UserDefaults.standard.bool(forKey: "shade.autoTrackCompanion")
        let autoResize = UserDefaults.standard.bool(forKey: "shade.autoResizeCompanion")

        // Check if auto-track is enabled
        guard autoTrack else { return }

        // Skip if this is already the current companion
        guard app.bundleIdentifier != companionBundleID else { return }

        Log.debug("Potential companion change: \(app.localizedName ?? "unknown") (autoTrack=\(autoTrack), autoResize=\(autoResize))")

        // If auto-resize is also enabled, update the companion and resize
        if autoResize {
            // Restore previous companion first
            if let prevBundleID = companionBundleID,
               let prevFrame = companionOriginalFrame,
               let prevApp = NSRunningApplication.runningApplications(withBundleIdentifier: prevBundleID).first {
                _ = setWindowFrame(for: prevApp, frame: prevFrame)
                Log.debug("Restored previous companion: \(prevApp.localizedName ?? "unknown")")
            }

            // Update to new companion
            companionBundleID = app.bundleIdentifier
            companionOriginalFrame = getWindowFrame(for: app)

            // Resize new companion
            if companionOriginalFrame != nil {
                resizeCompanionForSidebar(app: app, mode: currentMode)
            }
        } else {
            // Just track, don't resize (useful for next sidebar entry)
            Log.debug("Tracking new potential companion (no resize): \(app.localizedName ?? "unknown")")
            // Note: We don't update companionBundleID here - that only happens on sidebar entry
            // or when autoResize is enabled
        }
    }

    /// Resize a companion app to fit alongside Shade in sidebar mode
    private func resizeCompanionForSidebar(app: NSRunningApplication, mode: PanelMode) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame

        let sidebarWidth: CGFloat
        if appConfig.sidebarWidth <= 1.0 {
            sidebarWidth = screenFrame.width * CGFloat(appConfig.sidebarWidth)
        } else {
            sidebarWidth = CGFloat(appConfig.sidebarWidth)
        }

        let companionFrame: CGRect
        switch mode {
        case .sidebarLeft:
            companionFrame = CGRect(
                x: screenFrame.origin.x + sidebarWidth,
                y: screenFrame.origin.y,
                width: screenFrame.width - sidebarWidth,
                height: screenFrame.height
            )
        case .sidebarRight:
            companionFrame = CGRect(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y,
                width: screenFrame.width - sidebarWidth,
                height: screenFrame.height
            )
        case .floating:
            return
        }

        if setWindowFrame(for: app, frame: companionFrame) {
            Log.debug("Resized new companion to: \(companionFrame.debugDescription)")
        } else {
            Log.warn("Failed to resize new companion")
        }
    }

    /// Enter sidebar mode - dock panel to edge and resize companion app
    /// Shade handles ALL window management directly (no Hammerspoon round-trip)
    private func enterSidebarMode(_ mode: PanelMode) {
        guard mode != .floating else { return }

        // Use lastNonShadeFrontApp for companion tracking (actively tracked via workspace notifications)
        // This ensures mode toggling uses the CURRENT focused app, not a stale capture
        let companionApp = lastNonShadeFrontApp
        companionBundleID = companionApp?.bundleIdentifier
        currentMode = mode

        // Also capture for focus restoration (separate concern)
        capturePreviousFocusedApp()

        Log.debug("Entering sidebar mode: \(mode.rawValue), companion: \(companionApp?.localizedName ?? "none")")

        // Get screen frame for calculations
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.warn("No screen available for sidebar mode")
            return
        }
        let screenFrame = screen.visibleFrame

        // Calculate sidebar width
        let sidebarWidth: CGFloat
        if appConfig.sidebarWidth <= 1.0 {
            sidebarWidth = screenFrame.width * CGFloat(appConfig.sidebarWidth)
        } else {
            sidebarWidth = CGFloat(appConfig.sidebarWidth)
        }

        // Save companion window's original frame before resizing
        if let app = companionApp {
            companionOriginalFrame = getWindowFrame(for: app)
            Log.debug("Saved companion original frame: \(companionOriginalFrame?.debugDescription ?? "nil")")
        }

        // Position Shade panel at edge
        panel?.positionSidebar(mode: mode, width: appConfig.sidebarWidth)

        // Show the panel (skip repositioning since we just positioned it for sidebar)
        showPanelWithSurface(skipPositioning: true)

        // Resize companion window to fill remaining space
        if let app = companionApp, companionOriginalFrame != nil {
            let companionFrame: CGRect
            switch mode {
            case .sidebarLeft:
                // Shade on left, companion on right
                companionFrame = CGRect(
                    x: screenFrame.origin.x + sidebarWidth,
                    y: screenFrame.origin.y,
                    width: screenFrame.width - sidebarWidth,
                    height: screenFrame.height
                )
            case .sidebarRight:
                // Shade on right, companion on left
                companionFrame = CGRect(
                    x: screenFrame.origin.x,
                    y: screenFrame.origin.y,
                    width: screenFrame.width - sidebarWidth,
                    height: screenFrame.height
                )
            case .floating:
                return // Already guarded above
            }

            if setWindowFrame(for: app, frame: companionFrame) {
                Log.debug("Resized companion to: \(companionFrame.debugDescription)")
            } else {
                Log.warn("Failed to resize companion window")
            }
        }
    }

    /// Exit sidebar mode - restore companion app to original size
    /// Shade handles ALL window management directly (no Hammerspoon round-trip)
    private func exitSidebarMode() {
        guard currentMode != .floating else { return }

        Log.debug("Exiting sidebar mode")

        // Restore companion window to original frame
        if let bundleID = companionBundleID,
           let originalFrame = companionOriginalFrame,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if setWindowFrame(for: app, frame: originalFrame) {
                Log.debug("Restored companion to original frame: \(originalFrame.debugDescription)")
            } else {
                Log.warn("Failed to restore companion window")
            }
        }

        currentMode = .floating
        companionBundleID = nil
        companionOriginalFrame = nil
    }

    // MARK: - Window Management (AXUIElement)

    /// Get the main window's frame for an application using Accessibility API
    private func getWindowFrame(for app: NSRunningApplication) -> CGRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the main or focused window
        var window: AnyObject?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)
        if result != .success {
            result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &window)
        }

        guard result == .success, let windowElement = window else {
            Log.debug("Could not get window for \(app.localizedName ?? "app")")
            return nil
        }

        // Get position
        var positionValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              let position = positionValue else {
            return nil
        }

        var point = CGPoint.zero
        if !AXValueGetValue(position as! AXValue, .cgPoint, &point) {
            return nil
        }

        // Get size
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let size = sizeValue else {
            return nil
        }

        var dimensions = CGSize.zero
        if !AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
            return nil
        }

        return CGRect(origin: point, size: dimensions)
    }

    /// Set the main window's frame for an application using Accessibility API
    @discardableResult
    private func setWindowFrame(for app: NSRunningApplication, frame: CGRect) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the main or focused window
        var window: AnyObject?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)
        if result != .success {
            result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &window)
        }

        guard result == .success, let windowElement = window as! AXUIElement? else {
            Log.debug("Could not get window for \(app.localizedName ?? "app") to set frame")
            return false
        }

        // Set position
        var point = frame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &point) else {
            return false
        }
        let posResult = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        if posResult != .success {
            Log.debug("Failed to set position: \(posResult.rawValue)")
        }

        // Set size
        var size = frame.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }
        let sizeResult = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        if sizeResult != .success {
            Log.debug("Failed to set size: \(sizeResult.rawValue)")
        }

        return posResult == .success && sizeResult == .success
    }

    @objc private func handleNoteCaptureNotification(_ notification: Notification) {
        Log.debug("IPC: note.capture")

        // CRITICAL: Capture frontmost app BEFORE any async work
        // This single capture serves two purposes:
        // 1. Context gathering (what app/content to capture from)
        // 2. Focus restoration (where to return focus when hiding)
        let targetApp = capturePreviousFocusedApp()
        Log.debug("Target app for context: \(targetApp?.localizedName ?? "none")")

        // Resize panel to capture size (smaller)
        panel?.resize(width: appConfig.captureWidth, height: appConfig.captureHeight)

        // Always create a new capture, even if panel is already visible
        // User explicitly requested a capture, so honor that intent
        Task {
            let gatheredContext = await ContextGatherer.shared.gather(targetApp: targetApp)
            Log.debug("Gathered context: \(gatheredContext.appType ?? "unknown") from \(gatheredContext.appName ?? "unknown")")

            // Write context for obsidian.nvim templates to read
            StateDirectory.writeContext(gatheredContext)

            // Convert to CaptureContext for openNewCapture (backwards compat)
            let captureContext = CaptureContext(
                appType: gatheredContext.appType,
                appName: gatheredContext.appName,
                windowTitle: gatheredContext.windowTitle,
                url: gatheredContext.url,
                filePath: gatheredContext.filePath,
                selection: gatheredContext.selection,
                detectedLanguage: gatheredContext.detectedLanguage,
                timestamp: gatheredContext.timestamp
            )

            // Show panel with surface (will recreate if backgrounded)
            await MainActor.run {
                self.showPanelWithSurface()
            }

            // Open capture using native RPC (auto-connects with retry)
            ShadeNvim.shared.connectAndPerform(
                { nvim in try await nvim.openNewCapture(context: captureContext) },
                onSuccess: { path in Log.debug("Capture opened: \(path)") },
                onError: { error in Log.error("Failed to open capture: \(error)") }
            )
        }
    }

    @objc private func handleDailyNoteNotification(_ notification: Notification) {
        Log.debug("IPC: note.daily")

        // Capture previous app for focus restoration
        capturePreviousFocusedApp()

        // Resize panel to daily note size (larger)
        panel?.resize(width: appConfig.dailyWidth, height: appConfig.dailyHeight)

        // Show panel with surface (will recreate if backgrounded)
        showPanelWithSurface()

        // Open daily note using native RPC (auto-connects with retry)
        ShadeNvim.shared.connectAndPerform(
            { nvim in try await nvim.openDailyNote() },
            onSuccess: { path in Log.debug("Daily note opened: \(path)") },
            onError: { error in Log.error("Failed to open daily note: \(error)") }
        )
    }

    @objc private func handleImageCaptureNotification(_ notification: Notification) {
        Log.debug("IPC: note.capture.image")

        // Resize panel to capture size (smaller)
        panel?.resize(width: appConfig.captureWidth, height: appConfig.captureHeight)

        // Read context (written by clipper.lua with tempImagePath)
        guard var context = StateDirectory.readContext() else {
            Log.error("Image capture: no context file found")
            return
        }

        // Check for tempImagePath (new flow: Shade handles image)
        if let tempPath = context.tempImagePath {
            Log.debug("Image capture: processing temp image at \(tempPath)")

            // Process the image: copy to vault assets, delete temp
            let result = ImageCaptureHandler.processCapture(tempPath: tempPath)

            switch result {
            case .success(let captureResult):
                // Update context with final asset filename
                context.imageFilename = captureResult.filename
                context.tempImagePath = nil  // Clear temp path
                Log.debug("Image capture: asset filename = \(captureResult.filename)")

                // Run OCR on the asset image (VisionKit is fast, runs before note opens)
                var capturedContext = context
                let assetPath = captureResult.assetPath

                Task {
                    var ocrText: String?

                    // Run OCR first (fast, native)
                    do {
                        let ocr = VisionOCR()
                        let ocrResult = try await ocr.extractText(from: assetPath)

                        if ocrResult.hasText {
                            capturedContext.extractedText = ocrResult.text
                            capturedContext.ocrConfidence = ocrResult.confidence
                            ocrText = ocrResult.text
                            Log.info("Image capture: OCR extracted \(ocrResult.blocks.count) blocks, confidence=\(String(format: "%.2f", ocrResult.confidence))")
                        } else {
                            Log.debug("Image capture: OCR found no text")
                        }
                    } catch {
                        Log.warn("Image capture: OCR failed: \(error.localizedDescription)")
                        // Continue without OCR - not fatal
                    }

                    // Write context for obsidian.nvim template (without summary/tags yet)
                    StateDirectory.writeCaptureContext(capturedContext)

                    // Show panel and open note
                    await MainActor.run {
                        self.showPanelWithSurface()
                    }

                    // Open note and start async enrichment pipeline
                    await self.openImageCaptureWithAsyncEnrichment(
                        context: capturedContext,
                        ocrText: ocrText
                    )
                }
                return  // Early return - async task handles the rest

            case .failure(let error):
                Log.error("Image capture failed: \(error.localizedDescription)")
                // Still try to open note, but without image
                StateDirectory.deleteContextFile()
                showPanelWithSurface()
                return
            }
        } else if context.imageFilename != nil {
            // Legacy flow: Hammerspoon already processed the image
            // Just use the existing imageFilename
            Log.debug("Image capture: using pre-processed imageFilename=\(context.imageFilename ?? "nil")")
        } else {
            Log.warn("Image capture: no tempImagePath or imageFilename in context")
        }

        // Show panel with surface (will recreate if backgrounded)
        showPanelWithSurface()

        // Open image capture note (legacy path without async enrichment)
        openImageCaptureNote(context: context)
    }

    /// Open image capture note and start async enrichment pipeline
    ///
    /// This is the new async flow:
    /// 1. Open the note via obsidian.nvim template
    /// 2. Insert placeholders for summary/tags
    /// 3. Start background MLX enrichment
    /// 4. MLX task replaces placeholders when done
    private func openImageCaptureWithAsyncEnrichment(
        context: CaptureContext,
        ocrText: String?
    ) async {
        let nvim = ShadeNvim.shared

        // Step 1: Connect and open the note
        do {
            if await !nvim.isConnected {
                try await nvim.connect()
            }

            _ = try await nvim.openImageCapture(context: context)
            Log.debug("Image capture: note opened")

            // Small delay to ensure buffer is ready
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Step 2: If we have OCR text, set up async enrichment
            if let text = ocrText, !text.isEmpty {
                // Insert placeholders into the buffer
                let inserted = try await nvim.insertEnrichmentPlaceholders()
                if inserted {
                    Log.debug("Image capture: placeholders inserted")
                }

                // Get the buffer ID
                let bufferId = try await nvim.getCurrentBufferId()

                // Attach to buffer for close detection
                try await nvim.attachBuffer(bufferId)

                // Build GatheredContext for categorization
                let gatheredContext = GatheredContext(
                    appType: context.appType,
                    appName: context.appName,
                    url: context.url,
                    filePath: context.filePath,
                    detectedLanguage: context.detectedLanguage
                )

                // Step 3: Start async enrichment (runs in background)
                let enrichmentId = await AsyncEnrichmentManager.shared.startEnrichment(
                    bufferId: bufferId,
                    ocrText: text,
                    context: gatheredContext
                )

                Log.info("Image capture: started async enrichment \(enrichmentId.id) for buffer \(bufferId)")
            } else {
                Log.debug("Image capture: no OCR text, skipping enrichment")
            }

        } catch {
            Log.error("Image capture: failed to open note: \(error.localizedDescription)")
        }
    }

    /// Helper to open image capture note via nvim RPC (legacy path)
    private func openImageCaptureNote(context: CaptureContext) {
        // Capture context for async closure (Swift 6 compliance)
        let finalContext = context

        // Open image capture note using native RPC (auto-connects with retry)
        ShadeNvim.shared.connectAndPerform(
            { nvim in try await nvim.openImageCapture(context: finalContext) },
            onSuccess: { path in Log.debug("Image capture opened: \(path)") },
            onError: { error in Log.error("Failed to open image capture: \(error)") }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.debug("Shutting down...")

        // Cancel any pending async enrichments
        Task {
            await AsyncEnrichmentManager.shared.cancelAll()
        }

        // Remove workspace observer
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }

        // Remove menubar item
        menuBarManager?.teardown()
        menuBarManager = nil

        // Stop the timer
        tickTimer?.invalidate()
        tickTimer = nil

        // Disconnect from nvim
        Task {
            await ShadeNvim.shared.disconnect()
        }

        // Stop RPC server
        Task {
            await ShadeServer.shared.stop()
        }

        // Clean up ghostty
        if let app = ghosttyApp {
            ghostty_app_free(app)
            ghosttyApp = nil
        }
        if let cfg = ghosttyConfig {
            ghostty_config_free(cfg)
            ghosttyConfig = nil
        }

        // Clean up state files
        StateDirectory.removePIDFile()

        // Unregister hotkey
        GlobalHotkey.shared.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when panel is hidden - we're a toggle-able scratchpad
        return false
    }

    // MARK: - Public API

    /// Toggle the panel visibility
    func togglePanel() {
        panel?.toggle()
    }

    /// Show the panel
    func showPanel() {
        panel?.show()
    }

    /// Hide the panel
    func hidePanel() {
        // Track if we were in sidebar mode (for potential restoration)
        let wasInSidebarMode = currentMode != .floating

        // Restore companion window if in sidebar mode, but DON'T reset currentMode yet
        // This allows handleToggleNotification to properly detect and handle the mode reset
        if wasInSidebarMode {
            // Restore companion window to original frame
            if let bundleID = companionBundleID,
               let originalFrame = companionOriginalFrame,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                if setWindowFrame(for: app, frame: originalFrame) {
                    Log.debug("Restored companion to original frame: \(originalFrame.debugDescription)")
                } else {
                    Log.warn("Failed to restore companion window")
                }
            }
            // Clear companion tracking (companion restored, but mode stays for toggle detection)
            companionBundleID = nil
            companionOriginalFrame = nil
        }

        panel?.hide()

        // Restore focus to the most recent non-Shade app
        // Use lastNonShadeFrontApp (proactively tracked) as it's always up-to-date
        // Fallback to previousFocusedApp if tracking hasn't captured anything yet
        Log.debug("hidePanel: lastNonShadeFrontApp=\(lastNonShadeFrontApp?.localizedName ?? "nil"), previousFocusedApp=\(previousFocusedApp?.localizedName ?? "nil")")
        let appToRestore = lastNonShadeFrontApp ?? previousFocusedApp
        if let app = appToRestore {
            Log.debug("Restoring focus to: \(app.localizedName ?? "unknown") (bundle: \(app.bundleIdentifier ?? "?"))")

            // Activate the app first
            app.activate()

            // Use Accessibility API to raise and focus the app's main window
            // This ensures keyboard focus is properly restored (activate() alone may not be enough)
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

            if result == .success, let windows = windowsValue as? [AXUIElement], let firstWindow = windows.first {
                // Raise the main window
                AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
                // Also try to make it the focused window
                AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, firstWindow)
                Log.debug("Raised and focused window for \(app.localizedName ?? "unknown")")
            } else {
                Log.debug("Could not access windows for \(app.localizedName ?? "unknown")")
            }
        } else {
            Log.warn("No app to restore focus to")
        }
        previousFocusedApp = nil
    }

    /// Check if panel is visible
    var isPanelVisible: Bool {
        return panel?.isVisible ?? false
    }

    /// Check if Shade panel is focused (has keyboard input)
    /// This checks both that the panel is the key window AND that the terminal is first responder
    var isShadeFocused: Bool {
        guard let panel = panel, panel.isKeyWindow else { return false }
        // Verify terminal view is actually receiving input
        return panel.firstResponder === terminalView
    }

    /// Capture the frontmost app for later focus restoration
    /// Call this BEFORE any async work or showing the panel
    /// Returns the captured app (also stored in previousFocusedApp)
    ///
    /// This function uses `lastNonShadeFrontApp` (tracked proactively via workspace notifications)
    /// as a fallback, ensuring we always have a valid app for context gathering even if:
    /// - The panel is already visible
    /// - Shade has already become frontmost by the time this is called
    @discardableResult
    private func capturePreviousFocusedApp() -> NSRunningApplication? {
        // Only update previousFocusedApp if panel is not visible (avoid overwriting during toggle)
        if !isPanelVisible {
            let frontApp = NSWorkspace.shared.frontmostApplication
            // Don't save Shade itself as the previous app
            // Check both bundle ID (for .app bundles) and process name/PID (for bare executables in dev)
            let isShade = frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier ||
                          frontApp?.localizedName == "shade" ||
                          frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if !isShade {
                previousFocusedApp = frontApp
                Log.debug("Captured previous app: \(frontApp?.localizedName ?? "none")")
            } else if let tracked = lastNonShadeFrontApp {
                // Shade is frontmost (timing issue) - use proactively tracked app
                previousFocusedApp = tracked
                Log.debug("Captured previous app (via tracking): \(tracked.localizedName ?? "none")")
            }
        }

        // Always return a valid app for context gathering
        // Priority: previousFocusedApp (explicit capture) > lastNonShadeFrontApp (proactive tracking)
        let result = previousFocusedApp ?? lastNonShadeFrontApp
        if result == nil {
            Log.warn("No previous app available for context - this should not happen")
        }
        return result
    }

    /// Show panel, recreating surface if needed (when backgrounded)
    /// Note: Call capturePreviousFocusedApp() BEFORE this if you need focus restoration
    /// - Parameter skipPositioning: If true, don't reposition panel (used for sidebar mode)
    func showPanelWithSurface(skipPositioning: Bool = false) {
        if isBackgrounded, let terminalView = terminalView {
            Log.debug("Recreating surface from backgrounded state")
            terminalView.recreateSurface(
                command: appConfig.effectiveCommand,
                workingDirectory: appConfig.workingDirectory
            )
            isBackgrounded = false
        }
        panel?.show(skipPositioning: skipPositioning)
    }

    /// Background the app - destroy surface but keep running
    private func backgroundApp() {
        Log.debug("Backgrounding app (process exited)")
        hidePanel()
        terminalView?.destroySurface()
        isBackgrounded = true
    }

    // MARK: - Ghostty Callbacks (Static for C interop)

    /// Wakeup callback - called when ghostty needs the main thread
    private static let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        // Tick timer handles updates, nothing needed here
    }

    /// Action callback - handle ghostty actions (keybinds, etc.)
    private static let actionCallback: @convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool = { _, _, _ in
        Log.debug("Ghostty action triggered")
        return true
    }

    /// Read clipboard callback
    private static let readClipboardCallback: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Void = { _, _, _ in
        // Simplified - would need to implement clipboard reading
    }

    /// Confirm read clipboard callback
    private static let confirmReadClipboardCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void = { _, _, _, _ in
        // Auto-confirm clipboard reads for now
    }

    /// Write clipboard callback
    private static let writeClipboardCallback: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void = { _, _, content, _, _ in
        guard let content = content else { return }
        if let data = content.pointee.data {
            let str = String(cString: data)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }
    }

    /// Close surface callback - hide panel instead of terminating
    private static let closeSurfaceCallback: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { _, _ in
        DispatchQueue.main.async {
            ShadeAppDelegate.shared?.hidePanel()
        }
    }

    // MARK: - Ghostty Initialization

    private func initializeGhostty() -> Bool {
        // Create configuration
        guard let cfg = ghostty_config_new() else {
            Log.error("ghostty_config_new failed")
            return false
        }

        // Load default config files (user's ghostty config)
        ghostty_config_load_default_files(cfg)

        // Finalize config
        ghostty_config_finalize(cfg)
        self.ghosttyConfig = cfg

        // Create runtime configuration with callbacks
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: ShadeAppDelegate.wakeupCallback,
            action_cb: ShadeAppDelegate.actionCallback,
            read_clipboard_cb: ShadeAppDelegate.readClipboardCallback,
            confirm_read_clipboard_cb: ShadeAppDelegate.confirmReadClipboardCallback,
            write_clipboard_cb: ShadeAppDelegate.writeClipboardCallback,
            close_surface_cb: ShadeAppDelegate.closeSurfaceCallback
        )

        // Create the ghostty app
        guard let app = ghostty_app_new(&runtimeConfig, cfg) else {
            Log.error("ghostty_app_new failed")
            return false
        }
        self.ghosttyApp = app

        Log.debug("Ghostty app created")
        return true
    }

    // MARK: - Panel Creation

    private func createPanel() {
        guard let app = ghosttyApp else { return }

        // Calculate panel size based on config (percentage or absolute pixels)
        let panelSize = calculatePanelSize()
        let panelRect = NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)

        Log.debug("Panel size: \(Int(panelSize.width))x\(Int(panelSize.height))")

        // Create floating panel with screen mode from config
        let panel = ShadePanel(contentRect: panelRect, screenMode: appConfig.screenMode)

        // Create terminal view with command/workingDirectory from config
        let terminalView = TerminalView(
            frame: panelRect,
            ghosttyApp: app,
            command: appConfig.effectiveCommand,
            workingDirectory: appConfig.workingDirectory
        )
        panel.contentView = terminalView
        self.terminalView = terminalView
        self.panel = panel

        // Configure focus border from config
        let focusBorderConfig = ShadeConfig.shared.window?.focusBorder
        panel.configureFocusBorder(config: focusBorderConfig)

        // Configure unfocused dimming from config
        panel.dimUnfocusedOpacity = ShadeConfig.shared.window?.dimUnfocused

        // Observe panel focus changes to update menubar icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        // Apply initial mode from config and show unless startHidden is set
        if !appConfig.startHidden {
            if appConfig.panelMode != .floating {
                // Start in sidebar mode
                enterSidebarMode(appConfig.panelMode)
            } else {
                panel.show()
            }
        } else {
            Log.debug("Starting hidden")
        }
    }

    /// Calculate panel size from config values
    /// Values <= 1.0 are treated as percentages of screen size
    /// Values > 1.0 are treated as absolute pixel values
    private func calculatePanelSize() -> NSSize {
        // Use screen based on config mode (primary vs focused)
        let screen: NSScreen?
        switch appConfig.screenMode {
        case .primary:
            screen = NSScreen.screens.first
        case .focused:
            screen = NSScreen.main ?? NSScreen.screens.first
        }
        
        guard let screen = screen else {
            return NSSize(width: 800, height: 500)
        }

        let screenFrame = screen.visibleFrame

        let width: CGFloat
        if appConfig.width <= 1.0 {
            width = screenFrame.width * CGFloat(appConfig.width)
        } else {
            width = CGFloat(appConfig.width)
        }

        let height: CGFloat
        if appConfig.height <= 1.0 {
            height = screenFrame.height * CGFloat(appConfig.height)
        } else {
            height = CGFloat(appConfig.height)
        }

        return NSSize(width: width, height: height)
    }

    // MARK: - Event Loop

    private func startTickTimer() {
        // Run ghostty tick at 60fps
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self, let app = self.ghosttyApp else { return }
            ghostty_app_tick(app)

            // Check if child process has exited (only if not already backgrounded/terminating)
            if !self.isTerminating,
               !self.isBackgrounded,
               let terminalView = self.terminalView,
               terminalView.hasSurface,
               terminalView.hasProcessExited() {
                Log.debug("Child process exited, backgrounding")
                self.backgroundApp()
            }
        }
    }
}
