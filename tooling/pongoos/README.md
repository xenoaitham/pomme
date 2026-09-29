# pongoOS stage

Builds the pongoOS bootloader payload (`Pongo.bin`, an arm64 bare-metal binary
extracted from a Mach-O) plus the checkra1n kernel patchfinder as a pongoOS
module, from pinned upstream sources, on a plain Linux host with no sudo.

- **Upstream (primary):** https://github.com/palera1n/pongoOS @
  `e98323f8a09abd80fc4cbcd74dee023b91a1ec22` (branch `iOS15`, 2026-07-19) —
  the fork palera1n actually ships.
- **Submodule:** https://github.com/checkra1n/newlib @
  `f9ea5054de8fb51dff6f6d3c2e7cdd4aa89744b8` (gitlink recorded in the pin).
- **Reference (not built):** https://github.com/checkra1n/pongoOS @
  `4c9b7541629234147fcc778f0ce4162482aaccef` (2021-11-04), cloned under
  `upstream/pongoOS` for comparison only.

Run: `bash tooling/pongoos/build.sh` (non-interactive, re-runnable, logs to
stdout/stderr; `make pongoos` wraps it with a tee'd log).

## Upstream investigation summary

- `.github/workflows/ci.yml` builds **only on `macos-latest`** runners with
  plain `make` (Xcode toolchain) and uploads `build/Pongo.bin` +
  `build/checkra1n-kpf-pongo` via SFTP. The Linux path is not CI-exercised.
- `Makefile` (lines 90–99) has a first-class `HOST_OS=Linux` branch:
  `EMBEDDED_CC ?= clang` (`--target=arm64-apple-ios12.0`) and
  `EMBEDDED_LD := $(shell which ld64)` — i.e. it expects Apple `ld64` (cctools)
  on PATH. Line 144 calls bare `strip` on the KPF Mach-O.
- `README.md` documents this Linux build: install `ld64` and cctools' `strip`
  from checkra1n's Debian repo (`deb https://assets.checkra.in/debian /`,
  packages `ld64`, `cctools-strip`), or build them yourself (it links
  https://github.com/Siguza/ld64). It also hints (commented-out Makefile
  lines 81/94) at LLVM `ld64.lld` as an alternative linker.
- No Dockerfile, no osxcross support, no bundled toolchain in the repo. The
  `newlib` submodule is built with the same clang target and `llvm-ar`
  (not GNU ar) to produce `newlib/aarch64-none-darwin/fixup/libc.a`.
- `tools/vmacho.c` is a host-side C tool that extracts `build/Pongo` (Mach-O)
  into `build/Pongo.bin` (bare metal, entry at physical 0x80000, link base
  0x100000000).

## Build paths tried (evidence/builds/)

| # | Path | Result |
|---|------|--------|
| 1 | **Official Linux path** (this is what `build.sh` does): Ubuntu clang 18.1.3 + checkra1n `ld64 530-2` + `cctools-strip 949.0.1-2` debs (sha256-pinned, extracted locally, no root) + system LLVM `libLTO.so.18` exposed at ld64's expected `<prefix>/lib/llvm/libLTO.so`; `llvm-ar`/`llvm-ranlib` shimmed onto PATH; `strip` shim → `cctools-strip` | **GREEN** — `pongoos_attempt1_checkra1n-ld64_20260929.log`, canonical run `pongoos_2.6.3-e98323f8_20260929.log` |
| 2 | LLVM `ld64.lld` 18 variant (`make EMBEDDED_LD=.../ld64.lld`) | **RED** — `ld64.lld: error: must specify -platform_version` / `missing or unsupported -arch arm64`; would need flag patches, not attempted further (`pongoos_attempt2_ld64-lld_20260929.log`) |
| 3 | Hand-rolled cctools-port (source build of ld64) | **SKIPPED** — path 1 (the repo's own documented path) fully succeeded; cctools-port would duplicate what checkra1n's ld64 deb already provides. Rationale recorded here; no log. |
| 4 | Cross-host determinism container: clean `ubuntu:24.04`, repo + sha256-pinned deb cache mounted, deps apt-installed, full clean rebuild with the fixed `build.sh` | **GREEN build / PARTIAL match** — KPF byte-identical cross-host; Pongo differs through newlib's environment-sensitive archive member order plus a residual ld64+libLTO link-context sensitivity (full matrix + root causes in `pongoos_crosshost_20260929.log`). Attempt 1 first caught the bare-soname libLTO dlopen issue (fixed in §5). |

Reproducibility: builds are **deterministic within a context** (host rebuilds
reproduce the shipped hashes; container rebuilds reproduce the container hashes
exactly), and cross-host builds are **equally-valid but not byte-identical**
for `Pongo.bin`/`Pongo.macho` (see path 4); the shipped artifacts are the
canonical host build. The canonical run started from **no upstream clone**
(build.sh cloned the pinned commit itself) and produced artifacts
**bit-identical** (same sha256) to attempt 1.

## Single resolved LLVM version (enforced in code)

The build touches three LLVM components: the `clang` producing `-flto` bitcode,
the `libLTO.so` that cctools `ld64` loads to optimize/link it, and the
`llvm-ar`/`llvm-ranlib` that assemble newlib's `libc.a`. `build.sh` §0b derives
**one** version number — the major of the `clang` on PATH, cross-checked
against clang's own resource dir — and then requires `libLTO.so.<N>` (or
`libLTO.so.<N>.x`) **and** `llvm-ar`/`llvm-ranlib` from the *same* `llvm-N`
prefix, verifying llvm-ar reports the same major. Any absence or mismatch is
fatal. This matters: this host has `/usr/lib/llvm-16`, `-17` and `-18`
installed simultaneously, and a "first libLTO found wins" glob prefers
`llvm-16`'s — a silent clang-18-produces / libLTO-16-consumes mismatch. The
llvm-ar shim and the libLTO links are rebuilt from the resolved triple on every
run, so stale state from a previous toolchain cannot survive a re-run.

