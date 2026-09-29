# RESUME — pomme first hardware session (iPhone 7 / T8010)

You are picking up a **builds-not-boots** project at the moment it first
touches hardware. Everything is built and evidenced; nothing has ever been
booted. This file sequences that first session. Work through the checklist
top to bottom; do not skip items.

Environment facts (as left by the previous session):

- Repo VERSION `0.1.0`; manifest generated 2026-09-29 from repo commit
  `84ded9d937b79650394d3383264944a760d6b93e` (`artifacts/manifest.json`).
- All four stages are built green, with committed logs and sha256 manifests:
  gaster `artifacts/gaster/gaster` (`6802003b…`), pongoOS
  `artifacts/pongoos/Pongo.bin` (`22eec6e4…`), kernel
  `artifacts/kernel/Image` + 92 dtbs + `modules.tar.gz` (`a04d2a3f…` / the
  dtbs are listed per-file in the manifest), images
  `artifacts/images/initramfs.cpio.gz` + `rootfs.img` (`7319fcb4…` /
  `9df9bac9…`). Full hashes: `artifacts/manifest.json`; per-stage
  provenance: `artifacts/*/provenance.json`.
- Build logs: `evidence/builds/<stage>_<version>_<date>.log`; local-CI
  transcripts: `evidence/ci-local_*.log`.
- New hardware-session evidence goes to **`evidence/boot-logs/`** (directory
  does not exist yet — create it).
- Honest state of the chain, including the initramfs-handoff gap you will
  hit: `docs/bring-up.md` section 7. Read it before touching the phone.

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
- [ ] Confirm the iPhone 7 pieces exist:
      `ls artifacts/kernel/dtbs/t8010-d10.dtb artifacts/kernel/dtbs/t8010-d101.dtb`.

## 3. Confirm device, cable, host

- [ ] Device is an iPhone 7 / 7 Plus, battery above ~30%, passcode state
      irrelevant for this chain (the A11 passcode caveat does not apply to
      A10; `docs/compatibility-matrix.md`).
      Record the modem variant if known: Qualcomm A1660/A1661 → `d10`,
      Intel A1778/A1784 → `d101` (`scripts/boot-iphone7.sh:243-244`).
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
- [ ] **4.6 Kernel.** `tooling/boot/bin/load-linux artifacts/kernel/Image
      artifacts/kernel/dtbs/t8010-d10.dtb` (kernel first, dtb second; swap
      to `t8010-d101.dtb` if d10 panics early).
      *Expected:* loader prints `Success!` after `fdt`/`bootl`; kernel log
      streams on the pongoOS USB console.
      *Record:* the entire kernel console capture (`pongoterm` output tee'd
      to a file). **A kernel boot log reaching the hoolock startup is the
      single most important artifact of this session.**
- [ ] **4.7 Userspace (expected to fail).** Watch for `1d6b:0104` in
      `lsusb`; if the gadget appears, configure the host per
      `docs/bring-up.md` section 7 (`10.0.0.1/24`, `nc 10.0.0.2 23`).
      *Expected:* per the initramfs-handoff gap, likely a kernel panic
      about rootfs/initramfs instead. **That panic is evidence, not
      failure** — the chain is proven up to the loader contract; the gap is
      a design task (loader ramdisk patch vs m1n1 chain,
      `docs/bring-up.md` section 7).
      *Record:* whatever appeared, plus `/sys/class/udc` state if the
      kernel got far enough.

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
│    └─ kernel log stops early -> capture the tail; compare against
│        docs/bars.md bar-1 expectations (Sandcastle needed earlycon over
│        the pongoOS console)
└─ 4.7  no gadget / panic at rootfs -> the known initramfs-handoff gap;
     stop, document, decide (bring-up §7)
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
