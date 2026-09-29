# tooling/ux — `scripts/pomme`, the guided host UX

> **UNTESTED ON HARDWARE — build-verified only.** Nothing in this repository
> has ever touched a device (builds-not-boots rule,
> `docs/pipeline-conventions.md`). `scripts/pomme` has been verified with
> `bash -n`, a static sanity pass, fault injection, and repeated `--dry-run`
> runs with zero devices attached (`evidence/builds/ux_selftest_20260929.log`).
> Every hardware behavior it predicts is expectation, not experience.
>
> **A12 and newer are PERMANENTLY unsupported.** No public
> checkm8-equivalent bootROM exploit exists for A12+. The tool refuses such
> devices when it can see a CPID. That is a fact of the platform, not a
> TODO — the pipeline honesty rule says so in exactly those words, and
> upstream palera1n says the same: it "doesn't and never will work on A12+
> (arm64e)" (`upstream/palera1n/src/dfuhelper.c:73`).

## What this is

`scripts/pomme` is the one-command operator entry point for the iPhone 7
boot chain. It is a **bash UX wrapper around `scripts/boot-iphone7.sh`** —
it never re-implements the chain. What it adds is the layer that script
deliberately does not have:

1. device-state detection (read-only, `lsusb` + `/sys/bus/usb`),
2. per-state coaching (DFU button choreography with a live countdown,
   recovery-mode triage), and
3. the post-boot host-net coach (find the new USB-net interface, print —
   and on explicit consent run — the host side of the netboot).

## Why it wraps `scripts/boot-iphone7.sh` instead of forking it

The chain — `gaster pwn` -> `dfu-send Pongo.bin` -> `load-linux Image dtb` —
already exists as one script with pinned sources, per-step device gates,
and "success/failure looks like" coaching in every step's output. Duplicating
any of that would create two sources of truth for the most dangerous part of
the session. So `pomme`:

- **subprocesses** `scripts/boot-iphone7.sh` and streams its output
  unfiltered (the operator is meant to read every line — the same contract
  the chain script's banner demands),
- passes flags through (`--skip-pwn`) and artifacts via the documented env
  overrides (`POMME_KERNEL_IMAGE`, `POMME_DTB`, `POMME_USB_TIMEOUT`, ...),
- and limits itself to state detection, coaching, and net setup around it.

`pomme` does add its own **preflight** (tools + artifacts, including
`--kernel` / `--dtb` path validation) so that bad inputs fail loudly, with a
`pomme`-branded error and exit code 4, *before* the chain is even started —
let alone before any USB action (verified by fault injection in the evidence
log).

## State machine

Detection is read-only. States, in detection priority order:

```
                       lsusb sees
  ┌──────────────────────────────────────────────┐
  │ 1d6b:0104 (Linux NCM gadget)                 │ -> gadget
  │ 05ac:4141 (pongoOS)                          │ -> pongo
  │ 05ac:1227 (Apple DFU — plain OR pwned;       │ -> dfu
  │   lsusb cannot distinguish them)             │
  │ 05ac:1281 (Apple recovery)                   │ -> recovery
  │ 05ac:12a8 (iPhone running iOS)               │ -> normal
  │ nothing                                      │ -> none
  └──────────────────────────────────────────────┘

  none/normal ── coach DFU choreography ──────────┐
  recovery ── coach force-restart, then DFU ──────┤
  dfu ── run chain (boot-iphone7.sh) ─────────────┼──> host-net coach
  pongo ── run chain (script skips pwn+pongo) ────┘    (diff `ip -o link`,
  gadget ── chain already done; net coach only          print/offer commands,
                                                        exit)
```

Transitions are the device's, not the tool's: the tool re-detects after each
coaching step and never assumes. The VID/PID values come from
`docs/bring-up.md` (DFU `05ac:1227`, pongoOS `05ac:4141` —
`upstream/pongoOS-palera1n src/drivers/usb/synopsys_otg.c:143` — recovery
`05ac:1281`) and from the chain's success state (`1d6b:0104` Linux
multifunction gadget with the NCM interface, `docs/bring-up.md` §7).

**Honest limitation:** plain DFU and pwned DFU enumerate identically
(`05ac:1227`); `lsusb` cannot tell them apart. That is why `--skip-pwn` is a
pass-through with a warning ("only valid if the device is ALREADY in pwned
DFU from this session" — `scripts/boot-iphone7.sh:25-27`,
`tooling/boot/README.md` chain diagram), never a tool-level guess.

**A12+ refusal (best-effort):** recovery/DFU devices expose an iSerial of
the form `CPID:8010 SRTG:[...]`; the tool scans `/sys/bus/usb/devices/*/serial`
and refuses (exit 3, "permanently unsupported, not a TODO") on any A12+-era
CPID or anything above the checkm8 era (CPID > 8015). Non-8010 checkm8-era
CPIDs get a warning: pomme builds for T8010 only, and gaster's own SRTG/CPID
gate (`tooling/gaster/SUPPORT.md`) is the authoritative hard gate. Normal-mode
devices do not expose a CPID over plain USB — the check is explicitly
documented as best-effort.

## palera1n UX elements it borrows (modeled, not copied)

