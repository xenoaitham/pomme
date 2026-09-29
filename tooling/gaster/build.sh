#!/usr/bin/env bash
# pomme stage: gaster — checkm8 exploit tool, Linux x86-64 host binary.
# Contract: docs/pipeline-conventions.md
#
# Builds the pinned upstream (palera1n/gaster) with the host toolchain using
# its native Linux/libusb target, installs the binary to artifacts/gaster/,
# runs no-device smoke tests, gates on determinism (a second build from a
# fresh upstream clone at a different absolute path), and GENERATES
# artifacts/gaster/provenance.json — provenance is never hand-maintained.
#
# Logging: everything this script prints (and everything its tools print) is
# tee'd into the canonical stage log
#   evidence/builds/gaster_<VERSION>_<UTC-date>.log
# which is the path recorded in the generated provenance.json. A caller may
# still tee stdout elsewhere (the repo Makefile does); the canonical file is
# overwritten on every run so it always describes the current artifact.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_DIR="${REPO_ROOT}/upstream/gaster"
PATCH_DIR="${REPO_ROOT}/patches/gaster"
OUT_DIR="${REPO_ROOT}/artifacts/gaster"
PIN_FILE="${REPO_ROOT}/evidence/upstream-pins/gaster.json"
PROV_FILE="${OUT_DIR}/provenance.json"

# Pinned upstream — must match evidence/upstream-pins/gaster.json (hard-checked below).
UPSTREAM_URL="https://github.com/palera1n/gaster"
UPSTREAM_COMMIT="20958256a4706b6396e2d9ee9ca742618459980b"
UPSTREAM_DATE="2023-01-21"
UPSTREAM_LICENSE="Apache-2.0"
VERSION="2095825+pomme1"

# Canonical build log, written by this script itself.
BUILD_LOG_REL="evidence/builds/gaster_${VERSION}_$(date -u +%Y%m%d).log"
BUILD_LOG="${REPO_ROOT}/${BUILD_LOG_REL}"

