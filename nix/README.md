# Nix flake for the unofficial proton-cachyos NUMA+HDR+v3 build

This directory contains a **parameterized** flake that builds
`proton-cachyos-numa-hdr-v3` (and codegen variants of it). See
`../numa-hdr-v3/RELEASE-NOTES.md` for full provenance.

## Named variants (one command apart)

```bash
# Hermetic fixed-output source pins (top-level trees):
nix build .#sources

# Default: tree x86_64 AVX/AVX2 codegen ENABLED, DXVK keeps its own -mno-avx:
nix build .#proton-v3

# CachyOS stock: the -mno-avx/-mno-avx2/-mno-avx512f -fvect-cost-model=cheap
# workaround applied tree-wide (i386 and x86_64), exactly as CachyOS ships:
nix build .#proton-v3-cachyos-stock

# Run one:
nix run .#proton-v3
```

Both are non-hermetic builders (network + rootless podman + the SteamRT4 SDK
image). They embed their whole flag set in the produced artifact name, e.g.:

```
proton-cachyos-numa-hdr-v3-march-x86-64-v3-mtune-znver3-rustcpu-znver3-lto-off-treeavx-enabled
proton-cachyos-numa-hdr-v3-march-x86-64-v3-mtune-znver3-rustcpu-znver3-lto-off-treeavx-cachyos-workaround
```

so two artifacts can never be confused.

## What the `-mno-avx` workaround is, and why the default changed

The `-mno-avx -mno-avx2 -mno-avx512f` flags (plus `-fvect-cost-model=cheap`)
are **CachyOS's own patch**, added by Stelios Tsampas on 2026-04-17 in commit
`d89efe07` — the same commit that made `HOST_CFLAGS`/`HOST_RUSTFLAGS`
environment-overridable. The parent revision's `Makefile.in` has *zero*
`-mno-avx`. So this is not Valve upstream.

That commit gives two different reasons:

* **i386** — an ABI/correctness requirement: the 32-bit Windows ABI only
  guarantees 4-byte stack alignment, so the compiler must not assume 16/32-byte
  alignment nor emit aligned 16/32-byte vector spills. CachyOS pairs it with
  `-mpreferred-stack-boundary=2` (GCC) / `-mstack-alignment=4` (Clang) and
  `-mstackrealign`, citing Wine commit `4b458775bb8c` ("configure: Use
  -mpreferred-stack-boundary=2 on i386"). **Keep i386 exactly as-is.**
* **x86_64** — a DXVK bug, bisected to DXVK commits `5a4d8921` and `64124232`
  ("use -mno-avx for dxvk … Newer DXVK versions have problems again"). That is a
  DXVK-specific workaround, yet CachyOS applies it to **all** x86_64 code via
  `x86_64_CFLAGS +=`.

CachyOS's default `HOST_CFLAGS ?= -O2 -march=nocona -mtune=core-avx2` made
these flags a **no-op** (nocona has no AVX). They only bite for users who raise
`-march`, i.e. exactly these v3 builds. The flake default therefore scopes the
workaround to where the bug was bisected (DXVK) and enables AVX/AVX2 for the
rest of the x86_64 tree. This is a **deliberate, visible departure from
CachyOS's "never emit AVX regardless of `HOST_CFLAGS`" ISA policy**, and it
still needs an in-game test before being trusted.

DXVK keeps the workaround: `DXVK_x86_64_CFLAGS = -O3 -mno-avx` already carries
it (`-mno-avx` alone suffices, since AVX2/AVX-512 require AVX). The flake does
not add `-fvect-cost-model=cheap` there; that remains available as a follow-up.

Only the x86_64 tree AVX/vectorisation lines are stripped; no other x86_64
tuning flag (`-fno-semantic-interposition`, `-fipa-pta`, …) is touched.

## Codegen knobs

Defaults (`defaultCodegen` in `flake.nix`) reproduce the previously hard-coded
march/mtune/rust-cpu/lto configuration:

| knob                    | default       | effect |
| ----------------------- | ------------- | ------ |
| `march`                 | `x86-64-v3`   | GCC `-march` |
| `mtune`                 | `znver3`      | GCC `-mtune` |
| `rustTargetCpu`         | `znver3`      | rustc `-Ctarget-cpu` |
| `lto`                   | `false`       | injects `-flto` / `-Clto` and `USE_LTO=1` |
| `treeWideAvxWorkaround` | `false`       | `false` = strip CachyOS's x86_64 `-mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap` from the generated `Makefile` (tree AVX enabled); `true` = CachyOS stock, applied tree-wide |

`treeWideAvxWorkaround = false` edits the **generated** `Makefile` only (build
output), never the pinned source tree: CachyOS's `Makefile.in` appends those
flags inside `ifeq ($(CONTAINER),1)`, so the generated `Makefile` gets one
appended line

```make
x86_64_CFLAGS := $(filter-out -mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap,$(x86_64_CFLAGS))
```

`i386_CFLAGS` is never touched.

`lto` is exposed for completeness: `USE_LTO` has no consumer in the pinned tree,
which is why `lto = true` also injects `-flto`/`-Clto` directly. The `lto = true`
path is not covered by the verification below.

## Overriding any knob

Any configuration is one expression away via the flake's non-standard `lib`
output:

```bash
nix build --impure --expr \
  '((builtins.getFlake (toString ./nix)).lib.mkBuilder { march = "x86-64-v4"; })'
```

`lib.mkCodegen` merges an override attrset with the defaults; `lib.mkBuilder`
turns a full config into a builder derivation.

## What IS and IS NOT pinned

Pinned:

* top-level proton tree — `revProton`, fixed-output hash `hashProton`
  (`pkgs.fetchgit`);
* top-level wine tree — `revWine`, fixed-output hash `hashWine` (`pkgs.fetchgit`);
* SteamRT4 SDK image — sha256 digest, passed to `configure.sh` via
  `--proton-sdk-image`;
* codegen flags — baked into each variant at evaluation time;
* nixpkgs — `flake.lock`.

Not pinned / not hermetic:

* the compile itself (rootless podman + SDK image), which Nix cannot sandbox;
* the 52 non-wine submodule **contents**: a network checkout supplies `.git`
  metadata and the submodule gitlinks, `git submodule update` checks out the
  revisions recorded in the pinned proton tree, but the bytes come from each
  submodule's upstream git server;
* the snapshot.debian.org `unzip` tarball (the original Debian URL 404s; the
  file is fetched by content hash and verified with sha256);
* piper's `piper-phonemize`, which `piper/CMakeLists.txt` downloads at build
  time from a **moving branch**
  (`https://github.com/shaunren/piper-phonemize/archive/refs/heads/pic.zip`)
  with no hash. This is the source of the espeak-ng data used by the TTS build
  and it can change under the pinned tree (see the build status below).

The builder does **not** re-clone the top-level trees for the build: after the
network checkout it overwrites the top-level proton/wine trees with the
hash-pinned `protonSrc`/`wineSrc` Nix store trees, asserts the built tree's
`HEAD` equals `revProton`, asserts the pinned tree's `wine` gitlink equals
`revWine`, and asserts the pinned top-level tree is byte-identical to the pinned
git commit before configuring.

A fully sandboxed Nix build of Wine+Proton is a separate large project.

## Cheaply verifying that a codegen knob reaches the compiler

For either variant, generate the `Makefile` without building:

```bash
PROTON_BUILDER_STOP_AFTER_CONFIGURE=1 nix run .#proton-v3
```

Then expand the container-side target CFLAGS (the CachyOS overrides live inside
`ifeq ($(CONTAINER),1)`):

```bash
make -C ~/.cache/proton-cachyos-numa-hdr-v3/build-*-treeavx-enabled \
     CONTAINER=1 -f Makefile -f <(printf 'f:\n\t@echo $(x86_64_CFLAGS)\n') f
```

Expected, for the default `proton-v3`:

* `x86_64_CFLAGS` has **no** `-mno-avx`/`-mno-avx2`/`-mno-avx512f`/
  `-fvect-cost-model=cheap`;
* `i386_CFLAGS` **still has** all of them;
* `DXVK_x86_64_CFLAGS` still has `-mno-avx`;
* `HOST_CFLAGS` contains `-march=x86-64-v3` and no `-march=nocona`.

`proton-v3-cachyos-stock` keeps the workaround on both i386 and x86_64.

### Wine-level confirmation of the same knob

The `Makefile` variable is not what cc reads; wine's own generated makefile is.
After running only wine's configure through the SDK container, the flags in the
wine makefiles are:

* `obj-wine-x86_64/Makefile` `CFLAGS`: `-mcmodel=small -march=x86-64-v3 -mtune=znver3 -mfpmath=sse` — no `-mno-avx*` (the only `-mno-avx` strings in that file are the cross `i386_CFLAGS`/`i386_CXXFLAGS`);
* `obj-wine-i386/Makefile` `CFLAGS`: `-mstackrealign -march=x86-64-v3 -mtune=znver3 -mfpmath=sse -mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap`;
* `obj-dxvk-x86_64/build.ninja`: every one of the 271 compile rules carries `-O3 -march=x86-64-v3 -mtune=znver3 -mno-avx`.

## Build status (this environment)

A full `make redist` of the default `proton-v3` does **not** complete here. It
fails while building the `piper` TTS dependency: espeak-ng's `phondata` step
reports `Compiled phonemes: 30 errors` (`Bad vowel file: …`) and exits 1,
taking `redist` down with `Error 2`.

This failure is **independent of the AVX knob and was proven so by A/B**: the
`proton-v3-cachyos-stock` flag set (tree-wide `-mno-avx`, 60 occurrences in
piper's build) fails with byte-for-byte the same 30 `Bad vowel file` errors.
The espeak-ng `phsource` tree is also identical (1312 files) to an earlier
build of this tree that succeeded, and the flags themselves are not the cause.
The likely cause is the unpinned moving `piper-phonemize` branch noted above.

Consequences, stated plainly:

* **no runnable artifact has been produced yet** and the AVX2 codegen has
  **not** been validated in-game or disassembled;
* wine's configure and individual wine x86_64/i386 objects *were* built
  successfully in the SDK container, which is what the flag proof above rests
  on;
* a full build needs the `piper-phonemize`/espeak-ng issue resolved first
  (e.g. pinning that dependency, or configuring with `--without-tts`).
