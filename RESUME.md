# RESUME — pomme first hardware session (iPhone 7 / T8010)

You are picking up a **builds-not-boots** project at the moment it first
touches hardware. Everything is built and evidenced; nothing has ever been
booted. This file sequences that first session. Work through the checklist
top to bottom; do not skip items.

Environment facts (as left by the previous session):

- Repo VERSION `0.1.0`; manifest regenerated 2026-09-29T20:03:56Z (authoritative copy: artifacts/manifest.json)
  (authoritative copy: `artifacts/manifest.json`, which also records the
  `repo_commit` it was generated at).
- All four stages are built green, with committed logs and sha256 manifests:
  gaster `artifacts/gaster/gaster` (`6802003b…`), pongoOS
  `artifacts/pongoos/Pongo.bin` (`22eec6e4…`), kernel **two images** — bare
  `artifacts/kernel/Image` (`57ef480e…`) and `artifacts/kernel/Image.initramfs`
  (`473660c0…`, the images-stage initramfs embedded via
  `CONFIG_INITRAMFS_SOURCE`, see `tooling/kernel/README.md`) — plus 92 dtbs
  and `modules.tar.gz` (`fb480afd…`), and images
  `artifacts/images/initramfs.cpio.gz` (`39f349e9…`, the archive bundled
  into `Image.initramfs`) + `rootfs.img` (`66a2e301…`). Full hashes and
  sizes: `artifacts/manifest.json`; per-stage provenance:
  `artifacts/*/provenance.json` (kernel provenance additionally pins the
  bundled initramfs sha it was built from).
- Build logs: `evidence/builds/<stage>_<version>_<date>.log`; local-CI
  transcripts: `evidence/ci-local_*.log`.
- New hardware-session evidence goes to **`evidence/boot-logs/`** (directory
  does not exist yet — create it).
- Chain state, including the bundle-pinning dependency you must respect:
  `docs/bring-up.md` sections 1 and 7. Read it before touching the phone.

---

## 1. Read first

- [ ] `docs/bring-up.md` — the whole guide; it has the exact commands,
      expected observations, and the two cited button choreographies.
- [ ] `docs/compatibility-matrix.md` — so you know what a successful boot
      is allowed to claim (the iPhone 7 row, pomme column).
- [ ] `docs/pipeline-conventions.md` — the honesty rules you must not break.

## 2. Rebuild locally and verify

- [ ] `make all` (order-critical: images after kernel, the Makefile handles
      this; re-run `make images` alone if you ever build stages individually
      — `tooling/images/README.md`).
- [ ] `make verify` — must end `RESULT: PASS` (`scripts/verify.sh`
      recomputes every sha256; never proceed on FAIL).
- [ ] **Both kernel Images exist and are in the manifest:** the manifest
      (`artifacts/manifest.json`) must list `artifacts/kernel/Image`
      (`57ef480e…`) *and* `artifacts/kernel/Image.initramfs`
      (`473660c0…`); on disk:
      `ls artifacts/kernel/Image artifacts/kernel/Image.initramfs`.
- [ ] **4K flavor + m1n1 also in the manifest** (added 2026-09-29 release
      build): `artifacts/kernel-4k/` (Image, Image.initramfs, dtbs, modules
      — the A7/A8/A8X flavor), `artifacts/images-4k/`, and
      `artifacts/m1n1/m1n1.bin`. They are not needed for the iPhone 7
      session itself; their absence means the flavor stages were cleaned.
- [ ] **Bundle freshness (both flavors):** the initramfs sha bundled into
      each `Image.initramfs` (`artifacts/kernel[-4k]/provenance.json`,
      `initramfs_image.source_archive_sha256`) must equal the current
      `artifacts/images[-4k]/initramfs.cpio.gz` sha in
      `artifacts/manifest.json`. If they differ, the bundle is stale —
      re-run that flavor's kernel stage before the session
      (`tooling/kernel/README.md`, "Build and outputs").
- [ ] Confirm the iPhone 7 pieces exist:
      `ls artifacts/kernel/dtbs/t8010-d10.dtb artifacts/kernel/dtbs/t8010-d101.dtb`.

## 3. Confirm device, cable, host

- [ ] Device is an iPhone 7 / 7 Plus, battery above ~30%, passcode state
      irrelevant for this chain (the A11 passcode caveat does not apply to
      A10; `docs/compatibility-matrix.md`).
      Record the modem variant if known: Qualcomm A1660/A1661 → `d10`,
      Intel A1778/A1784 → `d101` (`scripts/boot-iphone7.sh:250-251`).
