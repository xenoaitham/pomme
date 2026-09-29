# Reference bars: Sandcastle vs palera1n vs postmarketOS apple-idevice

pomme builds a Linux boot pipeline for checkm8-era iPhones (A7-A11), iPhone 7
(T8010) first. This document compares the three public bars we measure against,
verified from pinned upstream clones (see `evidence/upstream-pins/*.json`) and
primary external sources. Per the pipeline conventions this project is
**builds-not-boots**: nothing here has run on hardware; every claim below cites
pinned code (`upstream/<repo>@<sha>`) or a primary URL.

Terminology: the checkm8 bootROM exploit (axi0mX, September 2019) affects the
bootROM of A5-A11 SoCs and is "permanent unpatchable" because the bug lives in
mask ROM (source: https://github.com/axi0mX/ipwndfu README, "permanent
unpatchable bootrom exploit for hundreds of millions of iOS devices"; SoC list
in that README). Every bar below exploits a device in DFU with some
implementation of checkm8, then loads pongoOS, then boots something.

## Bar 1 — Project Sandcastle (Corellium, 2020, dormant)

**What it is.** Android 10 / Linux on the iPhone, announced March 2020.
Upstream: `corellium/projectsandcastle` @ `03db9c6ae04141eb940f3b9f56d446f50d57fadf`
(2020-03-06, last commit; the repo has been dormant since) and kernel
`corellium/linux-sandcastle` @ `0c2f7dda13d67bb7e06123df516f8bdb1000a79b`
(Linux 5.4.14, `upstream/linux-sandcastle/Makefile`: VERSION=5 PATCHLEVEL=4
SUBLEVEL=14).

