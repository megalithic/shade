# meganote

A **standalone CLI executable** for macOS that provides a floating terminal panel using [libghostty](https://github.com/ghostty-org/ghostty). Designed for quick note capture workflows with nvim.

## What It Is

meganote is a **command-line tool**, not a traditional `.app` bundle or framework:

```
$ ./meganote --help
meganote - Floating terminal panel powered by libghostty

Usage: meganote [options]

Options:
  -w, --width <value>      Width (0.0-1.0 for %, or pixels if > 1)
  -h, --height <value>     Height (0.0-1.0 for %, or pixels if > 1)
  -c, --command <cmd>      Command to run (e.g., "nvim ~/notes/capture.md")
  -d, --working-directory  Working directory
  --hidden                 Start hidden (wait for toggle signal)
  -v, --verbose            Enable verbose logging
  --help                   Show this help
```

When run, it creates a floating NSPanel window hosting a ghostty terminal surface. When the terminal process exits, meganote automatically terminates.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Hammerspoon (Lua)                           │
│  - Launches meganote via hs.task.new()                      │
│  - Sends distributed notifications for show/hide/toggle     │
└─────────────────────────────────────────────────────────────┘
                              │
                     IPC (distributed notifications)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 meganote (Swift CLI)                        │
├─────────────────────────────────────────────────────────────┤
│  main.swift          Entry point, CLI arg parsing           │
│  MegaAppDelegate     App lifecycle, IPC listener, tick loop │
│  MegaPanel           NSPanel: floating, non-activating      │
│  TerminalView        NSView hosting ghostty surface         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 libghostty (Zig → C)                        │
│  Terminal emulation, GPU rendering (Metal), PTY management  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 Child Process (e.g., nvim)                  │
└─────────────────────────────────────────────────────────────┘
```

### IPC Protocol

meganote listens for macOS distributed notifications:

| Notification Name       | Action                    |
|------------------------|---------------------------|
| `com.meganote.toggle`  | Toggle panel visibility   |
| `com.meganote.show`    | Show panel                |
| `com.meganote.hide`    | Hide panel                |

Send from Hammerspoon:
```lua
hs.distributednotifications.post("com.meganote.toggle", nil, nil)
```

Or from command line:
```bash
# Using Swift
swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: NSNotification.Name("com.meganote.toggle"), object: nil)'
```

## Installation

### With Nix (Recommended)

The flake includes [Ghostty](https://github.com/ghostty-org/ghostty) as an input and builds GhosttyKit automatically:

```bash
# Clone meganote
git clone https://github.com/megalithic/meganote
cd meganote

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

# Clone and build meganote
cd ~/code
git clone https://github.com/megalithic/meganote
cd meganote

# Verify GhosttyKit is found
just check-deps

# Build and install
just release
just install
```

meganote auto-detects GhosttyKit in these locations:
1. `GHOSTTYKIT_PATH` environment variable
2. `./vendor/GhosttyKit` (vendored in repo)
3. `~/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64`
4. `~/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64`
5. `../ghostty/macos/GhosttyKit.xcframework/macos-arm64`

## Usage

### Standalone

```bash
# Open default shell
meganote

# Custom size (40% of screen)
meganote --width 0.4 --height 0.4

# Run nvim directly
meganote --command nvim --working-directory ~/notes

# Start hidden (show via IPC later)
meganote --hidden

# Debug output
meganote --verbose
```

### With Hammerspoon

The recommended setup uses Hammerspoon for hotkey integration:

```lua
-- ~/.hammerspoon/init.lua or your config
local meganote = require("lib.meganote")

-- Configure
meganote.configure({
    width = 0.4,
    height = 0.4,
    command = "/bin/zsh -c 'rm -f /tmp/nvim-capture.sock; exec nvim --listen /tmp/nvim-capture.sock'",
    workingDirectory = os.getenv("HOME") .. "/notes/captures",
    startHidden = true,
})

-- Pre-launch hidden
meganote.launch()

-- Bind hotkey
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "n", function()
    meganote.captureWithContext()
end)
```

The `meganote.lua` module handles:
- Launching meganote as a background process
- Sending IPC notifications to control visibility
- Context-aware capture (gathers frontmost app info)
- Opening files in nvim via `--remote`

## Development

### Project Structure

```
meganote/
├── Package.swift          # Swift PM config (auto-detects GhosttyKit)
├── flake.nix             # Nix flake (builds GhosttyKit from ghostty input)
├── flake.lock            # Pinned dependencies including ghostty
├── justfile              # Task runner
├── LICENSE               # MIT (with ghostty attribution)
├── README.md
└── Sources/
    ├── main.swift            # CLI parsing, logging, ghostty init
    ├── MegaAppDelegate.swift # App lifecycle, IPC, tick timer
    ├── MegaPanel.swift       # Floating NSPanel
    └── TerminalView.swift    # Ghostty surface view
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
just nix-build          # Build meganote with Nix
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
- `aarch64-darwin` → `-Dtarget=aarch64-macos` → `macos-arm64/`
- `x86_64-darwin` → `-Dtarget=x86_64-macos` → `macos-x86_64/`

**Output structure:**
```
$GHOSTTYKIT_PATH/
├── lib/
│   └── libghostty-fat.a    # Static library
└── include/
    ├── ghostty.h           # C header
    └── module.modulemap    # Swift module map
```

**Available flake outputs:**
```bash
# Just GhosttyKit (useful for other projects)
nix build .#ghosttykit

# meganote binary
nix build .#meganote
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

There's no `ghostty_config_load_string()` — command/workingDir go in surface config only.

### Process Exit Detection

meganote polls `ghostty_surface_process_exited()` in the 60fps tick timer. When the child process exits:
1. Hide panel
2. Terminate app

This ensures clean exit when nvim quits (`:wq`).

### Window Behavior

- `NSPanel` with `.nonactivatingPanel` — doesn't steal focus
- `.floating` level — above normal windows
- `.canJoinAllSpaces` — visible on all Spaces
- `.fullScreenAuxiliary` — can overlay fullscreen apps
- Hidden title bar and window buttons for clean appearance

### nvim Server Socket

When using nvim with `--listen`, wrap in shell to clean stale sockets:

```bash
/bin/zsh -c 'rm -f /tmp/nvim-capture.sock; exec nvim --listen /tmp/nvim-capture.sock'
```

This prevents "address already in use" errors on restart.

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
meganote --verbose
```

### libghostty Migration Path

This project currently builds against a local GhosttyKit framework compiled from the Ghostty source. When libghostty is released as a standalone public library:

1. **flake.nix** — Update ghostty input to use official libghostty package
2. **Package.swift** — Simplify to reference the official package
3. **API compatibility** — The C API (`ghostty_*` functions) should remain stable

The abstraction layer (TerminalView, callbacks) isolates libghostty interactions, making migration straightforward.

## License

MIT — See [LICENSE](LICENSE) for details.

This project uses [libghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto, also MIT licensed.

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) - Terminal emulator and libghostty
- [Hammerspoon](https://www.hammerspoon.org/) - macOS automation
