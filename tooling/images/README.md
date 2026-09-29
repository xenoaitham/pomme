# images stage — initramfs.cpio.gz + rootfs.img

Builds the userspace that runs on the phone after pongoOS boots the kernel:
a minimal bring-up initramfs and an Alpine-based ext4 rootfs. iPhone 7
(T8010 / A10) is the target. Everything here builds as an unprivileged user
on x86_64 Ubuntu 24.04 — no mounts, no sudo (the ext4 image is populated
with `mke2fs -d` under `fakeroot`).

**This is a builds-not-boots stage.** No artifact produced here has ever
been booted on hardware in this project. The smoke tests prove: the init
script parses, the archives are structurally valid, the ext4 image passes
`e2fsck -f`, and the image contents are correct by inspection. They do NOT
prove the images boot. A12 and newer devices are unsupported (no public
checkm8-class bootROM exploit) and out of scope everywhere in pomme.

## Security posture — read before use

**The initramfs serves an UNAUTHENTICATED ROOT shell on every channel it
can reach**: port 23 on the USB gadget network (`nc`/`telnet` to
10.0.0.2), `/dev/ttyGS0` serial, and a respawned root shell on
`/dev/console`. The rootfs additionally spawns a **passwordless root
getty on ttyGS0**. There is no login, no password, no lockout — anyone
who reaches any of these channels gets root, by design.

This is a deliberate bench bring-up posture: the device is expected to be
directly attached to **your** host while you debug it. **Never expose
these images to untrusted networks**, and harden (root password, ssh
keys, disabled getty) before any use beyond a bench. The same disclosure
is recorded in `artifacts/images/provenance.json` (`security_posture`)
and inside the rootfs at `/ROOTFS.txt`.

## What `build.sh` produces

| artifact | what it is | size |
|---|---|---|
| `artifacts/images/initramfs.cpio.gz` | newc cpio + gzip: busybox-static (aarch64, static-PIE), applet symlinks, `/init`, netboot module closure when the kernel stage has landed | ~0.7 MB |
| `artifacts/images/rootfs.img` | ext4, 256 MB (grows automatically if the modules tree needs it), Alpine 3.24.2 minirootfs aarch64 + pomme overlays | 256 MB |
| `artifacts/images/provenance.json` | URLs, sha256s, kernel release, initramfs listing, tool versions | — |

## Pinned upstream sources

Both pins use **immutable versioned URLs** (`…/alpine/v3.24/…`), never
`latest-stable` (that path is a moving target). The pins were resolved on
2026-09-29 while latest-stable pointed at 3.24.2, then fixed to the
versioned path; the bytes at both paths are identical (sha256-verified at
every build). The minirootfs additionally cross-checks the published
`.sha256` sidecar (also fetched from the immutable path) at build time.
Exact URLs + sha256 live in `provenance.json` and are baked into
`build.sh` as constants. Downloads land in `upstream/_downloads/`
(gitignored); bumping a pin means editing the constants and rebuilding.

1. **Alpine minirootfs aarch64** `alpine-minirootfs-3.24.2-aarch64.tar.gz`
   (release 2026-09-17), sha256
   `9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773`
   — `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz`
2. **busybox-static aarch64** `busybox-static-1.37.0-r31.apk` from the
   same versioned repo path
   (`…/alpine/v3.24/main/aarch64/busybox-static-1.37.0-r31.apk`), sha256
   `965777e06b94bf11981d5f4ecdfcd577879f4b0dda544294d1dd3f72b217bc75`;
   `bin/busybox.static` is extracted from the apk (a gzipped tar).

## Why the initramfs looks the way it does

pmOS's `device/testing/device-apple-idevice` carries a single keyword —
`netboot` — in its `modules-initfs`, and the wiki evidence collected in
`docs/bars.md` is blunt: only A11 devices have working internal storage,
"others do not and would have to use netboot". The iPhone 7 (A10) is in
that netboot-first class, so bring-up is USB-first, exactly mirroring
pmOS's `postmarketos-mkinitfs-hook-netboot` (which calls
`setup_usb_network` and `modprobe nbd`):

1. mount proc/sys/dev (devtmpfs with a tmpfs+mknod fallback), `mdev -s`
2. load the netboot module set if the kernel stage's `modules.tar.gz` was
   integrated: `configfs libcomposite usb_f_ncm usb_f_fs usb_f_acm nbd`
   (missing modules are logged, never fatal)
3. build a composite configfs gadget — `ncm.usb0` (usb0 network) +
   `acm.ttyGS0` (serial) — and bind the first UDC found
4. bring up usb0 as **10.0.0.2/24** (host side: **10.0.0.1**) and start a
   shell listener on port 23
5. shell on `/dev/ttyGS0`, and a PID1-respawned shell on `/dev/console`

Every step is failure-tolerant by design: a missing module or function
costs one log line, never the boot.

### Why port 23 is served by nc, not busybox telnetd

