import AppKit
import GhosttyKit

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

    // MARK: - Initialization

    init(config: AppConfig) {
        self.appConfig = config
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShadeAppDelegate.shared = self
        Log.debug("Starting...")

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

        Log.debug("Listening for IPC notifications")
    }

    @objc private func handleToggleNotification(_ notification: Notification) {
        Log.debug("IPC: toggle")
        if isPanelVisible {
            hidePanel()
        } else {
            showPanelWithSurface()
        }
    }

    @objc private func handleShowNotification(_ notification: Notification) {
        Log.debug("IPC: show")
        showPanelWithSurface()
    }

    @objc private func handleHideNotification(_ notification: Notification) {
        Log.debug("IPC: hide")
        hidePanel()
    }

    @objc private func handleQuitNotification(_ notification: Notification) {
        Log.debug("IPC: quit")
        isTerminating = true
        NSApp.terminate(nil)
    }

    @objc private func handleNoteCaptureNotification(_ notification: Notification) {
        Log.debug("IPC: note.capture")

        // Read context from context.json (written by Hammerspoon)
        // TODO: Context gathering will move to Shade in future task
        let context = StateDirectory.readContext()
        if let ctx = context {
            Log.debug("Capture context: \(ctx.appType ?? "unknown") from \(ctx.appName ?? "unknown")")
        }

        // Delete context file after reading (one-shot)
        StateDirectory.deleteContextFile()

        // If already showing and has active surface, just focus
        // (don't create a new capture when already in capture mode)
        if isPanelVisible && !isBackgrounded {
            Log.debug("Already visible with active surface, focusing")
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Show panel with surface (will recreate if backgrounded)
        showPanelWithSurface()

        // Open capture using native RPC (auto-connects with retry)
        ShadeNvim.shared.connectAndPerform(
            { nvim in try await nvim.openNewCapture(context: context) },
            onSuccess: { path in Log.debug("Capture opened: \(path)") },
            onError: { error in Log.error("Failed to open capture: \(error)") }
        )
    }

    @objc private func handleDailyNoteNotification(_ notification: Notification) {
        Log.debug("IPC: note.daily")

        // Show panel with surface (will recreate if backgrounded)
        showPanelWithSurface()

        // Open daily note using native RPC (auto-connects with retry)
        ShadeNvim.shared.connectAndPerform(
            { nvim in try await nvim.openDailyNote() },
            onSuccess: { path in Log.debug("Daily note opened: \(path)") },
            onError: { error in Log.error("Failed to open daily note: \(error)") }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.debug("Shutting down...")

        // Stop the timer
        tickTimer?.invalidate()
        tickTimer = nil

        // Disconnect from nvim
        Task {
            await ShadeNvim.shared.disconnect()
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
        panel?.hide()
    }

    /// Check if panel is visible
    var isPanelVisible: Bool {
        return panel?.isVisible ?? false
    }

    /// Show panel, recreating surface if needed (when backgrounded)
    func showPanelWithSurface() {
        if isBackgrounded, let terminalView = terminalView {
            Log.debug("Recreating surface from backgrounded state")
            terminalView.recreateSurface(
                command: appConfig.command,
                workingDirectory: appConfig.workingDirectory
            )
            isBackgrounded = false
        }
        panel?.show()
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

        // Create floating panel
        let panel = ShadePanel(contentRect: panelRect)

        // Create terminal view with command/workingDirectory from config
        let terminalView = TerminalView(
            frame: panelRect,
            ghosttyApp: app,
            command: appConfig.command,
            workingDirectory: appConfig.workingDirectory
        )
        panel.contentView = terminalView
        self.terminalView = terminalView
        self.panel = panel

        // Show panel unless startHidden is set
        if !appConfig.startHidden {
            panel.show()
        } else {
            Log.debug("Starting hidden")
        }
    }

    /// Calculate panel size from config values
    /// Values <= 1.0 are treated as percentages of screen size
    /// Values > 1.0 are treated as absolute pixel values
    private func calculatePanelSize() -> NSSize {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
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
