import Foundation
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "io.shade", category: "JXABridge")

// MARK: - Browser Context

/// Context extracted from a browser via JXA (JavaScript for Automation)
public struct BrowserContext: Sendable, Equatable {
    /// The URL of the active tab
    public let url: String?

    /// The title of the active tab
    public let title: String?

    /// Selected text in the page (if any)
    public let selection: String?

    public init(url: String?, title: String?, selection: String?) {
        self.url = url
        self.title = title
        self.selection = selection
    }

    /// Whether any meaningful context was captured
    public var hasContent: Bool {
        url != nil || title != nil || (selection != nil && !selection!.isEmpty)
    }
}

// MARK: - JXA Bridge

/// Bridge for executing JXA (JavaScript for Automation) scripts to query browser context.
///
/// JXA allows querying browser-specific information that isn't available via the
/// standard Accessibility API, such as the current URL and in-page text selection.
///
/// ## Supported Browsers
/// - **Chromium-based**: Brave, Chrome, Arc, Edge, Opera, Vivaldi, Chromium
/// - **Safari**: Uses a different JXA API (`doJavaScript` vs `execute`)
/// - **Firefox**: Limited support - URL and title only, no in-page JS execution
///
/// ## Usage
/// ```swift
/// if let browserInfo = AppTypeDetector.browserInfo(for: bundleID) {
///     let context = await JXABridge.shared.getBrowserContext(for: browserInfo)
///     print("URL: \(context?.url ?? "none")")
/// }
/// ```
///
/// ## Notes
/// - Requires Automation permission in System Preferences for Safari
/// - First call to a browser may trigger a permission prompt
/// - Scripts timeout after 2 seconds by default to avoid hanging on unresponsive apps
public final class JXABridge: Sendable {

    public static let shared = JXABridge()

    private init() {}

    // MARK: - Public API

    /// Get browser context (URL, title, selection) for a known browser.
    ///
    /// - Parameters:
    ///   - browserInfo: The BrowserInfo for this browser (from `AppTypeDetector.browserInfo(for:)`)
    ///   - timeout: Maximum time to wait for the script to complete (default 2 seconds)
    /// - Returns: BrowserContext if successful, nil if the browser isn't running or script fails
    public func getBrowserContext(
        for browserInfo: BrowserInfo,
        timeout: Duration = .seconds(2)
    ) async -> BrowserContext? {
        let script: String
        if browserInfo.isSafari {
            script = makeSafariScript()
        } else if browserInfo.jxaName == "Firefox" {
            // Firefox doesn't support in-page JS execution via JXA
            script = makeFirefoxScript()
        } else {
            script = makeChromiumScript(appName: browserInfo.jxaName)
        }

        return await executeJXA(script: script, timeout: timeout)
    }

    /// Get browser context by bundle ID.
    ///
    /// Convenience method that looks up the BrowserInfo automatically.
    ///
    /// - Parameters:
    ///   - bundleID: The browser's bundle identifier
    ///   - timeout: Maximum time to wait
    /// - Returns: BrowserContext if successful, nil if unknown browser or script fails
    public func getBrowserContext(
        forBundleID bundleID: String,
        timeout: Duration = .seconds(2)
    ) async -> BrowserContext? {
        guard let browserInfo = AppTypeDetector.browserInfo(for: bundleID) else {
            logger.debug("Unknown browser bundle ID: \(bundleID)")
            return nil
        }
        return await getBrowserContext(for: browserInfo, timeout: timeout)
    }

    // MARK: - Script Templates

