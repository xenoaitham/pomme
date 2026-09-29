# pomme bring-up guide — iPhone 7 (T8010) on a Linux host

> **UNTESTED ON HARDWARE — written for the first hardware session; `RESUME.md`
> sequences it.** Nothing in this repository has ever been executed against a
> real device (builds-not-boots rule, `docs/pipeline-conventions.md`). Every
> command below references scripts and binaries that exist in this repo; the
> *outcomes* are expectations from pinned source and prior-art documentation,
> not from pomme runs.

## What this chain is

```
iPhone 7 in DFU (05ac:1227)
  -- gaster pwn ------------------>  pwned DFU (still 05ac:1227)
  -- dfu-send Pongo.bin ---------->  pongoOS running (re-enumerates as 05ac:4141)
  -- load-linux <Image> <dtb> ---->  pongoOS `fdt` + `bootl` -> Linux kernel
```

Chain provenance: `tooling/boot/README.md`. The uploader protocol is Project
Sandcastle's `loader/load-linux.c`, compiled unmodified from the pinned clone
(`evidence/upstream-pins/projectsandcastle.json`, GPL-2.0); the pongoOS USB
PID 0x4141 is `upstream/pongoOS-palera1n src/drivers/usb/synopsys_otg.c:143`.

## 0. Prerequisites

- **Linux host.** The pipeline was built on Ubuntu 24.04 x86-64
  (`artifacts/*/provenance.json`, `build_host_os` / toolchain fields). Any
  distro with `libusb-1.0` headers works for the boot tools — the script
  checks `pkg-config --exists libusb-1.0` and dies otherwise
  (`scripts/boot-iphone7.sh:117`).
- **A data-capable USB-A/Lightning cable.** Charge-only cables enumerate
  nothing; `lsusb` will simply never show the device. (Generic hardware
  guidance — no repo evidence, but no repo tool can help you past it.)
- **Host USB permissions.** gaster and the helpers open the raw USB device.
  If you see `libusb_open failed: ...` with permission-denied semantics
  (`tooling/boot/src/dfu-send.c:63-67` handles and skips such devices), run
  the session under `sudo` or install a udev rule granting your user raw USB
  access to `05ac:*` devices. (Standard libusb practice, not repo-specific.)
- **All four stages built** (step 1 below). On-disk artifacts and their
  sha256s are pinned in `artifacts/manifest.json` (VERSION 0.1.0, generated
  2026-09-29).

### DFU button choreography — iPhone 7 / 7 Plus (no Home-button click)

Source: The iPhone Wiki, "DFU Mode"
(https://www.theiphonewiki.com/wiki/DFU_Mode, retrieved 2026-09-29 via the
web.archive.org 2024 snapshot — the live page returned HTTP 502 at retrieval):

1. Connect the device to the computer with the USB cable.
2. Hold down **both the Side (Sleep/Wake) button and Volume Down**.
3. **After 8 seconds, release the Side button while continuing to hold Volume
   Down.** The screen must stay black. If the Apple logo appears, the Side
   button was held too long — start over.

In DFU mode nothing is displayed on the phone screen; the host detects it
(the wiki notes iTunes' "recovery mode" alert as the classic detector — our
detector is `lsusb`, step 2).

> **Known erratum in the repo:** the informational die-message in
> `scripts/boot-iphone7.sh:133-135` says "hold Power+Home ~8s" — that is the
> pre-iPhone-7 choreography and is **wrong for the iPhone 7**, which has no
> physical Home-button click. Use the Side + Volume Down choreography above;
> the script's message is advisory text only and does not affect behavior.

### Force restart (recovery / exit)

Source: Apple Support, "If your iPhone won't turn on or is frozen"
(https://support.apple.com/en-us/HT201412, retrieved 2026-09-29 via the
web.archive.org 2023 snapshot): **press and hold both the side button and
the volume down button until the Apple logo appears** (~10 s). This exits
DFU/pongoOS states and reboots iOS normally.

## 1. Build everything

```
make all          # gaster -> pongoos -> kernel -> images (Makefile targets)
make verify       # recompute every sha256 in artifacts/manifest.json (scripts/verify.sh)
```

