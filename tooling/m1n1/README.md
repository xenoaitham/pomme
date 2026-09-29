# pomme stage: m1n1 (Apple iDevice fork)

Builds the **m1n1 bootloader** — Asahi Linux's stage-2 bootloader, ported to
Apple iDevices by HoolockLinux — from the pinned upstream commit, and installs
its outputs into `artifacts/m1n1/`.

- Upstream: <https://github.com/HoolockLinux/m1n1>
- Pin: `bd117d710e1c88a2cba45d47a030334bf74f212e` (2026-02-08), recorded in
  `evidence/upstream-pins/m1n1-apple-idevice.json`, clone at
  `upstream/m1n1-apple-idevice` (gitignored)
- Version string used for logs/provenance: `1.5.0_git20260208` (mirrors the
  pmaports `pkgver` for this exact commit)
- License: MIT ("Copyright The Asahi Linux Contributors")

## Why this stage exists in pomme

pomme's boot chain for the 4K-page A7/A8 generation is:

```
checkm8 (gaster) -> pongoOS -> bootm -> m1n1 -> Linux
                                              Image + DTBs + initramfs
                                              concatenated as m1n1-linux.bin
```

pongoOS `bootm` loads and jumps into m1n1 (pinned in
`evidence/upstream-pins/m1n1-apple-idevice.json` role field, citing pongoOS
`src/shell/main.c:294`); m1n1 then does the distribution-standard job of
handing a Linux kernel its DTBs and initramfs. This is the same boot flow the
postmarketOS `device/testing/device-apple-idevice` target documents (4K
rootfs sector size, generic "Apple iDevice" codename), and the artifact the
pmOS wiki boot flow concatenates into `m1n1-linux.bin`. pongoOS alone cannot
boot a mainline-style Linux arm64 Image; m1n1 is the missing link that gives
the A7/A8 devices a distribution-standard boot path.

Of the four outputs this stage installs, **`m1n1.bin` is the one the pomme
chain consumes**: the pmOS APKBUILD ships it explicitly as the "binary for
usage with PongoOS bootm". The Mach-O payloads (`m1n1.macho`,
`m1n1-idevice.macho`) serve iBoot-style loading paths, and
`monitor-stub.macho` exists for building mock kernel images — installed
because upstream's `all` target produces them and the pmOS package ships
them, not because this pipeline loads them.

## What gets built, with which knobs

Exactly the pmaports recipe:

```
make RELEASE=1 CHAINLOADING=1
```

- `RELEASE=1` — release configuration (stamped into `build/build_cfg.h`).
- `CHAINLOADING=1` — the configuration pongoOS chainloads; the reason this
  stage exists.

Outputs (upstream's own names, kept verbatim — the pmOS APKBUILD renames
`m1n1.bin` to `m1n1-idevice.bin` only to fit Alpine packaging, which this
pipeline does not need):

| artifact | kind | role |
|---|---|---|
| `m1n1.bin` | raw binary (objcopy of `m1n1-raw.elf`) | **pongoOS `bootm` payload — the pomme chain artifact** |
| `m1n1.macho` | Mach-O 64-bit arm64 | m1n1 payload (`m1n1.ld`) |
| `m1n1-idevice.macho` | Mach-O 64-bit arm64 | iBoot-style variant (`m1n1-idevice.ld`) |
| `monitor-stub.macho` | Mach-O 64-bit arm64 | stub for mock kernel images |

## Toolchain

- **Cross GCC**: the pinned Bootlin aarch64 toolchain at
  `/home/potato/toolchains/aarch64--glibc--stable-2026.08-1/`
  (GCC 15.3.0, binutils 2.45.1), passed via the fork Makefile's own
  `TOOLCHAIN`/`ARCH` variables. **LLVM is NOT required**: the Makefile's
  GCC path is first-class (the clang path exists for macOS hosts); the
  freestanding C and `-march=armv8.2-a` asm build clean under GCC 15.
