# Nix flake for the unofficial proton-cachyos NUMA+HDR+v3 build

This directory contains a **parameterized** flake that builds
`proton-cachyos-numa-hdr-v3` (and codegen variants of it). See
`../numa-hdr-v3/RELEASE-NOTES.md` for full provenance.

## Named variants (one command apart)

```bash
# Hermetic fixed-output source pins (top-level trees):
nix build .#sources

# Builder variant identical to the previously hard-coded configuration:
nix build .#proton-v3

# Same, but with AVX/AVX2/AVX-512 vector codegen enabled:
nix build .#proton-v3-avx2

# Run one:
nix run .#proton-v3-avx2
```

Both `proton-v3` and `proton-v3-avx2` are non-hermetic builders (network +
rootless podman + the SteamRT4 SDK image). They embed their whole flag set in
the produced artifact name, e.g.:

```
proton-cachyos-numa-hdr-v3-march-x86-64-v3-mtune-znver3-rustcpu-znver3-lto-off-avx2-off
proton-cachyos-numa-hdr-v3-march-x86-64-v3-mtune-znver3-rustcpu-znver3-lto-off-avx2-on
```

so two artifacts can never be confused.

## Codegen knobs

Defaults (`defaultCodegen` in `flake.nix`) reproduce the previously hard-coded
configuration:

| knob                | default       | effect |
| ------------------- | ------------- | ------ |
| `march`             | `x86-64-v3`   | GCC `-march` |
| `mtune`             | `znver3`      | GCC `-mtune` |
| `rustTargetCpu`     | `znver3`      | rustc `-Ctarget-cpu` |
| `lto`               | `false`       | injects `-flto` / `-Clto` and `USE_LTO=1` |
| `enableAvx2Codegen` | `false`       | `false` = CachyOS behaviour; `true` = strip CachyOS's `-mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap` from the GCC target CFLAGS |

`enableAvx2Codegen = true` edits the **generated** `Makefile` only (build
output), never the pinned source tree: CachyOS's `Makefile.in` appends those
flags to `i386_CFLAGS`/`x86_64_CFLAGS` inside `ifeq ($(CONTAINER),1)`, which
disables AVX/AVX2 vector codegen even with `-march=x86-64-v3`. Component-specific
AVX-disabling flags (DXVK's `-mno-avx`, OPENFST's `-mno-bmi2`, …) are **not**
touched.

`lto` is exposed for completeness: note that `USE_LTO` has no consumer in the
pinned tree, which is why `lto = true` also injects `-flto`/`-Clto` directly.
The `lto = true` path is not covered by the verification below.

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
  file is fetched by content hash and verified with sha256).

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
PROTON_BUILDER_STOP_AFTER_CONFIGURE=1 nix run .#proton-v3-avx2
```

Then expand the container-side target CFLAGS (the CachyOS overrides live inside
`ifeq ($(CONTAINER),1)`):

```bash
make -C ~/.cache/proton-cachyos-numa-hdr-v3/build-*-avx2-on \
     CONTAINER=1 -f Makefile -f <(printf 'f:\n\t@echo $(x86_64_CFLAGS)\n') f
```

`proton-v3` prints `... -mno-avx -mno-avx2 -mno-avx512f -fvect-cost-model=cheap`;
`proton-v3-avx2` prints the same flags without those tokens.
