{
  description = "Unofficial proton-cachyos (CachyOS fork) with the Wine NUMA fix, re-added cachyos HDR glue, and x86_64-v3/znver3 tuning";

  # ---------------------------------------------------------------------------
  # HONESTY / HERMETICITY
  # ---------------------------------------------------------------------------
  # This flake pins every *input* (proton fork, wine fork, SDK image) by
  # revision/digest/hash, and the builder reproduces the exact CachyOS CI
  # procedure.  It is however NOT a hermetic Nix build:
  #   * the actual compile runs inside rootless podman using the SteamRT4 SDK
  #     image, which Nix cannot sandbox;
  #   * git submodules (53 of them) are fetched from the network at build time
  #     (their revisions ARE pinned by the gitlinks of the pinned proton tree);
  #   * the protonfixes `unzip` tarball is fetched from snapshot.debian.org
  #     (see the workaround below);
  #   * nixpkgs is pinned in flake.lock.
  # A fully sandboxed Nix build of Wine+Proton is a separate large project
  # (32-bit toolchain, cachyos extras, no network, no podman in the sandbox).
  # `nix build .#sources` is hermetic; `nix build .#default` is not.
  # ---------------------------------------------------------------------------

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Pinned revisions of the two forks.
      revProton = "57d57d50db4170b2fb9eecefa2309cc2d66c10b3";
      revWine   = "b06a3d09d7a18cf5b45a8349afcc8f2202ab3e9d";

      # Fixed-output hashes (nix-prefetch-git).
      hashProton = "sha256-ZVC9T3Xb42H/9va8rJpy8rUbDDCDv40iUoa35bG4nXc=";
      hashWine   = "sha256-ygvhCaS3sqZSDoYNNQO/wPCbxv6i++JdAul9gvQk+Ks=";

      # SteamRT4 SDK image, pinned by digest (pulled by podman at build time).
      sdkImage = "registry.gitlab.steamos.cloud/proton/steamrt4/sdk/x86_64:4.0.20260331.220802-0@sha256:97526b794ce1a9bed5f891084462260b3a02399569f7438a3a57b5a253001db9";

      # Hermetic provenance pins (top-level trees only; no submodules).
      protonSrc = pkgs.fetchgit {
        url = "https://github.com/aviallon/proton-cachyos.git";
        rev = revProton;
        hash = hashProton;
      };
      wineSrc = pkgs.fetchgit {
        url = "https://github.com/aviallon/wine-cachyos.git";
        rev = revWine;
        hash = hashWine;
      };

      builder = pkgs.writeShellScriptBin "build-proton-cachyos-numa-hdr-v3" ''
        set -euo pipefail

        REV_PROTON="${revProton}"
        REV_WINE="${revWine}"
        SDK_IMAGE="${sdkImage}"

        WORK="''${XDG_CACHE_HOME:-$HOME/.cache}/proton-cachyos-numa-hdr-v3"
        SRC="$WORK/proton"
        BUILD="$WORK/build"

        mkdir -p "$WORK"
        if [ ! -d "$SRC/.git" ]; then
          git clone --filter=blob:none https://github.com/aviallon/proton-cachyos.git "$SRC"
        fi
        cd "$SRC"
        git fetch origin "$REV_PROTON"
        git checkout -q -B numa-hdr-v3 "$REV_PROTON"
        test "$(git rev-parse HEAD)" = "$REV_PROTON" || { echo "FATAL: proton rev mismatch" >&2; exit 1; }

        # 53 submodules (network). Their revisions come from the pinned tree.
        git submodule update --init --filter=blob:none --recursive
        git -C wine fetch origin "$REV_WINE"
        git -C wine checkout -q "$REV_WINE"
        test "$(git -C wine rev-parse HEAD)" = "$REV_WINE" || { echo "FATAL: wine rev mismatch" >&2; exit 1; }

        rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

        # --- protonfixes unzip source workaround ---------------------------------
        # The pinned protonfixes Makefile downloads unzip_6.0-29.debian.tar.xz
        # from deb.debian.org/debian/pool/main/u/unzip, which now returns 404
        # (Debian rotated the revision). Pin the exact file from
        # snapshot.debian.org and verify its sha256.
        UNZIP_DIR="$BUILD/obj-protonfixes-x86_64/downloads/unzip"
        mkdir -p "$UNZIP_DIR"
        if [ ! -f "$UNZIP_DIR/unzip_6.0-29.debian.tar.xz" ]; then
          curl -fL "https://snapshot.debian.org/file/60d291e40b4cba025591bdd84f1b00779f9c68d6" \
            -o "$UNZIP_DIR/unzip_6.0-29.debian.tar.xz"
          echo "14043e5ea351c02b3bc8676e1e6d20d79b9a690b6d7520e8138ac629cc048417  $UNZIP_DIR/unzip_6.0-29.debian.tar.xz" | sha256sum -c -
        fi

        export CFLAGS="-O3 -march=x86-64-v3 -mtune=znver3"
        export RUSTFLAGS="-Copt-level=3 -Ctarget-cpu=znver3"
        export USE_LTO=0

        bash "$SRC/configure.sh" \
          --build-name=proton-cachyos-numa-hdr-v3 \
          --container-engine=podman \
          --enable-ccache

        make -j"$(nproc)" redist

        echo
        echo "Built: $BUILD/proton-cachyos-numa-hdr-v3.tar.xz"
        echo "Install additively (does NOT select it for any game):"
        echo "  mkdir -p ~/.local/share/Steam/compatibilitytools.d/proton-cachyos-numa-hdr-v3"
        echo "  tar -xf $BUILD/proton-cachyos-numa-hdr-v3.tar.xz -C ~/.local/share/Steam/compatibilitytools.d/"
      '';

    in {
      packages.${system} = {
        # Hermetic fixed-output source pins (kept as separate named trees).
        sources = pkgs.linkFarm "proton-cachyos-numa-hdr-v3-sources" [
          { name = "proton"; path = protonSrc; }
          { name = "wine"; path = wineSrc; }
        ];
        # Non-hermetic builder (network + rootless podman + SDK image).
        default = builder;
        inherit builder;
      };

      apps.${system}.default = {
        type = "app";
        program = "${builder}/bin/build-proton-cachyos-numa-hdr-v3";
      };
    };
}
