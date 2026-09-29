#!/usr/bin/env bash
#
# pomme — hardware-session boot script for iPhone 7 (T8010, D10/D101).
#
# ══════════════════════════════════════════════════════════════════════════
#   EXPERIMENTAL — UNTESTED ON HARDWARE.
#   Nothing in this repository has ever been executed against a real device
#   (builds-not-boots, docs/pipeline-conventions.md). This script encodes the
#   researched protocol (docs/bars.md bar 1 loader protocol; gaster CLI verbs
#   from upstream/gaster; pongoOS USB PID from the pongoOS source) but every
#   hardware step below is a first run. Expect debugging, not magic.
# ══════════════════════════════════════════════════════════════════════════
#
# Chain (see tooling/boot/README.md):
#   DFU mode (05ac:1227)
#     --gaster pwn-->            pwned DFU (still 05ac:1227)
#     --dfu-send Pongo.bin-->    pongoOS running (05ac:4141)
#     --load-linux Image dtb-->  pongoOS `fdt` + `bootl` -> kernel
#
# Usage:
#   scripts/boot-iphone7.sh [--dry-run] [--skip-pwn] [--help]
#
#     --dry-run    compile helpers, check artifacts + attached devices, print
#                  the plan — issue no USB commands
#     --skip-pwn   the device is ALREADY in pwned DFU from an earlier `pwn` in
#                  this session; start from the Pongo.bin upload
#     --help       this text
#
# Environment overrides:
#   POMME_GASTER       path to gaster binary     (default artifacts/gaster/gaster)
#   POMME_PONGO_BIN    path to Pongo.bin         (default artifacts/pongoos/Pongo.bin)
#   POMME_KERNEL_IMAGE path to arm64 kernel Image (default: auto-detect under artifacts/kernel/)
#   POMME_DTB          path to iPhone 7 dtb      (default: auto-detect t8010 d10/d101)
#   POMME_USB_TIMEOUT  gaster USB_TIMEOUT env    (default: 30; gaster's own default is 5)
#
# Exit codes: 0 = all requested steps completed; nonzero = first failed step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/tooling/boot/bin"
SC_SRC="${REPO_ROOT}/upstream/projectsandcastle"
PIN_PROJECTSANDCASTLE="03db9c6ae04141eb940f3b9f56d446f50d57fadf"

GASTER="${POMME_GASTER:-${REPO_ROOT}/artifacts/gaster/gaster}"
PONGO_BIN="${POMME_PONGO_BIN:-${REPO_ROOT}/artifacts/pongoos/Pongo.bin}"
KERNEL_IMAGE="${POMME_KERNEL_IMAGE:-}"
DTB="${POMME_DTB:-}"

DRY_RUN=0
SKIP_PWN=0
for arg in "$@"; do
	case "${arg}" in
		--dry-run)  DRY_RUN=1 ;;
		--skip-pwn) SKIP_PWN=1 ;;
		-h|--help)
			sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "boot-iphone7: unknown argument: ${arg} (try --help)" >&2
			exit 2
			;;
	esac
done

log()  { printf '[boot-iphone7] %s\n' "$*"; }
step() { printf '\n[boot-iphone7] ── %s ──\n' "$*"; }
die()  { printf '[boot-iphone7] ERROR: %s\n' "$*" >&2; exit 1; }

banner() {
	cat <<'EOF'
════════════════════════════════════════════════════════════════════
 pomme boot session — iPhone 7 (T8010)
 EXPERIMENTAL / UNTESTED ON HARDWARE — builds-not-boots project.
 Every step below is its first real run; read each line it prints.
════════════════════════════════════════════════════════════════════
EOF
}

banner

# ─────────────────────────────────────────────── artifact / tool detection ──
step "preflight: artifacts, host tools, attached device"

for f in "${GASTER}" "${PONGO_BIN}"; do
	[ -f "${f}" ] || die "missing artifact: ${f} (run: make gaster pongoos)"
done
log "gaster   : ${GASTER}"
log "Pongo.bin: ${PONGO_BIN}"

# Kernel Image: explicit override > initramfs-bundled Image (self-contained
# userspace — preferred) > bare Image > anything Image-like
if [ -z "${KERNEL_IMAGE}" ]; then
	if [ -f "${REPO_ROOT}/artifacts/kernel/Image.initramfs" ]; then
		KERNEL_IMAGE="${REPO_ROOT}/artifacts/kernel/Image.initramfs"
		log "note     : using initramfs-bundled Image (userspace included; see tooling/kernel/README.md)"
	elif [ -f "${REPO_ROOT}/artifacts/kernel/Image" ]; then
		KERNEL_IMAGE="${REPO_ROOT}/artifacts/kernel/Image"
		log "note     : using bare Image — NO built-in userspace; see docs/bring-up.md for the net-root caveat"
	else
		KERNEL_IMAGE="$(find "${REPO_ROOT}/artifacts/kernel" -type f -name 'Image*' 2>/dev/null | head -n1 || true)"
	fi
