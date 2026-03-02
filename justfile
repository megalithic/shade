# shade - Floating terminal panel CLI using libghostty
# A lighter shade of ghost.
# https://github.com/megalithic/shade

set shell := ["bash", "-cu"]

# Configuration
name := "shade"
version := "0.2.0"
install_dir := env_var_or_default("PREFIX", env_var("HOME") + "/.local") + "/bin"
ghostty_src := env_var_or_default("GHOSTTY_SRC", env_var("HOME") + "/src/ghostty")

# Xcode path (prefer Xcode.app over CommandLineTools for Metal support)
xcode_dev_dir := "/Applications/Xcode.app/Contents/Developer"

# Default recipe: build debug
default: build

# Setup all dependencies (GhosttyKit check + Xcode/Metal Toolchain)
setup:
    @echo "Setting up shade build environment..."
    @echo ""
    @just check-deps || { echo ""; echo "Run 'just setup-ghostty' to build GhosttyKit"; exit 1; }
    @echo ""
    @just setup-xcode
    @echo ""
    @echo "Ready to build! Run 'just build' or 'just install'"

# ─────────────────────────────────────────────────────────────
# Development
# ─────────────────────────────────────────────────────────────

# Build debug binary (auto-installs Metal Toolchain if needed for MLX)
build:
    swift build
    @just install-metal-debug 2>/dev/null || echo "Note: MLX metallib not compiled (run 'just setup-xcode' if MLX features needed)"

# Build and run (debug)
run *ARGS: build
    .build/debug/{{name}} {{ARGS}}

# Run with common development flags (uses code defaults for dimensions)
dev: build
    .build/debug/{{name}} --verbose

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

# Create .app bundle (gives proper bundle ID for macOS/Hammerspoon)
bundle config="debug":
    #!/usr/bin/env bash
    set -euo pipefail

    BUILD_DIR=".build/{{config}}"
    APP_NAME="Shade.app"
    APP_PATH="${BUILD_DIR}/${APP_NAME}"
    BUNDLE_ID="io.shade"

    echo "Creating ${APP_NAME} bundle..."

    # Clean existing bundle
    rm -rf "${APP_PATH}"

    # Create bundle structure
    mkdir -p "${APP_PATH}/Contents/MacOS"
    mkdir -p "${APP_PATH}/Contents/Resources"

    # Copy binary
    cp "${BUILD_DIR}/{{name}}" "${APP_PATH}/Contents/MacOS/{{name}}"

    # Copy metallib if present
    if [ -f "${BUILD_DIR}/mlx.metallib" ]; then
        cp "${BUILD_DIR}/mlx.metallib" "${APP_PATH}/Contents/Resources/mlx.metallib"
    fi

    # Create Info.plist
    cat > "${APP_PATH}/Contents/Info.plist" << EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>${BUNDLE_ID}</string>
        <key>CFBundleName</key>
        <string>shade</string>
        <key>CFBundleDisplayName</key>
        <string>Shade</string>
        <key>CFBundleExecutable</key>
        <string>{{name}}</string>
        <key>CFBundleVersion</key>
        <string>{{version}}</string>
        <key>CFBundleShortVersionString</key>
        <string>{{version}}</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>LSUIElement</key>
        <true/>
        <key>NSHumanReadableCopyright</key>
        <string>Copyright 2024-2025 Seth Messer. All rights reserved.</string>
    </dict>
    </plist>
    EOF

    # Create PkgInfo
    echo -n "APPL????" > "${APP_PATH}/Contents/PkgInfo"

    echo "✓ Created ${APP_PATH}"
    echo "  Bundle ID: ${BUNDLE_ID}"

    # Register with Launch Services
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_PATH}" 2>/dev/null || true

# Show release binary info
release-info: release
    @echo "Binary: .build/release/{{name}}"
    @ls -lh .build/release/{{name}}
    @file .build/release/{{name}}
    @echo ""
    @echo "Dependencies:"
    @otool -L .build/release/{{name}} | head -20

# Install release binary to ~/.local/bin (or $PREFIX/bin)
# Idempotent: kills running shade, shows version diff, ready to use immediately
install:
    #!/usr/bin/env bash
    set -euo pipefail

    INSTALL_PATH="{{install_dir}}/{{name}}"

    # Capture previous version (if exists)
    PREV_VERSION="(none)"
    if [[ -f "$INSTALL_PATH" ]]; then
        PREV_VERSION=$("$INSTALL_PATH" --version 2>/dev/null || echo "unknown")
    fi

    # Kill running shade instances
    if pgrep -x {{name}} > /dev/null 2>&1; then
        echo "Stopping running shade..."
        pkill -x {{name}} || true
    fi

    # Build release
    rm -f .build/.lock
    just release

    # Install metallib (optional)
    just install-metal-release 2>/dev/null || echo "Note: MLX metallib not compiled"

    # Install binary
    mkdir -p {{install_dir}}
    cp .build/release/{{name}} "$INSTALL_PATH"
    if [[ -f .build/release/mlx.metallib ]]; then
        cp .build/release/mlx.metallib {{install_dir}}/mlx.metallib
    fi

    # Capture new version
    NEW_VERSION=$("$INSTALL_PATH" --version 2>/dev/null || echo "unknown")

    # Report
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  shade installed to $INSTALL_PATH"
    echo "═══════════════════════════════════════════════════"
    echo "  Previous: $PREV_VERSION"
    echo "  Current:  $NEW_VERSION"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "Ready to use. Launch via Hammerspoon or:"
    echo "  $INSTALL_PATH --hidden"

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