The pinned busybox-static 1.37.0-r31 has **no telnetd applet** (Alpine
keeps telnetd/telnet/httpd in `busybox-extras`; there is no
`busybox-extras-static` package — verified against the mirror index, see
the applet-table check in the build log). `/init` therefore tries
`telnetd` first (future-proof) and falls back to a respawned
`nc -l -p 23 -e /bin/sh`. From the host, `nc 10.0.0.2 23` gives a clean
shell; `telnet 10.0.0.2 23` also works (a few negotiation bytes hit the
shell's stdin at connect — harmless).

### What a user sees when it works

Phone plugged into the host after the boot chain runs:

- `lsusb` on the host shows a Linux Foundation device
  (VID 1d6b, PID 0104) with an NCM network interface.
- Host side (interface name varies: `usb0`/`enp0s20f0u1`/…):

  ```
  sudo ip addr add 10.0.0.1/24 dev <usbnet-if>
  sudo ip link set <usbnet-if> up
  nc 10.0.0.2 23        # or: telnet 10.0.0.2 23
  ```

  …which lands in the initramfs busybox shell, greeting you with the
  bring-up motd (`/etc/motd` documents the on-device introspection
  paths: loaded modules, gadget state).
- Console (pongoOS/kernel serial or the kmsg the loader exposes) shows the
  `init:` progress lines and then a login-less shell loop.
- If the acm gadget bound, `/dev/ttyGS0` at 115200 8N1 also carries a
  shell.

When it does not work, the honest failure modes are: no UDC bound (kernel
lacks the gadget/UDC driver for the Lightning port — check the kernel
stage's config), modules absent (kernel stage not yet integrated — rerun
`make images` after `make kernel`), or the console shows nothing at all
(loader problem, not an images problem).

## Rootfs details

- Alpine 3.24.2 minirootfs; its own dynamic busybox + musl are fine here
  (unlike the initramfs, which needs the static one).
- `/etc/network/interfaces`: usb0 static 10.0.0.2/24 (host 10.0.0.1).
- `/etc/inittab`: getty on ttyGS0 at 115200; ttyGS0 added to securetty.
- `/ROOTFS.txt`: full provenance (sources, sha256, kernel release) baked
  into the image itself.
- `/lib/modules/<kver>` from `artifacts/kernel/modules.tar.gz` when
  present (full tree, `depmod`-ed). The kernel Image itself is NOT in the
  rootfs — it arrives via the pongoOS/m1n1 boot chain.
- No sshd/telnetd preinstalled: remote access after boot needs
  `apk add openssh` or `busybox-extras` (network required), or the
  ttyGS0 getty.

## Kernel modules coordination

`build.sh` checks the flavor-matched kernel modules tarball on every run —
`artifacts/kernel/modules.tar.gz` for the default 16K flavor,
`artifacts/kernel-4k/modules.tar.gz` when `POMME_KERNEL_FLAVOR=4k` (output
goes to `artifacts/images-4k/`; canonical log `images-4k_<version>_<date>.log`).
Modules are page-size-ABI-sensitive, so the 4K flavor never integrates the
16K closure or vice versa:

- **present**: the kernel release string is read from the tree, the full
  tree goes into the rootfs, and the initramfs gets only the netboot
  closure (requested modules + transitive `modules.dep` deps). Modules
  that are `=y` in the kernel are detected via `modules.builtin` and
  reported as builtin; modules absent from the kernel build are logged as
  missing — noted, never fatal.
- **absent** (kernel stage still building in parallel): a loud warning is
  printed and the build proceeds without modules; provenance records
  `"integrated": false`. The orchestrator re-runs `make images` after
  `make kernel` lands.

## Reproducibility

- `initramfs.cpio.gz` is **byte-reproducible**: staging mtimes are pinned
  to a fixed epoch, cpio runs with `--reproducible` (inode numbers are
  renumbered — without this the archive drifted whenever the host's inode
  allocation shifted between runs), and gzip runs with `-n` (no header
  timestamp). The build repacks and demands a sha256 match; provenance
  pins the hash.
- `rootfs.img` is **not** byte-reproducible: mke2fs randomizes the
  filesystem UUID and superblock timestamps per run. `e2fsck -f` proves
  structural integrity and provenance pins the sha256 of the exact image
  shipped.

## Smoke tests (all no-device)

`sh -n` on `/init` under both host `/bin/sh` and host busybox ash; applet
table verification of the pinned busybox binary; `gzip -t`; `cpio -t`
count + top-level listing; `file(1)` class checks on both artifacts;
`e2fsck -f` exit 0 on rootfs.img; root-ownership verification inside the
ext4 image (proves the fakeroot trick) via debugfs; presence checks for
`/ROOTFS.txt` and the usb0 config inside the image; qemu-user execution of
the busybox binary when available (skipped with a logged note when not).

## Known limitations

- Nothing here has booted. Kernel command line, DTB selection, and the
  m1n1 chainload packaging are the kernel/pongoOS stages' problem; this
  stage only guarantees the images are valid and self-describing.
- The gadget assumes one UDC (`/sys/class/udc` first entry). The iPhone 7
  Lightning controller must appear there for any USB gadget to work —
  that is a kernel-stage property, not verifiable here.
- Module compression: if the kernel stage ships `.ko.zst`/`.ko.xz`, the
  kernel must support in-kernel module decompression (CONFIG_MODULE_*_DECOMPRESS)
  for busybox modprobe to load them from the initramfs; modules.builtin
  detection and the closure copy are agnostic to compression.
- rootfs has no root password set (empty lockout semantics of Alpine
  minirootfs default); before this image is ever used beyond a bench,
  that must change.
