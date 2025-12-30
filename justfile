# MegaNote - Floating terminal panel CLI using libghostty
# https://github.com/megalithic/MegaNote

set shell := ["bash", "-cu"]

# Configuration
name := "MegaNote"
version := "0.1.0"
install_dir := env_var_or_default("PREFIX", env_var("HOME") + "/.local") + "/bin"
ghostty_src := env_var_or_default("GHOSTTY_SRC", env_var("HOME") + "/src/ghostty")

# Default recipe: build debug
default: build

# ─────────────────────────────────────────────────────────────
# Development
# ─────────────────────────────────────────────────────────────

# Build debug binary
build:
    swift build

# Build and run (debug)
run *ARGS: build
    .build/debug/{{name}} {{ARGS}}

# Run with common development flags
dev: build
    .build/debug/{{name}} --width 0.4 --height 0.4 --verbose

# Run hidden (for Hammerspoon integration testing)
run-hidden: build
    .build/debug/{{name}} --hidden --verbose

# Show help
help: build
    .build/debug/{{name}} --help

# ─────────────────────────────────────────────────────────────
# Release / Distribution
# ─────────────────────────────────────────────────────────────

# Build optimized release binary
release:
    swift build -c release

# Build universal binary (arm64 + x86_64) for distribution
universal:
    swift build -c release --arch arm64 --arch x86_64

# Show release binary info
release-info: release
    @echo "Binary: .build/release/{{name}}"
    @ls -lh .build/release/{{name}}
    @file .build/release/{{name}}
    @echo ""
    @echo "Dependencies:"
    @otool -L .build/release/{{name}} | head -20

# Install release binary to ~/.local/bin (or $PREFIX/bin)
install: release
    @mkdir -p {{install_dir}}
    cp .build/release/{{name}} {{install_dir}}/{{name}}
    @echo "Installed to {{install_dir}}/{{name}}"

# Uninstall from ~/.local/bin
uninstall:
    rm -f {{install_dir}}/{{name}}
    @echo "Removed {{install_dir}}/{{name}}"

# ─────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────

# Clean build artifacts
clean:
    rm -rf .build

# Clean and rebuild debug
rebuild: clean build

# Clean and rebuild release
rebuild-release: clean release

# Format Swift code (requires swift-format)
format:
    swift-format -i -r Sources/

# Lint Swift code (requires swift-format)
lint:
    swift-format lint -r Sources/

# ─────────────────────────────────────────────────────────────
# GhosttyKit Dependency
# ─────────────────────────────────────────────────────────────

# Check if GhosttyKit is available (searches standard locations)
check-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking for GhosttyKit..."
    echo ""

    # Check env var first (handles both Nix and xcframework structures)
    if [[ -n "${GHOSTTYKIT_PATH:-}" ]]; then
        # Nix output structure: lib/libghostty-fat.a
        if [[ -f "$GHOSTTYKIT_PATH/lib/libghostty-fat.a" ]]; then
            echo "✓ Found via GHOSTTYKIT_PATH (Nix): $GHOSTTYKIT_PATH"
            echo "  Library: $GHOSTTYKIT_PATH/lib/libghostty-fat.a"
            echo "  Headers: $GHOSTTYKIT_PATH/include/"
            exit 0
        # xcframework structure: libghostty-fat.a in root
        elif [[ -f "$GHOSTTYKIT_PATH/libghostty-fat.a" ]]; then
            echo "✓ Found via GHOSTTYKIT_PATH (xcframework): $GHOSTTYKIT_PATH"
            echo "  Library: $GHOSTTYKIT_PATH/libghostty-fat.a"
            echo "  Headers: $GHOSTTYKIT_PATH/Headers/"
            exit 0
        else
            echo "✗ GHOSTTYKIT_PATH set but libghostty-fat.a not found"
            echo "  Checked: $GHOSTTYKIT_PATH/lib/libghostty-fat.a (Nix)"
            echo "  Checked: $GHOSTTYKIT_PATH/libghostty-fat.a (xcframework)"
            exit 1
        fi
    fi

    # Check standard locations
    locations=(
        "./vendor/GhosttyKit"
        "$HOME/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
        "$HOME/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64"
        "../ghostty/macos/GhosttyKit.xcframework/macos-arm64"
    )

    for loc in "${locations[@]}"; do
        if [[ -f "$loc/libghostty-fat.a" ]]; then
            echo "✓ Found at: $loc"
            echo ""
            echo "To use explicitly, set:"
            echo "  export GHOSTTYKIT_PATH=\"$loc\""
            exit 0
        fi
    done

    echo "✗ GhosttyKit not found in any standard location"
    echo ""
    echo "Checked:"
    for loc in "${locations[@]}"; do
        echo "  - $loc"
    done
    echo ""
    echo "To fix, either:"
    echo "  1. Run 'just setup-ghostty' to clone and build"
    echo "  2. Set GHOSTTYKIT_PATH to your GhosttyKit location"
    echo "  3. Symlink/copy GhosttyKit to ./vendor/GhosttyKit"
    exit 1

