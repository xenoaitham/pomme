# pomme

pomme is a maintained, documented build pipeline that produces a complete
open-source Linux boot chain for checkm8-era iPhones and iPads (A7–A11),
targeting the iPhone 7 (Apple T8010) first. It assembles seven stages from
pinned upstream commits with a fully Linux host toolchain — no macOS, no
Apple SDK — and records a build log and sha256 for everything it ships.

```
Linux host (x86-64)                                iPhone 7 in DFU (05ac:1227)
─────────────────────                              ───────────────────────────
  gaster  ────── checkm8 ────────►   pwned DFU      (still 05ac:1227)
  dfu-send Pongo.bin ────────────►   pongoOS        (re-enumerates 05ac:4141)
  load-linux Image.initramfs     ►   fdt + bootl →  Linux 7.0.12 (16K, initramfs
              + t8010-*.dtb                         bundled) → USB-net shell 10.0.0.2
```

## Status

All seven stages **build green** on Ubuntu 24.04 x86-64, with committed build
logs and sha256 manifests (VERSION `0.1.0`; manifest regenerated 2026-09-29T20:03:56Z (authoritative copy: artifacts/manifest.json)):

| Stage | Artifact | sha256 | Upstream pin | Build log |
|---|---|---|---|---|
| gaster | `artifacts/gaster/gaster` | `6802003b…` | `palera1n/gaster@20958256` | `evidence/builds/gaster_2095825+pomme1_20260929.log` |
| pongoos | `artifacts/pongoos/Pongo.bin` (+ `Pongo.macho`, `checkra1n-kpf-pongo.macho`) | `22eec6e4…` | `palera1n/pongoOS@e98323f8` | `evidence/builds/pongoos_2.6.3-e98323f8_20260929.log` |
| kernel | `artifacts/kernel/Image` (bare, 16K pages) | `57ef480e…` | `HoolockLinux/linux@dfa4d420` (tag `hoolock-7.0.12`, 16K-page config) | `evidence/builds/kernel_7.0.12-hoolock_20260929.log` |
| kernel | `artifacts/kernel/Image.initramfs` (16K pages, images-stage initramfs bundled via `CONFIG_INITRAMFS_SOURCE`) | `473660c0…` | same pin; bundles `initramfs.cpio.gz@39f349e9` | `evidence/builds/kernel_7.0.12-hoolock_20260929.log` |
| kernel | `artifacts/kernel/dtbs/` (92 `apple/*.dtb`) + `modules.tar.gz` | dtbs per-file in manifest / `fb480afd…` | same pin | `evidence/builds/kernel_7.0.12-hoolock_20260929.log` |
| images | `artifacts/images/initramfs.cpio.gz`, `artifacts/images/rootfs.img` | `39f349e9…` / `66a2e301…` | Alpine 3.24.2 minirootfs + busybox-static 1.37.0 (checksum-pinned) | `evidence/builds/images_3.24.2_20260929.log` |
| m1n1 | `artifacts/m1n1/m1n1.bin` (+ `m1n1.macho`, `m1n1-idevice.macho`, `monitor-stub.macho`; `RELEASE=1 CHAINLOADING=1`, the pongoOS-`bootm` chainloader for the 4K devices) | `4014f9f7…` | `HoolockLinux/m1n1@bd117d71` | `evidence/builds/m1n1_1.5.0_git20260208_20260929.log` |
| kernel-4k | `artifacts/kernel-4k/Image` (bare, 4K pages) + `Image.initramfs` (4K module closure bundled) + 92 DTBs + modules | per-file in manifest | same kernel pin; `pmaports` 4K config lineage (`linux-postmarketos-apple-4k`) | `evidence/builds/kernel_4k_hoolock-7.0.12_20260929.log` |
| images-4k | `artifacts/images-4k/initramfs.cpio.gz`, `artifacts/images-4k/rootfs.img` (4K module closure) | per-file in manifest | same Alpine/busybox pins | `evidence/builds/images-4k_3.24.2_20260929.log` |

Full hashes and sizes: `artifacts/manifest.json`. Re-verify anytime with
`make verify`.

## HONESTY BOX — read this first

- **Builds, not boots.** Nothing in this repository has ever been booted on
  hardware — this project has no device. "Green" means the build pipeline
  and its evidence are clean, not that a phone ran them. First hardware
  session: `RESUME.md`; operator guide: `docs/bring-up.md`.
- All four original stages were rebuilt clean-room after blind review;
  determinism evidence in `artifacts/*/provenance.json` (kernel: `clean_room`
  + `determinism` keys — dtbs bit-identical across independent clean-room
  rebuilds, Image delta is the epoch-fixed `KBUILD_BUILD_TIMESTAMP` only;
  gaster/pongoos: `determinism`/`reproducibility` keys; m1n1: byte-identical
  across three consecutive full builds; images: the initramfs is
  byte-reproducible by pinned mtimes + `gzip -n`, the rootfs is not, by
  mke2fs design — `tooling/images/README.md`). Generated provenance is
  re-emitted by each stage's `build.sh` whenever shipped bytes change;
  pongoos additionally documents that cross-host (clang/LLVM major) rebuilds
  are byte-different — reproducibility is gated per-host.