`make all` builds in dependency order and regenerates the manifest
(`Makefile`, `all: gaster pongoos kernel images` +
`scripts/manifest.sh`). `make verify` must print `RESULT: PASS`
(`scripts/verify.sh`). The images stage integrates the kernel's
`modules.tar.gz`, so `make images` must run *after* `make kernel`
(`tooling/images/README.md`, "Kernel modules coordination") — the `all`
order already guarantees this; if you built stages individually, re-run
`make images`.

Expected artifacts (sha256 short forms from `artifacts/manifest.json`):

| Stage | Artifact | sha256 (first 8) |
|---|---|---|
| gaster | `artifacts/gaster/gaster` | `6802003b` |
| pongoos | `artifacts/pongoos/Pongo.bin` | `22eec6e4` |
| kernel | `artifacts/kernel/Image` (16K pages) | `a04d2a3f` |
| kernel | `artifacts/kernel/dtbs/t8010-d10.dtb` / `t8010-d101.dtb` | `a5bf0426` / `bbec66db` |
| images | `artifacts/images/initramfs.cpio.gz`, `rootfs.img` | `7319fcb4` / `9df9bac9` |

## 2. Put the device in DFU mode

Follow the choreography above (Side + Volume Down, 8 s, release Side, keep
Volume Down, screen stays black) with the cable already plugged into the
host. Time it against a wall clock the first few times.

## 3. Verify DFU mode from the host

```
lsusb | grep -i 05ac:1227
```

Expected: a line containing `05ac:1227` (Apple DFU). This is the exact
VID/PID gaster waits on — the shipped gaster prints
`[libusb] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227`
(`evidence/builds/gaster_2095825+pomme1_20260929.log`, smoke test 2;
VID/PID source `gaster.c:31,38` per `tooling/gaster/SUPPORT.md`). The boot
script performs the same check (`scripts/boot-iphone7.sh:121-127`).

If nothing appears: the choreography failed (usually the Apple logo showed,
meaning you spent too long in step 2 of the choreography). Re-enter DFU.

## 4. Pwn with gaster

Guided (recommended for the first session):

```
scripts/boot-iphone7.sh --dry-run   # compiles tooling/boot/bin/{dfu-send,load-linux}, checks artifacts+device, issues no USB commands
scripts/boot-iphone7.sh             # full chain: pwn -> Pongo.bin -> kernel+dtb
```

Manual, step by step (exactly what the script runs):

```
USB_TIMEOUT=30 artifacts/gaster/gaster pwn
```

(`scripts/boot-iphone7.sh:183-184`; gaster's own default timeout is 5 s —
the script raises it to 30 via `POMME_USB_TIMEOUT`.)

- gaster's CLI verbs are exactly: `pwn`, `reset`, `decrypt src dst`,
  `decrypt_kbag kbag` — there is deliberately **no "load payload" verb**
  (`tooling/boot/README.md`, "Why dfu-send exists").
- **Success:** exploit progress output ending in `Now you can boot untrusted
  images.`, exit 0 (`scripts/boot-iphone7.sh:176-177`). The device is now in
  pwned DFU, still enumerated as `05ac:1227`.
- **Failure:** `Waiting for the USB handle ...` printing forever means the
  device is not in DFU; an SRTG/CPID refusal means the device is not
  checkm8-compatible — iPhone 7 is SRTG `iBoot-2696.0.0.1.33`, CPID 0x8010
  (`scripts/boot-iphone7.sh:178-181`; full table
  `tooling/gaster/SUPPORT.md`).

## 5. Load Pongo.bin (pongoOS)

```
tooling/boot/bin/dfu-send artifacts/pongoos/Pongo.bin --wait-pid 0x4141 --timeout 60
```

(Exact invocation of the script, `scripts/boot-iphone7.sh:201`. `dfu-send`
is pomme's minimal open replacement for the closed checkra1n loader — it
speaks standard USB DFU 1.1 download against `05ac:1227`,
`tooling/boot/src/dfu-send.c:1-30`.)

- **Success:** `N bytes sent in M DFU block(s)`, then within the timeout
  `05ac:4141 present — payload is running` (`dfu-send.c:201-226`).
- **Verify independently:** `lsusb | grep -i 05ac:4141` — pongoOS
  re-enumerates with `.idProduct = 0x4141`
  (`upstream/pongoOS-palera1n/src/drivers/usb/synopsys_otg.c:143`).