- **Rust**: host rustc 1.89.0 (rustup-managed) with the
  `aarch64-unknown-none-softfloat` target installed; the Makefile exports
  `RUSTC_BOOTSTRAP=1` itself and builds `librust.a` with the lockfile-pinned
  crates (uuid/bitflags/log from crates.io, fatfs from the
  `rust/vendor/rust-fatfs` git submodule, pinned at `4eccb50d…92e7`).
  First run needs network for `rustup target add` and the crates; later
  runs are fully cached.
- **Python is NOT needed for the build.** Unlike some m1n1 packaging flows,
  this fork's Makefile assembles the Mach-O/ binaries with the cross
  toolchain's own objcopy; the proxyclient python deps
  (`requirements.txt`, pyelftools et al.) are only for the runtime tooling
  and the hardware-in-the-loop pytest suite, which builds-not-boots
  deliberately does not run.
- `inkscape`/`imagemagick` are NOT needed either — those exist in the pmOS
  recipe only to stamp a postmarketOS boot logo (see deviations below); the
  clone ships its own committed `data/bootlogo_*.bin`.

## Patches: none (`patches/m1n1/` is empty)

The pinned fork builds as-is with the toolchain above. In particular, the
pmaports patch
(`upstream/pmaports/device/testing/m1n1-apple-idevice/0001-vendor-dependencies-with-cargo-instead-of-git.patch`)
is **deliberately NOT applied**: it converts `fatfs` from upstream's path
dependency on the vendored git submodule into a cargo git dependency,
because aports builds from a submodule-less source tarball. We build from
the actual git clone, so upstream's own vendored layout is used and no
deviation is needed.

build.sh asserts machine-checkably that upstream is never modified: the
clone is reset to the pin, the submodule pinned, and `git status
--porcelain` must be empty before any build step runs. Any future deviation
goes in `patches/m1n1/*.patch` with a header explaining why.

## Determinism

- Each `build.sh` run performs TWO full clean rebuilds and gates on all four
  artifacts hashing identically between them (recorded in provenance.json).
- The build is byte-reproducible on this host: nothing embeds timestamps
  (no `__DATE__`/`__TIME__` in upstream sources; `SOURCE_DATE_EPOCH` is set
  from the pin date for good citizenship but nothing consumes it). The only
  variable input is the embedded `BUILD_TAG`, which comes from
  `git describe --tags --always --dirty` in the pinned clone — for this
  depth-1, tag-less clone that is the abbreviated pin sha (`bd117d7`),
  embedded behind the `##m1n1_ver##` magic and asserted by smoke test 3.
  A full-history reclone could change that string and thus the bytes.
- The smoke tests verify, among other things, that `m1n1-raw.elf` is ELF64
  AArch64 (entry `0x800`), that the Mach-O payloads are `arm64` Mach-O, that
  `build_cfg.h` really contains `RELEASE` + `CHAINLOADING`, and that
  provenance.json's `artifact_files` match the files on disk.

## Known limitations

- **builds-not-boots**: nothing in this pipeline, m1n1 included, has ever
  been booted on hardware by this project. "Proven to build" is exactly and
  only what is claimed.
- **A12 and newer are permanently unsupported** (no public checkm8-equivalent
  bootROM exploit). Nothing in this stage changes that, and no device support
  is claimed beyond what the pinned fork itself implements.
- The pmOS APKBUILD additionally regenerates boot logos with the
  postmarketOS artwork and renames outputs for Alpine packaging; this stage
  intentionally does neither (no branding, upstream names kept). No impact on
  the pongoOS `bootm` chain.
- The pmOS `check()` phase (proxyclient pytest against a live device) is not
  run — it requires hardware this pipeline does not have.

## Running

```
bash tooling/m1n1/build.sh
```

Fully non-interactive, re-runnable (resets the clone to the pin, rebuilds
from clean, overwrites artifacts and provenance, self-tees the canonical log
to `evidence/builds/m1n1_<version>_<date>.log`). Standalone by design; the
repo Makefile wiring is the orchestrator's job.
