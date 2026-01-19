import AppKit
import GhosttyKit

// MARK: - Logging

/// Simple logging utility with verbose flag support
enum Log {
    /// Whether verbose logging is enabled (set via --verbose flag)
    static var verbose = false

    /// Log debug message (only when verbose is enabled)
    static func debug(_ message: @autoclosure () -> String) {
        if verbose {
            print("[shade] \(message())")
        }
    }

    /// Log info message (only when verbose is enabled)
    static func info(_ message: @autoclosure () -> String) {
        if verbose {
            print("[shade] \(message())")
        }
    }

    /// Log error message (always visible)
    static func error(_ message: @autoclosure () -> String) {
        fputs("[shade] ERROR: \(message())\n", stderr)
    }

    /// Log warning message (always visible)
    static func warn(_ message: @autoclosure () -> String) {
        fputs("[shade] WARN: \(message())\n", stderr)
    }
}

// MARK: - Configuration

/// Screen selection mode for panel positioning
enum ScreenMode: String {
    case primary = "primary"   // Always use primary screen (menu bar screen)
    case focused = "focused"   // Use screen with keyboard focus
}

/// Panel display mode
enum PanelMode: String, CaseIterable {
    case floating = "floating"           // Centered, floating above other windows (default)
    case sidebarLeft = "sidebar-left"    // Docked to left edge of screen (sidebar mode)
}

/// Configuration for shade, parsed from command-line args
struct AppConfig {
    /// Width as percentage of screen (0.0-1.0) or absolute pixels if > 1
    var width: Double = 0.5
    /// Height as percentage of screen (0.0-1.0) or absolute pixels if > 1
    var height: Double = 0.5
    /// Command to run in terminal (default: nvim with socket)
    /// Uses StateDirectory.nvimSocketPath for RPC communication
    var command: String? = nil
    /// Working directory
    var workingDirectory: String? = nil

    /// Get effective command - returns configured command or default nvim with socket
    var effectiveCommand: String {
        if let cmd = command {
            return cmd
        }
        // Default: nvim with socket for RPC, cleanup stale socket first
        // SHADE=1 env var lets nvim config detect it's running in Shade
        let socketPath = StateDirectory.nvimSocketPath
        return "/usr/bin/env zsh -c 'rm -f \(socketPath); SHADE=1 exec nvim --listen \(socketPath)'"
    }
    /// Start hidden (wait for toggle signal)
    var startHidden: Bool = false
    /// Enable verbose logging
    var verbose: Bool = false
    /// Screen mode for positioning (primary or focused)
    var screenMode: ScreenMode = .primary

    // MARK: - Size presets for different note types

    /// Daily note panel width (larger for daily notes)
    var dailyWidth: Double = 0.5
    /// Daily note panel height
    var dailyHeight: Double = 0.5
    /// Capture note panel width (smaller for quick captures)
    var captureWidth: Double = 0.5
    /// Capture note panel height
    var captureHeight: Double = 0.5

    // MARK: - Sidebar Mode Configuration

    /// Panel display mode (floating, sidebar-left, sidebar-right)
    var panelMode: PanelMode = .floating
    /// Sidebar width as percentage of screen (0.0-1.0) or absolute pixels if > 1
    var sidebarWidth: Double = 0.33

    // MARK: - LLM Configuration

    /// Disable LLM features entirely
    var noLLM: Bool = false
    /// LLM backend override (e.g., "mlx", "ollama")
    var llmBackend: String? = nil
    /// LLM model override (e.g., "mlx-community/Qwen3-8B-Instruct-4bit")
    var llmModel: String? = nil

