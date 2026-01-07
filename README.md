# shade

A **standalone CLI executable** for macOS that provides a floating terminal panel using [libghostty](https://github.com/ghostty-org/ghostty). A lighter shade of ghost.

## Use Cases

shade is a **general-purpose floating terminal** that can run any command:

- **Quick shell access**: Pop up a terminal for quick commands, hide when done
- **Note capture with nvim**: Deep nvim integration for note-taking workflows
- **REPLs and scripts**: Run Python, Node, or any interactive tool in a floating window
- **Monitoring**: Keep `htop`, `lazygit`, or logs visible while working
- **AI assistants**: Run CLI tools like `aichat` or `ollama` in an always-available panel

The nvim integration (msgpack-rpc, note capture, daily notes) is optional -- shade works great as a simple floating terminal wrapper.

## What It Is

shade is a **command-line tool**, not a traditional `.app` bundle or framework:

```
$ ./shade --help
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
```

When run, it creates a floating NSPanel window hosting a ghostty terminal surface. When the terminal process exits, shade hides (backgrounds) rather than terminating.

## Architecture

```
+-------------------------------------------------------------+
|                 Hammerspoon (Lua)                           |
|  - Launches shade via hs.task.new()                         |
|  - Sends distributed notifications for show/hide/toggle     |
|  - Writes context to ~/.local/state/shade/context.json      |
+-------------------------------------------------------------+
                              |
                     IPC (distributed notifications)
                              |
                              v
+-------------------------------------------------------------+
|                 shade (Swift CLI)                           |
+-------------------------------------------------------------+
|  main.swift            Entry point, CLI arg parsing         |
|  ShadeAppDelegate      App lifecycle, IPC listener, tick    |
|  ShadePanel            NSPanel: floating, non-activating    |
|  TerminalView          NSView hosting ghostty surface       |
|  NvimSocketManager     Native msgpack-rpc over Unix socket  |
|  MsgpackRpc            Protocol encoder/decoder             |
+-------------------------------------------------------------+
           |                                    |
           v                                    v
+-------------------------+    +--------------------------------+
|   libghostty (Zig->C)   |    |   Unix Socket (msgpack-rpc)    |
|   Terminal emulation    |    |   ~/.local/state/shade/        |
|   GPU rendering (Metal) |    |   nvim.sock                    |
|   PTY management        |    |                                |
+-------------------------+    +--------------------------------+
           |                                    |
           v                                    v
+-------------------------------------------------------------+
|                 nvim (--listen <socket>)                    |
|   - Terminal UI via libghostty PTY                          |
|   - API access via msgpack-rpc socket                       |
+-------------------------------------------------------------+
```

**Communication Paths:**
1. **Hammerspoon -> shade**: Distributed notifications (`io.shade.*`)
2. **shade -> libghostty**: C FFI calls for terminal rendering
3. **shade <-> nvim**: Bidirectional msgpack-rpc over Unix socket
4. **libghostty <-> nvim**: PTY for terminal I/O

### IPC Protocol

shade listens for macOS distributed notifications:

| Notification Name       | Action                    |
|-------------------------|---------------------------|
| `io.shade.toggle`       | Toggle panel visibility   |
| `io.shade.show`         | Show panel                |
| `io.shade.hide`         | Hide panel                |
| `io.shade.quit`         | Terminate shade           |
| `io.shade.note.capture` | Open quick capture note   |
| `io.shade.note.daily`   | Open daily note           |

Send from Hammerspoon:
```lua
hs.distributednotifications.post("io.shade.toggle", nil, nil)
```

Or from command line:
```bash
# Using Swift
swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: NSNotification.Name("io.shade.toggle"), object: nil)'
```

### XDG Directories

shade uses XDG-compliant paths for state:

```
~/.local/state/shade/
+-- context.json    # Capture context (written by Hammerspoon)
+-- nvim.sock       # Nvim RPC socket
+-- shade.pid       # Process management
```

### Key Features

**Background-on-Exit**: When the child process (e.g., nvim `:wq`) exits, shade hides instead of terminating. The app stays running in the background, ready to show again instantly when triggered.

**Emergency Escape Hotkey**: Press `Cmd+Escape` at any time to hide shade, even if Hammerspoon is broken or unresponsive. This uses a CGEvent tap and requires Accessibility permissions.

**Nvim RPC Integration**: shade can communicate with nvim via `--server` to open files, run commands, and check buffer state. The nvim socket path is `~/.local/state/shade/nvim.sock`.

**Note Workflows**:
- `io.shade.note.capture`: Opens a new quick capture note. Reads context from `context.json` (written by Hammerspoon) for source app, URL, selection, etc.
- `io.shade.note.daily`: Opens today's daily note, using `:ObsidianToday` if available.

## Installation

### With Nix (Recommended)

The flake includes [Ghostty](https://github.com/ghostty-org/ghostty) as an input and builds GhosttyKit automatically:

```bash
# Clone shade
git clone https://github.com/megalithic/shade
cd shade

# Enter dev shell (builds GhosttyKit from source - may take a few minutes first time)
nix develop

# Build and install
just release
just install
```

The Nix flake:
- Fetches Ghostty source automatically
- Builds GhosttyKit (libghostty) for your architecture
- Sets `GHOSTTYKIT_PATH` environment variable
- Provides Swift, just, and Zig toolchains

### Without Nix

You'll need to build GhosttyKit manually:

```bash
# Prerequisites: Zig 0.13+, Swift 5.9+

# Clone and build Ghostty
cd ~/src
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Doptimize=ReleaseFast

# Clone and build shade
cd ~/code
git clone https://github.com/megalithic/shade
cd shade

# Verify GhosttyKit is found
just check-deps

# Build and install
just release
just install
```

shade auto-detects GhosttyKit in these locations:
1. `GHOSTTYKIT_PATH` environment variable
2. `./vendor/GhosttyKit` (vendored in repo)
3. `~/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64`
4. `~/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64`
5. `../ghostty/macos/GhosttyKit.xcframework/macos-arm64`

## Usage

### Standalone

```bash
# Open default shell
shade

# Custom size (40% of screen)
shade --width 0.4 --height 0.4

# Run nvim directly
shade --command nvim --working-directory ~/notes

# Start hidden (show via IPC later)
shade --hidden

# Debug output
shade --verbose
```

### Non-Nvim Examples

shade works great with any terminal command:

```bash
# Floating Python REPL
shade --command python3 --width 0.5 --height 0.4

# Floating lazygit for the current repo
shade --command lazygit --working-directory ~/code/myproject

# System monitoring
shade --command "htop" --width 0.6 --height 0.5

# AI chat assistant
shade --command "aichat" --width 0.4 --height 0.6

# Tail logs
shade --command "tail -f /var/log/system.log" --width 0.8 --height 0.3

# Interactive node REPL
shade --command node --working-directory ~/projects/myapp
```

When the command exits, shade hides and waits for the next toggle -- it doesn't quit. This makes it perfect for ephemeral tasks.

### With Hammerspoon

The recommended setup uses Hammerspoon for hotkey integration:

```lua
-- ~/.hammerspoon/init.lua or your config
local shade = require("lib.interop.shade")

-- Configure
shade.configure({
    width = 0.4,
    height = 0.4,
    command = "/bin/zsh -c 'rm -f ~/.local/state/shade/nvim.sock; exec nvim --listen ~/.local/state/shade/nvim.sock'",
    workingDirectory = os.getenv("HOME") .. "/notes/captures",
    startHidden = true,
})

-- Pre-launch hidden
shade.launch()

-- Bind hotkey
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "n", function()
    shade.captureWithContext()
end)
```

The `shade.lua` module handles:
- Launching shade as a background process
- Sending IPC notifications to control visibility
- Context-aware capture (gathers frontmost app info)
- Opening files in nvim via RPC

#### Complete Hammerspoon Module Example

Here's a full-featured `shade.lua` module for Hammerspoon:

```lua
-- ~/.hammerspoon/lib/interop/shade.lua
local M = {}

local stateDir = os.getenv("HOME") .. "/.local/state/shade"
local contextFile = stateDir .. "/context.json"

-- Default configuration
M.config = {
    binary = os.getenv("HOME") .. "/.local/bin/shade",
    width = 0.4,
    height = 0.4,
    command = nil,  -- Set in configure()
    workingDirectory = os.getenv("HOME") .. "/notes",
    startHidden = true,
    verbose = false,
}

-- Configure shade options
function M.configure(opts)
    for k, v in pairs(opts or {}) do
        M.config[k] = v
    end
    
    -- Default command if not set
    if not M.config.command then
        M.config.command = string.format(
            "/bin/zsh -c 'rm -f %s/nvim.sock; exec nvim --listen %s/nvim.sock'",
            stateDir, stateDir
        )
    end
end

-- Launch shade (if not already running)
function M.launch()
    -- Check if already running
    local pidFile = stateDir .. "/shade.pid"
    local f = io.open(pidFile, "r")
    if f then
        local pid = f:read("*n")
        f:close()
        if pid then
            local result = os.execute("kill -0 " .. pid .. " 2>/dev/null")
            if result then
                return -- Already running
            end
        end
    end
    
    -- Build arguments
    local args = {
        "-w", tostring(M.config.width),
        "-h", tostring(M.config.height),
        "-c", M.config.command,
        "-d", M.config.workingDirectory,
    }
    if M.config.startHidden then
        table.insert(args, "--hidden")
    end
    if M.config.verbose then
        table.insert(args, "--verbose")
    end
    
    -- Launch as background task
    hs.task.new(M.config.binary, nil, args):start()
end

-- Send IPC notification to shade
function M.notify(name)
    hs.distributednotifications.post("io.shade." .. name, nil, nil)
end

-- Toggle visibility
function M.toggle()
    M.launch()  -- Ensure running
    M.notify("toggle")
end

-- Show panel
function M.show()
    M.launch()
    M.notify("show")
end

-- Hide panel
function M.hide()
    M.notify("hide")
end

-- Quit shade
function M.quit()
    M.notify("quit")
end

-- Gather context from frontmost app
local function gatherContext()
    local app = hs.application.frontmostApplication()
    local win = app and app:focusedWindow()
    
    local context = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        source_app = app and app:name() or "Unknown",
        source_bundle = app and app:bundleID() or nil,
        window_title = win and win:title() or nil,
    }
    
    -- Try to get URL from browser
    if app then
        local bundleID = app:bundleID()
        if bundleID == "com.apple.Safari" then
            local ok, url = hs.osascript.applescript([[
                tell application "Safari" to return URL of current tab of front window
            ]])
            if ok then context.url = url end
        elseif bundleID == "com.google.Chrome" then
            local ok, url = hs.osascript.applescript([[
                tell application "Google Chrome" to return URL of active tab of front window
            ]])
            if ok then context.url = url end
        elseif bundleID == "company.thebrowser.Browser" then
            local ok, url = hs.osascript.applescript([[
                tell application "Arc" to return URL of active tab of front window
            ]])
            if ok then context.url = url end
        end
    end
    
    -- Try to get selected text
    local oldClipboard = hs.pasteboard.getContents()
    hs.eventtap.keyStroke({"cmd"}, "c", 50000)  -- 50ms
    hs.timer.usleep(100000)  -- 100ms
    local selection = hs.pasteboard.getContents()
    if selection and selection ~= oldClipboard and #selection < 10000 then
        context.selection = selection
    end
    hs.pasteboard.setContents(oldClipboard or "")
    
    return context
end

-- Write context to file for shade to read
local function writeContext(context)
    -- Ensure directory exists
    os.execute("mkdir -p " .. stateDir)
    
    local f = io.open(contextFile, "w")
    if f then
        f:write(hs.json.encode(context))
        f:close()
    end
end

-- Open quick capture with context
function M.captureWithContext()
    M.launch()
    
    -- Gather and write context
    local context = gatherContext()
    writeContext(context)
    
    -- Tell shade to open capture
    M.notify("note.capture")
end

-- Open daily note
function M.openDailyNote()
    M.launch()
    M.notify("note.daily")
end

-- Example hotkey bindings (add to your init.lua)
--[[
local shade = require("lib.interop.shade")

shade.configure({
    width = 0.5,
    height = 0.6,
    workingDirectory = os.getenv("HOME") .. "/notes",
})

-- Hyper+N: Quick capture with context
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "n", shade.captureWithContext)

-- Hyper+D: Daily note
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "d", shade.openDailyNote)

-- Hyper+Space: Toggle shade
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "space", shade.toggle)
]]

return M
```

#### Context JSON Format

When `captureWithContext()` is called, shade reads `~/.local/state/shade/context.json`:

```json
{
    "timestamp": "2026-01-07T12:30:00Z",
    "source_app": "Arc",
    "source_bundle": "company.thebrowser.Browser",
    "window_title": "GitHub - shade repository",
    "url": "https://github.com/megalithic/shade",
    "selection": "Selected text from the page..."
}
```

This context is available to nvim for creating rich capture notes with source attribution.

## Development

### Project Structure

```
shade/
+-- Package.swift          # Swift PM config (auto-detects GhosttyKit)
+-- flake.nix              # Nix flake (builds GhosttyKit from ghostty input)
+-- flake.lock             # Pinned dependencies including ghostty
+-- justfile               # Task runner
+-- LICENSE                # MIT (with ghostty attribution)
+-- README.md
+-- Sources/
    +-- main.swift            # CLI parsing, logging, ghostty init
    +-- ShadeAppDelegate.swift # App lifecycle, IPC, tick timer
    +-- ShadePanel.swift       # Floating NSPanel
    +-- TerminalView.swift     # Ghostty surface view
    +-- StateDirectory.swift   # XDG state directory management
    +-- NvimRPC.swift          # Nvim CLI communication (--server --remote-send)
    +-- NvimSocketManager.swift # Native msgpack-rpc over Unix socket
    +-- MsgpackRpc.swift       # Msgpack-RPC protocol encoder/decoder
    +-- GlobalHotkey.swift     # Emergency escape hotkey (CGEvent tap)
```

### Just Commands

```bash
# Development
just build              # Debug build
just run [ARGS]         # Build and run
just dev                # Run at 40% size with verbose
just run-hidden         # Test hidden mode

# Release
just release            # Optimized build
just universal          # Universal binary (arm64 + x86_64)
just release-info       # Show binary info
just install            # Install to ~/.local/bin
just uninstall          # Remove from ~/.local/bin

# GhosttyKit
just check-deps         # Verify GhosttyKit is available
just setup-ghostty      # Clone & build Ghostty (non-Nix)
just update-ghostty     # Update Ghostty and rebuild
just vendor-ghostty     # Copy GhosttyKit to ./vendor/

# Maintenance
just clean              # Remove .build/
just rebuild            # Clean + build
just rebuild-release    # Clean + release
just format             # Format code (needs swift-format)
just lint               # Lint code

# Nix
just nix-build          # Build shade with Nix
just nix-build-ghosttykit # Build only GhosttyKit
just nix-run [ARGS]     # Run with Nix
just nix-develop        # Enter dev shell (full, with Zig)
just nix-develop-lite   # Enter lite shell (no Zig)
just nix-update-ghostty # Update ghostty input to latest
just nix-info           # Show flake outputs and metadata
```

## Technical Notes

### How the Nix Flake Builds GhosttyKit

The flake fetches Ghostty source directly from GitHub and builds GhosttyKit (libghostty) locally:

```nix
# flake.nix - key parts explained
inputs.ghostty = {
  url = "github:ghostty-org/ghostty";
  flake = false;  # Raw source, not flake outputs
};

# Build derivation
ghosttyKit = pkgs.stdenv.mkDerivation {
  src = ghostty;  # Uses the fetched source
  nativeBuildInputs = [ zig_0_13 git ];
  buildInputs = [ /* macOS frameworks: Metal, AppKit, etc. */ ];

  buildPhase = ''
    zig build -Doptimize=ReleaseFast -Dtarget=${zigTarget}
  '';

  installPhase = ''
    # Copies from: macos/GhosttyKit.xcframework/{arch}/
    cp libghostty-fat.a $out/lib/
    cp Headers/* $out/include/
  '';
};
```

**Architecture targeting:**
- `aarch64-darwin` -> `-Dtarget=aarch64-macos` -> `macos-arm64/`
- `x86_64-darwin` -> `-Dtarget=x86_64-macos` -> `macos-x86_64/`

**Output structure:**
```
$GHOSTTYKIT_PATH/
+-- lib/
|   +-- libghostty-fat.a    # Static library
+-- include/
    +-- ghostty.h           # C header
    +-- module.modulemap    # Swift module map
```

**Available flake outputs:**
```bash
# Just GhosttyKit (useful for other projects)
nix build .#ghosttykit

# shade binary
nix build .#shade
# or
nix build  # default

# Development shells
nix develop           # Full (includes Zig)
nix develop .#lite    # Lite (uses pre-built GhosttyKit)
```

**Troubleshooting:**
- **Build takes forever**: First build compiles Zig + Ghostty (~5-10 min). Subsequent builds use Nix cache.
- **"zig not found"**: Ensure you're in `nix develop`, not `nix develop .#lite`
- **Framework errors**: The flake includes all required Apple frameworks. If missing, check `buildInputs`.
- **Wrong architecture**: Nix auto-detects; force with `nix develop --system aarch64-darwin`

### libghostty Integration

**C String Lifetime**: Swift strings passed to ghostty C functions must stay alive during the call. Use nested `withCString` closures:

```swift
command.withCString { cmdPtr in
    workDir.withCString { dirPtr in
        config.command = cmdPtr
        config.working_directory = dirPtr
        ghostty_surface_new(app, &config)
    }
}
```

**Config vs Surface Config**:
- `ghostty_config_t` = App-level settings (loaded from user's `~/.config/ghostty/config`)
- `ghostty_surface_config_s` = Per-surface settings (command, working directory)

There's no `ghostty_config_load_string()` -- command/workingDir go in surface config only.

### Process Exit Detection

shade polls `ghostty_surface_process_exited()` in the 60fps tick timer. When the child process exits:
1. Hide panel (don't terminate)
2. Await new IPC command to show again

This enables persistent background operation.

### Window Behavior

- `NSPanel` with `.nonactivatingPanel` -- doesn't steal focus
- `.floating` level -- above normal windows
- `.canJoinAllSpaces` -- visible on all Spaces
- `.fullScreenAuxiliary` -- can overlay fullscreen apps
- Hidden title bar and window buttons for clean appearance

### nvim Server Socket

When using nvim with `--listen`, wrap in shell to clean stale sockets:

```bash
/bin/zsh -c 'rm -f ~/.local/state/shade/nvim.sock; exec nvim --listen ~/.local/state/shade/nvim.sock'
```

This prevents "address already in use" errors on restart.

### Native Nvim RPC (msgpack-rpc)

shade includes two approaches for communicating with nvim:

**Option A: CLI Shell-out (`NvimRPC.swift`)**
- Uses `nvim --server <socket> --remote-send/--remote-expr`
- Simple, spawns a process per command
- Good for occasional commands

**Option B: Native Socket (`NvimSocketManager.swift`)**
- Persistent Unix socket connection using msgpack-rpc protocol
- No process spawning overhead
- Supports async requests, notifications, and bidirectional communication
- Access to all 400+ nvim API functions

The native socket manager implements the [msgpack-rpc spec](https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md):

```
Message Types:
- Request:      [0, msgid, method, params]  -> awaits Response
- Response:     [1, msgid, error, result]   -> matches Request by msgid
- Notification: [2, method, params]         -> fire-and-forget
```

**Architecture:**
```
+------------------+     Unix Socket      +------------------+
|     shade        | <-- msgpack-rpc -->  |      nvim        |
|                  |                      |                  |
| NvimSocketManager|     ~/.local/state/  | --listen <sock>  |
|   MsgpackRpc     |     shade/nvim.sock  |                  |
+------------------+                      +------------------+
```

**Usage Example (Swift):**
```swift
// Create and connect
let nvim = NvimSocketManager()
try await nvim.connect()

// Call nvim API functions
let response = try await nvim.request(
    method: "nvim_eval",
    params: [.string("expand('%:p')")]
)
if response.isSuccess, let path = response.stringResult {
    print("Current file: \(path)")
}

// Send notification (no response)
try nvim.notify(method: "nvim_command", params: [.string("echo 'Hello from shade!'")])

// Listen for events
for await message in nvim.messageStream {
    switch message {
    case .notification(let notif):
        print("Got notification: \(notif.method)")
    case .request(let req):
        // nvim asking us something (rare)
        try nvim.respond(msgid: req.msgid, result: .bool(true))
    default:
        break
    }
}

// Disconnect
await nvim.disconnect()
```

**Common nvim API Methods:**
| Method | Description | Example Params |
|--------|-------------|----------------|
| `nvim_eval` | Evaluate Vimscript | `[.string("expand('%')")]` |
| `nvim_command` | Run Ex command | `[.string(":write")]` |
| `nvim_buf_get_name` | Get buffer filename | `[.int(0)]` (0 = current) |
| `nvim_buf_set_lines` | Set buffer content | `[.int(0), .int(0), .int(-1), .bool(false), .array([...])]` |
| `nvim_get_current_buf` | Get current buffer handle | `[]` |
| `nvim_buf_attach` | Subscribe to buffer events | `[.int(bufnr), .bool(false), .map([:])]` |

See [nvim API docs](https://neovim.io/doc/user/api.html) for the full list.

## Maintenance

### Updating GhosttyKit

With Nix:
```bash
nix flake lock --update-input ghostty
nix develop  # Rebuilds GhosttyKit
just rebuild-release
```

Without Nix:
```bash
just update-ghostty
just rebuild-release
```

### Debug Output

Use `--verbose` or `-v` flag to enable debug logging:

```bash
shade --verbose
```

### libghostty Migration Path

This project currently builds against a local GhosttyKit framework compiled from the Ghostty source. When libghostty is released as a standalone public library:

1. **flake.nix** -- Update ghostty input to use official libghostty package
2. **Package.swift** -- Simplify to reference the official package
3. **API compatibility** -- The C API (`ghostty_*` functions) should remain stable

The abstraction layer (TerminalView, callbacks) isolates libghostty interactions, making migration straightforward.

## License

MIT -- See [LICENSE](LICENSE) for details.

This project uses [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto, also MIT licensed.

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) - Terminal emulator and libghostty
- [Hammerspoon](https://www.hammerspoon.org/) - macOS automation