log() { printf '[gaster-build] %s\n' "$*"; }
die() { printf '[gaster-build] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${REPO_ROOT}/evidence/builds" "${OUT_DIR}"
# From here on, everything goes to the console AND the canonical stage log.
exec > >(tee "${BUILD_LOG}") 2>&1

log "stage=gaster version=${VERSION} upstream=${UPSTREAM_URL}@${UPSTREAM_COMMIT:0:7} (${UPSTREAM_DATE})"
log "canonical build log: ${BUILD_LOG_REL}"

# ---------------------------------------------------------------- preflight
for tool in git make xxd pkg-config timeout stdbuf jq awk sha256sum stat; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

# Pin agreement (hard gate): the pin file is authoritative. Refuse to build if
# its commit disagrees with the commit this script pins.
[ -f "${PIN_FILE}" ] || die "missing ${PIN_FILE}"
PIN_COMMIT="$(jq -r '.commit // empty' "${PIN_FILE}")"
PIN_URL="$(jq -r '.url // empty' "${PIN_FILE}")"
if [ "${PIN_COMMIT}" != "${UPSTREAM_COMMIT}" ]; then
	die "upstream pin mismatch: evidence/upstream-pins/gaster.json commit '${PIN_COMMIT}' != script UPSTREAM_COMMIT '${UPSTREAM_COMMIT}'"
fi
if [ -n "${PIN_URL}" ] && [ "${PIN_URL}" != "${UPSTREAM_URL}" ]; then
	die "upstream pin mismatch: evidence/upstream-pins/gaster.json url '${PIN_URL}' != script UPSTREAM_URL '${UPSTREAM_URL}'"
fi
log "pin check OK: evidence/upstream-pins/gaster.json agrees with script pin ${UPSTREAM_COMMIT:0:7}"

if command -v gcc >/dev/null 2>&1; then
	CC_BIN=gcc
elif command -v clang >/dev/null 2>&1; then
	CC_BIN=clang
else
	die "no C compiler found (need gcc or clang)"
fi
CC_VERSION="$("${CC_BIN}" --version | head -1)"
log "host compiler: ${CC_VERSION}"

pkg-config --exists libusb-1.0 || die "libusb-1.0 development files missing (pkg-config 'libusb-1.0')"
LIBUSB_VERSION="$(pkg-config --modversion libusb-1.0)"
log "libusb-1.0: ${LIBUSB_VERSION}"

printf '#include <openssl/evp.h>\nint main(void){return 0;}\n' \
	| "${CC_BIN}" -x c - -o /dev/null -lcrypto 2>/dev/null \
	|| die "OpenSSL development headers (openssl/evp.h) missing"
OPENSSL_VERSION="$(openssl version 2>/dev/null || pkg-config --modversion openssl 2>/dev/null || echo 'unknown')"
log "openssl headers: OK (libcrypto present; ${OPENSSL_VERSION})"

HOST_OS="$(uname -s -r -m)"
if [ -r /etc/os-release ]; then
	HOST_OS="${HOST_OS}; $(. /etc/os-release && printf '%s' "${PRETTY_NAME}")"
fi

# Patch inventory for provenance (deviations live in patches/gaster/ per contract).
PATCHES_JSON="[]"
if compgen -G "${PATCH_DIR}/*.patch" >/dev/null 2>&1; then
	for p in "${PATCH_DIR}"/*.patch; do
		PATCHES_JSON="$(jq -c --arg b "$(basename "${p}")" '. + [$b]' <<<"${PATCHES_JSON}")"
	done
fi

fetch_pin() { # $1 = target dir; $2 = "reuse" (clone only if missing) | "fresh" (dir is new)
	local dir="$1" mode="$2"
	if [ "${mode}" = "fresh" ] || [ ! -d "${dir}/.git" ]; then
		log "cloning ${UPSTREAM_URL} into ${dir}"
		git clone --no-checkout "${UPSTREAM_URL}" "${dir}"
	fi
	(
	cd "${dir}"
	if [ "$(git rev-parse HEAD)" != "${UPSTREAM_COMMIT}" ]; then
		log "fetching pinned commit ${UPSTREAM_COMMIT}"
		git fetch --depth 1 origin "${UPSTREAM_COMMIT}"
		git checkout --detach "${UPSTREAM_COMMIT}"
	fi
	# Re-runnable from any state: drop patches/outputs from previous runs.
	git reset --hard "${UPSTREAM_COMMIT}" >/dev/null
	git clean -fdx >/dev/null
	)
}

apply_patches() { # $1 = worktree dir
	local dir="$1"
	if compgen -G "${PATCH_DIR}/*.patch" >/dev/null 2>&1; then
		for p in "${PATCH_DIR}"/*.patch; do
			log "applying patch $(basename "${p}") to ${dir}"
			git -C "${dir}" apply --whitespace=nowarn "${p}"
		done
	else
		log "no patches in patches/gaster/ — building pristine upstream"
	fi
}

# ------------------------------------------------- clone-or-reuse the pin
if [ -d "${UPSTREAM_DIR}/.git" ]; then
	log "reusing upstream clone at ${UPSTREAM_DIR} (reset to pin below)"
else
	log "upstream/gaster missing"
fi
fetch_pin "${UPSTREAM_DIR}" reuse
log "upstream checkout clean at pin $(git -C "${UPSTREAM_DIR}" rev-parse HEAD) ($(git -C "${UPSTREAM_DIR}" show -s --format=%ad --date=short HEAD))"

# --------------------------------------------------------------- patches
apply_patches "${UPSTREAM_DIR}"

# ------------------------------------------------------------------ build
log "building make libusb (host ${CC_BIN}, VERSION=${VERSION})"
make -C "${UPSTREAM_DIR}" -j"$(nproc)" libusb CC="${CC_BIN}" VERSION="${VERSION}"
log "build OK: ${UPSTREAM_DIR}/gaster"
file "${UPSTREAM_DIR}/gaster"

# ---------------------------------------------------------------- install
install -m 0755 "${UPSTREAM_DIR}/gaster" "${OUT_DIR}/gaster"
ART_SHA="$(sha256sum "${OUT_DIR}/gaster" | awk '{print $1}')"
ART_BYTES="$(stat -c '%s' "${OUT_DIR}/gaster")"
log "installed artifacts/gaster/gaster sha256=${ART_SHA} (${ART_BYTES} bytes)"

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

# ------------------------------------------------------- determinism gate
# Same recipe, fresh upstream clone at a DIFFERENT absolute path; the built
# binary must hash identically. The result is recorded in this log and in the
# generated provenance.json ("determinism" object).
DET_PARENT="${TMPDIR:-/tmp}/gaster-det"
mkdir -p "${DET_PARENT}"
DET_ROOT="$(mktemp -d "${DET_PARENT}/det-XXXXXXXXXXXX")"
DET_DIR="${DET_ROOT}/gaster"
DET_CLONE_SOURCE="network"
log "determinism gate 1/3: fresh upstream clone at a different absolute path: ${DET_DIR}"
if ! git clone --no-checkout --quiet "${UPSTREAM_URL}" "${DET_DIR}" 2>/dev/null; then
	log "network clone failed; falling back to a fresh clone from the local pin checkout (same pinned objects, new absolute path)"
	git clone --no-checkout --quiet "${UPSTREAM_DIR}" "${DET_DIR}"
	DET_CLONE_SOURCE="local pin checkout"
fi
fetch_pin "${DET_DIR}" reuse
apply_patches "${DET_DIR}"
log "determinism gate 2/3: same recipe (make libusb CC=${CC_BIN} VERSION=${VERSION})"
make -C "${DET_DIR}" -j"$(nproc)" libusb CC="${CC_BIN}" VERSION="${VERSION}"
DET_SHA="$(sha256sum "${DET_DIR}/gaster" | awk '{print $1}')"
if [ "${DET_SHA}" = "${ART_SHA}" ]; then
	DET_MATCH=true
	log "determinism gate 3/3 PASSED: builds at two different absolute paths produced byte-identical artifacts"
else
	DET_MATCH=false
	log "determinism gate 3/3 FAILED: sha256 differs across build paths"
	log "  A (pipeline checkout): ${ART_SHA}"
	log "  B (fresh clone):       ${DET_SHA}"
fi
DET_JSON="$(jq -n \
	--arg method "artifact sha256 comparison of two builds of the same pinned commit with an identical recipe (make libusb CC=${CC_BIN} VERSION=${VERSION}): (A) upstream clone at the pipeline checkout path, (B) fresh git clone at an independent absolute path under ${DET_PARENT}/" \
	--argjson match "${DET_MATCH}" \
	--arg a_path "${UPSTREAM_DIR}" \
	--arg a_sha "${ART_SHA}" \
	--arg b_path "${DET_DIR}" \
	--arg b_sha "${DET_SHA}" \
	--arg b_source "${DET_CLONE_SOURCE}" \
	'{method: $method, match: $match,
	  build_a: {path: $a_path, artifact_sha256: $a_sha},
	  build_b: {path: $b_path, artifact_sha256: $b_sha, fresh_clone: true, clone_source: $b_source}}')"
log "determinism result: match=${DET_MATCH} A=${ART_SHA:0:12}… B=${DET_SHA:0:12}… (B left in place at ${DET_ROOT} for inspection)"

# -------------------------------------------------- generate provenance.json
# artifacts/gaster/provenance.json is GENERATED here, from what this run
# actually did — never hand-maintained.
FILES_JSON="$(jq -n '[]')"
for f in "${OUT_DIR}"/*; do
	if [ -f "${f}" ]; then
		base="$(basename "${f}")"
		if [ "${base}" != "provenance.json" ]; then
			fsha="$(sha256sum "${f}" | awk '{print $1}')"
			fbytes="$(stat -c '%s' "${f}")"
			FILES_JSON="$(jq -c --arg path "artifacts/gaster/${base}" --arg sha "${fsha}" --argjson bytes "${fbytes}" \
				'. + [{path: $path, sha256: $sha, bytes: $bytes}]' <<<"${FILES_JSON}")"
			log "provenance: artifacts/gaster/${base} sha256=${fsha} (${fbytes} bytes)"
		fi
	fi
done

SMOKE_RESULT="PASS — (1) no-arg usage path: prints 'Version: ${VERSION}' + options, rc=1; (2) 'pwn' with no device: libusb-1.0 initializes, prints '[libusb] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227', stays in poll loop until timeout kill (rc=124), no crash. No device was attached; exploit path untested on hardware (builds-not-boots)."

jq -n \
	--arg stage "gaster" \
	--arg version "${VERSION}" \
	--arg url "${UPSTREAM_URL}" \
	--arg commit "${UPSTREAM_COMMIT}" \
	--arg commit_date "${UPSTREAM_DATE}" \
	--arg license "${UPSTREAM_LICENSE}" \
	--arg built_by "tooling/gaster/build.sh (pomme gaster stage — generated by the build, never hand-maintained)" \
	--arg host "${HOST_OS}" \
	--arg cc "${CC_BIN}" \
	--arg cc_version "${CC_VERSION}" \
	--arg libusb "${LIBUSB_VERSION} (distro libusb-1.0-dev, dynamic)" \
	--arg openssl "${OPENSSL_VERSION} (distro libssl-dev, dynamic libcrypto)" \
	--arg flags "-Wall -Wextra -Wpedantic -DHAVE_LIBUSB -Os (upstream Makefile 'libusb' target, unmodified)" \
	--argjson patches "${PATCHES_JSON}" \
	--argjson files "${FILES_JSON}" \
	--arg build_log "${BUILD_LOG_REL}" \
	--arg smoke "${SMOKE_RESULT}" \
	--argjson det "${DET_JSON}" \
	'{stage: $stage, version: $version,
	  upstream_url: $url, upstream_commit: $commit, upstream_commit_date: $commit_date, upstream_license: $license,
	  built_by: $built_by, build_host_os: $host,
	  toolchain: {cc: $cc, cc_version: $cc_version, make_target: "libusb", libusb: $libusb, openssl: $openssl, flags: $flags},
	  patches_applied: $patches,
	  artifact_files: $files,
	  build_log: $build_log,
	  smoke_test_result: $smoke,
	  determinism: $det,
	  generated_utc: (now | todateiso8601),
	  notes: "Dynamic linkage (libusb-1.0.so.0, libcrypto.so.3, libudev.so.1). A12+ devices are out of scope by design; see tooling/gaster/SUPPORT.md."}' \
	> "${PROV_FILE}.tmp"
mv "${PROV_FILE}.tmp" "${PROV_FILE}"
PROV_SHA="$(sha256sum "${PROV_FILE}" | awk '{print $1}')"
log "generated provenance: artifacts/gaster/provenance.json sha256=${PROV_SHA} ($(stat -c '%s' "${PROV_FILE}") bytes)"

if [ "${DET_MATCH}" != "true" ]; then
	die "determinism gate failed — see the determinism section above and in artifacts/gaster/provenance.json"
fi

log "done"
