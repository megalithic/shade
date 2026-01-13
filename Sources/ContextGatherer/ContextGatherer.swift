import AppKit
import Foundation
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "io.shade", category: "ContextGatherer")

// MARK: - Gathered Context

/// Complete context gathered from the frontmost application
///
/// This struct matches the JSON schema expected by obsidian.nvim templates
/// and the existing Hammerspoon context format for backwards compatibility.
public struct GatheredContext: Sendable, Codable, Equatable {
    /// The type of application: "browser", "terminal", "neovim", "editor", "communication", "other"
    public var appType: String?

    /// The application name (e.g., "Brave Browser Nightly")
    public var appName: String?

    /// The application bundle identifier
    public var bundleID: String?

    /// The window title
    public var windowTitle: String?

    /// URL if source is a browser
    public var url: String?

    /// File path if source is an editor or nvim
    public var filePath: String?

    /// Filetype/language from nvim or detected
    public var filetype: String?

    /// Selected text (from AX, JXA, or nvim)
    public var selection: String?

    /// Detected programming language
    public var detectedLanguage: String?

    /// Cursor line number (1-indexed, from nvim)
    public var line: Int?

    /// Cursor column number (1-indexed, from nvim)
    public var col: Int?

    /// ISO8601 timestamp when context was gathered
    public var timestamp: String?

    public init(
        appType: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        filePath: String? = nil,
        filetype: String? = nil,
        selection: String? = nil,
        detectedLanguage: String? = nil,
        line: Int? = nil,
        col: Int? = nil,
        timestamp: String? = nil
    ) {
        self.appType = appType
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.filePath = filePath
        self.filetype = filetype
        self.selection = selection
        self.detectedLanguage = detectedLanguage
        self.line = line
        self.col = col
        self.timestamp = timestamp
    }

    /// Whether any meaningful content was gathered
    public var hasContent: Bool {
        selection != nil || url != nil || filePath != nil || windowTitle != nil
    }
}

// MARK: - Context Gatherer

/// Orchestrates context gathering from the frontmost application
///
/// This class coordinates multiple subsystems to gather rich context:
/// - **AccessibilityHelper**: Window title, selected text via AX API
/// - **AppTypeDetector**: Categorize app (browser, terminal, editor, etc.)
/// - **JXABridge**: Browser URL, title, and in-page selection
/// - **ShadeNvim**: Nvim buffer info, filetype, visual selection
/// - **LanguageDetector**: Detect programming language from context
///
/// ## Usage
///
/// ```swift
/// let context = await ContextGatherer.shared.gather()
/// print("App: \(context.appName ?? "unknown")")
/// print("Selection: \(context.selection ?? "none")")
/// ```
///
/// ## Flow
///
/// 1. Get frontmost app via NSWorkspace
/// 2. Detect app type from bundle ID
/// 3. Based on type:
///    - **Browser**: Use JXA for URL/title/selection, fallback to AX
///    - **Terminal**: Check for nvim, use RPC if found, else AX
///    - **Other**: Use Accessibility API
/// 4. Detect programming language from gathered context
/// 5. Return complete GatheredContext
public final class ContextGatherer: @unchecked Sendable {

    public static let shared = ContextGatherer()

    private let accessibilityHelper: AccessibilityProviding
    private let jxaBridge: JXABridge

    private init(
        accessibilityHelper: AccessibilityProviding = AccessibilityHelper.shared,
        jxaBridge: JXABridge = JXABridge.shared
    ) {
        self.accessibilityHelper = accessibilityHelper
        self.jxaBridge = jxaBridge
    }

    // MARK: - Public API

