#!/usr/bin/env bash
# pomme stage: gaster — checkm8 exploit tool, Linux x86-64 host binary.
# Contract: docs/pipeline-conventions.md
#
# Builds the pinned upstream (palera1n/gaster) with the host toolchain using
# its native Linux/libusb target, installs the binary to artifacts/gaster/,
# prints sha256sums, and runs a no-device smoke test. Non-interactive;
# everything is logged to stdout/stderr (caller redirects).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_DIR="${REPO_ROOT}/upstream/gaster"
PATCH_DIR="${REPO_ROOT}/patches/gaster"
OUT_DIR="${REPO_ROOT}/artifacts/gaster"

# Pinned upstream — must match evidence/upstream-pins/gaster.json.
UPSTREAM_URL="https://github.com/palera1n/gaster"
UPSTREAM_COMMIT="20958256a4706b6396e2d9ee9ca742618459980b"
UPSTREAM_DATE="2023-01-21"
VERSION="2095825+pomme1"

log() { printf '[gaster-build] %s\n' "$*"; }
die() { printf '[gaster-build] ERROR: %s\n' "$*" >&2; exit 1; }

log "stage=gaster version=${VERSION} upstream=${UPSTREAM_URL}@${UPSTREAM_COMMIT:0:7} (${UPSTREAM_DATE})"

# ---------------------------------------------------------------- preflight
for tool in git make xxd pkg-config timeout stdbuf; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

if command -v gcc >/dev/null 2>&1; then
	CC_BIN=gcc
elif command -v clang >/dev/null 2>&1; then
	CC_BIN=clang
else
	die "no C compiler found (need gcc or clang)"
fi
log "host compiler: $(${CC_BIN} --version | head -1)"

pkg-config --exists libusb-1.0 || die "libusb-1.0 development files missing (pkg-config 'libusb-1.0')"
log "libusb-1.0: $(pkg-config --modversion libusb-1.0)"

printf '#include <openssl/evp.h>\nint main(void){return 0;}\n' \
	| "${CC_BIN}" -x c - -o /dev/null -lcrypto 2>/dev/null \
	|| die "OpenSSL development headers (openssl/evp.h) missing"
log "openssl headers: OK (libcrypto present)"

# ------------------------------------------------- clone-or-reuse the pin
if [ ! -d "${UPSTREAM_DIR}/.git" ]; then
	log "upstream/gaster missing; cloning ${UPSTREAM_URL} (shallow)"
	git clone --no-checkout "${UPSTREAM_URL}" "${UPSTREAM_DIR}"
fi

cd "${UPSTREAM_DIR}"
if [ "$(git rev-parse HEAD)" != "${UPSTREAM_COMMIT}" ]; then
	log "upstream HEAD != pin; fetching pinned commit ${UPSTREAM_COMMIT}"
	git fetch --depth 1 origin "${UPSTREAM_COMMIT}"
	git checkout --detach "${UPSTREAM_COMMIT}"
fi
# Re-runnable from any state: drop patches/outputs from previous runs.
git reset --hard "${UPSTREAM_COMMIT}" >/dev/null
git clean -fdx >/dev/null
log "upstream checkout clean at pin $(git rev-parse HEAD) ($(git show -s --format=%ad --date=short HEAD))"

# --------------------------------------------------------------- patches
if compgen -G "${PATCH_DIR}/*.patch" >/dev/null 2>&1; then
	for p in "${PATCH_DIR}"/*.patch; do
		log "applying patch $(basename "${p}")"
		git apply --whitespace=nowarn "${p}"
	done
else
	log "no patches in patches/gaster/ — building pristine upstream"
fi

# ------------------------------------------------------------------ build
log "building make libusb (host ${CC_BIN}, VERSION=${VERSION})"
make -j"$(nproc)" libusb CC="${CC_BIN}" VERSION="${VERSION}"
log "build OK: ${UPSTREAM_DIR}/gaster"
file "${UPSTREAM_DIR}/gaster"

# ---------------------------------------------------------------- install
mkdir -p "${OUT_DIR}"
install -m 0755 "${UPSTREAM_DIR}/gaster" "${OUT_DIR}/gaster"
log "installed artifacts:"
(cd "${REPO_ROOT}" && find artifacts/gaster -type f -print -exec sha256sum {} \; -exec stat -c '%s bytes' {} \;)

# ------------------------------------------------------------ smoke tests
# No iPhone is attached on build hosts; the bar is "executes correctly on the
# host and exercises its real USB code path", not "pwns a device".
log "smoke test 1/2: no-argument invocation (usage path, expected rc=1)"
set +e
SMOKE1="$(stdbuf -oL "${OUT_DIR}/gaster" 2>&1)"
RC1=$?
set -e
printf '%s\n' "${SMOKE1}"
if [ "${RC1}" -ne 1 ]; then
	die "smoke test 1 failed: expected rc=1, got ${RC1}"
fi
printf '%s\n' "${SMOKE1}" | grep -q "Version: ${VERSION}" \
	|| die "smoke test 1 failed: 'Version: ${VERSION}' not printed"
printf '%s\n' "${SMOKE1}" | grep -q "pwn - Put the device in pwned DFU mode" \
	|| die "smoke test 1 failed: usage text not printed"
log "smoke test 1 PASSED (rc=1, version + usage printed)"

log "smoke test 2/2: 'pwn' with no device (libusb init + DFU poll loop, expected rc=124 via timeout)"
set +e
SMOKE2="$(timeout 5 stdbuf -oL "${OUT_DIR}/gaster" pwn 2>&1)"
RC2=$?
set -e
printf '%s\n' "${SMOKE2}"
printf '%s\n' "${SMOKE2}" | grep -q "\[libusb\] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227" \
	|| die "smoke test 2 failed: libusb DFU wait line (VID 0x5AC / PID 0x1227) not printed"
if [ "${RC2}" -ne 124 ]; then
	die "smoke test 2 failed: expected rc=124 (still polling at timeout), got ${RC2}"
fi
log "smoke test 2 PASSED (libusb initialized, device poll loop entered, no crash)"

log "runtime linkage of installed artifact:"
ldd "${OUT_DIR}/gaster" | sed 's/^/[gaster-build]   /'
log "smoke_test_result: PASS (usage path rc=1; libusb DFU-wait path rc=124 under timeout, VID 0x5AC PID 0x1227)"
log "done"