    static func parse() -> AppConfig {
        var config = AppConfig()
        let args = CommandLine.arguments

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--width", "-w":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.width = val
                    i += 1
                }
            case "--height", "-h":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.height = val
                    i += 1
                }
            case "--command", "-c":
                if i + 1 < args.count {
                    config.command = args[i + 1]
                    i += 1
                }
            case "--working-directory", "-d":
                if i + 1 < args.count {
                    config.workingDirectory = args[i + 1]
                    i += 1
                }
            case "--hidden":
                config.startHidden = true
            case "--verbose", "-v":
                config.verbose = true
            case "--screen", "-s":
                if i + 1 < args.count {
                    if let mode = ScreenMode(rawValue: args[i + 1].lowercased()) {
                        config.screenMode = mode
                    }
                    i += 1
                }
            case "--daily-width":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.dailyWidth = val
                    i += 1
                }
            case "--daily-height":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.dailyHeight = val
                    i += 1
                }
            case "--capture-width":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.captureWidth = val
                    i += 1
                }
            case "--capture-height":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.captureHeight = val
                    i += 1
                }
            // Sidebar mode options
            case "--mode", "-m":
                if i + 1 < args.count, let mode = PanelMode(rawValue: args[i + 1]) {
                    config.panelMode = mode
                    i += 1
                }
            case "--sidebar-width":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    config.sidebarWidth = val
                    i += 1
                }
            // LLM options
            case "--no-llm":
                config.noLLM = true
            case "--llm-backend":
                if i + 1 < args.count {
                    config.llmBackend = args[i + 1]
                    i += 1
                }
            case "--llm-model":
                if i + 1 < args.count {
                    config.llmModel = args[i + 1]
                    i += 1
                }
            case "--help":
                printUsage()
                exit(0)
            default:
                break
            }
            i += 1
        }
        return config
    }

    static func printUsage() {
        print("""
        shade - Floating terminal panel powered by libghostty
        A lighter shade of ghost.

        Usage: shade [options]

        Options:
          -w, --width <value>      Width (0.0-1.0 for %, or pixels if > 1)
          -h, --height <value>     Height (0.0-1.0 for %, or pixels if > 1)
          -c, --command <cmd>      Command to run (e.g., "nvim ~/notes/capture.md")
          -d, --working-directory  Working directory
          --hidden                 Start hidden (wait for toggle signal)
          -s, --screen <mode>      Screen for positioning: primary (default), focused
          --daily-width <value>    Daily note panel width (default: 0.6)
          --daily-height <value>   Daily note panel height (default: 0.6)
          --capture-width <value>  Capture panel width (default: 0.4)
          --capture-height <value> Capture panel height (default: 0.4)
          -v, --verbose            Enable verbose logging
          --help                   Show this help

        Sidebar Mode:
          -m, --mode <mode>        Panel mode: floating (default), sidebar-left, sidebar-right
          --sidebar-width <value>  Sidebar width (default: 0.35)

        LLM Options:
          --no-llm                 Disable LLM features entirely
          --llm-backend <backend>  LLM backend: "mlx" (default), "ollama"
          --llm-model <model>      Model ID (e.g., "mlx-community/Qwen3-8B-Instruct-4bit")

        Toggle via distributed notification:
          io.shade.toggle              Toggle visibility
          io.shade.show                Show panel
          io.shade.hide                Hide panel
          io.shade.quit                Terminate shade
          io.shade.note.capture        Open quick capture
          io.shade.note.daily          Open daily note
          io.shade.mode.floating       Switch to floating mode
          io.shade.mode.sidebar-left   Switch to left sidebar mode
          io.shade.mode.sidebar-right  Switch to right sidebar mode

        Examples:
          shade --width 0.5 --height 0.4 --command "nvim ~/notes/capture.md"
          shade -w 800 -h 600 --hidden
          shade --verbose  # Debug output
        """)
    }
}

// MARK: - Application Entry Point

// Parse configuration first
let appConfig = AppConfig.parse()

// Enable verbose logging if requested
Log.verbose = appConfig.verbose

// Apply LLM CLI overrides to ShadeConfig
let cliArgs = CLIArguments(
    noLLM: appConfig.noLLM,
    llmBackend: appConfig.llmBackend,
    llmModel: appConfig.llmModel
)
ShadeConfig.configure(with: cliArgs)
Log.debug("ShadeConfig initialized (LLM enabled: \(ShadeConfig.shared.llm?.enabled ?? true))")

// Initialize Ghostty global state FIRST - this is required before any other API calls
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Log.error("ghostty_init failed")
    exit(1)
}
Log.debug("Ghostty initialized")

let app = NSApplication.shared
let delegate = ShadeAppDelegate(config: appConfig)
app.delegate = delegate
app.run()
