# proton-cachyos, NUMA-fixed + HDR glue + x86_64-v3/znver3 (UNOFFICIAL)

**This is an unofficial, community rebuild. Do NOT report bugs from this build to
CachyOS, Valve, or Wine upstream.** It is derived from the CachyOS Proton fork,
which is itself derived from Valve's Proton.

## What it is

A build of **`CachyOS/proton-cachyos`** (branch `cachyos_11.0_20260702/main`,
the exact source of the last completed CachyOS release) with:

1. **The Wine NUMA fix**, cherry-picked onto the CachyOS wine fork
   (`aviallon/wine-cachyos`, branch `numa-fix`).
2. **The CachyOS HDR glue re-added** (`PROTON_ENABLE_HDR` -> `hdr` ->
   `DXVK_HDR=1` and `ENABLE_HDR_WSI` on NVIDIA), which CachyOS removed on
   2026-05-16 but which the user's known-good `20260428` build had.
3. **x86_64-v3 + znver3 tuning**: `-O3 -march=x86-64-v3 -mtune=znver3` and
   Rust `-Copt-level=3 -Ctarget-cpu=znver3`, with `USE_LTO=0`.

The full CachyOS feature set is kept: `dxvk-sarek`, `d7vk`,
`dxvk-low-latency`, `vkd3d-low-latency`, `nvidia-libs` (nvcuda/nvenc/
wine-nvml/wine-nvoptix), `discord-rpc-bridge`, `icu`, the cachyos wine patchset,
and the CachyOS `HOST_CFLAGS`/`HOST_RUSTFLAGS` build mechanism.

## Exact provenance

| Component | Revision |
|---|---|
| Proton fork tree | `aviallon/proton-cachyos` @ `57d57d50db4170b2fb9eecefa2309cc2d66c10b3` (branch `numa-hdr-v3`), based on `CachyOS/proton-cachyos` `cachyos_11.0_20260702/main` @ `ea0053a9` |
| Wine | `aviallon/wine-cachyos` @ `b06a3d09d7a18cf5b45a8349afcc8f2202ab3e9d` (branch `numa-fix`), based on `CachyOS/wine-cachyos` `cachyos_11.0_20260702/main` @ `b5f2dc7b59` |
| NUMA fix commits (cherry-picked from `ValveSoftware/wine` bleeding-edge, author Paul Gofman) | `f279ca9f7f` (ntdll `SystemNumaProcessorMap`), `60c0797db3` (`GetNumaHighestNodeNumber`), `29a03ee1f7` (`GetNumaProcessorNode[Ex]`), `6803d94538`, `b83efcca92` (`GetNumaNodeProcessorMask[Ex]`), `9755ccc9f9` |
| Original landing of the same fix (Valve, 2026-08-10) | `ff40cef784a0`, `073a4edad752`, `76696b6d42bb` — same changes, re-landed on 2026-09-01 as the SHAs above |
| Build container | `registry.gitlab.steamos.cloud/proton/steamrt4/sdk/x86_64:4.0.20260331.220802-0` (digest `sha256:97526b794ce1a9bed5f891084462260b3a02399569f7438a3a57b5a253001db9`) |

## What is matched vs not matched against CachyOS

Matched: the CachyOS Proton tree, wine fork and patchset; the component list
above; the `configure.sh`/`build_in_container` mechanism; `HOST_CFLAGS`
`-O3 -march=x86-64-v3`; `HOST_RUSTFLAGS -Copt-level=3`; the GCC sanity flags
(`-mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap`; the DXVK/openfst
overrides).

Deliberately changed: `-mtune=core-avx2` -> `-mtune=znver3` and Rust
`-Ctarget-cpu=nocona` -> `-Ctarget-cpu=znver3` (the target CPU is a Ryzen 9
5950X, Zen 3). HDR glue re-added (CachyOS). Wine base is newer than any CachyOS
release (contains the 2026-08-10/09-01 NUMA fix).

Not matched: nothing from the CachyOS feature set was intentionally dropped.
`nvidia-libs` are the Wine-Staging LGPL reimplementations, not NVIDIA blobs.

## Licences

Wine LGPL-2.1+; Valve Proton mixed BSD-3-Clause/LGPL-2.1; CachyOS patches under
their respective upstream licences; DXVK (and DXVK-Sarek, d7vk,
dxvk-low-latency) zlib; vkd3d-proton (and vkd3d-low-latency) LGPL-2.1;
nvcuda/nvenc (Wine-Staging reimplementations) LGPL-2.1; wine-nvml LGPL-2.1;
wine-nvoptix MIT; dxvk-nvapi MIT/zlib; discord-rpc-bridge MIT; ICU
Unicode-DFS; FAudio zlib; wine-mono MIT; wine-gecko MPL-2.0; GStreamer
LGPL-2.1+. No redistribution prohibition found.

## Build workaround recorded

`protonfixes` fetches `unzip_6.0-29.debian.tar.xz` from `deb.debian.org`, which
now 404s (Debian rotated the revision). The build places the exact file from
`snapshot.debian.org` (sha256
`14043e5ea351c02b3bc8676e1e6d20d79b9a690b6d7520e8138ac629cc048417`) into
`build/obj-protonfixes-x86_64/downloads/unzip/` first.

## Reproduce

```
nix run github:aviallon/proton-cachyos?dir=nix        # or: nix build .#sources for the pinned trees
```
See `nix/flake.nix` in this repository. The flake pins every input but is
**not hermetic** (rootless podman + network submodule fetches are required).

## Install (does not select it for any game)

```
mkdir -p ~/.local/share/Steam/compatibilitytools.d/
tar -xf proton-cachyos-numa-hdr-v3-11.0-20260702.tar.xz \
    -C ~/.local/share/Steam/compatibilitytools.d/
```
Select it per-game yourself in Steam's Properties -> Compatibility.
