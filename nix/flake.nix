{
  description = "Parameterized Nix flake to build proton-cachyos (CachyOS fork) with the Wine NUMA fix, re-added cachyos HDR glue, and configurable x86-64 codegen";

  # ---------------------------------------------------------------------------
  # HONESTY / HERMETICITY
  # ---------------------------------------------------------------------------
  # This flake pins every *input* (proton fork, wine fork, SDK image, nixpkgs)
  # by revision/digest/hash.  It is however NOT a hermetic Nix build:
  #   * the actual compile runs inside rootless podman using the SteamRT4 SDK
  #     image, which Nix cannot sandbox;
  #   * the 53 git submodules are fetched from the network at build time.  The
  #     network checkout is used ONLY for .git metadata and the submodule
  #     gitlinks: the top-level proton/wine trees are then overwritten with the
  #     hash-pinned `protonSrc`/`wineSrc` Nix store trees, and the recorded
  #     submodule revisions ARE pinned by the gitlinks of the pinned proton
  #     commit (which this flake asserts before compiling);
  #   * the protonfixes `unzip` tarball is fetched from snapshot.debian.org
  #     (see the workaround in the builder; verified by sha256);
  #   * nixpkgs is pinned in flake.lock.
  # What IS pinned, precisely:
  #   * top-level proton tree  -> revProton, fixed-output hash hashProton;
  #   * top-level wine tree    -> revWine,   fixed-output hash hashWine;
  #   * SteamRT4 SDK image     -> pinned by sha256 digest (passed to
  #                               configure.sh via --proton-sdk-image);
  #   * codegen flags          -> baked into each named variant at eval time.
  # What is NOT pinned:
  #   * the 52 non-wine submodule contents (their *revisions* come from the
  #     pinned gitlinks, but the bytes are fetched from their own upstream git
  #     servers at build time);
  #   * the snapshot.debian.org unzip file (sha256-checked, not pinned by URL
  #     because the original URL 404s).
  # A fully sandboxed Nix build of Wine+Proton is a separate large project
  # (32-bit toolchain, cachyos extras, no network, no podman in the sandbox).
  # `nix build .#sources` is hermetic; the builder variants are not.
  # ---------------------------------------------------------------------------

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      # Pinned revisions of the two forks.
      revProton = "57d57d50db4170b2fb9eecefa2309cc2d66c10b3";
      revWine   = "b06a3d09d7a18cf5b45a8349afcc8f2202ab3e9d";

      # Fixed-output hashes (nix-prefetch-git).  These hashes are what pin the
      # *content* of the top-level trees to the revisions above.
      hashProton = "sha256-ZVC9T3Xb42H/9va8rJpy8rUbDDCDv40iUoa35bG4nXc=";
      hashWine   = "sha256-ygvhCaS3sqZSDoYNNQO/wPCbxv6i++JdAul9gvQk+Ks=";

      protonUrl = "https://github.com/aviallon/proton-cachyos.git";
      wineUrl   = "https://github.com/aviallon/wine-cachyos.git";

      # SteamRT4 SDK image, pinned by digest (pulled by podman at build time and
      # explicitly selected at configure time).
      sdkImage = "registry.gitlab.steamos.cloud/proton/steamrt4/sdk/x86_64:4.0.20260331.220802-0@sha256:97526b794ce1a9bed5f891084462260b3a02399569f7438a3a57b5a253001db9";

      # Hermetic provenance pins (top-level trees only; no submodules).
      protonSrc = pkgs.fetchgit {
        url = protonUrl;
        rev = revProton;
        hash = hashProton;
      };
      wineSrc = pkgs.fetchgit {
        url = wineUrl;
        rev = revWine;
        hash = hashWine;
      };

      # -----------------------------------------------------------------------
      # Codegen configuration.
      # The defaults reproduce the previously hard-coded configuration exactly.
      # Every field is overridable; see `lib.mkBuilder` below.
      # -----------------------------------------------------------------------
      defaultCodegen = {
        march = "x86-64-v3";        # GCC -march
        mtune = "znver3";           # GCC -mtune
        rustTargetCpu = "znver3";   # rustc -Ctarget-cpu
        lto = false;                # inject -flto / -Clto + USE_LTO=1
        treeWideAvxWorkaround = false;  # false = strip CachyOS's x86_64
                                        # -mno-avx/-mno-avx2/-mno-avx512f
                                        # -fvect-cost-model=cheap (i386 ABI
                                        # flags and DXVK's own -mno-avx are
                                        # kept); true = CachyOS stock
      };

      sanitize = s: lib.replaceStrings [ "/" " " ] [ "-" "-" ] s;

      # mkBuilder: build a shell-script derivation for one codegen config.
      # `variantName` only names the binary/human label; the *artifact* name
      # encodes every knob so two artifacts can never be confused.
      mkBuilder = variantName: codegen:
        let
          c = defaultCodegen // codegen;
          hostCflags =
            "-O3 -march=${sanitize c.march} -mtune=${sanitize c.mtune}"
            + lib.optionalString c.lto " -flto";
          hostRustflags =
            "-Copt-level=3 -Ctarget-cpu=${sanitize c.rustTargetCpu}"
            + lib.optionalString c.lto " -Clto";
          buildName =
            "proton-cachyos-numa-hdr-v3"
            + "-march-${sanitize c.march}"
            + "-mtune-${sanitize c.mtune}"
            + "-rustcpu-${sanitize c.rustTargetCpu}"
            + "-lto-${if c.lto then "on" else "off"}"
            + "-treeavx-${if c.treeWideAvxWorkaround then "cachyos-workaround" else "enabled"}";
        in
        pkgs.writeShellScriptBin "build-${variantName}" ''
          set -euo pipefail

          die() { echo "FATAL: $*" >&2; exit 1; }

          BUILD_NAME="${buildName}"
          PROTON_REV="${revProton}"
          WINE_REV="${revWine}"
          PROTON_URL="${protonUrl}"
          WINE_URL="${wineUrl}"
          SDK_IMAGE="${sdkImage}"
          PROTON_STORE="${protonSrc}"
          WINE_STORE="${wineSrc}"
          MARCH="${sanitize c.march}"
          MTUNE="${sanitize c.mtune}"
          RUST_TARGET_CPU="${c.rustTargetCpu}"
          LTO="${if c.lto then "1" else "0"}"
          TREE_WIDE_AVX_WORKAROUND="${if c.treeWideAvxWorkaround then "1" else "0"}"
          HOST_CFLAGS_BAKED="${hostCflags}"
          HOST_RUSTFLAGS_BAKED="${hostRustflags}"
          STOP_AFTER_CONFIGURE="''${PROTON_BUILDER_STOP_AFTER_CONFIGURE:-0}"

          WORK="''${XDG_CACHE_HOME:-$HOME/.cache}/proton-cachyos-numa-hdr-v3"
          GITDIR="$WORK/git-proton"
          SRC="$GITDIR"
          BUILD="$WORK/build-$BUILD_NAME"

          mkdir -p "$WORK"

          echo ":: variant            : $BUILD_NAME"
          echo ":: march/mtune        : $MARCH / $MTUNE"
          echo ":: rust target-cpu    : $RUST_TARGET_CPU"
          echo ":: lto                : $LTO"
          echo ":: treeWideAvxWorkaround: $TREE_WIDE_AVX_WORKAROUND"

          if [ "$STOP_AFTER_CONFIGURE" != "1" ]; then
            # --- 1. network checkout, used ONLY for .git metadata + gitlinks ---
            if [ ! -d "$GITDIR/.git" ]; then
              # (a previous STOP_AFTER_CONFIGURE run may have left a plain tree
              # here without .git metadata, so clear the target first.)
              rm -rf "$GITDIR"
              git clone --filter=blob:none "$PROTON_URL" "$GITDIR"
            fi
            git -C "$GITDIR" fetch -q origin "$PROTON_REV"
            git -C "$GITDIR" checkout -q --detach "$PROTON_REV"
          else
            # cheap proof path: no network, no submodules; the hash-pinned
            # Nix store trees are enough to generate (and inspect) the Makefile.
            rm -rf "$SRC"
            mkdir -p "$SRC"
          fi

          # --- 2. overwrite the top-level trees with the hash-pinned Nix store
          #        trees.  Nix's fixed-output hash is the pin for the content. --
          cp -r "$PROTON_STORE/." "$SRC/"
          rm -rf "$SRC/wine"
          mkdir -p "$SRC/wine"
          cp -r "$WINE_STORE/." "$SRC/wine/"
          chmod -R u+w "$SRC" 2>/dev/null || true

          if [ "$STOP_AFTER_CONFIGURE" != "1" ]; then
            # --- 3. assert the built tree's revisions match the pins ---------
            test "$(git -C "$SRC" rev-parse HEAD)" = "$PROTON_REV" \
              || die "built proton tree HEAD != pinned $PROTON_REV"
            test "$(git -C "$SRC" rev-parse HEAD:wine)" = "$WINE_REV" \
              || die "pinned tree records wine gitlink != pinned $WINE_REV"
            test -z "$(git -C "$SRC" status --porcelain --ignore-submodules=all)" \
              || die "hash-pinned top-level tree differs from pinned git commit"

            # --- 4. submodules (network; revisions from the pinned gitlinks) --
            # `git submodule update` clones into each submodule path, so the
            # wine path (pre-filled from wineSrc above) must be cleared first;
            # it is restored from wineSrc after the checkouts below.
            rm -rf "$SRC/wine"
            git -C "$SRC" submodule update --init --recursive

            # wine is itself a pinned flake input: require the submodule
            # checkout to be at the pin, then restore wineSrc over it.
            test "$(git -C "$SRC/wine" rev-parse HEAD)" = "$WINE_REV" \
              || die "wine submodule HEAD != pinned $WINE_REV"
            cp -r "$WINE_STORE/." "$SRC/wine/"
            chmod -R u+w "$SRC/wine" 2>/dev/null || true
            test "$(git -C "$SRC/wine" rev-parse HEAD)" = "$WINE_REV" \
              || die "wine submodule HEAD != pinned $WINE_REV after restore"
          fi

          # --- 5. configure -------------------------------------------------
          rm -rf "$BUILD"
          mkdir -p "$BUILD"
          cd "$BUILD"

          {
            echo "variant=$BUILD_NAME"
            echo "march=$MARCH"
            echo "mtune=$MTUNE"
            echo "rustTargetCpu=$RUST_TARGET_CPU"
            echo "lto=$LTO"
            echo "treeWideAvxWorkaround=$TREE_WIDE_AVX_WORKAROUND"
            echo "protonRev=$PROTON_REV"
            echo "wineRev=$WINE_REV"
            echo "sdkImage=$SDK_IMAGE"
            echo "hostCFlags=$HOST_CFLAGS_BAKED"
            echo "hostRustFlags=$HOST_RUSTFLAGS_BAKED"
          } > BUILD-CONFIG.txt
          echo ":: build config:"
          sed 's/^/::   /' BUILD-CONFIG.txt

          # --- protonfixes unzip source workaround ---------------------------
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

          export CFLAGS="$HOST_CFLAGS_BAKED"
          export RUSTFLAGS="$HOST_RUSTFLAGS_BAKED"
          export USE_LTO="$LTO"

          bash "$SRC/configure.sh" \
            --build-name="$BUILD_NAME" \
            --container-engine=podman \
            --proton-sdk-image="$SDK_IMAGE" \
            --enable-ccache

          # --- 6. tree-wide x86_64 AVX workaround ----------------------------
          # CachyOS commit d89efe07 (2026-04-17, Stelios Tsampas) appends, in
          # the GCC branch:
          #   i386_CFLAGS   += -mno-avx -mno-avx2 -mno-avx512f
          #   i386_CFLAGS   += -fvect-cost-model=cheap
          #   x86_64_CFLAGS += -mno-avx -mno-avx2 -mno-avx512f
          #   x86_64_CFLAGS += -fvect-cost-model=cheap
          # and the analogous single x86_64 += in the Clang branch.  The i386
          # flags are an ABI correctness requirement (the 32-bit Windows ABI
          # guarantees only 4-byte stack alignment; paired with
          # -mpreferred-stack-boundary=2 / -mstack-alignment=4 and
          # -mstackrealign), so they are ALWAYS kept exactly.  The x86_64 flags
          # are a DXVK-specific workaround (bisected to DXVK 5a4d8921 /
          # 64124232) that CachyOS applies tree-wide; DXVK keeps its own
          # -mno-avx via DXVK_x86_64_CFLAGS.
          #
          # Default (treeWideAvxWorkaround=false): strip the x86_64 AVX-disable
          # and anti-vectorisation flags from the generated Makefile (build
          # output), leaving i386 untouched.  This is a deliberate departure
          # from CachyOS's "never emit AVX regardless of HOST_CFLAGS" ISA
          # policy, visible only because -march=x86-64-v3 raises HOST_CFLAGS
          # above CachyOS's nocona default.  It still needs an in-game test.
          # Opt-in (treeWideAvxWorkaround=true): leave the tree exactly as
          # CachyOS ships it.
          if [ "$TREE_WIDE_AVX_WORKAROUND" != "1" ]; then
            cat >> Makefile <<'TREEAVXEOF'

          # proton-cachyos Nix flake: treeWideAvxWorkaround=false.
          # Strip only the x86_64 tree flags; i386 ABI flags are untouched.
          x86_64_CFLAGS := $(filter-out -mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap,$(x86_64_CFLAGS))
          TREEAVXEOF
          fi

          echo ":: generated Makefile HOST_* flags:"
          grep -n 'HOST_CFLAGS\|HOST_RUSTFLAGS' Makefile || true
          if [ "$TREE_WIDE_AVX_WORKAROUND" = "1" ]; then
            echo ":: tree-wide x86_64 AVX workaround: CACHYOS STOCK (kept)"
            echo ":: (no filter-out appended; i386 and x86_64 left exactly as CachyOS ships)"
          else
            echo ":: tree-wide x86_64 AVX workaround: STRIPPED (tree x86_64 AVX enabled)"
            echo ":: i386 ABI flags kept; DXVK keeps its own -mno-avx"
            grep -n 'filter-out' Makefile || true
          fi

          if [ "$STOP_AFTER_CONFIGURE" = "1" ]; then
            echo ":: PROTON_BUILDER_STOP_AFTER_CONFIGURE=1: stopping before 'make redist'"
            exit 0
          fi

          # --- 7. build -----------------------------------------------------
          nice -n 19 make -j"$(nproc)" redist

          echo
          echo "Built: $BUILD/$BUILD_NAME.tar.xz"
          echo "Install additively (does NOT select it for any game):"
          echo "  mkdir -p ~/.local/share/Steam/compatibilitytools.d/$BUILD_NAME"
          echo "  tar -xf $BUILD/$BUILD_NAME.tar.xz -C ~/.local/share/Steam/compatibilitytools.d/"
        '';

      variants = {
        # default: tree x86_64 AVX enabled; DXVK keeps its own -mno-avx
        "proton-v3" = { };
        # CachyOS stock: apply the -mno-avx/-mno-avx2/-mno-avx512f
        # -fvect-cost-model=cheap workaround tree-wide (i386 and x86_64)
        "proton-v3-cachyos-stock" = { treeWideAvxWorkaround = true; };
      };

      mkVariant = name: overrides:
        mkBuilder name (defaultCodegen // overrides);

      packages = lib.mapAttrs mkVariant variants;

    in {
      packages.${system} = {
        # Hermetic fixed-output source pins (kept as separate named trees).
        sources = pkgs.linkFarm "proton-cachyos-numa-hdr-v3-sources" [
          { name = "proton"; path = protonSrc; }
          { name = "wine"; path = wineSrc; }
        ];
      }
      // packages
      // {
        # Named builder variants: one command apart.
        #   proton-v3               : tree x86_64 AVX enabled, DXVK -mno-avx kept
        #   proton-v3-cachyos-stock : CachyOS stock tree-wide AVX workaround
        default = packages."proton-v3";
        builder = packages."proton-v3";
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${packages."proton-v3"}/bin/build-proton-v3";
        };
        proton-v3 = {
          type = "app";
          program = "${packages."proton-v3"}/bin/build-proton-v3";
        };
        proton-v3-cachyos-stock = {
          type = "app";
          program = "${packages."proton-v3-cachyos-stock"}/bin/build-proton-v3-cachyos-stock";
        };
      };

      # Programmatic override hook: build an arbitrary codegen configuration.
      #   nix build --impure --expr \
      #     '((builtins.getFlake (toString ./nix)).lib.mkBuilder { march = "x86-64-v4"; })'
      lib = {
        inherit defaultCodegen;
        mkCodegen = overrides: defaultCodegen // overrides;
        mkBuilder = codegen: mkBuilder "custom" codegen;
      };
    };
}