- **Console:** build pongoOS' USB terminal from the pinned fork (the clone
  is created by `make pongoos` at pin `e98323f8`):

  ```
  make -C upstream/pongoOS-palera1n/scripts    # Makefile target 'all: pongoterm' (scripts/Makefile:43-45)
  upstream/pongoOS-palera1n/scripts/pongoterm  # attaches to 05ac:4141
  ```

  Expect the pongoOS banner and a `pongo%`-style shell prompt once it is up.
  (Exact banner text UNKNOWN until first hardware run — record it.)
  **Do not use screen/minicom:** the console is a pongoOS USB interface, not
  a ttyACM device (`scripts/boot-iphone7.sh:234-236`).
- **Failure:** a DFU error status from the device, or timeout with no
  `05ac:4141` — pwned DFU was lost or the payload was rejected; re-enter DFU
  and start over from step 4 (`scripts/boot-iphone7.sh:198-202`).

## 6. Send DTB + kernel Image via the loader

```
tooling/boot/bin/load-linux artifacts/kernel/Image artifacts/kernel/dtbs/t8010-d10.dtb
```

- **Argument order is KERNEL first, DTB second** (`load-linux.c:26-28`,
  quoted at `scripts/boot-iphone7.sh:218`).
- **DTB selection:** iPhone 7 Qualcomm (A1660/A1661) = `t8010-d10.dtb`;
  iPhone 7 Intel (A1778/A1784) = `t8010-d101.dtb`
  (`scripts/boot-iphone7.sh:243-244`). If unsure, try d10 first, then the
  other with `POMME_DTB=...` (env override table,
  `scripts/boot-iphone7.sh:29-34`).
- What the loader does: finds pongoOS on `05ac:4141`, bulk-sends the DTB,
  then the kernel Image, and issues the pongoOS shell commands `fdt` and
  `bootl` (`tooling/boot/README.md`, citing `load-linux.c:8-9,140,188`).
- **Success:** the loader prints `Success!` after `fdt`/`bootl` execute;
  the kernel then takes the console (`scripts/boot-iphone7.sh:219-221`).

## 7. What the phone should show, and what the host should see

**Phone screen:** black throughout DFU/pwn; pongoOS output goes to USB, not
the display; after `bootl`, any output depends on the kernel's console
configuration — do not expect iPhone-screen Linux yet (pmOS reports screen
support only "partial" even on tested devices,
`docs/compatibility-matrix.md` iPhone 7 row).

**Host, while pongoOS owns USB:** device stays `05ac:4141`; the kernel
console rides the pongoOS USB serial interface — capture it with `pongoterm`
(`scripts/boot-iphone7.sh:229-237`).

**Host, after the kernel boots and the initramfs gadget comes up** (per
`tooling/images/README.md`, "What a user sees when it works"):

```
lsusb                      # Linux Foundation device, VID 1d6b PID 0104, NCM interface
sudo ip addr add 10.0.0.1/24 dev <usbnet-if>   # usb0 / enp0s20f0u1 / ...
sudo ip link set <usbnet-if> up
nc 10.0.0.2 23             # initramfs busybox shell (telnet 10.0.0.2 23 also works)
```

Device side is `10.0.0.2/24`, host side `10.0.0.1`; a shell also runs on
`/dev/ttyGS0` at 115200 8N1 if the ACM gadget function bound. The initramfs
`/init` builds the configfs gadget (`ncm.usb0` + `acm.ttyGS0`), brings up
usb0, and listens on port 23 via `nc -l -p 23 -e /bin/sh` (the pinned
busybox-static has no telnetd — `tooling/images/README.md`, "Why port 23").