fi
[ -n "${KERNEL_IMAGE}" ] && [ -f "${KERNEL_IMAGE}" ] \
	|| die "kernel Image not found under artifacts/kernel/ (run: make kernel) — or set POMME_KERNEL_IMAGE"
log "Image    : ${KERNEL_IMAGE}"

# DTB: iPhone 7 = t8010, board d10 (Qualcomm) or d101 (Intel)
if [ -z "${DTB}" ]; then
	for pat in '*t8010*d10*.dtb' '*t8010*d101*.dtb' '*t8010*.dtb'; do
		DTB="$(find "${REPO_ROOT}/artifacts/kernel" -type f -name "${pat}" 2>/dev/null | sort | head -n1 || true)"
		[ -n "${DTB}" ] && break
	done
fi
[ -n "${DTB}" ] && [ -f "${DTB}" ] \
	|| die "iPhone 7 dtb not found under artifacts/kernel/ (expected *t8010*d10*.dtb / *t8010*d101*.dtb) — or set POMME_DTB"
log "DTB      : ${DTB}"

for tool in lsusb gcc pkg-config git; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
pkg-config --exists libusb-1.0 || die "libusb-1.0 development files missing (pkg-config 'libusb-1.0')"

# Attached device state (informational; the hard gate is per-step below).
DFU_PRESENT=0
PONGO_PRESENT=0
if lsusb 2>/dev/null | grep -qi '05ac:1227'; then
	DFU_PRESENT=1
	log "device   : Apple DFU 05ac:1227 attached"
else
	log "device   : NO Apple DFU device (05ac:1227) attached"
fi
if lsusb 2>/dev/null | grep -qi '05ac:4141'; then
	PONGO_PRESENT=1
	log "device   : pongoOS 05ac:4141 attached (pongoOS is already running)"