## Why libLTO matters (real mechanism, verified by LD_PRELOAD)

The build uses `-flto`; cctools `ld64` links LLVM bitcode after loading a
libLTO at runtime. Despite its error message printing
`<dir of ld64>/../lib/llvm/libLTO.so`, checkra1n's ld64-530 actually calls
`dlopen("libLTO.so", RTLD_LAZY)` — the **bare soname**. Bare-soname resolution
follows the standard loader search (`LD_LIBRARY_PATH`, then ld64's hardwired
`RUNPATH=/usr/lib/llvm-10/lib`, which never exists here) and requires a file
*literally named* `libLTO.so`; the versioned runtime `libLTO.so.18.1` does not
match. Hosts only worked when a dev package provided the unversioned alias.

`build.sh` therefore publishes the version-enforced `libLTO.so.<N>` under the
exact name `libLTO.so` in a build-owned directory
(`<toolchain>/lto/libLTO.so`) placed first on `LD_LIBRARY_PATH` (which also
carries `<llvm-prefix>/lib` for the `libLLVM-<N>.so` dependency). The
`<toolchain>/root/lib/llvm/libLTO.so` path link is kept as well for source-built
ld64 variants that really do path-dlopen it. Verified cross-host: a clean
`ubuntu:24.04` container without dev packages now links green (see
`evidence/builds/pongoos_crosshost_20260929.log`).

## Patch mechanism (re-runnable by construction)

`patches/pongoos/*.patch` are applied by §3 of `build.sh`: the tracked upstream
tree is first forced back to the pristine pinned commit (`git reset --hard`;
untracked build outputs survive), then each patch is validated with
`git apply --check` against that pristine state and applied. A reused clone
always yields the same post-patch tree — an already-applied patch is reverted
by the reset and re-applied cleanly, never doubled. The mechanism was
demonstrated with a throwaway patch in a scratch clone of the pin (apply →
double-apply correctly rejected without reset → re-run via reset+apply yields
an identical tree): `evidence/builds/pongoos_patchrerun_20260929.log`.

## Licensing caveats

- **pongoOS:** MIT (LICENSE.md, © 2019–2023 checkra1n team; third-party bits
  keep their own licenses, also in LICENSE.md).
- **newlib submodule:** checkra1n's newlib fork carries the upstream newlib
  per-file BSD-style license collection (see the upstream repo's README/patches).
- **Apple linker/strip (`ld64`, `cctools-strip`):** these are Apple cctools
  binaries redistributed by the checkra1n project as Debian packages. They are
  downloaded at build time, checksum-pinned (sha256 recorded in build.sh and
  provenance.json), and stored under `/home/potato/toolchains/` (outside the
  repo, never committed). Redistribution terms for Apple cctools are the
  APSL-derived terms shipped inside the packages; we treat them as
  build-time-only toolchain, not as pomme artifacts.
- **No macOS SDK is used or needed.** The build is freestanding
  (`-ffreestanding -nostdlibinc`); Apple SDK headers are not required — the
  in-tree `apple-include/` directory covers what pongoOS needs. The SDK-fetch
  rule of docs/pipeline-conventions.md therefore does not trigger for this
  stage.

## Limitations (honesty rules)

- **builds-not-boots:** nothing here has been booted on hardware. `Pongo.bin`
  is validated by format only (`Mach-O arm64` / extracted raw payload,
  sha256-recorded). Booting requires a checkm8 exploit stage (pomme `gaster`)
  plus a DFU-connected A7–A11 device.
- **A12 and newer are unsupported**, permanently — no public checkm8-equivalent
  bootROM exploit exists. This pongoOS binary contains no A12+ platform code.
- palera1n's Makefile does not build the historic `PongoConsolidated.bin`
  (pongoOS+KPF single blob, mentioned in the old checkra1n README). palera1n
  loads the KPF as a separate module; we ship both artifacts instead.
- The KPF embeds `CHECKRA1N_VERSION="beta 0.12.4"` (Makefile default) —
  cosmetic version string, not a functional knob.
- `toolchain debs` come from `assets.checkra.in`; if that host disappears,
  build.sh fails at the pinned download step (by design — no silent pin drift).
  Alternative documented: build ld64 via Siguza/ld64 or cctools-port.