    /// Generate JXA script for Chromium-based browsers (Brave, Chrome, Arc, Edge, etc.)
    private func makeChromiumScript(appName: String) -> String {
        // Note: We escape the app name in case it contains special characters
        let escapedName = appName.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function() {
            var browser = Application("\(escapedName)");
            if (!browser.running()) {
                return JSON.stringify({error: "not_running"});
            }
            var windows = browser.windows;
            if (!windows || windows.length === 0) {
                return JSON.stringify({error: "no_windows"});
            }
            var win = windows[0];
            var tab = win.activeTab;
            if (!tab) {
                return JSON.stringify({error: "no_active_tab"});
            }
            
            var url = null;
            var title = null;
            var selection = "";
            
            try { url = tab.url(); } catch(e) {}
            try { title = tab.title(); } catch(e) {}
            try {
                selection = browser.execute(tab, {javascript: "window.getSelection().toString()"}) || "";
            } catch(e) {
                // Selection extraction failed - this is common and OK
            }
            
            return JSON.stringify({
                url: url,
                title: title,
                selection: selection
            });
        })();
        """
    }

    /// Generate JXA script for Safari (uses different API)
    private func makeSafariScript() -> String {
        return """
        (function() {
            var safari = Application("Safari");
            if (!safari.running()) {
                return JSON.stringify({error: "not_running"});
            }
            var windows = safari.windows;
            if (!windows || windows.length === 0) {
                return JSON.stringify({error: "no_windows"});
            }
            var win = windows[0];
            var tab = win.currentTab;
            if (!tab) {
                return JSON.stringify({error: "no_active_tab"});
            }
            
            var url = null;
            var title = null;
            var selection = "";
            
            try { url = tab.url(); } catch(e) {}
            try { title = tab.name(); } catch(e) {}
            try {
                // Safari uses doJavaScript with {in: tab} syntax
                selection = safari.doJavaScript("window.getSelection().toString()", {in: tab}) || "";
            } catch(e) {
                // Selection extraction failed - may need Automation permission
            }
            
            return JSON.stringify({
                url: url,
                title: title,
                selection: selection
            });
        })();
        """
    }

    /// Generate JXA script for Firefox (limited - no in-page JS execution)
    private func makeFirefoxScript() -> String {
        return """
        (function() {
            var firefox = Application("Firefox");
            if (!firefox.running()) {
                return JSON.stringify({error: "not_running"});
            }
            var windows = firefox.windows;
            if (!windows || windows.length === 0) {
                return JSON.stringify({error: "no_windows"});
            }
            var win = windows[0];
            
            var url = null;
            var title = null;
            
            // Firefox exposes URL and title but doesn't support execute()
            try { url = win.url ? win.url() : null; } catch(e) {}
            try { title = win.name ? win.name() : null; } catch(e) {}
            
            return JSON.stringify({
                url: url,
                title: title,
                selection: null
            });
        })();
        """
    }

    // MARK: - Script Execution

    /// Execute a JXA script with timeout using Process + osascript
    private func executeJXA(script: String, timeout: Duration) async -> BrowserContext? {
        // Race between script execution and timeout
        return await withTaskGroup(of: BrowserContext?.self) { group in
            // Task 1: Execute the script
            group.addTask {
                await self.runOsascript(script: script)
            }

            // Task 2: Timeout
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // Timeout sentinel
            }

            // Return first result, cancel the other
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    /// Run osascript with the given JXA script
    private func runOsascript(script: String) async -> BrowserContext? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { [stdoutPipe, stderrPipe] _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                // Log stderr if there was an error
                if !stderrData.isEmpty {
                    if let stderrString = String(data: stderrData, encoding: .utf8) {
                        logger.debug("JXA stderr: \(stderrString)")
                    }
                }

                // Parse stdout
                guard let output = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !output.isEmpty else {
                    logger.debug("JXA returned empty output")
                    continuation.resume(returning: nil)
                    return
                }

                let result = self.parseJXAOutput(output)
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                logger.error("Failed to run osascript: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Output Parsing

    /// Parse JSON output from JXA script
    private func parseJXAOutput(_ output: String) -> BrowserContext? {
        guard let data = output.data(using: .utf8) else {
            logger.warning("Failed to convert JXA output to data")
            return nil
        }

        // Define the expected JSON structure
        struct JXAResponse: Decodable {
            let url: String?
            let title: String?
            let selection: String?
            let error: String?
        }

        do {
            let response = try JSONDecoder().decode(JXAResponse.self, from: data)

            // Check for error field
            if let error = response.error {
                logger.debug("JXA script returned error: \(error)")
                return nil
            }

            return BrowserContext(
                url: response.url,
                title: response.title,
                selection: response.selection?.isEmpty == true ? nil : response.selection
            )
        } catch {
            logger.warning("Failed to parse JXA output: \(error). Output was: \(output.prefix(200))")
            return nil
        }
    }
}
