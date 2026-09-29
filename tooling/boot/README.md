# boot stage (host tooling only — no build.sh, not a pipeline stage)

This directory holds the **hardware-session boot helpers**: two small host
binaries compiled on demand by `scripts/boot-iphone7.sh` (never built by
`make all`, never shipped as pipeline artifacts).

> **EXPERIMENTAL / UNTESTED ON HARDWARE.** Nothing in this directory — or in
> this repository — has ever been run against a real device. This is the
> builds-not-boots rule from `docs/pipeline-conventions.md`. The boot script
> prints the same warning on every run.

## What gets compiled here

| Binary | Source | Provenance |
|---|---|---|
| `bin/load-linux` | `upstream/projectsandcastle/loader/load-linux.c`, compiled **unmodified, straight from the pinned upstream clone** (no patches; `patches/boot-loader/` is intentionally empty) | `evidence/upstream-pins/projectsandcastle.json` — corellium/projectsandcastle @ `03db9c6ae04141eb940f3b9f56d446f50d57fadf` (2020-03-06, GPL-2.0). The loader is the pinned bar-1 kernel-deployment protocol: finds pongoOS on USB VID `0x05ac` PID `0x4141` (`load-linux.c:18`), bulk-sends DTB then kernel Image, issues pongoOS shell commands `fdt\n` and `bootl\n` (`load-linux.c:8-9,140,188`) |
| `bin/dfu-send` | `src/dfu-send.c` — written for pomme, not copied from upstream | pomme build glue. Standard USB DFU 1.1 download (DFU_DNLOAD `0x21/1` + DFU_GETSTATUS `0xa1/3`) against Apple bootROM DFU VID `0x05ac` PID `0x1227` — the same device/requests gaster itself drives (pinned gaster prints `Waiting for the USB handle with VID: 0x5AC, PID: 0x1227`) |

## Why dfu-send exists (the honest gap)

The pinned gaster CLI (`palera1n/gaster` @ `2095825`, see
`evidence/upstream-pins/gaster.json` and its `main()` in `gaster.c`) exposes
exactly these verbs: `pwn`, `reset`, `decrypt src dst`, `decrypt_kbag kbag`.
**There is no "load Pongo.bin" verb** — after `gaster pwn`, putting pongoOS
onto the device is a separate DFU download that upstream leaves to the caller
(gaster's own output: "Now you can boot untrusted images."). pomme does not
use the closed checkra1n binary that bar-1/bar-2 delegate this to, so
`dfu-send` is our minimal open replacement.

## Chain implemented by scripts/boot-iphone7.sh

```
DFU mode (05ac:1227)
  --gaster pwn-->      pwned DFU (still 05ac:1227)
  --dfu-send Pongo.bin-->  pongoOS running (re-enumerates as 05ac:4141,
                           upstream/pongoOS-palera1n
                           src/drivers/usb/synopsys_otg.c:143)
  --load-linux <Image> <dtb>-->  pongoOS `fdt` + `bootl` -> kernel boots
```

No patch to the Sandcastle loader was needed for the pomme chain: it already
sends exactly DTB + kernel, which is the pipeline's kernel-deployment
contract. If a future change ever requires touching the loader (e.g. adding
an initramfs path), the deviation goes in `patches/boot-loader/*.patch` per
the pipeline convention — the upstream clone itself is never edited.

Rebuild any time (idempotent, upstream untouched):

```
bash scripts/boot-iphone7.sh --dry-run    # checks state, compiles, no USB actions
```
