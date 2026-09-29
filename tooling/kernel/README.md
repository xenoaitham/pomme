# kernel stage — Linux arm64 for iPhone 7 (T8010)

Builds the Linux kernel (Image + DTBs + modules) for pomme's primary target,
the iPhone 7 (Apple T8010 / A10 Fusion, board D10; 7+ is D101). Output feeds
the m1n1 chainload handoff documented in `docs/bars.md` (bar 3): pongoOS
`bootm` → m1n1 → `Image` + `apple/*.dtb` + initramfs.

## Upstream and lineage

- Pinned source: `https://github.com/HoolockLinux/linux` @ tag `hoolock-7.0.12`
  (commit `dfa4d42081312dd34ec33ee8d23174309f683188`, 2026-06-12), mainline
  v7.0.12 based with `CONFIG_ARCH_APPLE` support. Pin recorded in
  `evidence/upstream-pins/linux-hoolock.json`; the tree is cloned to
  `upstream/linux-hoolock` (gitignored) and verified by SHA before every build.
- Lineage (see `docs/bars.md`): Corellium's Project Sandcastle kernel
  (`corellium/linux-sandcastle`, Linux 5.4.14, dormant since 2020-03) proved a
  T8010 Linux kernel is feasible but is archived; the postmarketOS
  "Apple Generic iDevice" port moved to the HoolockLinux 7.x kernel
  (`device/testing/linux-postmarketos-apple-{4k,16k}` in pmaports). pomme
  builds the pmOS lineage kernel because it is mainline-based, maintained
  (kernel tag 2026-06-12, pmaports tip 2026-09-28), and its DTS set covers the
  whole checkm8-era range (A7–A11, see `SUPPORT.md`).

## Toolchain

Pinned Bootlin aarch64 glibc stable 2026.08-1 cross GCC (gcc 15.3.0; tarball
sha256 `0213efac9b5577f20d58de9431960a191347ffc2257b27ffe7250522bf1f7867`).
Location is env-overridable (`POMME_TOOLCHAIN_DIR`, `TOOLCHAIN_ROOT`,
`TOOLCHAIN_TARBALL`); if the cross gcc is absent, `build.sh` fetches the
pinned tarball (URL + sha256 pinned in the script) and verifies the hash
before extracting — the stage is self-contained. Deviation from pmOS: pmOS
builds this kernel with `LLVM=1` (clang/lld + rust). pomme uses the pinned
GCC toolchain; consequences are listed under "Deviations from the pmOS
flavor" below.

## Config provenance (16K vs 4K — decision + citation)

`config-postmarketos-apple-16k.aarch64` (committed here; byte-identical to
pmaports `device/testing/linux-postmarketos-apple-16k/config-postmarketos-apple-16k.aarch64`
at pmaports @ `34a4e3c3a38c88f52319ecce80f02b561d2eeee2` (2026-09-28, pinned
in `evidence/upstream-pins/pmaports.json`) — APKBUILD sha512
`711c982ec45ad6594ae428bb486b0f1deb113838a35993c058e0bbfe76a129f7d1e02…`
matches) is the build input. `build.sh` copies it over `out/.config`, runs
`olddefconfig` to settle toolchain-dependent symbols, and writes the settled
result to `config-settled.aarch64` — that file is the exact build input for
the shipped artifacts.

**The iPhone 7's SoC (T8010 = A10 Fusion) requires the 16K-page kernel.** The
page-size rule is per SoC generation, and the deciding citations are:

1. postmarketOS wiki, "Apple Generic iDevice (apple-idevice)",
   https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice)
   (retrieved 2026-09-29): "There are two kernels. One for 4k page size
   devices, and one for 16k devices" — 4K kernel for A7/A8/A8X; 16K kernel for
   A9/A9X/A10 Fusion/A10X/A11/T2. Also summarized in `docs/bars.md`
   (bar 3, "Kernel" paragraph).
2. pmaports `device/testing/linux-postmarketos-apple-16k/config-postmarketos-apple-16k.aarch64`
   line 462: `CONFIG_ARM64_16K_PAGES=y` (and line 461 `# CONFIG_ARM64_4K_PAGES
   is not set`); the mirrored 4K flavor does the inverse
   (`config-postmarketos-apple-4k.aarch64` line 461).
3. The device package offers both as subpackages
   (`device/testing/device-apple-idevice/APKBUILD`: `kernel_4k` / `kernel_16k`),
   with the wiki instructing users to pick "the valid kernel page size for the
   device's SoC".

Note: the *in-tree* reason why A9+ wants 16K is not documented in the kernel
source (no comment in `arch/arm64/Kconfig` or the apple DTS establishes it);
the requirement is established at the distribution level by the pmOS port.
The settled config keeps `CONFIG_ARM64_16K_PAGES=y`, and `build.sh` fails hard
if that ever stops being true.

## Patches (all in `patches/kernel/`, applied by `build.sh`)

- `0001-backlight-apple_pmic_bl-add-default-case-to-get_brightness.patch` —
  GCC 15 rejects `drivers/video/backlight/apple_pmic_bl.c` with
  `-Werror=return-type` (switch without a default falls off the end of a
  non-void function). pmOS never sees this because they compile with clang.
  Adds `default: return 0;`; no behavior change for the two defined PMIC
  types. Generated with `git diff` and verified to apply under BOTH plain
  `patch -p1 --dry-run` and `git apply --check`. (A hand-anchored variant of
  the same change at hunk header -62,7 +62,9 is byte-correct but GNU patch
  2.7.6 refuses it — "Hunk #1 FAILED" / aligns only "with fuzz 2" — so the
  git-generated -64,6 +64,8 form is shipped; documented in the patch header.)

## Deviations from the pmOS flavor

