import AppKit
import Carbon.HIToolbox

/// Global hotkey registration using CGEvent tap
/// Provides emergency escape hotkey independent of Hammerspoon
class GlobalHotkey {

    // MARK: - Singleton

    static let shared = GlobalHotkey()

    // MARK: - Properties

    /// The event tap for capturing global key events
    private var eventTap: CFMachPort?

    /// Run loop source for the event tap
    private var runLoopSource: CFRunLoopSource?

    /// Callback when escape hotkey is pressed
    var onEscapePressed: (() -> Void)?

    /// Whether the hotkey is currently registered
    var isRegistered: Bool {
        return eventTap != nil
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Registration

    /// Register the emergency escape hotkey (Cmd+Escape)
    /// Requires Accessibility permissions
    /// - Returns: true if registration succeeded
    @discardableResult
    func register() -> Bool {
        guard eventTap == nil else {
            Log.debug("GlobalHotkey: Already registered")
            return true
        }

        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        if !trusted {
            Log.warn("GlobalHotkey: Accessibility permissions not granted")
            Log.warn("GlobalHotkey: Enable in System Settings > Privacy & Security > Accessibility")
            // Don't fail - the tap might still work for some events
        }

        // Create event tap for key down events
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        // Note: We use a static callback wrapper because CGEvent tap requires a C function pointer
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: GlobalHotkey.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("GlobalHotkey: Failed to create event tap")
            Log.error("GlobalHotkey: This usually means Accessibility permissions are denied")
            return false
        }

        eventTap = tap

        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.debug("GlobalHotkey: Registered Cmd+Escape as emergency escape")
        return true
    }

    /// Unregister the hotkey
    func unregister() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }

        Log.debug("GlobalHotkey: Unregistered")
    }

    // MARK: - Event Handling

    /// Static callback for CGEvent tap (required for C interop)
    private static let eventCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }

        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userInfo).takeUnretainedValue()
        return hotkey.handleEvent(proxy: proxy, type: type, event: event)
    }

    /// Handle a key event
    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Handle tap disabled events (system can disable taps)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("GlobalHotkey: Event tap was disabled, re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Only handle key down
        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        // Get key code and modifiers
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Check for Cmd+Escape (keyCode 53 = Escape)
        let isEscape = keyCode == kVK_Escape
        let isCmd = flags.contains(.maskCommand)
        let noOtherMods = !flags.contains(.maskShift) &&
                          !flags.contains(.maskControl) &&
                          !flags.contains(.maskAlternate)

        if isEscape && isCmd && noOtherMods {
            Log.debug("GlobalHotkey: Cmd+Escape pressed")

            // Call handler on main thread
            DispatchQueue.main.async { [weak self] in
                self?.onEscapePressed?()
            }

            // Return nil to consume the event (don't pass to other apps)
            return nil
        }

        // Pass through all other events
        return Unmanaged.passRetained(event)
    }
}

// MARK: - Key Codes Reference
// From Carbon.HIToolbox.Events.h
// kVK_Escape = 0x35 (53)
// kVK_Command = 0x37 (55) - but we use flags, not keycode for modifiers
