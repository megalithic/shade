{
  description = "shade - Floating terminal panel CLI using libghostty. A lighter shade of ghost.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Use Ghostty's flake for proper GhosttyKit build (handles zon2nix deps)
    ghostty.url = "github:ghostty-org/ghostty";
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

        # Get GhosttyKit from Ghostty's flake outputs
        # Ghostty's flake exposes packages including the library we need
        ghosttyFlake = ghostty.packages.${system} or {};

        # GhosttyKit derivation - extract from Ghostty or build with their flake
        ghosttyKit = pkgs.stdenv.mkDerivation {
          pname = "ghosttykit";
          version = "1.0.0";

          # No source needed - we extract from the Ghostty build
          dontUnpack = true;
          dontBuild = true;

          # Depend on Ghostty's build output
          buildInputs = [
            (ghosttyFlake.default or ghosttyFlake.ghostty or null)
          ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib $out/include

            # Ghostty builds GhosttyKit as part of their macOS app
            # The library should be available in Ghostty's output
            GHOSTTY="${ghosttyFlake.default or ghosttyFlake.ghostty or ""}"

            if [ -n "$GHOSTTY" ] && [ -d "$GHOSTTY" ]; then
              echo "Looking for GhosttyKit in: $GHOSTTY"

              # Check for framework in app bundle
              if [ -d "$GHOSTTY/Applications/Ghostty.app/Contents/Frameworks/GhosttyKit.framework" ]; then
                FWPATH="$GHOSTTY/Applications/Ghostty.app/Contents/Frameworks/GhosttyKit.framework"
                echo "Found GhosttyKit.framework at: $FWPATH"

                # Copy the static library (or dynamic library renamed)
                if [ -f "$FWPATH/Versions/A/GhosttyKit" ]; then
                  cp "$FWPATH/Versions/A/GhosttyKit" $out/lib/libghostty-fat.a
                fi

                # Copy headers
                if [ -d "$FWPATH/Headers" ]; then
                  cp -r "$FWPATH/Headers"/* $out/include/
                fi
              fi

              # Also check for standalone library
              find "$GHOSTTY" -name "libghostty*.a" -o -name "GhosttyKit*" 2>/dev/null | head -20 || true
            fi

            # Verify we got what we need
            if [ ! -f "$out/lib/libghostty-fat.a" ]; then
              echo "ERROR: Could not extract GhosttyKit from Ghostty build"
              echo "This may be because Ghostty's macOS build doesn't produce a standalone library."
              echo ""
              echo "As a fallback, you can:"
              echo "1. Build GhosttyKit manually and set GHOSTTYKIT_PATH"
              echo "2. Download a pre-built GhosttyKit from Ghostty releases"
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
          ];

          # Make GhosttyKit available
          GHOSTTYKIT_PATH = "${ghosttyKit}";

          shellHook = ''
            echo "👻 shade development shell (a lighter shade of ghost)"
            echo "Swift: $(swift --version 2>/dev/null | head -1 || echo 'not found')"
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

        # Lite shell (same as default now)
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
