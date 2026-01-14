{
  description = "shade - Floating terminal panel CLI using libghostty. A lighter shade of ghost.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Ghostty source for building libghostty
    ghostty = {
      url = "github:ghostty-org/ghostty";
      flake = false; # Don't use their flake outputs, just the source
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ghostty,
    }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Version from git or fallback
        version = self.shortRev or self.dirtyShortRev or "dev";

        # Architecture-specific paths
        zigTarget = if system == "aarch64-darwin" then "aarch64-macos" else "x86_64-macos";
        xcfwArch = if system == "aarch64-darwin" then "macos-arm64" else "macos-x86_64";

        # Build GhosttyKit (libghostty) from source
        ghosttyKit = pkgs.stdenv.mkDerivation {
          pname = "ghosttykit";
          version = "0.0.0-dev";

          src = ghostty;

          nativeBuildInputs = with pkgs; [
            zig_0_13
            git # Required by ghostty's build.zig for version info
          ];

          # Darwin frameworks are now provided by stdenv via $SDKROOT
          # No explicit buildInputs needed for frameworks

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild

            # Zig needs a writable cache
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            mkdir -p $ZIG_LOCAL_CACHE_DIR $ZIG_GLOBAL_CACHE_DIR

            # Build libghostty for macOS
            zig build \
              -Doptimize=ReleaseFast \
              -Dtarget=${zigTarget} \
              --verbose

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib $out/include

            # Copy the xcframework contents
            XCFW="macos/GhosttyKit.xcframework/${xcfwArch}"
            if [ -d "$XCFW" ]; then
              cp "$XCFW/libghostty-fat.a" $out/lib/
              cp -r "$XCFW/Headers"/* $out/include/
            else
              echo "ERROR: GhosttyKit.xcframework not found at $XCFW"
              ls -la macos/
              exit 1
            fi

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "libghostty - Terminal emulation library from Ghostty";
            homepage = "https://github.com/ghostty-org/ghostty";
            license = licenses.mit;
            platforms = platforms.darwin;
          };
        };

      in
      {
        # Expose GhosttyKit as a package
        packages.ghosttykit = ghosttyKit;

        # Development shell with all build tools
        devShells.default = pkgs.mkShell {
          name = "shade-dev";

          buildInputs = with pkgs; [
            # Swift toolchain
            swift
            swiftPackages.swiftpm

            # Build tools
            just

            # Zig for building GhosttyKit from source
            zig_0_13
          ];

          # Make GhosttyKit available
          GHOSTTYKIT_PATH = "${ghosttyKit}";

          shellHook = ''
            echo "👻 shade development shell (a lighter shade of ghost)"
            echo "Swift: $(swift --version 2>/dev/null | head -1 || echo 'not found')"
            echo "Zig: $(zig version 2>/dev/null || echo 'not found')"
            echo ""
            echo "✓ GhosttyKit: $GHOSTTYKIT_PATH"
            echo ""
            echo "Commands:"
            echo "  just build        - Build debug binary"
            echo "  just release      - Build release binary"
            echo "  just install      - Install to ~/.local/bin"
            echo "  just check-deps   - Verify GhosttyKit is available"
            echo ""
          '';
        };

        # Lite shell without Zig (uses pre-built GhosttyKit)
        devShells.lite = pkgs.mkShell {
          name = "shade-lite";

          buildInputs = with pkgs; [
            swift
            swiftPackages.swiftpm
            just
          ];

          GHOSTTYKIT_PATH = "${ghosttyKit}";

          shellHook = ''
            echo "👻 shade lite shell"
            echo "✓ GhosttyKit: $GHOSTTYKIT_PATH"
          '';
        };

        # shade package
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "shade";
          inherit version;

          src = ./.;

          nativeBuildInputs = with pkgs; [
            swift
            swiftPackages.swiftpm
          ];

          # Bring in GhosttyKit
          GHOSTTYKIT_PATH = "${ghosttyKit}";

          buildPhase = ''
            runHook preBuild

            # Swift needs writable directories
            export HOME=$TMPDIR
            mkdir -p $HOME/.swiftpm

            # Verify GhosttyKit is available
            if [ ! -f "$GHOSTTYKIT_PATH/lib/libghostty-fat.a" ]; then
              echo "ERROR: GhosttyKit not found at $GHOSTTYKIT_PATH"
              exit 1
            fi

            swift build -c release

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp .build/release/shade $out/bin/
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Floating terminal panel CLI using libghostty. A lighter shade of ghost.";
            homepage = "https://github.com/megalithic/shade";
            license = licenses.mit;
            platforms = platforms.darwin;
            mainProgram = "shade";
          };
        };

        packages.shade = self.packages.${system}.default;
      }
    );
}