# Check all build dependencies (GhosttyKit, Xcode, Metal Toolchain)
check-all-deps:
    @just check-deps
    @echo ""
    @just check-xcode

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
        echo "shade will auto-detect this location, or you can set:"
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
# Xcode & Metal Toolchain
# ─────────────────────────────────────────────────────────────
# MLX requires Metal shaders compiled with the Metal Toolchain.
# SwiftPM can't compile Metal shaders, so we do it manually.
# The Metal Toolchain is a separate download from Xcode.

# Check if Xcode and Metal Toolchain are properly configured
check-xcode:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Checking Xcode configuration..."
    echo ""

    # Check for Xcode.app
    if [[ ! -d "{{xcode_dev_dir}}" ]]; then
        echo "✗ Xcode.app not found at /Applications/Xcode.app"
        echo "  Install Xcode from the App Store or:"
        echo "    xcode-select --install  # (CommandLineTools only, no Metal)"
        exit 1
    fi
    echo "✓ Xcode.app found"

    # Check xcode-select path
    CURRENT_DEV_DIR=$(xcode-select -p 2>/dev/null || echo "")
    if [[ "$CURRENT_DEV_DIR" != "{{xcode_dev_dir}}" ]]; then
        echo "⚠ xcode-select points to: $CURRENT_DEV_DIR"
        echo "  Metal compilation requires Xcode.app. To fix:"
        echo "    sudo xcode-select -s {{xcode_dev_dir}}"
        echo "  (shade will use DEVELOPER_DIR override for now)"
    else
        echo "✓ xcode-select configured correctly"
    fi

    # Check first launch
    export DEVELOPER_DIR="{{xcode_dev_dir}}"
    if ! xcodebuild -checkFirstLaunchStatus &>/dev/null; then
        echo "⚠ Xcode first launch not completed"
        echo "  Run: just setup-xcode"
    else
        echo "✓ Xcode first launch completed"
    fi

    # Check Metal Toolchain
    METAL_STATUS=$(xcodebuild -showComponent MetalToolchain 2>/dev/null | grep "Status:" | awk '{print $2}' || echo "unknown")
    if [[ "$METAL_STATUS" == "installed" ]]; then
        echo "✓ Metal Toolchain installed"
    else
        echo "✗ Metal Toolchain not installed (status: $METAL_STATUS)"
        echo "  Run: just setup-xcode"
        exit 1
    fi

    # Verify metal compiler works
    if xcrun -sdk macosx metal --version &>/dev/null; then
        METAL_VERSION=$(xcrun -sdk macosx metal --version 2>&1 | head -1)
        echo "✓ Metal compiler: $METAL_VERSION"
    else
        echo "✗ Metal compiler not working"
        exit 1
    fi

    echo ""
    echo "All Xcode dependencies satisfied!"

# Setup Xcode for Metal compilation (runs first launch, installs Metal Toolchain)
setup-xcode:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Setting up Xcode for Metal compilation..."
    echo ""

    # Check for Xcode.app
    if [[ ! -d "{{xcode_dev_dir}}" ]]; then
        echo "✗ Xcode.app not found at /Applications/Xcode.app"
        echo ""
        echo "Xcode is required for Metal shader compilation."
        echo "Install from: https://developer.apple.com/xcode/"
        echo "Or from the App Store."
        exit 1
    fi

    export DEVELOPER_DIR="{{xcode_dev_dir}}"

    # Run first launch setup (installs system components, accepts license)
    echo "Running Xcode first launch setup..."
    if ! xcodebuild -checkFirstLaunchStatus &>/dev/null; then
        echo "  Installing Xcode system components..."
        xcodebuild -runFirstLaunch
        echo "  ✓ First launch completed"
    else
        echo "  ✓ Already completed"
    fi

    # Check and install Metal Toolchain
    echo ""
    echo "Checking Metal Toolchain..."
    METAL_STATUS=$(xcodebuild -showComponent MetalToolchain 2>/dev/null | grep "Status:" | awk '{print $2}' || echo "unknown")

    if [[ "$METAL_STATUS" == "installed" ]]; then
        echo "  ✓ Metal Toolchain already installed"
    else
        echo "  Downloading Metal Toolchain (~700MB)..."
        xcodebuild -downloadComponent MetalToolchain
        echo "  ✓ Metal Toolchain installed"
    fi

    # Verify metal compiler
    echo ""
    echo "Verifying Metal compiler..."
    if xcrun -sdk macosx metal --version &>/dev/null; then
        METAL_VERSION=$(xcrun -sdk macosx metal --version 2>&1 | head -1)
        echo "  ✓ $METAL_VERSION"
    else
        echo "  ✗ Metal compiler verification failed"
        exit 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  Xcode setup complete!"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "You can now build shade with MLX support:"
    echo "  just build"