**Maturity/maintenance.** Frozen in March 2020. The official site states
"Android for the iPhone is in beta and has only had limited testing"
(https://projectsandcastle.org/status, retrieved 2026-09-29). Its iOS-host
components bit-rot quickly (the pmOS port of it was archived — see bar 3).

**Boot chain.**
1. checkra1n (proprietary) runs checkm8 in DFU and loads pongoOS. Sandcastle's
   own docs never ship an exploit; the official downloads are hosted on
   `assets.checkra.in` (https://projectsandcastle.org/status).
2. `loader/load-linux.c` (upstream/projectsandcastle, pinned) is a host-side
   libusb tool that finds pongoOS on USB (Apple VID 0x05ac, pongoOS PID
   0x4141, lines 16-18), bulk-sends the DTB then the kernel Image, issuing the
   pongoOS shell commands `fdt\n` and `bootl\n` over the Apple DFU-style
   control endpoint (lines 8-9, 134-144, 159-188). The matching pongoOS-side
   commands are registered in `checkra1n/pongoOS` @ `4c9b7541…`
   `src/shell/linux.c:86-88` (`bootl` = "boots linux", `fdt`).
3. The Sandcastle kernel boots with the DTB shipped by pongoOS; DTS boards are
   D10, D101, D11, D111, N112 — iPhone 7 (2 RF variants), iPhone 7 Plus
   (2 RF variants), iPod touch 7 (`arch/arm64/boot/dts/hx/hx-h9p-*.dts`,
   `hardware-model` properties; `arch/arm64/boot/dts/hx/Makefile`).
4. Initramfs/rootfs comes from Corellium's buildroot fork
   (`corellium/sandcastle-buildroot`, branch `sandcastle` @
   `95af39e1b271f2b25f73b32555db92c83f916ca8`, 2020-03-07). The booted system
   mounts the **iOS APFS container read-only** via the **in-kernel APFS
   driver**: `sandcastle-overlay/etc/fstab` line 10 is
   `/dev/nvme0n1p1  /hostfs  apfs  ro,relatime  0  0`, and the driver is
   `fs/apfs/` in the pinned kernel, enabled by `CONFIG_APFS_FS=y`
   (`arch/arm64/configs/hx_h9p_defconfig:1505`). The iOS filesystem is then
   harvested for firmware (WiFi/BT/touch: `sandcastle-overlay/etc/network/wlan0-up`,
   `sandcastle-overlay/etc/hw/hx-touch.fwlist`).
   **Correction of a common claim:** Sandcastle does *not* use FUSE in the
   initramfs to reach the data partition; it uses the in-kernel APFS driver
   (read-only), which Corellium extended "by adding support for compressed
   files and concurrent mounting of subvolumes"
   (https://projectsandcastle.org/history). The Android payload itself is a
   synthetic NAND image assembled by `android/build-nand-1.1/filldisk.sh`
   (partitions SUPER/VBMETA/SDCARD at fixed offsets, `partmap.txt`), deployed
   by the closed checkra1n-hosted installer — that deployment step is not in
   any open repo.

**Devices.** iPhone 7, iPhone 7 Plus, iPod touch 7 — "Currently, these builds
are only supported for iPhone 7 / 7+ and the iPod touch 7"
(https://projectsandcastle.org/status). Matches the five pinned DTS boards.

**Kernel/storage/page size.** Linux 5.4.14 fork (out-of-tree, ~unmainlined
Apple platform code under `drivers/`+`arch/arm64/boot/dts/hx/`), NVMe storage
exposed as `nvme0n1`, APFS container read-only, Android partitions from the
synthetic NAND image, 16 kB pages enforced throughout (README.md "16kB page
size" linker guidance; `android/README`).

**License.** GPL-2.0 (`projectsandcastle/LICENSE`), kernel GPL-2.0. The
exploit/installer binary it relied on is proprietary.

**What pomme takes from Sandcastle (stage traceability).**
- kernel stage reference: the only complete prior T8010 Linux kernel
  (`linux-sandcastle` pin); its DTS/defconfig is the cross-check for our
  config choices.
- loader protocol: `fdt`/`bootl` over pongoOS USB is the minimal
  kernel-deployment contract any pomme initramfs must replicate.
- storage reality check: read-only APFS harvest for firmware is a viable
  pomme initramfs strategy; writing iOS APFS is not required.

## Bar 2 — palera1n (2022-, actively maintained)

**What it is.** A jailbreak for checkm8 devices on iOS/iPadOS/tvOS 15+ ("A8
through A11, T2 devices", README.md; full device table in README.md, pinned @
`3ba32c40dbd90b9bcff1a71b5f9ee26c3388b0ad`, 2026-07-27 — commits continue as
of July 2026). It boots patched iOS, not Linux — but its exploit+pongoOS
plumbing is the best-maintained public pipeline for getting arbitrary arm64
payloads onto these devices.

**Maturity/maintenance.** Active: pinned tip is 2026-07-27 with DFU guidance
fixes; the palera1n pongoOS fork (`palera1n/pongoOS` @
`e98323f8a09abd80fc4cbcd74dee023b91a1ec22`, 2026-07-19) is likewise current.

**Boot chain.**
1. The `palera1n` binary embeds **the closed-source checkra1n exploit
   binary** and `Pongo.bin`; it writes both to temp files and spawns
   `checkra1n <args> -k <Pongo.bin>` (`src/exec_checkra1n.c`, embedded-blob
   write at lines 51-67, `posix_spawn` with `-k` at lines 175-181).
   checkra1n performs checkm8 and loads pongoOS. **This piece is proprietary:
   pomme cannot and does not reuse it.** pomme's equivalent is gaster
   (Apache-2.0, `upstream/gaster` pin).
2. palera1n's `src/pongo_helper.c` then talks to pongoOS over USB: it uploads
   the KPF pongoOS module LZMA-compressed and issues `modload`
   (`src/pongo_helper.c:70-74`), uploads a ramdisk DMG (line 88) and binpack
   overlay (line 106) as needed.
3. The pongoOS used is the palera1n fork, whose module set builds from
   `checkra1n/kpf` in-repo (`pongoOS-palera1n/Makefile:44,134,142` builds
   `Pongo.bin` + `checkra1n-kpf-pongo`). Crucially for pomme, the fork
   registers `bootm` — "boots m1n1" (`src/shell/main.c:294`) — the hook
   postmarketOS uses to leave iOS-land and boot Linux (bar 3).

**Devices.** README device table: iPhone 6s through X (6s, 6s+, SE 2016, 7,
7+, 8, 8+, X), iPad mini 4, iPad 5/6/7, iPad Pro 9.7/12.9-1g/10.5/12.9-2g,
iPad Air 2, iPod touch 7, Apple TV HD/4K-1g, plus T2 Macs. Note A7 devices are
*not* in palera1n's support list, and the A11 caveat: "on `A11` (iPhone X, 8,
8 Plus), **you must disable your passcode while in the jailbroken state**"
(README.md).

**Kernel/storage.** None of its own — it patches the stock iOS kernel via the
KPF module and uses iOS storage (with a fake-rootfs APFS snapshot/overlay
strategy). Not a Linux-storage reference.

**License.** MIT (`palera1n/LICENSE`) for the CLI, its pongoOS fork MIT
(`pongoOS-palera1n/LICENSE.md`, checkra1n team 2019-2023, with third-party
sections: Apache-2.0 for Synopsys USB drivers `src/drivers/usb/synopsys`,
Apple Public Source License 2.0 for `apple-include` and `src/lib/libDER`,
plus libfdt/LZMA sections) — but the embedded checkra1n helper is closed.

**What pomme takes from palera1n (stage traceability).**
- pongoOS stage: `upstream/pongoOS-palera1n` is our pongoOS build input —
  maintained, module-capable, and it has the `bootm` m1n1 hook.
- DFU orchestration patterns (USB event handling, device mode detection) from
  `src/pongo_helper.c`/`src/dfuhelper.c`, reimplemented against gaster.
- Explicitly *not* taken: the closed exploit binary, KPF (iOS-jailbreak
  specific).

## Bar 3 — postmarketOS "Apple Generic iDevice" (2023-, testing)

**What it is.** The only distribution-level Linux port for checkm8-era
hardware. Current incarnation: `device/testing/device-apple-idevice` ("Apple
Generic iDevice") in `postmarketOS/pmaports` @
`34a4e3c3a38c88f52319ecce80f02b561d2eeee2` (2026-09-28 tip). The older
per-device ports — `device/archived/device-apple-iphone7` (Sandcastle
kernel 5.4.14, `_commit="0c2f7dda13d67bb7e06123df516f8bdb1000a79b"`,
config `config-apple-iphone7.aarch64` sha512 `a932d5a6…`,
`device/archived/linux-apple-iphone7/APKBUILD`), `device-apple-n61`
(iPhone 6), `device-apple-d22` (iPhone X) — are archived; the generic port
replaced them.

**Maturity/maintenance.** Kernel and port actively maintained (hoolock kernel
tag 2026-06-12; pmaports tip 2026-09-28), but the port is in `device/testing`,
has no pre-built images, and boots are tethered (every boot needs a host).

**Boot chain** (verified against pinned code + wiki instructions).
1. checkm8 via **palera1n as the exploit driver**, loading only pongoOS:
   `PALERA1N_BYPASS_PASSCODE_CHECK=1 palera1n -p -f -k Pongo.bin`
   (wiki: https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice),
   Booting section; wiki.postmarketos.org 301-redirects there).
2. pongoOS (palera1n fork, pinned) runs; the operator sends a concatenated
   `m1n1 + DTBs + vmlinuz + initramfs` image over USB with
   `pongoterm` (`/send m1n1-linux.bin` then `bootm` — same wiki page).
   `bootm` is the fork's m1n1 entrypoint (`pongoOS-palera1n/src/shell/main.c:294`).
3. **m1n1** (`HoolockLinux/m1n1` @ `bd117d710e1c88a2cba45d47a030334bf74f212e`,
   2026-02-08; packaged by `device/testing/m1n1-apple-idevice/APKBUILD`)
   does final bring-up and boots the Linux kernel + initramfs — the Asahi
   Linux bootloader pattern ported to idevices.
4. Kernel: `linux-postmarketos-apple-4k` / `-16k` = `HoolockLinux/linux` tag
   `hoolock-7.0.12` (`device/testing/linux-postmarketos-apple-4k/APKBUILD`:
   `pkgver=7.0.12`, source tarball `hoolock-$pkgver`), mainline-based with
   `CONFIG_ARCH_APPLE` (v7.0.12, commit `dfa4d42081312dd34ec33ee8d23174309f683188`).
   Page size per SoC generation: 4K for A7/A8/A8X, 16K for A9/A9X/A10/A10X/
   A11/T2 (wiki, Booting section step 1).

**Devices.** Wiki tested list (same URL): Apple TV HD, iBridge T2
(MBP15,1/15,2), iPad 6/7 Wi-Fi, iPad Air, iPad Air 2, iPad mini 4, iPhone 5s
(LTE), iPhone 6, iPhone 6s (S8003), iPhone 7, iPhone 8, iPhone X (Global) —
"Many other devices will most likely boot, but are untested." The pinned
hoolock kernel's DTS coverage is far wider: every A7-A11 device class
(`arch/arm64/boot/dts/apple/`, models from "iPhone 5s" through "iPhone X",
iPads mini 2 through Pro 2, iPod touch 6/7 — see `docs/matrix-data.md`).

**Rootfs/initramfs/storage.** Thin initramfs: `modules-initfs` contains only
`netboot` (`device/testing/device-apple-idevice/modules-initfs`). Per the
wiki: only A11 devices have working internal storage; "others do not and would
have to use netboot". Feature status (wiki, tested devices): works = USB
networking (telnet in initramfs, SSH booted); partial = flashing, internal
storage, battery, screen; broken = touchscreen, GPU, audio, camera, WiFi, BT,
NFC, FDE, OTG, sensors. The device-specific iPhone 7/7+ page
(https://wiki.nura.eco/wiki/Apple_iPhone_7/7%2B_(apple-d10)) reports more
working per-device: touchscreen, WiFi, Bluetooth, battery, and internal
storage "need apfs driver, apfs-linux-rw for rw support" — treat the generic
page as the conservative floor and the d10 page as best-case.

**License.** pmaports GPL-3.0 (repo LICENSE; APKBUILDs declare per-package
MIT/GPL-2.0-only), kernel GPL-2.0, m1n1 MIT (Asahi). Fully open chain — no
proprietary components in bar 3's own artifacts (the exploit comes from
palera1n/checkra1n at runtime, as in every bar).

**What pomme takes from postmarketOS (stage traceability).**
- kernel stage primary candidate: `linux-hoolock` pin (mainline-based,
  maintained, wide DTS coverage, kconfigcheck'd by pmOS).
- images stage: m1n1-chainload packaging (m1n1+dtbs+kernel+initramfs), the
  netboot initramfs hook pattern, and the honest per-feature matrix.
- pongoOS stage: confirms `pongoos-palera1n` + `bootm` as the handoff point.

## Summary table

| | Sandcastle | palera1n | pmOS apple-idevice |
|---|---|---|---|
| Pinned repo | `corellium/projectsandcastle` @ `03db9c6a` (2020-03-06) | `palera1n/palera1n` @ `3ba32c40` (2026-07-27) | `postmarketOS/pmaports` @ `34a4e3c3` (2026-09-28) |
| Kernel | `corellium/linux-sandcastle` @ `0c2f7dda` (5.4.14, out-of-tree) | none (patches iOS) | `HoolockLinux/linux` @ `dfa4d420` (7.0.12, mainline-based) |
| Exploit | checkra1n (closed, at runtime) | checkra1n binary embedded (closed) | borrows palera1n at runtime |
| Bootloader | pongoOS + `fdt`/`bootl` | pongoOS + kpf `modload` | pongoOS + `bootm` → m1n1 |
| Boots | Android 10 / Linux 5.4 | patched iOS 15+ | Linux 7.0.12 (Alpine/pmOS) |
| Storage | in-kernel APFS ro (`/hostfs`) + synthetic NAND image | iOS APFS w/ snapshot | netboot initramfs; internal storage A11 only |
| Devices | iPhone 7/7+, iPod 7 | A8-A11 + T2 (iOS 15+) | A7-A11 + T2 (tested subset; wide kernel DTS) |
| Maintenance | dormant since 2020-03 | active (2026-07) | active (2026-09), testing tier |
| Licenses | GPL-2.0 (+closed installer) | MIT (+closed embedded helper) | GPL-3.0 / GPL-2.0 / MIT, all open |
| pomme takes | kernel cross-reference, loader protocol, APFS-ro firmware harvest | pongoOS fork + `bootm`, DFU orchestration patterns | kernel base, m1n1 packaging, netboot initramfs |

## Where pomme sits

pomme's chain — gaster (open checkm8, Apache-2.0) → pongoOS-palera1n (MIT,
`bootm`) → hoolock kernel + own initramfs — is bar 3's chain with the
proprietary checkra1n runtime replaced by gaster, assembled from pinned
sources by `tooling/<stage>/build.sh`. Sandcastle remains the reference for
what a T8010 kernel needs to actually work. Nothing pomme ships has been
booted on hardware; the bars above are code-verified, not hardware-verified.