- **A12 and newer are permanently unsupported.** iPhone XS/XR (2018) and
  everything after ship bootROMs without the checkm8 bug, and no public
  checkm8-equivalent exploit exists for them — checkm8 covers A5–A11 only
  (ipwndfu SoC list: `s5l8960x` … `t8015`, https://github.com/axi0mX/ipwndfu).
  This is not a TODO; pomme will not pretend otherwise.
- **macOS-free Linux build.** Even pongoOS — normally an Xcode build — is
  produced natively on Linux with checksum-pinned `ld64`/`cctools-strip`
  from the checkra1n Debian repo; no Apple SDK is used or needed
  (`tooling/pongoos/README.md`).
- **Both page-size flavors ship.** The 16K kernel serves A9–A11 SoCs
  (iPhone 7 primary); the 4K kernel + its own initramfs/rootfs closure
  serve A7/A8/A8X (`docs/compatibility-matrix.md`, page-size gate). The
  4K devices' chainloader (m1n1, chainloaded by pongoOS `bootm`) is built
  too — all still builds-not-boots.
- **Bundle dependency (both flavors):** `Image.initramfs` embeds one exact
  `initramfs.cpio.gz` (pinned in the flavor's `provenance.json`). After any
  images-stage change, re-run that flavor's kernel stage or the Image
  serves a stale initramfs (`tooling/kernel/README.md`, "Build and outputs").
  Modules are page-size-ABI-sensitive: never pair the 16K initramfs with
  the 4K kernel or vice versa.

## Quickstart

```
make gaster      # checkm8 exploit tool (Linux host binary)
make pongoos     # pongoOS bootloader (Pongo.bin)
make kernel      # Linux arm64 Image + 92 DTBs + modules, 16K pages (iPhone 7)
make images      # initramfs.cpio.gz + Alpine ext4 rootfs.img (16K closure)
make m1n1        # m1n1 chainloader (pongoOS bootm payload; 4K-device chain)
make kernel-4k   # 4K-page kernel flavor (A7/A8/A8X)
make images-4k   # 4K initramfs + rootfs (4K module closure)
make all-4k      # full 4K chain incl. the initramfs rebundle
make verify      # recompute every sha256 against artifacts/manifest.json
```

No device required for any of it. Builds are re-runnable from any state and
tee their logs into `evidence/builds/`.

## Provenance

Every shipped artifact traces to a pinned upstream commit
(`evidence/upstream-pins/<name>.json` records URL, SHA, date, role) or to a
committed build log from this pipeline (`evidence/builds/`), or both. Every
deviation from upstream lives in `patches/<stage>/` and is applied by
`tooling/<stage>/build.sh` — vendored clones are never edited. The rules are
in `docs/pipeline-conventions.md`; `make verify` enforces the manifest
end-to-end.

## Documentation

- `docs/bars.md` — the three reference bars compared (Sandcastle, palera1n,
  postmarketOS), stage by stage.
- `docs/compatibility-matrix.md` — per-device matrix, cited per cell
  (gaster / pongoOS / kernel DTS / pmOS status / pomme status).
- `docs/bring-up.md` — full bring-up guide for an operator holding an
  iPhone 7 (UNTESTED ON HARDWARE).
- `RESUME.md` — checklist sequencing the first hardware session.
- `docs/matrix-data.md` — raw per-device evidence behind the matrix.

## Standing on the shoulders of three projects

pomme's chain is postmarketOS's chain with the proprietary checkra1n runtime
replaced by gaster. Credited, with the exact pins pomme tracks:

| Bar | What pomme takes | Pin (`evidence/upstream-pins/`) |
|---|---|---|
| **Project Sandcastle** (Corellium, 2020, dormant) | kernel cross-reference, the `fdt`/`bootl` loader protocol (used verbatim in step 6 of bring-up), APFS-ro firmware-harvest idea | `corellium/projectsandcastle@03db9c6a`, `corellium/linux-sandcastle@0c2f7dda` |
| **palera1n** (2022–, active) | the pongoOS fork pomme builds, DFU orchestration patterns; A11 passcode caveat | `palera1n/pongoOS@e98323f8`, `palera1n/palera1n@3ba32c40` (its embedded checkra1n helper is proprietary and **not** used) |
| **postmarketOS apple-idevice** (2023–, testing) | kernel base, m1n1 packaging pattern, netboot initramfs design, the honest per-feature floor | `postmarketOS/pmaports@34a4e3c3`, `HoolockLinux/linux@dfa4d420`, `HoolockLinux/m1n1@bd117d71` |

## Licenses

pomme's own files (build glue, scripts, this pipeline) are **MIT**. Upstream
stages carry their own licenses, per the pin records:

- gaster — Apache-2.0 (`evidence/upstream-pins/gaster.json`)
- pongoOS — MIT, © 2019–2023 checkra1n team, with third-party sections in
  its LICENSE.md (Apache-2.0 Synopsys USB drivers; APSL 2.0 apple-include /
  libDER; libfdt / LZMA) (`evidence/upstream-pins/pongoos.json`)
- Linux (hoolock) — GPL-2.0 (`evidence/upstream-pins/linux-hoolock.json`)
- m1n1 (idevice fork) — MIT, © The Asahi Linux Contributors
  (`evidence/upstream-pins/m1n1-apple-idevice.json`)
- images — Alpine minirootfs / busybox under their published licenses,
  checksums pinned in `artifacts/images/provenance.json`
- Sandcastle loader (compiled at boot time, unmodified) — GPL-2.0
  (`evidence/upstream-pins/projectsandcastle.json`)

## Disclaimer

pomme is an independent open-source project and is **not affiliated with,
endorsed by, or connected to Apple Inc.** iPhone and iPad are trademarks of
Apple Inc., used here nominatively to refer to hardware compatibility.