- [ ] Data-capable Lightning cable, direct into the Linux host (no hub).
- [ ] Host: `lsusb` and `pkg-config --exists libusb-1.0` both work
      (`scripts/boot-iphone7.sh:114-117` checks these).
- [ ] `mkdir -p evidence/boot-logs` and open a session transcript:
      `scripts/boot-iphone7.sh ... 2>&1 | tee evidence/boot-logs/session_$(date +%Y%m%d_%H%M%S).log`.

## 4. The sequence — expected observations + what to record

Do these one at a time. After every step, write down what actually happened
before moving on. Record console captures as files under
`evidence/boot-logs/` and take photos of any phone-screen state that
differs from "black".

- [ ] **4.1 DFU mode.** iPhone 7 choreography (The iPhone Wiki, DFU Mode —
      cited in `docs/bring-up.md`): cable connected; hold **Side + Volume
      Down**; after **8 s** release **Side**, keep **Volume Down**; screen
      stays black (Apple logo = retry).
      *Expected:* black screen.
      *Record:* which phone model/modem, photo if anything showed.
- [ ] **4.2 Host sees DFU.** `lsusb | grep -i 05ac:1227`.
      *Expected:* one line with `05ac:1227`.
      *Record:* the lsusb line.
- [ ] **4.3 Pwn.** `scripts/boot-iphone7.sh --dry-run` first (compiles
      `tooling/boot/bin/{dfu-send,load-linux}`, checks artifacts, no USB
      actions), then `scripts/boot-iphone7.sh` — or manually:
      `USB_TIMEOUT=30 artifacts/gaster/gaster pwn`.
      *Expected:* progress output ending `Now you can boot untrusted
      images.`, exit 0; device still `05ac:1227`.
      *Record:* full gaster output (tee'd file).
- [ ] **4.4 Pongo.bin.** `tooling/boot/bin/dfu-send
      artifacts/pongoos/Pongo.bin --wait-pid 0x4141 --timeout 60`.
      *Expected:* blocks sent, then `05ac:4141 present — payload is
      running`; `lsusb` confirms.
      *Record:* dfu-send output + the lsusb line.
- [ ] **4.5 pongoOS console.** `make -C upstream/pongoOS-palera1n/scripts`
      then run `upstream/pongoOS-palera1n/scripts/pongoterm`.
      *Expected:* pongoOS banner + shell prompt (banner text UNKNOWN until
      now — capture it verbatim).
      *Record:* full console capture; this is the first on-device evidence
      the project will ever have.
- [ ] **4.6 Kernel (initramfs-bundled).** `scripts/boot-iphone7.sh`
      auto-prefers `artifacts/kernel/Image.initramfs` (it prints
      `using initramfs-bundled Image` — `scripts/boot-iphone7.sh:91-103`);
      manual equivalent:
      `tooling/boot/bin/load-linux artifacts/kernel/Image.initramfs artifacts/kernel/dtbs/t8010-d10.dtb`
      (kernel first, dtb second; swap to `t8010-d101.dtb` if d10 panics
      early).
      *Expected:* loader prints `Success!` after `fdt`/`bootl`; kernel log
      streams on the pongoOS USB console, then the kernel unpacks the
      bundled initramfs and `/init` starts bring-up.
      *Record:* the entire console capture (`pongoterm` output tee'd to a
      file). **A kernel boot log reaching the hoolock startup and the
      initramfs `init:` lines is the single most important artifact of this
      session.**
- [ ] **4.7 Userspace (expected to work).** `/init` loads the netboot
      module closure, builds the configfs gadget (`ncm.usb0` +
      `acm.ttyGS0`), brings up usb0 as 10.0.0.2/24, and listens on port 23
      (`tooling/images/README.md`). On the host:
      `lsusb` should gain a `1d6b:0104` Linux Foundation entry with an NCM
      interface; then
      `sudo ip addr add 10.0.0.1/24 dev <usbnet-if>`,
      `sudo ip link set <usbnet-if> up`,
      `nc 10.0.0.2 23` (or `telnet 10.0.0.2 23`) → initramfs busybox
      shell; `/dev/ttyGS0` at 115200 8N1 carries a shell too if ACM bound.
      *Expected:* a shell prompt from the bundled initramfs.
      *Record:* the lsusb line, the host interface config, and the shell
      transcript — this is first on-device userspace evidence.
      *If USB net does not come up:* see triage below; capture the
      diagnostics over the `/dev/ttyGS0` or `/dev/console` shell.

## 5. First-failure triage decision tree

```
Which step first showed an anomaly?
├─ 4.1/4.2  no DFU in lsusb
│    ├─ Apple logo appeared during choreography -> timing; retry (bring-up §2)
│    └─ recovery screen (connector icon) instead -> force restart, retry
├─ 4.3  gaster
│    ├─ "Waiting for the USB handle..." forever -> not in DFU; back to 4.1
│    ├─ SRTG/CPID refusal -> verify device identity vs
│    │   tooling/gaster/SUPPORT.md (expect iBoot-2696.0.0.1.33 / 0x8010)
│    └─ USB errors mid-exploit -> cable/hub; try another port, rerun 4.1
├─ 4.4  dfu-send
│    ├─ DFU error status -> DFU state lost; 4.1 -> 4.3 again
│    └─ timeout, no 05ac:4141 -> payload rejected; retry once, then
│        compare Pongo.bin sha256 vs artifacts/manifest.json
├─ 4.5  no console output -> wrong reader (use pongoterm, not minicom)
├─ 4.6  load-linux
│    ├─ fails to find pongoOS -> 05ac:4141 gone; pongoOS crashed; 4.1 over
│    ├─ console dies at bootl -> try the other t8010 dtb (POMME_DTB)
│    └─ kernel log stops before initramfs init: lines -> capture the tail;
│        compare against docs/bars.md bar-1 expectations (earlycon over the
│        pongoOS console)
└─ 4.7  kernel reached the initramfs but USB net does not come up
     (no 1d6b:0104, no NCM host interface, nc refused):
     get onto the phone shell any way you can — /dev/ttyGS0 at 115200 8N1
     (ACM builtin) or the /dev/console PID1 shell — then capture, each to
     its own file under evidence/boot-logs/:
       ip link                            # did usb0 get created/configured?
       ls /sys/class/udc                  # any UDC for the gadget to bind?
       dmesg | grep -i -E 'udc|configfs|ncm'
     then match against tooling/images/README.md failure modes:
       no UDC listed  -> kernel lacks the Lightning-port UDC driver (kernel
                         stage problem)
       UDC present, no usb0 -> module closure problem; check whether
                         Image.initramfs is stale (bundle-sha check in
                         step 2) and re-run make images + make kernel
       usb0 up, host sees nothing -> host-side ip config or cable
```

## 6. Update the repo afterwards

- [ ] Commit every raw capture to `evidence/boot-logs/` (console files,
      lsusb outputs, photos of anomalies). Follow the provenance rule:
      evidence lands in the repo or the claim does not exist
      (`docs/pipeline-conventions.md`).
- [ ] `docs/compatibility-matrix.md`, iPhone 7 row, "pomme boot-chain
      status": replace "UNTESTED ON HARDWARE" with exactly what was proven
      (e.g. "pongoOS boots (console evidence: evidence/boot-logs/…); kernel
      boots to <point>; userspace handoff open"), citing the log file.
- [ ] Resolve matrix UNKNOWNs the session actually resolved (candidates:
      internal storage on A10, UDC presence, pongoOS banner text, d10-vs-d101
      behavior) — each with its evidence path.
- [ ] Update `docs/bring-up.md` where expectations were wrong (it is marked
      as a first-session document; correct it against what happened).
- [ ] If any stage's *output* changed, bump `VERSION` per
      `docs/pipeline-conventions.md`; re-run `make verify`.

## 7. Do NOT

- **Do not claim a boot success without console evidence.** "It seemed to
  work" is not a matrix cell. Screenshots of panics are fine; vibes are not.
- **Do not touch A12 or newer devices.** No public checkm8-equivalent
  bootROM exploit exists; they are permanently out of scope
  (`docs/pipeline-conventions.md`, `tooling/gaster/SUPPORT.md` — no A12+ CPID
  in the SRTG table). Do not "just try it".
- Do not edit files under `upstream/` — deviations go in `patches/` and are
  applied by `tooling/<stage>/build.sh` (pipeline directory contract).
- Do not skip `make verify` after rebuilding; do not hand-edit
  `artifacts/manifest.json` (regenerate with `scripts/manifest.sh`).
- Do not put the device on a network or sync it with a desktop tool mid-DFU
  experiments; the session only needs `lsusb`, gaster, and the boot helpers.