# Ensure Metal Toolchain is available (called by build recipes)
[private]
ensure-metal:
    #!/usr/bin/env bash
    # Quick check if metal works, setup if not
    export DEVELOPER_DIR="{{xcode_dev_dir}}"

    if xcrun -sdk macosx metal --version &>/dev/null; then
        exit 0
    fi

    # Metal not working - check if Xcode exists
    if [[ ! -d "{{xcode_dev_dir}}" ]]; then
        echo "⚠ Xcode.app not found - MLX features will be disabled"
        echo "  Install Xcode for Metal shader compilation"
        exit 1
    fi

    # Try first launch
    if ! xcodebuild -checkFirstLaunchStatus &>/dev/null; then
        echo "Running Xcode first launch setup..."
        xcodebuild -runFirstLaunch || {
            echo "⚠ Xcode first launch failed - MLX features will be disabled"
            exit 1
        }
    fi

    # Check Metal Toolchain status
    METAL_STATUS=$(xcodebuild -showComponent MetalToolchain 2>/dev/null | grep "Status:" | awk '{print $2}' || echo "unknown")

    if [[ "$METAL_STATUS" != "installed" ]]; then
        echo "Metal Toolchain not installed. Installing (~700MB)..."
        xcodebuild -downloadComponent MetalToolchain || {
            echo "⚠ Metal Toolchain download failed - MLX features will be disabled"
            exit 1
        }
        echo "✓ Metal Toolchain installed"
    fi

# ─────────────────────────────────────────────────────────────
# Debugging
# ─────────────────────────────────────────────────────────────

# Show binary location (debug)
where: build
    @echo ".build/debug/{{name}}"

# Show binary location (release)
where-release: release
    @echo ".build/release/{{name}}"

# Kill any running shade instances
kill:
    @pkill -f {{name}} || echo "No {{name}} process found"

# Open in Xcode (generates xcodeproj if needed)
xcode:
    swift package generate-xcodeproj
    open {{name}}.xcodeproj

# ─────────────────────────────────────────────────────────────
# MLX Metal Shaders
# ─────────────────────────────────────────────────────────────
# SwiftPM can't compile Metal shaders; we need to do it manually.
# This compiles .metal files into a metallib that MLX can load at runtime.

# Compile MLX Metal shaders (required for MLX to work at runtime)
compile-metal: ensure-metal
    #!/usr/bin/env bash
    set -euo pipefail

    export DEVELOPER_DIR="{{xcode_dev_dir}}"

    METAL_SRC=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"

    if [[ ! -d "$METAL_SRC" ]]; then
        echo "Metal shaders not found. Run 'swift build' first to fetch dependencies."
        exit 1
    fi

    # Double-check metal compiler works (ensure-metal should have set it up)
    if ! xcrun -sdk macosx metal --version &>/dev/null; then
        echo "✗ Metal compiler not available after setup."
        echo "  Run 'just setup-xcode' to diagnose."
        exit 1
    fi

    echo "Compiling MLX Metal shaders..."
    cd "$METAL_SRC"

    # Clean previous builds
    rm -f /tmp/mlx_*.air /tmp/mlx.metallib 2>/dev/null || true

    # Track compilation success
    compiled=0
    failed=0

    # Compile all .metal files (including subdirectories)
    while IFS= read -r -d '' f; do
        safename=$(echo "$f" | sed 's|^\./||; s|/|_|g; s|\.metal$||')
        echo "  Compiling: $f"
        if xcrun -sdk macosx metal -c "$f" -I. -o "/tmp/mlx_${safename}.air" 2>&1; then
            ((compiled++)) || true
        else
            echo "  Warning: Failed to compile $f"
            ((failed++)) || true
        fi
    done < <(find . -name "*.metal" -print0)

    echo "  Compiled: $compiled, Failed: $failed"

    # Link into metallib
    if ls /tmp/mlx_*.air 1>/dev/null 2>&1; then
        echo "Linking metallib..."
        xcrun -sdk macosx metallib /tmp/mlx_*.air -o /tmp/mlx.metallib
        echo "✓ Created /tmp/mlx.metallib"
    else
        echo "✗ No AIR files to link"
        exit 1
    fi

# Copy metallib to debug build directory
install-metal-debug: compile-metal
    @mkdir -p .build/debug
    cp /tmp/mlx.metallib .build/debug/mlx.metallib
    @echo "✓ Installed metallib to .build/debug/"

# Copy metallib to release build directory
install-metal-release: compile-metal
    @mkdir -p .build/release
    cp /tmp/mlx.metallib .build/release/mlx.metallib
    @echo "✓ Installed metallib to .build/release/"

# ─────────────────────────────────────────────────────────────
# Nix
# ─────────────────────────────────────────────────────────────

# Build shade with Nix
nix-build:
    nix build

# Build only GhosttyKit (useful for other projects)
nix-build-ghosttykit:
    nix build .#ghosttykit

# Run shade with Nix
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