    /// Gather context from the frontmost application
    ///
    /// This is the main entry point. It automatically detects the app type
    /// and uses the appropriate method to gather context.
    ///
    /// - Parameters:
    ///   - nvimSocketDir: Directory containing nvim socket files (default: /tmp/nvim-sockets)
    ///   - targetApp: Optional pre-captured app to use instead of querying frontmost.
    ///                Use this when calling from async contexts where frontmost might change.
    /// - Returns: GatheredContext with all available information
    public func gather(
        nvimSocketDir: String = "/tmp/nvim-sockets",
        targetApp: NSRunningApplication? = nil
    ) async -> GatheredContext {
        let startTime = Date()

        // Use provided app or query frontmost
        guard let app = targetApp ?? accessibilityHelper.getFrontmostApp() else {
            logger.warning("No frontmost app found")
            return makeEmptyContext()
        }

        let bundleID = app.bundleIdentifier
        let appName = app.localizedName

        logger.debug("Gathering context from: \(appName ?? "unknown") (\(bundleID ?? "unknown"))")

        // Get window title via AX (works for all apps)
        let windowTitle = accessibilityHelper.getWindowTitle(for: app)

        // Get document URL from AX (useful for browser detection and fallback)
        let axDocumentURL = accessibilityHelper.getDocumentURL(for: app)

        // Detect app type
        let appType = AppTypeDetector.detect(bundleID: bundleID, documentURL: axDocumentURL)

        // Build initial context
        var context = GatheredContext(
            appType: appType.rawValue,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Gather type-specific context
        switch appType {
        case .browser:
            await gatherBrowserContext(app: app, bundleID: bundleID, axDocumentURL: axDocumentURL, into: &context)

        case .terminal:
            await gatherTerminalContext(app: app, nvimSocketDir: nvimSocketDir, into: &context)

        case .neovim:
            // Standalone nvim (rare - usually detected as terminal first)
            await gatherNvimContext(nvimSocketDir: nvimSocketDir, into: &context)

        case .editor, .communication, .other:
            gatherAccessibilityContext(app: app, into: &context)
        }

        // Detect programming language from gathered context
        context.detectedLanguage = LanguageDetector.detect(
            selection: context.selection,
            url: context.url,
            filetype: context.filetype,
            filePath: context.filePath
        )

        let elapsed = Date().timeIntervalSince(startTime)
        logger.debug("Context gathered in \(String(format: "%.2f", elapsed * 1000))ms")

        return context
    }

    // MARK: - Type-Specific Gathering

    /// Gather context from a browser using JXA
    private func gatherBrowserContext(
        app: NSRunningApplication,
        bundleID: String?,
        axDocumentURL: String?,
        into context: inout GatheredContext
    ) async {
        // Try JXA first for rich context
        if let bundleID = bundleID {
            if let browserContext = await jxaBridge.getBrowserContext(forBundleID: bundleID) {
                context.url = browserContext.url
                context.windowTitle = browserContext.title ?? context.windowTitle
                context.selection = browserContext.selection

                if browserContext.hasContent {
                    logger.debug("Browser context via JXA: url=\(browserContext.url ?? "nil")")
                    return
                }
            }
        }

        // Fallback to AX API
        logger.debug("Browser JXA failed, falling back to AX")
        context.url = axDocumentURL
        gatherAccessibilityContext(app: app, into: &context)
    }

    /// Gather context from a terminal, checking for nvim
    private func gatherTerminalContext(
        app: NSRunningApplication,
        nvimSocketDir: String,
        into context: inout GatheredContext
    ) async {
        // Check if there's an nvim instance we can query
        if let nvimContext = await gatherNvimContextIfAvailable(nvimSocketDir: nvimSocketDir) {
            // Upgrade app type to neovim
            context.appType = AppType.neovim.rawValue
            context.filePath = nvimContext.filePath
            context.filetype = nvimContext.filetype
            context.selection = nvimContext.selection
            context.line = nvimContext.line
            context.col = nvimContext.col

            if nvimContext.hasContent {
                logger.debug("Terminal context via nvim RPC: file=\(nvimContext.filePath ?? "nil")")
                return
            }
        }

        // No nvim or nvim query failed - use AX
        gatherAccessibilityContext(app: app, into: &context)
    }

    /// Gather context from nvim via RPC
    private func gatherNvimContext(
        nvimSocketDir: String,
        into context: inout GatheredContext
    ) async {
        if let nvimContext = await gatherNvimContextIfAvailable(nvimSocketDir: nvimSocketDir) {
            context.filePath = nvimContext.filePath
            context.filetype = nvimContext.filetype
            context.selection = nvimContext.selection
            context.line = nvimContext.line
            context.col = nvimContext.col
        }
    }

    /// Try to gather nvim context from any available nvim socket
    private func gatherNvimContextIfAvailable(nvimSocketDir: String) async -> NvimContextResult? {
        // Try to find an active nvim socket
        guard let socketPath = findActiveNvimSocket(in: nvimSocketDir) else {
            logger.debug("No active nvim socket found")
            return nil
        }

        logger.debug("Found nvim socket: \(socketPath)")

        // Query nvim via command line (simpler than full RPC for one-shot)
        return await queryNvimContext(socketPath: socketPath)
    }

    /// Find the most appropriate nvim socket
    ///
    /// Priority:
    /// 1. Tmux context match (if in tmux)
    /// 2. Most recently modified global socket
    private func findActiveNvimSocket(in socketDir: String) -> String? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: socketDir) else {
            return nil
        }

        // Try tmux-based detection first
        if let tmuxPrefix = getTmuxPrefix() {
            if let socketPath = findTmuxSocket(prefix: tmuxPrefix, in: socketDir) {
                return socketPath
            }
        }

