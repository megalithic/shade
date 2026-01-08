import Foundation

// MARK: - App Type Enum

/// Categorization of application types for context gathering
public enum AppType: String, Codable, CaseIterable, Sendable {
    /// Web browser (Safari, Chrome, Brave, Arc, Firefox, etc.)
    case browser

    /// Terminal emulator (Ghostty, Kitty, iTerm, Terminal.app, etc.)
    case terminal

    /// Neovim running inside a terminal (detected via socket, upgraded from terminal)
    case neovim

    /// Code editor or IDE (VS Code, Xcode, Zed, etc.)
    case editor

    /// Communication app (Slack, Discord, Messages, etc.)
    case communication

    /// Any other application
    case other
}

// MARK: - App Type Detector

/// Detects the type of an application based on its bundle identifier
/// and optional context (like AXDocument URL for browser detection)
public struct AppTypeDetector {

    // MARK: - Bundle ID Patterns

    /// Terminal emulator bundle ID patterns (case-insensitive substring match)
    public static let terminalPatterns: Set<String> = [
        "ghostty",
        "kitty",
        "iterm",
        "terminal",
        "alacritty",
        "warp",
        "hyper",
        "wezterm",
        "tabby",
    ]

    /// Browser bundle ID patterns (case-insensitive substring match)
    public static let browserPatterns: Set<String> = [
        "safari",
        "chrome",
        "brave",
        "firefox",
        "edge",
        "opera",
        "vivaldi",
        "thebrowser", // Arc
        "chromium",
        "orion",
        "duckduckgo",
        "tor browser",
    ]

    /// Editor/IDE bundle ID patterns (case-insensitive substring match)
    public static let editorPatterns: Set<String> = [
        "vscode",
        "visual studio code",
        "xcode",
        "sublime",
        "textedit",
        "bbedit",
        "nova",
        "zed",
        "textmate",
        "atom",
        "intellij",
        "webstorm",
        "pycharm",
        "rubymine",
        "goland",
        "clion",
        "rider",
        "android studio",
        "fleet",
        "cursor",
    ]

    /// Communication app bundle ID patterns (case-insensitive substring match)
    public static let communicationPatterns: Set<String> = [
        "slack",
        "discord",
        "messages",      // Apple Messages (com.apple.MobileSMS)
        "mail",
        "teams",
        "telegram",
        "signal",
        "whatsapp",
        "zoom",
        "facetime",
        "skype",
        "webex",
        "element",       // Matrix client
        "beeper",
    ]

    // MARK: - Known Bundle IDs (exact match, higher priority)