The pinned reference is `upstream/palera1n` (UX model only; no code copied):

| palera1n behavior | Upstream location | What `pomme` does with it |
|---|---|---|
| Timed DFU `step()` countdown that redraws one line and **exits early when the device re-enumerates in DFU** | `src/dfuhelper.c:43-60` (`step(..., conditional, ecid)`) | `countdown` / `countdown_until_dfu`: `Hold Volume Down` counts down while polling `lsusb` for `05ac:1227`, stopping the moment the device appears |
| Device-specific button script: "Hold volume down + side button" -> release -> "Hold volume down button" | `src/dfuhelper.c:207-209` (the `USES_VOLUME_DOWN_FOR_DFU` branch, which covers iPhone 7 / CPID 8010) | The coached choreography: Side + Volume Down 8 s (counted), release Side, keep Volume Down while the tool watches for DFU; screen-must-stay-black and Apple-logo failure notes come from `docs/bring-up.md` |
| "Press Enter when ready for DFU mode" gate | `src/dfuhelper.c:158` | The Enter gate before the countdown (skipped with `--yes` / non-tty), and the same [y/N] gate before running the chain and before sudo net commands |
| Friendly failure/success wording and retry encouragement | `src/dfuhelper.c:216` ("Whoops, device did not enter DFU mode"), `:230` ("Device entered DFU mode successfully"), `:217` ("Waiting for device to reconnect...") | Same three messages (verbatim acknowledgment of the borrow), 3 attempts, then a `lsusb` verification hint |
| State-driven flow: recovery (modes 1-4) vs DFU take different branches | `src/dfuhelper.c:268-353` (`irecv_device_event_cb`) | The `detect_state` case table above: recovery -> force-restart coaching first (Apple HT201412, `docs/bring-up.md` "Force restart"), DFU -> chain |
| Refusing A12+ as permanent | `src/dfuhelper.c:73` ("palera1n doesn't and never will work on A12+ (arm64e)") | The exit-3 refusal and the permanent-unsupported wording in `--help` and the banner |
| CLI flags style: paired long options incl. `--device-info` informational mode and `--no-colors` | `upstream/palera1n/README.md:82-104` (`-I, --device-info`, `-S, --no-colors`, ...) | `--dry-run`, `--skip-pwn`, `--kernel`, `--dtb`, `--yes`, `-h/--help` (the set this repo's task defines); color auto-disabled when not a tty or `NO_COLOR` is set — the `--no-colors` behavior via environment, no extra flag |
| TUI only when attached to a terminal, plain flow otherwise | `src/main.c:117` (`isatty(STDIN_FILENO) && isatty(STDOUT_FILENO)`) | `confirm()` never prompts on non-tty stdin: with `--yes` it applies the documented default; without it, it declines and says so instead of hanging |

## Host-net coach

After a chain run (and in the `gadget` state), `pomme` snapshots
`ip -o link` interface names **before** the chain and diffs after (pure-bash
set difference, no `comm`). A new interface — the NCM gadget appears as
`usb0` / `enp0s20f0u1` / `enx<mac>` depending on the host's udev — is offered
with the exact commands from `docs/bring-up.md` §7 /
`tooling/images/README.md`:

```
sudo ip addr add 10.0.0.1/24 dev <if>
sudo ip link set <if> up
nc 10.0.0.2 23
```

(telnet 10.0.0.2 23 also works; phone side is 10.0.0.2/24, served by busybox
`nc -l -p 23 -e /bin/sh` because the pinned busybox has no telnetd). The two
`ip` commands are the **only** sudo in the entire tool, and they run only on
an explicit interactive yes — `--yes` prints them and stops there. If no new
interface appears, the tool says so, points at the stale-bundle
troubleshooting row (`docs/bring-up.md` §8) and the `/dev/ttyGS0` fallback.

## Flags, exit codes

Documented in `scripts/pomme --help` (extracted from the header comment, the
same `sed` pattern `scripts/boot-iphone7.sh` uses). Exit codes: `0` ok,
`1` chain failure (propagated from `boot-iphone7.sh`), `2` usage,
`3` unsupported device (A12+), `4` preflight, `5` guided flow found nothing
actionable. `--dry-run` compiles the boot helpers and validates artifacts by
delegating to `boot-iphone7.sh --dry-run` (which itself issues no USB
commands and does not require a device), then prints the per-state plan; it
is idempotent (verified: two runs byte-identical, exit 0, no device attached).

## Verification status (build-verified only)

- `bash -n` clean; shellcheck not installed on the build host (documented in
  the evidence log, with a static sanity pass in its place: every `read` is
  `IFS= read -r`, no unquoted command substitutions in list context, no
  external deps beyond `lsusb`/`ip`/`grep`/`awk`).
- Fault injection: bogus `POMME_KERNEL_IMAGE` (env and `--kernel` both) exits
  4 with a branded error in preflight, before any state action or USB
  activity.
- NOT verifiable without hardware: every device-state branch (DFU coaching
  against a real iPhone 7, recovery triage, pwn/pongo/linux handover, gadget
  enumeration timing, udev interface naming, A12+ serial content on real
  silicon). First hardware session must record actual observations in
  `docs/bring-up.md` and re-rate this tool.
