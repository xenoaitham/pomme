# pomme

pomme is a maintained, documented build pipeline that produces a complete
open-source Linux boot chain for checkm8-era iPhones and iPads (A7–A11),
targeting the iPhone 7 (Apple T8010) first. It assembles four stages from
pinned upstream commits with a fully Linux host toolchain — no macOS, no
Apple SDK — and records a build log and sha256 for everything it ships.

```
Linux host (x86-64)                                iPhone 7 in DFU (05ac:1227)
─────────────────────                              ───────────────────────────
  gaster  ────── checkm8 ────────►   pwned DFU      (still 05ac:1227)
  dfu-send Pongo.bin ────────────►   pongoOS        (re-enumerates 05ac:4141)
  load-linux Image + t8010-*.dtb ►   fdt + bootl →  Linux 7.0.12 (16K) + initramfs/rootfs
```

## Status

All four stages **build green** on Ubuntu 24.04 x86-64, with committed build
logs and sha256 manifests (VERSION `0.1.0`, manifest generated 2026-09-29,
repo commit `84ded9d9`):

| Stage | Artifact | sha256 | Upstream pin | Build log |
|---|---|---|---|---|
| gaster | `artifacts/gaster/gaster` | `6802003b…` | `palera1n/gaster@20958256` | `evidence/builds/gaster_2095825+pomme1_20260929.log` |
| pongoos | `artifacts/pongoos/Pongo.bin` (+ `Pongo.macho`, `checkra1n-kpf-pongo.macho`) | `22eec6e4…` | `palera1n/pongoOS@e98323f8` | `evidence/builds/pongoos_2.6.3-e98323f8_20260929.log` |
| kernel | `artifacts/kernel/Image` + 92 dtbs + `modules.tar.gz` | `a04d2a3f…` / `3ca2fb6a…` | `HoolockLinux/linux@dfa4d420` (tag `hoolock-7.0.12`, 16K-page config) | `evidence/builds/kernel_7.0.12-hoolock_20260929.log` |
| images | `artifacts/images/initramfs.cpio.gz`, `artifacts/images/rootfs.img` | `7319fcb4…` / `9df9bac9…` | Alpine 3.24.2 minirootfs + busybox-static 1.37.0 (checksum-pinned) | `evidence/builds/images_3.24.2_20260929.log` |

Full hashes and sizes: `artifacts/manifest.json`. Re-verify anytime with
`make verify`.

## HONESTY BOX — read this first

- **Builds, not boots.** Nothing in this repository has ever been booted on
  hardware — this project has no device. "Green" means the build pipeline
  and its evidence are clean, not that a phone ran them. First hardware
  session: `RESUME.md`; operator guide: `docs/bring-up.md`.
- **A12 and newer are permanently unsupported.** iPhone XS/XR (2018) and
  everything after ship bootROMs without the checkm8 bug, and no public
  checkm8-equivalent exploit exists for them — checkm8 covers A5–A11 only
  (ipwndfu SoC list: `s5l8960x` … `t8015`, https://github.com/axi0mX/ipwndfu).
  This is not a TODO; pomme will not pretend otherwise.
- **macOS-free Linux build.** Even pongoOS — normally an Xcode build — is
  produced natively on Linux with checksum-pinned `ld64`/`cctools-strip`
  from the checkra1n Debian repo; no Apple SDK is used or needed
  (`tooling/pongoos/README.md`).
- The shipped kernel is the **16K-page** build: it serves A9–A11 SoCs.
  A7/A8/A8X devices need the (unbuilt) 4K flavor —
  `docs/compatibility-matrix.md`, page-size gate.

## Quickstart

```
make gaster      # checkm8 exploit tool (Linux host binary)
make pongoos     # pongoOS bootloader (Pongo.bin)
make kernel      # Linux arm64 Image + 92 DTBs + modules (iPhone 7 target)
make images      # initramfs.cpio.gz + Alpine ext4 rootfs.img
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
- images — Alpine minirootfs / busybox under their published licenses,
  checksums pinned in `artifacts/images/provenance.json`
- Sandcastle loader (compiled at boot time, unmodified) — GPL-2.0
  (`evidence/upstream-pins/projectsandcastle.json`)

## Disclaimer

pomme is an independent open-source project and is **not affiliated with,
endorsed by, or connected to Apple Inc.** iPhone and iPad are trademarks of
Apple Inc., used here nominatively to refer to hardware compatibility.