# Clone and build Ghostty to get GhosttyKit (requires Zig)
setup-ghostty:
    #!/usr/bin/env bash
    set -euo pipefail

    GHOSTTY_DIR="{{ghostty_src}}"

    echo "Setting up GhosttyKit..."
    echo "Target: $GHOSTTY_DIR"
    echo ""

    # Check for Zig
    if ! command -v zig &> /dev/null; then
        echo "✗ Zig not found. Install via:"
        echo "  - nix: nix-shell -p zig"
        echo "  - brew: brew install zig"
        echo "  - https://ziglang.org/download/"
        exit 1
    fi
    echo "✓ Zig found: $(zig version)"

    # Clone if needed
    if [[ ! -d "$GHOSTTY_DIR" ]]; then
        echo ""
        echo "Cloning ghostty..."
        git clone https://github.com/ghostty-org/ghostty "$GHOSTTY_DIR"
    else
        echo "✓ Ghostty directory exists"
    fi

    # Build
    echo ""
    echo "Building libghostty (this may take a few minutes)..."
    cd "$GHOSTTY_DIR"
    zig build -Doptimize=ReleaseFast

    # Verify
    XCFW="$GHOSTTY_DIR/macos/GhosttyKit.xcframework/macos-arm64"
    if [[ -f "$XCFW/libghostty-fat.a" ]]; then
        echo ""
        echo "✓ GhosttyKit built successfully!"
        echo ""
        echo "Location: $XCFW"
        echo ""
        echo "MegaNote will auto-detect this location, or you can set:"
        echo "  export GHOSTTYKIT_PATH=\"$XCFW\""
    else
        echo ""
        echo "✗ Build completed but libghostty-fat.a not found"
        echo "Check $GHOSTTY_DIR for build errors"
        exit 1
    fi

# Update Ghostty and rebuild GhosttyKit
update-ghostty:
    #!/usr/bin/env bash
    set -euo pipefail

    GHOSTTY_DIR="{{ghostty_src}}"

    if [[ ! -d "$GHOSTTY_DIR" ]]; then
        echo "Ghostty not found. Run 'just setup-ghostty' first."
        exit 1
    fi

    echo "Updating Ghostty..."
    cd "$GHOSTTY_DIR"
    git pull

    echo ""
    echo "Rebuilding libghostty..."
    zig build -Doptimize=ReleaseFast

    echo ""
    echo "✓ GhosttyKit updated"

# Vendor GhosttyKit into repo (for CI or portable builds)
vendor-ghostty:
    #!/usr/bin/env bash
    set -euo pipefail

    # Find GhosttyKit
    SRC=""
    if [[ -n "${GHOSTTYKIT_PATH:-}" ]] && [[ -d "$GHOSTTYKIT_PATH" ]]; then
        SRC="$GHOSTTYKIT_PATH"
    elif [[ -d "$HOME/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64" ]]; then
        SRC="$HOME/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
    elif [[ -d "$HOME/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64" ]]; then
        SRC="$HOME/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64"
    else
        echo "✗ GhosttyKit not found. Run 'just setup-ghostty' first."
        exit 1
    fi

    echo "Vendoring GhosttyKit from: $SRC"
    mkdir -p vendor/GhosttyKit
    cp -R "$SRC/Headers" vendor/GhosttyKit/
    cp "$SRC/libghostty-fat.a" vendor/GhosttyKit/

    echo ""
    echo "✓ Vendored to ./vendor/GhosttyKit"
    echo ""
    echo "Size: $(du -sh vendor/GhosttyKit | cut -f1)"
    echo ""
    echo "Note: This is ~135MB and architecture-specific."
    echo "Consider adding vendor/ to .gitignore unless you need portable builds."

# ─────────────────────────────────────────────────────────────
# Debugging
# ─────────────────────────────────────────────────────────────

# Show binary location (debug)
where: build
    @echo ".build/debug/{{name}}"

# Show binary location (release)
where-release: release
    @echo ".build/release/{{name}}"

# Kill any running MegaNote instances
kill:
    @pkill -f {{name}} || echo "No {{name}} process found"

# Open in Xcode (generates xcodeproj if needed)
xcode:
    swift package generate-xcodeproj
    open {{name}}.xcodeproj

# ─────────────────────────────────────────────────────────────
# Nix
# ─────────────────────────────────────────────────────────────

# Build MegaNote with Nix
nix-build:
    nix build

# Build only GhosttyKit (useful for other projects)
nix-build-ghosttykit:
    nix build .#ghosttykit

# Run MegaNote with Nix
nix-run *ARGS:
    nix run . -- {{ARGS}}

# Enter Nix development shell (full - includes Zig)
nix-develop:
    nix develop

# Enter Nix lite shell (uses pre-built GhosttyKit, no Zig)
nix-develop-lite:
    nix develop .#lite

# Update ghostty input to latest commit
nix-update-ghostty:
    nix flake lock --update-input ghostty
    @echo ""
    @echo "✓ Updated ghostty input. Run 'nix develop' to rebuild GhosttyKit."

# Show flake info
nix-info:
    nix flake show
    @echo ""
    nix flake metadata