> **HONEST GAP — first boot reaches the kernel, userspace handoff is
> unsolved.** `scripts/boot-iphone7.sh` sends **only DTB + Image**: the
> Sandcastle loader has no initramfs verb (`fdt`/`bootl` only,
> `tooling/boot/README.md`: "e.g. adding an initramfs path" is listed as a
> *future* loader change), and the kernel is built without a bundled
> initramfs. The USB-net shell above is what the *images stage* promises
> **if** its initramfs reaches the kernel — the mechanism for that is the
> first design decision the hardware session must make. Candidate paths,
> with prior art: (a) patch the loader to send a ramdisk (deviation goes in
> `patches/boot-loader/` per the pipeline convention), or (b) switch to the
> pmOS m1n1 chain — pongoOS `/send m1n1-linux.bin` then `bootm`
> (`docs/bars.md` bar 3, wiki-cited), for which the concatenated image is
> `m1n1 + DTBs + Image + initramfs`. Neither is built yet. Expect the first
> `bootl` to end in a kernel panic about a missing rootfs/initramfs — that
> is still a *successful kernel boot* for matrix purposes (console evidence,
> not a working system).

## 8. Troubleshooting

| Symptom | Likely cause | Next step |
|---|---|---|
| No `05ac:1227` in `lsusb` after choreography | Timing wrong; Apple logo appeared (Side held >8 s) | Retry DFU entry; screen must stay black (The iPhone Wiki, DFU Mode) |
| `lsusb` shows a device but not `05ac:1227` | Device is in recovery mode (connector+iTunes screen), not DFU | Force restart (Side + Vol-down to Apple logo, Apple HT201412), re-enter DFU |
| gaster prints `Waiting for the USB handle ...` forever | Device left DFU / never entered | Re-enter DFU; confirm `05ac:1227` first (`scripts/boot-iphone7.sh:178-179`) |
| gaster exits with SRTG/CPID refusal | Device not checkm8-class, or not an iPhone 7 | Check SRTG against `tooling/gaster/SUPPORT.md` (iPhone 7 = `iBoot-2696.0.0.1.33`, 0x8010) |
| `dfu-send`: device reported DFU error status | Payload rejected / DFU state lost mid-transfer | Re-enter DFU, re-run pwn, retry Pongo.bin (`scripts/boot-iphone7.sh:198-199`) |
| `dfu-send` timeout, no `05ac:4141` | Pongo.bin did not execute | Same as above; keep `pongoterm` attached to catch early output |
| `load-linux` cannot find pongoOS | Pongo step not completed this session | `lsusb` must show `05ac:4141` before this step (`scripts/boot-iphone7.sh:213-214`) |
| `load-linux` fails or console dies during `bootl` | Wrong DTB variant (Qualcomm vs Intel), or pongoOS crashed | Re-run with the other `t8010-*.dtb` via `POMME_DTB` (`scripts/boot-iphone7.sh:241-244`) |
| Kernel boots but no `1d6b:0104` gadget ever appears | Kernel lacks UDC/gadget driver for the Lightning port, or modules not integrated | Check `/sys/class/udc` capture; re-run `make images` after `make kernel` (`tooling/images/README.md` failure modes) |
| `nc 10.0.0.2 23` refused | Host USB-net interface not configured | `ip addr add 10.0.0.1/24` + `ip link set up` on the new interface (`tooling/images/README.md`) |
| Console reader shows nothing | Wrong reader — it is not a ttyACM device | Use `pongoterm`, not screen/minicom (`scripts/boot-iphone7.sh:234-236,245`) |
| Kernel panic after `bootl` (expected on first run) | No initramfs handoff — the honest gap in section 7 | Record the panic as console evidence; pick a handoff path (loader ramdisk patch or m1n1 chain) |

## 9. Recovery

- **Device won't boot / stuck black:** force restart — press and hold the
  **side button and volume down until the Apple logo appears**
  (https://support.apple.com/en-us/HT201412, retrieved via web.archive.org
  2023 snapshot). DFU/pongoOS/pwned states are RAM-resident bootROM/loader
  states; a force restart exits them and boots iOS (The iPhone Wiki,
  "DFU Mode", general reference). Nothing in this chain flashes storage.
- **iOS came back up fine but you want another try:** just re-enter DFU and
  repeat from step 2. `pwn` must be repeated after every DFU re-entry —
  pwned DFU does not survive re-entering plain DFU (chain diagram,
  `tooling/boot/README.md`; use `scripts/boot-iphone7.sh --skip-pwn` only
  when the device is *already* in pwned DFU from the same session,
  `scripts/boot-iphone7.sh:25-27`).
- **Host side wedged:** unplug, `lsusb` to confirm the device vanished,
  force restart on the phone, start from step 2.