    /// Known browser bundle IDs (exact match)
    public static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.brave.Browser.nightly",
        "com.brave.Browser.dev",
        "com.brave.Browser.beta",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", // Arc
        "org.chromium.Chromium",
        "com.kagi.kagimacOS", // Orion
        "com.duckduckgo.macos.browser",
    ]

    /// Known terminal bundle IDs (exact match)
    public static let knownTerminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "io.alacritty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
    ]

    /// Known editor bundle IDs (exact match)
    public static let knownEditorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.apple.TextEdit",
        "com.barebones.bbedit",
        "com.panic.Nova",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// Known communication app bundle IDs (exact match)
    public static let knownCommunicationBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.MobileSMS",  // Messages
        "com.apple.mail",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp",
        "us.zoom.xos",
        "com.apple.FaceTime",
    ]

    // MARK: - Detection

    /// Detect the app type from a bundle identifier
    /// - Parameters:
    ///   - bundleID: The bundle identifier (e.g., "com.apple.Safari")
    ///   - documentURL: Optional AXDocument URL - if it's http(s), indicates browser-like behavior
    /// - Returns: The detected AppType
    public static func detect(bundleID: String?, documentURL: String? = nil) -> AppType {
        guard let bundleID = bundleID, !bundleID.isEmpty else {
            return .other
        }

        // 1. Check exact matches first (highest confidence)
        if knownBrowserBundleIDs.contains(bundleID) {
            return .browser
        }
        if knownTerminalBundleIDs.contains(bundleID) {
            return .terminal
        }
        if knownEditorBundleIDs.contains(bundleID) {
            return .editor
        }
        if knownCommunicationBundleIDs.contains(bundleID) {
            return .communication
        }

        let lowercasedID = bundleID.lowercased()

        // 2. Check pattern matches (case-insensitive substring)
        for pattern in terminalPatterns {
            if lowercasedID.contains(pattern) {
                return .terminal
            }
        }

        for pattern in browserPatterns {
            if lowercasedID.contains(pattern) {
                return .browser
            }
        }

        for pattern in editorPatterns {
            if lowercasedID.contains(pattern) {
                return .editor
            }
        }

        for pattern in communicationPatterns {
            if lowercasedID.contains(pattern) {
                return .communication
            }
        }

        // 3. Check AXDocument URL for browser-like behavior
        // Apps that show http(s) URLs in their AXDocument are acting like browsers
        if let url = documentURL, !url.isEmpty {
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                return .browser
            }
        }

        return .other
    }

    /// Check if an app type represents a code-related context
    public static func isCodeContext(_ appType: AppType) -> Bool {
        switch appType {
        case .terminal, .neovim, .editor:
            return true
        case .browser, .communication, .other:
            return false
        }
    }

    /// Check if an app type might have text selection available via Accessibility
    public static func supportsAccessibilitySelection(_ appType: AppType) -> Bool {
        // All app types theoretically support AX selection, but some are more reliable
        // Browsers are better queried via JXA for selection
        switch appType {
        case .browser:
            return false // Use JXA instead for browsers
        case .terminal, .neovim, .editor, .communication, .other:
            return true
        }
    }
}

// MARK: - Browser Info

/// Information about a known browser for JXA scripting
public struct BrowserInfo: Sendable {
    /// The JXA application name (e.g., "Brave Browser Nightly")
    public let jxaName: String

    /// Whether this is Safari (uses different JXA syntax)
    public let isSafari: Bool

    public init(jxaName: String, isSafari: Bool = false) {
        self.jxaName = jxaName
        self.isSafari = isSafari
    }
}

extension AppTypeDetector {

    /// Map of browser bundle IDs to their JXA info
    public static let browserJXAInfo: [String: BrowserInfo] = [
        "com.apple.Safari": BrowserInfo(jxaName: "Safari", isSafari: true),
        "com.brave.Browser.nightly": BrowserInfo(jxaName: "Brave Browser Nightly"),
        "com.brave.Browser": BrowserInfo(jxaName: "Brave Browser"),
        "com.brave.Browser.dev": BrowserInfo(jxaName: "Brave Browser Dev"),
        "com.brave.Browser.beta": BrowserInfo(jxaName: "Brave Browser Beta"),
        "com.google.Chrome": BrowserInfo(jxaName: "Google Chrome"),
        "com.google.Chrome.canary": BrowserInfo(jxaName: "Google Chrome Canary"),
        "org.chromium.Chromium": BrowserInfo(jxaName: "Chromium"),
        "company.thebrowser.Browser": BrowserInfo(jxaName: "Arc"),
        "org.mozilla.firefox": BrowserInfo(jxaName: "Firefox"),
        "com.microsoft.edgemac": BrowserInfo(jxaName: "Microsoft Edge"),
        "com.operasoftware.Opera": BrowserInfo(jxaName: "Opera"),
        "com.vivaldi.Vivaldi": BrowserInfo(jxaName: "Vivaldi"),
    ]

    /// Get JXA info for a browser bundle ID
    /// - Parameter bundleID: The browser's bundle identifier
    /// - Returns: BrowserInfo if this is a known browser with JXA support, nil otherwise
    public static func browserInfo(for bundleID: String) -> BrowserInfo? {
        return browserJXAInfo[bundleID]
    }
}
