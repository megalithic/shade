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

/// Configuration for shade, parsed from command-line args
struct AppConfig {
    /// Width as percentage of screen (0.0-1.0) or absolute pixels if > 1
    var width: Double = 0.45
    /// Height as percentage of screen (0.0-1.0) or absolute pixels if > 1
    var height: Double = 0.5
    /// Command to run in terminal (default: user's shell)
    var command: String? = nil
    /// Working directory
    var workingDirectory: String? = nil
    /// Start hidden (wait for toggle signal)
    var startHidden: Bool = false
    /// Enable verbose logging
    var verbose: Bool = false

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
          -v, --verbose            Enable verbose logging
          --help                   Show this help

        Toggle via distributed notification:
          io.shade.toggle          Toggle visibility
          io.shade.show            Show panel
          io.shade.hide            Hide panel
          io.shade.quit            Terminate shade
          io.shade.note.capture    Open quick capture
          io.shade.note.daily      Open daily note

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