fi
if [ "${DFU_PRESENT}" -eq 0 ] && [ "${PONGO_PRESENT}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
	die "no Apple device found (neither 05ac:1227 DFU nor 05ac:4141 pongoOS).
       Enter DFU mode first (iPhone 7/7+ choreography, cited in docs/bring-up.md):
       connect via USB, hold Side+Volume Down ~8 s, release Side, keep
       Volume Down until the screen stays black (Apple logo = held too long);
       verify with lsusb."
fi

# ────────────────────────────────────────────────────────────── build step ──
step "build: compile host loaders from pinned sources (upstream unmodified)"

# Pinned Sandcastle loader: reuse the clone if it is at the pin, else fetch
# the exact commit (same discipline as tooling/*/build.sh).
if [ ! -e "${SC_SRC}/.git" ]; then
	log "cloning corellium/projectsandcastle at pin ${PIN_PROJECTSANDCASTLE}"
	git init -q "${SC_SRC}"
	git -C "${SC_SRC}" remote add origin https://github.com/corellium/projectsandcastle
	git -C "${SC_SRC}" fetch -q --depth 1 origin "${PIN_PROJECTSANDCASTLE}" \
		|| die "git fetch of pinned projectsandcastle commit failed (network?)"
	git -C "${SC_SRC}" checkout -q -f FETCH_HEAD
fi
SC_HEAD="$(git -C "${SC_SRC}" rev-parse HEAD)"
[ "${SC_HEAD}" = "${PIN_PROJECTSANDCASTLE}" ] \
	|| die "upstream/projectsandcastle HEAD ${SC_HEAD} != pin ${PIN_PROJECTSANDCASTLE} (run: git -C ${SC_SRC} fetch origin ${PIN_PROJECTSANDCASTLE})"
log "projectsandcastle at pin: ${SC_HEAD}"

mkdir -p "${BIN_DIR}"
LIBUSB="$(pkg-config --cflags --libs libusb-1.0)"
gcc -O2 -Wall -o "${BIN_DIR}/load-linux" "${SC_SRC}/loader/load-linux.c" ${LIBUSB} \
	|| die "compiling load-linux.c failed"
log "built ${BIN_DIR}/load-linux (from upstream/projectsandcastle/loader, unmodified; no patches/boot-loader/*.patch needed)"
gcc -O2 -Wall -o "${BIN_DIR}/dfu-send" "${REPO_ROOT}/tooling/boot/src/dfu-send.c" ${LIBUSB} \
	|| die "compiling dfu-send.c failed"
log "built ${BIN_DIR}/dfu-send (pomme's pwned-DFU uploader — see tooling/boot/README.md for why it exists)"

# ──────────────────────────────────────────────────────────────── pwn step ──
if [ "${PONGO_PRESENT}" -eq 1 ]; then
	log "skipping pwn + pongo steps: pongoOS (05ac:4141) is already running"
elif [ "${SKIP_PWN}" -eq 1 ] && [ "${DFU_PRESENT}" -eq 1 ]; then
	step "pwn: SKIPPED (--skip-pwn; device expected to be in pwned DFU already)"
else
	step "pwn: gaster checkm8 -> pwned DFU"
	if [ "${DFU_PRESENT}" -ne 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
		die "no DFU device 05ac:1227 for gaster pwn (device state changed since preflight; re-check lsusb)"
	fi
	log "running: USB_TIMEOUT=${POMME_USB_TIMEOUT:-30} ${GASTER} pwn"
	log "success looks like: gaster prints exploit progress ending in"
	log "  'Now you can boot untrusted images.' and exits 0."
	log "failure looks like: 'Waiting for the USB handle with VID: 0x5AC, PID: 0x1227'"
	log "  forever (device not in DFU), or an SRTG/CPID refusal (device not"
	log "  checkm8-compatible; iPhone 7 = SRTG iBoot-2696.0.0.1.33, CPID 0x8010 —"
	log "  see tooling/gaster/SUPPORT.md)."
	[ "${DRY_RUN}" -eq 1 ] && { log "dry-run: skipping actual invocation"; } || {
		export USB_TIMEOUT="${POMME_USB_TIMEOUT:-30}"
		"${GASTER}" pwn || die "gaster pwn failed (rc=$?) — device may still be plain DFU; do NOT proceed"
	}
fi

# ────────────────────────────────────────────────────────────── pongo step ──
if [ "${PONGO_PRESENT}" -eq 0 ]; then
	step "pongo: send Pongo.bin into pwned DFU"
	if [ "${DFU_PRESENT}" -ne 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
		die "no pwned-DFU device 05ac:1227 for Pongo.bin upload (re-enter DFU and re-run with --skip-pwn AFTER pwn)"
	fi
	[ -x "${BIN_DIR}/dfu-send" ] || die "internal error: dfu-send missing (build step must run first)"
	log "running: ${BIN_DIR}/dfu-send ${PONGO_BIN} --wait-pid 0x4141 --timeout 60"
	log "success looks like: blocks sent, then pongoOS re-enumerates as"
	log "  05ac:4141 (pongoOS USB PID, upstream src/drivers/usb/synopsys_otg.c:143)."
	log "failure looks like: DFU error status from the device, or a timeout"
	log "  with no 05ac:4141 — re-enter DFU mode and start over from pwn."
	[ "${DRY_RUN}" -eq 1 ] && { log "dry-run: skipping actual invocation"; } || {
		"${BIN_DIR}/dfu-send" "${PONGO_BIN}" --wait-pid 0x4141 --timeout 60 \
			|| die "Pongo.bin upload failed (rc=$?) — pongoOS did not come up; re-enter DFU mode"
	}
else
	log "pongo step: not needed (pongoOS already running)"
fi

# ───────────────────────────────────────────────────────────── linux step ──
step "linux: send DTB + kernel Image via Sandcastle loader (fdt/bootl)"
if [ "${DRY_RUN}" -eq 1 ]; then
	log "dry-run: not checking for pongoOS device 05ac:4141 (no USB commands issued)"
else
	lsusb 2>/dev/null | grep -qi '05ac:4141' \
		|| die "pongoOS device 05ac:4141 not present — cannot send the kernel (pongo step did not complete in this session)"
fi
[ -x "${BIN_DIR}/load-linux" ] || die "internal error: load-linux missing (build step must run first)"
log "running: ${BIN_DIR}/load-linux ${KERNEL_IMAGE} ${DTB}"
log "  (loader argument order is KERNEL first, DTREE second — load-linux.c:26-28)"
log "success looks like: the loader prints 'Success!' after the pongoOS"
log "  shell commands 'fdt' and 'bootl' execute; the kernel then takes the"
log "  console."
[ "${DRY_RUN}" -eq 1 ] && { log "dry-run: skipping actual invocation"; } || {
	"${BIN_DIR}/load-linux" "${KERNEL_IMAGE}" "${DTB}" \
		|| die "load-linux failed (rc=$?) — kernel not booted; check pongoOS console"
}

# ───────────────────────────────────────────────── console expectations ────
step "console: what to expect now"
cat <<'EOF'
Expected state after bootl:
  - Device stays enumerated as Apple 05ac:4141 (pongoOS owns USB; the kernel
    console rides the pongoOS USB serial interface).
  - Kernel output (hoolock/sandcastle: earlycon over the pongoOS console)
    streams over that USB interface. Grab it with a pongoOS USB terminal —
    e.g. palera1n's `pongoterm` — NOT with screen/minicom (it is not a
    ttyACM device).
  - First signs of life: pongoOS banner before bootl; after bootl, kernel
    boot log; on the Sandcastle kernel, eventual APFS/rootfs messages.

If nothing appears:
  1. lsusb                      -> is 05ac:4141 still there? (gone = pongoOS
                                   crashed during bootl; re-enter DFU)
  2. Wrong DTB? iPhone 7 (Qualcomm, A1660/A1661) = d10; iPhone 7 (Intel,
     A1778/A1784) = d101. Re-run with POMME_DTB=/path/to/other.dtb.
  3. Console reader attached to the wrong interface — use pongoterm.
Troubleshooting references (by path, create-if-missing is fine):
  - docs/bring-up.md            (device bring-up notes, when written)
  - docs/bars.md                (bar 1 = the exact loader protocol in use)
  - tooling/gaster/SUPPORT.md   (SRTG/CPID table for the pwn step)
  - tooling/boot/README.md      (chain diagram + provenance)
EOF

log "done (dry-run=${DRY_RUN})"