- **Toolchain**: GCC 15.3.0 instead of clang/LLVM (see above). The one source
  patch exists because of this.
- **Rust support dropped**: the pmOS config sets `CONFIG_RUST=y`, but olddefconfig
  with the GCC toolchain (no rustc/bindgen pairing) drops it along with the
  Rust samples. No boot-critical driver depends on Rust; Android binder is C
  and stays. If pomme ever needs Rust abstractions, the build must move to an
  LLVM toolchain like pmOS.
- **Reproducibility pins**: `KBUILD_BUILD_TIMESTAMP` (fixed epoch
  `@1781222400` = exactly 2026-06-12T00:00:00Z), `KBUILD_BUILD_VERSION=1`,
  `KBUILD_BUILD_USER/HOST=pomme`. (The 2026-09-29 first build used
  `@1781232000`, mislabeled 00:00Z when it is 02:40Z; the fix changes
  embedded timestamps and therefore artifact hashes — see provenance.json.)
  The release string is still `7.0.12-gdfa4d4208131-dirty` because
  `CONFIG_LOCALVERSION_AUTO=y` appends the git describe of the *patched* tree
  (the backlight patch makes the checkout dirty). This is deliberate and
  honest — the `-dirty` marks patched-tree builds.

## Build and outputs

`bash tooling/kernel/build.sh > log 2>&1` (re-runnable; verify+patch+config
+build+install+package, ends with sha256sums of everything). Resource
profile: `-j8` with automatic `-j4` retry on failure (12 cores / ~6.3 GB RAM
host).

- `artifacts/kernel/Image` — arm64 kernel image, bare (m1n1/pongoOS bootable
  payload)
- `artifacts/kernel/Image.initramfs` — same kernel with the images stage's
  `artifacts/images/initramfs.cpio.gz` embedded via `CONFIG_INITRAMFS_SOURCE`
  (relative path, built in a second O= dir; only when that artifact exists —
  kernel target `Image` only, dtbs/modules are not rebuilt; single `.cpio.*`
  sources are embedded as-is per `usr/Makefile`, so
  `CONFIG_INITRAMFS_COMPRESSION_GZIP` is not set and runtime decompression
  relies on `CONFIG_RD_GZIP=y`).
  **Dependency: the bundle is a build-time snapshot of one exact initramfs
  (sha256 pinned in `artifacts/kernel/provenance.json`,
  `initramfs_image.source_archive_sha256`). If the images stage re-runs and
  produces a new `initramfs.cpio.gz`, the kernel stage must re-run to
  re-bundle it — otherwise `Image.initramfs` keeps serving the stale
  initramfs. `make all` builds kernel before images (`Makefile:37`), so
  after any images-stage change, run `make kernel` again.**
- `artifacts/kernel/dtbs/` — the 92 `apple/*.dtb` device trees built from
  `arch/arm64/boot/dts/apple/` (iPhone 7: `t8010-d10.dtb` Qualcomm modem,
  `t8010-d101.dtb` Intel modem)
- `artifacts/kernel/modules.tar.gz` — stripped modules, `lib/modules/<release>/`
  layout, ready to be unpacked into an initramfs or rootfs by the images stage
- `artifacts/kernel/provenance.json` — full traceability (sources, toolchain,
  config hashes, artifact hashes)

Modules policy: ship all modules the pmOS config builds (stripped, zstd
compressed). The images stage decides what goes into an initramfs; pmOS's own
`modules-initfs` for this device needs only `netboot`
(`device/testing/device-apple-idevice/modules-initfs`), so the tarball is a
superset by design.

## Known limitations

- **builds-not-boots**: nothing in this repo has been booted on hardware.
  This artifact's only evidence is the committed build log
  (`evidence/builds/kernel_7.0.12-hoolock_<date>.log[.gz]`). Boot-readiness
  (m1n1 payload assembly, firmware) is the images stage's problem.
- **Page size is per-SoC, not per-device**: this 16K kernel is wrong for
  A7/A8/A8X devices (iPhone 5s/6/6+, iPad Air 1/2, mini 2/3/4, iPod 6, Apple
  TV HD) — those are served by the **4K flavor** (below). See `SUPPORT.md`.
- **16K rationale is not in-tree** (see above): if pmOS changes the rule, our
  citation chain goes stale — re-verify against the wiki + pmaports on any
  rebase.
- A12+ is out of scope forever (no checkm8; `docs/pipeline-conventions.md`).

## The 4K flavor (`POMME_KERNEL_FLAVOR=4k` / `make kernel-4k`)

The same pinned source, patches, and toolchain build a second Image from the
pmaports `linux-postmarketos-apple-4k` config
(`tooling/kernel/config-postmarketos-apple-4k.aarch64`, verbatim import —
sha512 matches the APKBUILD at the pinned pmaports revision). Differences
from the 16K run, all mechanical:

- outputs to `artifacts/kernel-4k/`, build tree `out-4k/` (+ `out-4k-initramfs/`)
- settled config written to `tooling/kernel/config-settled-4k.aarch64`
- page-size asserts check `CONFIG_ARM64_4K_PAGES=y` and `file(1)` "4K pages"
- the initramfs bundle pass embeds `artifacts/images-4k/initramfs.cpio.gz`
  (the flavor's own module closure — modules are page-size-ABI-sensitive;
  `make all-4k` sequences kernel → images-4k → kernel rebundle)
- DTBs are the same 92-file set (page-size agnostic; both flavors ship them)
- canonical self-log `evidence/builds/kernel_4k_<tag>_<date>.log`; provenance
  generated per flavor (`artifacts/kernel-4k/provenance.json`) with the same
  freshness guard as the 16K one (which also gained its generator in the same
  change — 16K provenance stays curated-preserved while bytes are unchanged)
