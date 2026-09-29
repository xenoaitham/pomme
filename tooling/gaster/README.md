# gaster stage

Builds **gaster**, the checkm8 exploit tool that puts A7–A11 Apple SoCs into
pwned DFU — the entry point of the pomme pipeline (gaster → pongoOS → kernel).
On this host it produces a **Linux x86-64 host binary** that talks to a device
in Apple DFU mode (USB VID `0x05AC`, PID `0x1227`) over libusb-1.0.

## Upstream

| | |
|---|---|
| URL | https://github.com/palera1n/gaster |
| Pinned commit | `20958256a4706b6396e2d9ee9ca742618459980b` |
| Commit date | 2023-01-21 (subject: "merge") |
| Pin record | `evidence/upstream-pins/gaster.json` |
| License | Apache-2.0 (© 2023 0x7ff, per the file header at `gaster.c:1-14` and the `LICENSE` file in the pinned commit) |

gaster originates from 0x7ff (https://github.com/0x7ff/gaster); the palera1n
fork keeps the same core and is what palera1n ships. We pin the palera1n fork
because pomme's downstream stages (pongoOS stage of the palera1n ecosystem)
pair with it.

## Linux support status

Linux is a **first-class build host** for this fork: upstream CI builds it on
Ubuntu via `make libusb-static` (see `.github/workflows/makefile.yml` in the
pinned commit). We use the dynamic-link variant `make libusb` against the
distro's `libusb-1.0` and `libcrypto` (OpenSSL 3) instead of upstream CI's
hand-rolled static OpenSSL 1.1.1 + static libusb — same source target, fewer
moving parts. gaster.c only uses the non-deprecated `EVP_*` cipher API
(`gaster.c:1432-1440` region), so OpenSSL 3 needs no compatibility shims.

Requirements on Ubuntu 24.04 (all satisfied without sudo):
`gcc` or `clang`, `make`, `xxd`, `pkg-config`, `libusb-1.0-dev`, `libssl-dev`.

## Patches

**None.** `patches/gaster/` is empty — the pinned upstream builds and runs
green on this host unmodified (gcc 13.3, `-Wall -Wextra -Wpedantic`, no
warnings). `build.sh` still applies any future `*.patch` dropped into
`patches/gaster/`, so deviations stay outside the upstream clone per the
pipeline convention.

## Build

```
make gaster          # from repo root (tee's the log into evidence/builds/)
# or directly:
bash tooling/gaster/build.sh
```

The script: hard-checks that `evidence/upstream-pins/gaster.json` agrees with
the script's pin (build aborts on any disagreement) → clones-or-reuses
`upstream/gaster` at the pinned commit (`git reset --hard` + `git clean -fdx`
before every build, so it is re-runnable from any state) → applies patches →
`make libusb CC=gcc VERSION=2095825+pomme1` → installs to
`artifacts/gaster/gaster` → runs two no-device smoke tests (see below) →
runs the determinism gate (see below) → **generates**
`artifacts/gaster/provenance.json`.

## Provenance (generated, never hand-maintained)

`artifacts/gaster/provenance.json` is written by `build.sh` at the end of
every run — never by hand. It records the VERSION string, the toolchain
(compiler/version, make target, libusb/OpenSSL versions, flags), every
artifact file with sha256 and byte size, the build-log path, the smoke-test
results, and the determinism result. It is regenerated from scratch on each
run, so it always describes exactly the artifact sitting next to it.

## Determinism gate

After the main build, the script performs a second build of the same pinned
commit from a **fresh upstream clone at a different absolute path**
(`mktemp -d /tmp/gaster-det/det-*`, left in place for inspection) with the
identical recipe (`make libusb CC=<cc> VERSION=<version>`), and compares the
sha256 of the two binaries. The result — method, match true/false, both
paths and hashes — is recorded in the build log and in the generated
provenance.json (`"determinism"` object). A mismatch fails the build (after
the honest result is recorded). The build is expected to be
path-independent: no debug info, no `__DATE__`/`__TIME__`/`__FILE__` use,
relative source paths, content-derived GNU build-id.

## Build log

Everything the script prints — build output, smoke tests, determinism gate —
is tee'd into the canonical log
`evidence/builds/gaster_<VERSION>_<UTC-date>.log` (overwritten each run so it
always describes the shipped artifact); that path is what the generated
provenance.json records. The repo Makefile additionally tees stdout into its
own timestamped copy.

## Smoke tests (no device required)

1. **Usage path** — `./gaster` with no arguments prints
   `Version: 2095825+pomme1` and the option list, exits 1. Asserted.
2. **libusb path** — `timeout 5 ./gaster pwn` initializes libusb, prints
   `[libusb] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227`, and
   keeps polling; the timeout kills it (rc=124). Asserted: this proves the
   binary links and inits libusb-1.0 and enters its real DFU wait loop
   instead of crashing. (Without a device it can never get past the poll —
   by design.)

Full log of the shipped build: `evidence/builds/gaster_2095825+pomme1_20260929.log`.

## Known limitations (honesty)

- **Builds-not-boots.** This artifact has never been run against real
  hardware in this project. The exploit path (`pwn`) is untested on-device;
  only host-side execution is verified.
- **Device coverage** is whatever the pinned upstream implements — see
  `SUPPORT.md`. **A12 and newer are not supported and never will be** (no
  public bootROM exploit); gaster's own SRTG table contains no A12+ entries.
- **Dynamic linkage**: the binary needs `libusb-1.0.so.0` and
  `libcrypto.so.3` at runtime (see `ldd` output in the build log). A fully
  static build (upstream's `libusb-static` target) is a possible follow-up if
  portability is ever needed.
- Payload `.bin` blobs (`payload_*.bin`) are taken from the pinned upstream
  commit as-is; they are pre-built ARM blobs whose rebuild path (`make
  payload`) needs a macOS/Apple ARM toolchain and is not exercised here.
- The `VERSION` string baked into the binary is `2095825+pomme1` (pinned
  short-SHA + pomme suffix), overriding upstream's git-derived version so the
  artifact string is reproducible.
