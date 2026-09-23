#!/usr/bin/env bash
# Build proton-cachyos (CachyOS fork) with:
#   - Wine NUMA fix (cherry-picked on top of CachyOS wine)
#   - re-added CachyOS HDR glue
#   - x86_64-v3 + znver3 tuning, USE_LTO=0
# Follows CachyOS's own CI method (configure.sh + make redist in the SteamRT4 SDK container).
set -eu

ROOT="$HOME/.cache/cachyos-proton"
SRC="$ROOT/proton"
BUILD="$ROOT/build"

rm -rf "$BUILD"
mkdir -p "$BUILD"

export CFLAGS="-O3 -march=x86-64-v3 -mtune=znver3"
export RUSTFLAGS="-Copt-level=3 -Ctarget-cpu=znver3"
export USE_LTO=0

cd "$BUILD"
bash "$SRC/configure.sh" \
  --build-name=proton-cachyos-numa-hdr-v3 \
  --container-engine=podman \
  --enable-ccache

echo "===== generated Makefile flags ====="
grep -n 'HOST_CFLAGS\|HOST_RUSTFLAGS\|CONTAINER_ENGINE\|BUILD_NAME' Makefile || true
echo "==================================="

nice -n 19 make -j"$(nproc)" redist
