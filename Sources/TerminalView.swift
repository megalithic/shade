import AppKit
import GhosttyKit

/// NSView that hosts a ghostty terminal surface
class TerminalView: NSView {

    // MARK: - Properties

    /// The ghostty app
    private let ghosttyApp: ghostty_app_t

    /// Command to run in terminal (nil = default shell)
    private let command: String?

    /// Working directory for the terminal
    private let workingDirectory: String?

    /// The ghostty surface
    private var surface: ghostty_surface_t?

    /// Whether we accept first responder (for keyboard input)
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Initialization

    init(frame: NSRect, ghosttyApp: ghostty_app_t, command: String? = nil, workingDirectory: String? = nil) {
        self.ghosttyApp = ghosttyApp
        self.command = command
        self.workingDirectory = workingDirectory
        super.init(frame: frame)

        // Set up the view
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Create the surface after a brief delay to ensure view is ready
        DispatchQueue.main.async { [weak self] in
            self?.createSurface()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface Creation

    private func createSurface() {
        // Use nested closures to keep C strings alive during surface creation
        createSurfaceWithStrings(
            command: command,
            workingDirectory: workingDirectory
        )
    }

    /// Helper to create surface with proper C string lifetime management
    private func createSurfaceWithStrings(command: String?, workingDirectory: String?) {
        // Create surface configuration
        var config = ghostty_surface_config_new()

        // Set userdata to self
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Set platform-specific config
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))

        // Set scale factor
        if let screen = window?.screen ?? NSScreen.main {
            config.scale_factor = screen.backingScaleFactor
        } else {
            config.scale_factor = 2.0
        }

        // Helper to create surface with optional C strings
        func doCreateSurface(cmdPtr: UnsafePointer<CChar>?, dirPtr: UnsafePointer<CChar>?) {
            config.command = cmdPtr
            config.working_directory = dirPtr

            if let cmd = command {
                Log.debug("Creating surface with command: \(cmd)")
            }
            if let dir = workingDirectory {
                Log.debug("Creating surface with working directory: \(dir)")
            }

            // Create the surface
            guard let newSurface = ghostty_surface_new(ghosttyApp, &config) else {
                Log.error("ghostty_surface_new failed")
                return
            }
            self.surface = newSurface
            Log.debug("Surface created")

            // Set initial size
            updateSurfaceSize()
        }

        // Handle all combinations of optional strings
        switch (command, workingDirectory) {
        case (let cmd?, let dir?):
            cmd.withCString { cmdPtr in
                dir.withCString { dirPtr in
                    doCreateSurface(cmdPtr: cmdPtr, dirPtr: dirPtr)
                }
            }
        case (let cmd?, nil):
            cmd.withCString { cmdPtr in
                doCreateSurface(cmdPtr: cmdPtr, dirPtr: nil)
            }
        case (nil, let dir?):
            dir.withCString { dirPtr in
                doCreateSurface(cmdPtr: nil, dirPtr: dirPtr)
            }
        case (nil, nil):
            doCreateSurface(cmdPtr: nil, dirPtr: nil)
        }
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            // Update scale factor when moving to a window
            updateSurfaceSize()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface = surface else { return }

        // Get the backing size (in pixels)
        let backingSize = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(backingSize.width),
            UInt32(backingSize.height)
        )
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        // Create key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.mods = convertModifiers(event.modifierFlags)

        // Consumed mods are the modifiers that contributed to producing the text.
        // Control and command never contribute to text translation, so we exclude them.
        // This allows shift+; to produce ":" while still reporting shift as a modifier.
        keyEvent.consumed_mods = convertModifiers(
            event.modifierFlags.subtracting([.control, .command])
        )

        keyEvent.keycode = UInt32(event.keyCode)

        // Calculate unshifted codepoint - the character with no modifiers applied.
        // This is needed for proper key encoding (e.g., shift+; should know the base key is ";")
        keyEvent.unshifted_codepoint = 0
        if let unshiftedChars = event.characters(byApplyingModifiers: []),
           let codepoint = unshiftedChars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = codepoint.value
        }

        // Set text if available
        if let chars = event.characters {
            chars.withCString { cstr in
                keyEvent.text = cstr
                keyEvent.composing = false
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            keyEvent.composing = false
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.mods = convertModifiers(event.modifierFlags)
        keyEvent.consumed_mods = convertModifiers(
            event.modifierFlags.subtracting([.control, .command])
        )
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.composing = false

        // Calculate unshifted codepoint for key release as well
        keyEvent.unshifted_codepoint = 0
        if let unshiftedChars = event.characters(byApplyingModifiers: []),
           let codepoint = unshiftedChars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = codepoint.value
        }

        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        // For modifier keys, we need to determine if press or release
        // based on whether the modifier is now present
        keyEvent.action = GHOSTTY_ACTION_PRESS  // Simplified - would need to track state
        keyEvent.mods = convertModifiers(event.modifierFlags)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0

        _ = ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let mods = convertModifiers(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else {
            super.mouseUp(with: event)
            return
        }

        let mods = convertModifiers(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }

        let point = convert(event.locationInWindow, from: nil)
        let mods = convertModifiers(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }

        let point = convert(event.locationInWindow, from: nil)
        let mods = convertModifiers(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else {
            super.scrollWheel(with: event)
            return
        }

        // Scroll mods is an int bitmask with precision flag
        var scrollMods: ghostty_input_scroll_mods_t = Int32(convertModifiers(event.modifierFlags).rawValue)
        // Add precision flag if needed (bit 16 or similar - need to check actual value)
        if event.hasPreciseScrollingDeltas {
            scrollMods |= (1 << 16)  // Precision flag position - may need adjustment
        }

        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods
        )
    }

    // MARK: - Tracking Area (for mouse moved events)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Add new tracking area for mouse moved events
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    // MARK: - Process State

    /// Check if the child process has exited
    func hasProcessExited() -> Bool {
        guard let surface = surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if surface exists
    var hasSurface: Bool {
        return surface != nil
    }

    /// Destroy the current surface (called when process exits and we're backgrounding)
    func destroySurface() {
        if let surface = surface {
            Log.debug("Destroying surface")
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    /// Recreate the surface with new command/workingDirectory
    func recreateSurface(command: String? = nil, workingDirectory: String? = nil) {
        destroySurface()
        Log.debug("Recreating surface")
        createSurfaceWithStrings(
            command: command ?? self.command,
            workingDirectory: workingDirectory ?? self.workingDirectory
        )
    }

    // MARK: - Helpers

    private func convertModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) {
            mods |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.control) {
            mods |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.option) {
            mods |= GHOSTTY_MODS_ALT.rawValue
        }
        if flags.contains(.command) {
            mods |= GHOSTTY_MODS_SUPER.rawValue
        }
        if flags.contains(.capsLock) {
            mods |= GHOSTTY_MODS_CAPS.rawValue
        }

        return ghostty_input_mods_e(rawValue: mods)
    }
}
