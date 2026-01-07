# shade

A **standalone CLI executable** for macOS that provides a floating terminal panel using [libghostty](https://github.com/ghostty-org/ghostty). A lighter shade of ghost.

Designed for quick note capture workflows with nvim.

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
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|                 libghostty (Zig -> C)                       |
|  Terminal emulation, GPU rendering (Metal), PTY management  |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|                 Child Process (e.g., nvim)                  |
+-------------------------------------------------------------+
```

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
