# Nix flake for the unofficial proton-cachyos NUMA+HDR+v3 build

This directory contains a flake that pins and reproduces the build of
`proton-cachyos-numa-hdr-v3`. See `../numa-hdr-v3/RELEASE-NOTES.md` for full
provenance.

```bash
# Hermetic fixed-output source pins (top-level trees):
nix build .#sources

# The builder (NON-hermetic: needs network + rootless podman + the SteamRT4
# SDK image). It clones the pinned revisions, applies the recorded workaround
# for the removed Debian unzip source, and runs the CachyOS CI procedure.
nix run .
```

Hermetic: `.#sources` (pinned `fetchgit` outputs) and nixpkgs (`flake.lock`).
Not hermetic: the compile itself (rootless podman + SDK image), the git
submodule fetches (revisions pinned by the pinned trees), and the
snapshot.debian.org unzip fetch (verified by sha256). A fully sandboxed Nix
build of Wine+Proton is a separate large project.