        // Fallback to most recent global socket
        return findMostRecentGlobalSocket(in: socketDir)
    }

    /// Get current tmux context prefix (session_window_pane)
    private func getTmuxPrefix() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmux")
        process.arguments = ["display-message", "-p", "#{session_name}_#{window_index}_#{pane_index}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let prefix = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prefix.isEmpty {
                return prefix
            }
        } catch {
            // Not in tmux or tmux not available
        }

        return nil
    }

    /// Find socket matching tmux prefix
    private func findTmuxSocket(prefix: String, in socketDir: String) -> String? {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(atPath: socketDir) else {
            return nil
        }

        for filename in contents where filename.hasPrefix(prefix + "_") {
            let socketFile = (socketDir as NSString).appendingPathComponent(filename)
            if let socketPath = try? String(contentsOfFile: socketFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !socketPath.isEmpty {
                return socketPath
            }
        }

        return nil
    }

    /// Find most recent global_* socket
    private func findMostRecentGlobalSocket(in socketDir: String) -> String? {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(atPath: socketDir) else {
            return nil
        }

        // Find global_* files, sort by modification time
        let globalFiles = contents.filter { $0.hasPrefix("global_") }

        var mostRecent: (path: String, date: Date)?

        for filename in globalFiles {
            let fullPath = (socketDir as NSString).appendingPathComponent(filename)
            if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
               let modDate = attrs[.modificationDate] as? Date {
                if mostRecent == nil || modDate > mostRecent!.date {
                    mostRecent = (fullPath, modDate)
                }
            }
        }

        if let socketFile = mostRecent?.path,
           let socketPath = try? String(contentsOfFile: socketFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            return socketPath
        }

        return nil
    }

    /// Query nvim context via command line RPC
    private func queryNvimContext(socketPath: String) async -> NvimContextResult? {
        // Use Lua to gather all context in one call
        let luaCode = """
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        local pos = vim.api.nvim_win_get_cursor(win)
        
        -- Get visual selection if available
        local selection = nil
        local start_pos = vim.api.nvim_buf_get_mark(buf, '<')
        local end_pos = vim.api.nvim_buf_get_mark(buf, '>')
        if start_pos[1] > 0 then
            local lines = vim.api.nvim_buf_get_lines(buf, start_pos[1] - 1, end_pos[1], false)
            if #lines == 1 then
                selection = string.sub(lines[1], start_pos[2] + 1, end_pos[2] + 1)
            elseif #lines > 1 then
                lines[1] = string.sub(lines[1], start_pos[2] + 1)
                lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
                selection = table.concat(lines, '\\n')
            end
        end
        
        return vim.json.encode({
            path = vim.api.nvim_buf_get_name(buf),
            filetype = vim.bo[buf].filetype,
            line = pos[1],
            col = pos[2] + 1,
            selection = selection
        })
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nvim")
        process.arguments = [
            "--server", socketPath,
            "--remote-expr", "luaeval('\(luaCode.replacingOccurrences(of: "'", with: "''"))')"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                return nil
            }

            return parseNvimContextJSON(output)
        } catch {
            logger.warning("Failed to query nvim: \(error)")
            return nil
        }
    }

    /// Parse nvim context JSON response
    private func parseNvimContextJSON(_ json: String) -> NvimContextResult? {
        guard let data = json.data(using: .utf8) else { return nil }

        struct Response: Decodable {
            let path: String?
            let filetype: String?
            let line: Int?
            let col: Int?
            let selection: String?
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let hasPath = response.path != nil && !response.path!.isEmpty

            return NvimContextResult(
                filePath: hasPath ? response.path : nil,
                filetype: response.filetype?.isEmpty == false ? response.filetype : nil,
                selection: response.selection?.isEmpty == false ? response.selection : nil,
                line: response.line,
                col: response.col
            )
        } catch {
            logger.warning("Failed to parse nvim context: \(error)")
            return nil
        }
    }

    /// Gather context using Accessibility API
    private func gatherAccessibilityContext(app: NSRunningApplication, into context: inout GatheredContext) {
        // Get selection via AX
        if let focused = accessibilityHelper.getFocusedElement() {
            context.selection = accessibilityHelper.getSelectedText(from: focused)
        }
    }

    // MARK: - Helpers

    private func makeEmptyContext() -> GatheredContext {
        return GatheredContext(
            appType: AppType.other.rawValue,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}

// MARK: - Internal Types

/// Result from nvim context query
private struct NvimContextResult {
    let filePath: String?
    let filetype: String?
    let selection: String?
    let line: Int?
    let col: Int?

    var hasContent: Bool {
        filePath != nil || selection != nil
    }
}
