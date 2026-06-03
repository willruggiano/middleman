# Packages the middleman binary: the Go HTTP server with the Bun-built Svelte
# SPA embedded via //go:embed (internal/web/embed.go).
#
# Build is three derivations:
#   1. nodeModules   - fixed-output (network) `bun install` of the workspace
#   2. frontendDist  - offline `vite build` producing frontend/dist
#   3. middleman     - buildGoModule that stages dist into internal/web/dist
#                      and compiles ./cmd/middleman
{
  self,
  lib,
  ...
}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    # Clean git source tree of the flake (no .git, no gitignored node_modules/dist).
    src = self;

    bunVersion = "1.3.11"; # frontend/package.json packageManager pin (informational)

    # 1. Workspace node_modules. Fixed-output so `bun install` may hit the
    #    network. Bun materializes real files into node_modules (it is not a
    #    global content-addressed store like pnpm), so the captured trees are
    #    self-contained apart from relative workspace symlinks, which resolve
    #    against the source we re-supply in derivation 2.
    nodeModules = pkgs.stdenv.mkDerivation {
      pname = "middleman-node-modules";
      version = bunVersion;
      inherit src;

      nativeBuildInputs = [pkgs.bun pkgs.git];

      dontConfigure = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild

        export HOME="$TMPDIR"
        export BUN_INSTALL_CACHE_DIR="$TMPDIR/.bun-cache"
        chmod -R u+w .

        bun install --frozen-lockfile --no-progress

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p "$out"
        # Preserve each node_modules tree at its path under $out so it can be
        # overlaid back onto the source tree later.
        find . -type d -name node_modules -prune | while read -r dir; do
          mkdir -p "$out/$dir"
          cp -a "$dir/." "$out/$dir/"
        done

        runHook postInstall
      '';

      # Fixed-output derivation: replace with the hash Nix reports on first build.
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = "sha256-TYC3/ReVyEsr8UndlF8ArSbokD042bwRvmtkfuiXHcw=";
    };

    # 2. Built SPA (frontend/dist). Offline: deps come from nodeModules.
    frontendDist = pkgs.stdenv.mkDerivation {
      pname = "middleman-frontend";
      version = "0.1.0"; # frontend/package.json
      inherit src;

      # `bun run build` runs `node ./node_modules/vite/bin/vite.js build`, so
      # both bun and node must be on PATH.
      nativeBuildInputs = [pkgs.bun pkgs.nodejs];

      dontConfigure = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild

        export HOME="$TMPDIR"
        chmod -R u+w .
        # Overlay the prefetched node_modules trees (root + frontend + packages/ui).
        cp -a ${nodeModules}/. .
        chmod -R u+w .

        (cd frontend && bun run build)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        cp -r frontend/dist "$out"
        runHook postInstall
      '';
    };
  in {
    devshells.default.packagesFrom = [config.packages.middleman];
    # 3. The middleman binary with the SPA embedded.
    #
    # go.mod requires Go 1.26.3. If the pinned nixpkgs' default `go` is older,
    # swap `pkgs.buildGoModule` for `pkgs.buildGo126Module` (or
    # `pkgs.buildGoModule.override { go = pkgs.go_1_26; }`).
    packages.middleman = pkgs.buildGoModule {
      pname = "middleman";
      version = "dev";
      inherit src;

      vendorHash = "sha256-UPQooDVfyjbOY/eCDDBdmL01n/HFcbepTtjmSe3ns/0=";

      # CGO stays enabled (buildGoModule default, with stdenv's C compiler).
      # modernc.org/sqlite is pure Go, but the transitive indirect dep
      # github.com/miekg/pkcs11 (via ThalesIgnite/crypto11) is a cgo package
      # whose type definitions live in cgo-gated files; CGO_ENABLED=0 drops
      # them and the build fails with "undefined: pkcs11.*". pkcs11 bundles its
      # own headers, so no extra buildInputs are required.

      subPackages = ["cmd/middleman"];

      # Stage the built SPA into the embed directory before `go build` runs, so
      # //go:embed all:dist in internal/web/embed.go has the real assets.
      preBuild = ''
        rm -rf internal/web/dist
        mkdir -p internal/web/dist
        cp -r ${frontendDist}/. internal/web/dist/
        printf 'ok\n' > internal/web/dist/stub.html
      '';

      # Strip debug info; do not inject -X version flags (keeps the build
      # reproducible). main.version/commit/buildDate keep their defaults.
      ldflags = ["-s" "-w"];

      meta = {
        description = "Local-first dashboard for tracking PRs/MRs across repositories on multiple platforms";
        homepage = "https://go.kenn.io/middleman";
        license = lib.licenses.mit;
        mainProgram = "middleman";
        platforms = lib.platforms.unix;
      };
    };
  };
}
