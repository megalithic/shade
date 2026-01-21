import AppKit
import os.log

// MARK: - Protocols for Dependency Injection

/// Protocol for querying running applications (allows mocking in tests)
public protocol WorkspaceProvider: Sendable {
    var frontmostApplication: NSRunningApplication? { get }
}

/// Protocol for app identity checking (allows mocking in tests)
public protocol AppIdentityProvider: Sendable {
    var bundleIdentifier: String? { get }
    var processIdentifier: Int32 { get }
}

// MARK: - Default Implementations

/// Default implementation using real NSWorkspace
public struct RealWorkspaceProvider: WorkspaceProvider {
    public var frontmostApplication: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    public init() {}
}

/// Default implementation using real Bundle/ProcessInfo
public struct RealAppIdentityProvider: AppIdentityProvider {
    public var bundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    public var processIdentifier: Int32 {
        ProcessInfo.processInfo.processIdentifier
    }

    public init() {}
}

// MARK: - FocusTracker

/// Tracks the previously focused (non-Shade) application for context gathering and focus restoration.
///
/// This class solves a race condition: when Shade receives a capture notification, it may already
/// be frontmost, making it impossible to query the "previous" app at that moment.
///
/// ## Solution
/// We proactively track `lastNonShadeFrontApp` via workspace notifications, updating it whenever
/// ANY non-Shade app becomes frontmost. This gives us a reliable way to know which app the user
/// was in, even after Shade has become frontmost.
///
/// ## Two Distinct Use Cases
/// 1. **Context Gathering** - Uses `lastNonShadeFrontApp` (always current, proactively tracked)
/// 2. **Focus Restoration** - Uses `previousFocusedApp` (set when panel first becomes visible)
///
/// ## Testing
/// Inject mock `WorkspaceProvider` and `AppIdentityProvider` to test without real window management.
public final class FocusTracker {

    // MARK: - Dependencies

    private let workspaceProvider: WorkspaceProvider
    private let appIdentityProvider: AppIdentityProvider
    private let logger = Logger(subsystem: "io.shade", category: "FocusTracker")

    // MARK: - State

    /// Last known non-Shade frontmost app (tracked proactively via workspace notifications)
    /// This is the PRIMARY source for context gathering - always reflects the most recent non-Shade app.
    public private(set) var lastNonShadeFrontApp: NSRunningApplication?

    /// Previously focused app (set when panel becomes visible)
    /// This is used for FOCUS RESTORATION - where to return focus when hiding the panel.
    public private(set) var previousFocusedApp: NSRunningApplication?

    /// Whether the panel is currently visible (affects which tracking mode is used)
    public var isPanelVisible: Bool = false

    // MARK: - Initialization

    public init(
        workspaceProvider: WorkspaceProvider = RealWorkspaceProvider(),
        appIdentityProvider: AppIdentityProvider = RealAppIdentityProvider()
    ) {
        self.workspaceProvider = workspaceProvider
        self.appIdentityProvider = appIdentityProvider
    }

    // MARK: - Public API

    /// Called when an app becomes frontmost (from workspace notification)
    /// Updates `lastNonShadeFrontApp` if the app is not Shade.
    public func trackAppActivation(_ app: NSRunningApplication) {
        if !isShade(app) {
            lastNonShadeFrontApp = app
            logger.debug("Tracked frontmost app: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
        } else {
            logger.debug("Skipping Shade from tracking")
        }
    }

    /// Get the target app for context gathering.
    ///
    /// Returns the most recent non-Shade app:
    /// - Primary: `lastNonShadeFrontApp` (proactively tracked, always current)
    /// - Fallback: `previousFocusedApp` (if tracking hasn't captured anything yet)
    ///
    /// Also updates `previousFocusedApp` for focus restoration if panel is not visible.
    @discardableResult
    public func captureTargetApp() -> NSRunningApplication? {
        logger.debug("captureTargetApp: isPanelVisible=\(self.isPanelVisible)")
        logger.debug("  lastNonShadeFrontApp: \(self.lastNonShadeFrontApp?.localizedName ?? "nil")")
        logger.debug("  previousFocusedApp: \(self.previousFocusedApp?.localizedName ?? "nil")")

        // For FOCUS RESTORATION: only update previousFocusedApp when panel becomes visible
        if !isPanelVisible {
            let frontApp = workspaceProvider.frontmostApplication
            if let app = frontApp, !isShade(app) {
                previousFocusedApp = frontApp
                logger.debug("Updated previousFocusedApp: \(app.localizedName ?? "none")")
            } else if let tracked = lastNonShadeFrontApp {
                // Shade is frontmost (timing issue) - use proactively tracked app
                previousFocusedApp = tracked
                logger.debug("Updated previousFocusedApp via tracking: \(tracked.localizedName ?? "none")")
            }
        }

        // For CONTEXT GATHERING: always use lastNonShadeFrontApp (proactively tracked)
        // This is the most recent non-Shade app, even if user switched apps while panel is visible
        let result = lastNonShadeFrontApp ?? previousFocusedApp
        logger.debug("captureTargetApp returning: \(result?.localizedName ?? "nil")")

        if result == nil {
            logger.warning("No target app available - this should not happen")
        }

        return result
    }

    /// Get the app to restore focus to when hiding the panel.
    /// Uses `lastNonShadeFrontApp` for the most current app, falling back to `previousFocusedApp`.
    public func getAppForFocusRestoration() -> NSRunningApplication? {
        lastNonShadeFrontApp ?? previousFocusedApp
    }

    /// Check if an app is Shade (by bundle ID, name, or PID)
    public func isShade(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == appIdentityProvider.bundleIdentifier ||
        app.localizedName == "shade" ||
        app.processIdentifier == appIdentityProvider.processIdentifier
    }

    // MARK: - Testing Helpers

    /// Reset all tracked state (useful for tests)
    public func reset() {
        lastNonShadeFrontApp = nil
        previousFocusedApp = nil
        isPanelVisible = false
    }

    /// Directly set lastNonShadeFrontApp (for tests)
    public func setLastNonShadeFrontApp(_ app: NSRunningApplication?) {
        lastNonShadeFrontApp = app
    }

    /// Directly set previousFocusedApp (for tests)
    public func setPreviousFocusedApp(_ app: NSRunningApplication?) {
        previousFocusedApp = app
    }
}
