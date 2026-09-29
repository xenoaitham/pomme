#!/usr/bin/env bash
# pomme stage: m1n1 — the Asahi Linux m1n1 bootloader, HoolockLinux Apple
# iDevice fork. AArch64 freestanding payload chainloaded by pongoOS 'bootm'.
# Contract: docs/pipeline-conventions.md
#
# Builds the pinned upstream (HoolockLinux/m1n1) with the pinned Bootlin
# aarch64 cross-GCC plus rustc (aarch64-unknown-none-softfloat) for its Rust
# component, installs the four upstream-named outputs to artifacts/m1n1/,
# gates on intra-run determinism (full clean rebuild must hash identically),
# and GENERATES artifacts/m1n1/provenance.json — provenance is never
# hand-maintained.
#
# Logging: everything this script prints (and everything its tools print) is
# tee'd into the canonical stage log
#   evidence/builds/m1n1_<VERSION>_<UTC-date>.log
# which is the path recorded in the generated provenance.json. A caller may
# still tee stdout elsewhere; the canonical file is overwritten on every run
# so it always describes the current artifact.
#
# Upstream is NEVER modified: build.sh asserts the clone is pristine at the
# pin before building (patches/m1n1/*.patch, currently empty, would be the
# only sanctioned source of deviation and would be applied after that check).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_DIR="${REPO_ROOT}/upstream/m1n1-apple-idevice"
PATCH_DIR="${REPO_ROOT}/patches/m1n1"
OUT_DIR="${REPO_ROOT}/artifacts/m1n1"
PIN_FILE="${REPO_ROOT}/evidence/upstream-pins/m1n1-apple-idevice.json"
PROV_FILE="${OUT_DIR}/provenance.json"

# Pinned upstream — must match evidence/upstream-pins/m1n1-apple-idevice.json
# (hard-checked below). VERSION mirrors the pmaports pkgver for this commit
# (upstream/pmaports/device/testing/m1n1-apple-idevice/APKBUILD: pkgver=1.5.0_git20260208).
UPSTREAM_URL="https://github.com/HoolockLinux/m1n1"
UPSTREAM_COMMIT="bd117d710e1c88a2cba45d47a030334bf74f212e"
UPSTREAM_DATE="2026-02-08"
UPSTREAM_LICENSE="MIT"
VERSION="1.5.0_git20260208"
# The clone carries one git submodule the Rust build needs as a PATH
# dependency (rust/Cargo.toml: fatfs = { path = "vendor/rust-fatfs" }).
# rev per the clone's gitlink (also the rev the pmaports patch fetches).
RUST_FATFS_REV="4eccb50d011146fbed20e133d33b22f3c27292e7"

# Toolchain: the pinned Bootlin aarch64 cross-GCC (m1n1 is freestanding; the
# Makefile's GCC path takes TOOLCHAIN=<dir-prefix> + ARCH=<prefix>). Default is
# $HOME-relative — never a hardcoded user path (the same CI-portability defect
# the kernel stage's author-path default hit on the first hosted run; the
# kernel fix and this one keep the pipeline runnable on any POSIX host).
TC_DIR="${POMME_TOOLCHAIN_DIR:-${HOME}/toolchains}/aarch64--glibc--stable-2026.08-1/bin/"
TC_ARCH="aarch64-buildroot-linux-gnu-"
RUST_TARGET="aarch64-unknown-none-softfloat"

# Build knobs — exactly the pmaports recipe (APKBUILD build(): make RELEASE=1
# CHAINLOADING=1). RELEASE=1 strips debug conveniences; CHAINLOADING=1 builds
# the pongoOS-chainloadable configuration.
MAKE_KNOBS=(RELEASE=1 CHAINLOADING=1)

# Artifacts, upstream's own output names (Makefile targets; we do NOT adopt
# the pmaports renames — those exist to fit Alpine packaging layouts):
#   m1n1.bin            raw binary for pongoOS 'bootm'  <- the pomme boot chain
#   m1n1.macho          Mach-O payload (m1n1.ld)
#   m1n1-idevice.macho  Mach-O payload (m1n1-idevice.ld, iBoot-style load)
#   monitor-stub.macho  stub for building mock kernel images
ARTIFACTS=(m1n1.bin m1n1.macho m1n1-idevice.macho monitor-stub.macho)

# Canonical build log, written by this script itself.
BUILD_LOG_REL="evidence/builds/m1n1_${VERSION}_$(date -u +%Y%m%d).log"
BUILD_LOG="${REPO_ROOT}/${BUILD_LOG_REL}"

log()  { printf '[m1n1-build] %s\n' "$*"; }
warn() { printf '[m1n1-build] WARNING: %s\n' "$*"; }
die()  { printf '[m1n1-build] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "${REPO_ROOT}/evidence/builds" "${OUT_DIR}"
# From here on, everything goes to the console AND the canonical stage log.
exec > >(tee "${BUILD_LOG}") 2>&1

log "stage=m1n1 version=${VERSION} upstream=${UPSTREAM_URL}@${UPSTREAM_COMMIT:0:7} (${UPSTREAM_DATE})"
log "canonical build log: ${BUILD_LOG_REL}"
log "build host disk before: $(df -h "${REPO_ROOT}" | awk 'NR==2{print $4" free ("$5" used)"}')"

# ---------------------------------------------------------------- preflight
for tool in git make jq python3 sha256sum stat file awk cargo rustc rustup; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
[ -x "${TC_DIR}${TC_ARCH}gcc" ] || die "Bootlin cross-gcc not found at ${TC_DIR}${TC_ARCH}gcc"
TC_GCC_VERSION="$("${TC_DIR}${TC_ARCH}gcc" --version | head -1)"
TC_LD_VERSION="$("${TC_DIR}${TC_ARCH}ld" -V | head -1)"
TC_OBJCOPY_VERSION="$("${TC_DIR}${TC_ARCH}objcopy" --version | head -1)"
# aarch64elf emulation is required by the Makefile LDFLAGS (-maarch64elf).
"${TC_DIR}${TC_ARCH}ld" -V | grep -qx ' *aarch64elf' \
	|| die "${TC_DIR}${TC_ARCH}ld does not list the aarch64elf emulation (Makefile LDFLAGS need it)"
log "cross toolchain: ${TC_GCC_VERSION}"
log "cross binutils:  ${TC_LD_VERSION}"
log "cross objcopy:   ${TC_OBJCOPY_VERSION}"
RUSTC_VERSION="$(rustc --version)"
CARGO_VERSION="$(cargo --version)"
log "rust: ${RUSTC_VERSION} / ${CARGO_VERSION}"
# The Rust lib links as a staticlib for a bare-metal target; its rust-std
# component must be installed before make runs (make itself fails later and
# less clearly otherwise). Non-interactive: needs the network on first add.
if ! rustup target list --installed 2>/dev/null | grep -qx "${RUST_TARGET}"; then
	log "rust target ${RUST_TARGET} missing — adding (rustup target add)"
	rustup target add "${RUST_TARGET}" || die "could not add rust target ${RUST_TARGET} (network?)"
fi
rustup target list --installed 2>/dev/null | grep -qx "${RUST_TARGET}" \
	|| die "rust target ${RUST_TARGET} still not installed after rustup target add"
log "rust target ${RUST_TARGET}: installed"

# Reproducibility citizenship: pin SOURCE_DATE_EPOCH to the pin commit date.
# Nothing in THIS build chain consumes it (verified: no __DATE__/__TIME__ in
# src/ or sysinc/; the embedded BUILD_TAG comes from git describe), but if a
# future pin adds timestamped code this keeps it deterministic. Recorded in
# provenance.
SOURCE_DATE_EPOCH="$(date -u -d "${UPSTREAM_DATE}T00:00:00Z" +%s)"
export SOURCE_DATE_EPOCH
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (pin commit date; not consumed by this build chain)"

# ---------------------------------------------------------------- pin gate
# Hard gate: the pin file is authoritative. Refuse to build on disagreement.
[ -f "${PIN_FILE}" ] || die "missing ${PIN_FILE}"
PIN_COMMIT="$(jq -r '.commit // empty' "${PIN_FILE}")"
PIN_URL="$(jq -r '.url // empty' "${PIN_FILE}")"
PIN_DATE="$(jq -r '.date // empty' "${PIN_FILE}")"
[ "${PIN_COMMIT}" = "${UPSTREAM_COMMIT}" ] \
	|| die "upstream pin mismatch: evidence/upstream-pins/m1n1-apple-idevice.json commit '${PIN_COMMIT}' != script UPSTREAM_COMMIT '${UPSTREAM_COMMIT}'"
if [ -n "${PIN_URL}" ] && [ "${PIN_URL}" != "${UPSTREAM_URL}" ]; then
	die "upstream pin mismatch: evidence/upstream-pins/m1n1-apple-idevice.json url '${PIN_URL}' != script UPSTREAM_URL '${UPSTREAM_URL}'"
fi
log "pin check OK: evidence/upstream-pins/m1n1-apple-idevice.json agrees with script pin ${UPSTREAM_COMMIT:0:7}"

# ------------------------------------------------- clone-or-reuse the pin
if [ ! -d "${UPSTREAM_DIR}/.git" ]; then
	log "upstream clone missing at ${UPSTREAM_DIR} — fetching pinned commit"
	git init -q "${UPSTREAM_DIR}"
	git -C "${UPSTREAM_DIR}" remote add origin "${UPSTREAM_URL}"
fi
if [ "$(git -C "${UPSTREAM_DIR}" rev-parse HEAD 2>/dev/null || true)" != "${UPSTREAM_COMMIT}" ]; then
	log "checking out pin ${UPSTREAM_COMMIT}"
	git -C "${UPSTREAM_DIR}" fetch --depth 1 origin "${UPSTREAM_COMMIT}" \
		|| die "could not fetch ${UPSTREAM_COMMIT} from ${UPSTREAM_URL} (network?)"
	git -C "${UPSTREAM_DIR}" checkout --detach -q "${UPSTREAM_COMMIT}"
fi
# Re-runnable from any state: reset tracked files to the pin and drop build
# outputs from earlier runs. Registered submodules are NOT touched by
# clean -fdx (that needs -ff), so the rust-fatfs checkout below survives.
git -C "${UPSTREAM_DIR}" reset --hard -q "${UPSTREAM_COMMIT}"
git -C "${UPSTREAM_DIR}" clean -fdx -q
ACTUAL_COMMIT="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)"
[ "${ACTUAL_COMMIT}" = "${UPSTREAM_COMMIT}" ] \
	|| die "clone HEAD ${ACTUAL_COMMIT} != pin ${UPSTREAM_COMMIT} after checkout"
log "upstream checkout clean at pin ${ACTUAL_COMMIT} ($(git -C "${UPSTREAM_DIR}" show -s --format=%ad --date=short HEAD))"

# ------------------------------------------------------ rust-fatfs submodule
# rust/Cargo.toml depends on fatfs as a PATH dependency pointing at the
# git submodule. (The pmaports patch goes the OTHER way — path->git — because
# aports builds from a submodule-less tarball; building from the clone we use
# upstream's vendored submodule layout and need NO patch.)
SUB_DIR="${UPSTREAM_DIR}/rust/vendor/rust-fatfs"
if [ ! -e "${SUB_DIR}/Cargo.toml" ] \
	|| [ "$(git -C "${SUB_DIR}" rev-parse HEAD 2>/dev/null || true)" != "${RUST_FATFS_REV}" ]; then
	log "initializing submodule rust/vendor/rust-fatfs at ${RUST_FATFS_REV:0:7}"
	git -C "${UPSTREAM_DIR}" submodule update --init rust/vendor/rust-fatfs \
		|| die "submodule init failed (network?)"
fi
[ "$(git -C "${SUB_DIR}" rev-parse HEAD)" = "${RUST_FATFS_REV}" ] \
	|| die "rust-fatfs submodule at $(git -C "${SUB_DIR}" rev-parse HEAD), expected ${RUST_FATFS_REV}"
log "submodule rust/vendor/rust-fatfs pinned at ${RUST_FATFS_REV:0:7} (v0.3.2-157-g4eccb50)"

# Upstream immutability assertion: after reset+clean+submodule-ensure the
# tracked tree (including submodule gitlinks) must be pristine. This is the
# contract's "NO edits to upstream/" made machine-checkable.
if [ -n "$(git -C "${UPSTREAM_DIR}" status --porcelain)" ]; then
	git -C "${UPSTREAM_DIR}" status --porcelain | sed 's/^/[m1n1-build]   dirty: /' >&2
	die "upstream clone is dirty before any build step — refusing to build a modified tree"
fi
log "upstream tree pristine (git status --porcelain empty) — no upstream edits"

# --------------------------------------------------------------- patches
# Deviations from upstream live in patches/m1n1/ per the stage contract.
# Currently EMPTY: the pinned fork builds as-is with the Bootlin GCC + rustc
# (see tooling/m1n1/README.md for why the pmaports patch is not needed here).
PATCHES_JSON="[]"
if compgen -G "${PATCH_DIR}/*.patch" >/dev/null 2>&1; then
	for p in "${PATCH_DIR}"/*.patch; do
		log "applying patch $(basename "${p}") to ${UPSTREAM_DIR}"
		git -C "${UPSTREAM_DIR}" apply --whitespace=nowarn "${p}"
		PATCHES_JSON="$(jq -c --arg b "$(basename "${p}")" '. + [$b]' <<<"${PATCHES_JSON}")"
	done
else
	log "no patches in patches/m1n1/ — building pristine upstream"
fi

# ------------------------------------------------------------------ build
# NOTE on make flags: TOOLCHAIN (directory prefix) and ARCH (prefix) are the
# fork Makefile's own cross-toolchain knobs; without them it would default to
# aarch64-linux-gnu-. USE_CLANG stays unset => GCC path (adds
# -Wstack-usage=2048). -j comes from nproc.
MAKE_VARS=(TOOLCHAIN="${TC_DIR}" ARCH="${TC_ARCH}" -j"$(nproc)")

build_pass() { # $1 = label
	log "building (${1}): make ${MAKE_KNOBS[*]} TOOLCHAIN=<Bootlin 2026.08-1 bin/> ARCH=${TC_ARCH} -j$(nproc)"
	make -C "${UPSTREAM_DIR}" clean "${MAKE_KNOBS[@]}" "${MAKE_VARS[@]}" >/dev/null
	local t0 t1
	t0=${SECONDS}
	make -C "${UPSTREAM_DIR}" "${MAKE_KNOBS[@]}" "${MAKE_VARS[@]}"
	t1=$((SECONDS - t0))
	log "build pass (${1}) finished in ${t1}s"
	for a in "${ARTIFACTS[@]}"; do
		[ -f "${UPSTREAM_DIR}/build/${a}" ] || die "pass (${1}): expected output build/${a} missing"
	done
	log "build pass (${1}): all ${#ARTIFACTS[@]} outputs present"
}

build_pass "1/2 determinism pair"

# ------------------------------------------------------- determinism gate
# Full clean rebuild of the SAME tree with the SAME recipe; every artifact
# must hash identically. Exercises the entire compile+assemble+link+objcopy
# path twice with independently produced objects — catches embedded
# timestamps, path leakage, and toolchain nondeterminism.
log "determinism gate: rebuilding from clean and comparing artifact hashes"
declare -A PASS1_SHA=()
for a in "${ARTIFACTS[@]}"; do
	PASS1_SHA[$a]="$(sha256sum "${UPSTREAM_DIR}/build/${a}" | awk '{print $1}')"
done
build_pass "2/2 determinism pair"
DET_MATCH="true"
DET_LINES=""
for a in "${ARTIFACTS[@]}"; do
	sha2="$(sha256sum "${UPSTREAM_DIR}/build/${a}" | awk '{print $1}')"
	if [ "${sha2}" = "${PASS1_SHA[$a]}" ]; then
		log "determinism: ${a} byte-identical across clean rebuilds (${sha2:0:12}…)"
	else
		DET_MATCH="false"
		log "determinism: ${a} DIFFERS pass1=${PASS1_SHA[$a]:0:12}… pass2=${sha2:0:12}…"
	fi
	DET_LINES+="${a} ${PASS1_SHA[$a]} -> ${sha2}
"
done
log "determinism result: match=${DET_MATCH}"

# ---------------------------------------------------------------- install
for a in "${ARTIFACTS[@]}"; do
	install -m 0644 "${UPSTREAM_DIR}/build/${a}" "${OUT_DIR}/${a}"
	sha="$(sha256sum "${OUT_DIR}/${a}" | awk '{print $1}')"
	bytes="$(stat -c '%s' "${OUT_DIR}/${a}")"
	log "installed artifacts/m1n1/${a} sha256=${sha} (${bytes} bytes)"
done

# ------------------------------------------------------------- smoke tests
log "---------------------------------------- smoke tests"

# 1. file(1) class on every artifact. The .macho payloads must be arm64
#    Mach-O; m1n1.bin is objcopy -O binary output — file(1) reports plain
#    "data" for a raw loadable blob, which is the expected class.
for a in m1n1.macho m1n1-idevice.macho monitor-stub.macho; do
	FOUT="$(file "${OUT_DIR}/${a}")"
	log "smoke 1 file(${a}): ${FOUT#*: }"
	case "${FOUT}" in
		*Mach-O*64-bit*arm64*) : ;;
		*) die "smoke 1 FAIL: ${a} is not a Mach-O 64-bit arm64 image (${FOUT})" ;;
	esac
done
FOUT_BIN="$(file "${OUT_DIR}/m1n1.bin")"
log "smoke 1 file(m1n1.bin): ${FOUT_BIN#*: }"
case "${FOUT_BIN}" in *data*) : ;; *) die "smoke 1 FAIL: m1n1.bin not raw data (${FOUT_BIN})" ;; esac
log "smoke 1 PASS: file(1) classes correct (arm64 Mach-O x3, raw binary x1)"

# 2. AArch64 confirmation on the raw path: the m1n1.bin bytes are a dump of
#    build/m1n1-raw.elf; readelf that ELF (kept in the clone's build/) and
#    assert Machine: AArch64 + ELF64.
READELF_OUT="$("${TC_DIR}${TC_ARCH}readelf" -h "${UPSTREAM_DIR}/build/m1n1-raw.elf")"
printf '%s\n' "${READELF_OUT}" | grep -q "Machine:.*AArch64" \
	|| die "smoke 2 FAIL: m1n1-raw.elf is not AArch64"
printf '%s\n' "${READELF_OUT}" | grep -q "Class:.*ELF64" \
	|| die "smoke 2 FAIL: m1n1-raw.elf is not ELF64"
ENTRY_ADDR="$(printf '%s\n' "${READELF_OUT}" | awk '/Entry point/{print $4}')"
log "smoke 2 PASS: m1n1-raw.elf is ELF64 AArch64, entry ${ENTRY_ADDR} (m1n1.bin = its loadable bytes)"

# 3. Embedded version tag: the fork embeds BUILD_TAG from `git describe
#    --tags --always --dirty` (here: abbreviated pin sha, no tags in the
#    depth-1 clone) behind the '##m1n1_ver##' magic, and stages it into the
#    device tree as 'asahi,m1n1-stage1-version'. Assert the magic is present
#    and matches the pin's short sha. Checked FILE-based (strings dumped to
#    disk first): `strings | grep -q` in a pipe is a pipefail trap — grep -q
#    exits at the first match, the producer eats SIGPIPE, and the pipeline
#    status races (the images stage documents the same trap).
SMOKE_STRINGS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/m1n1-smoke-XXXXXXXX")"
trap 'rm -rf "${SMOKE_STRINGS_DIR}"' EXIT
BUILD_TAG="$(cat "${UPSTREAM_DIR}/build/build_tag.h" | sed -n 's/.*BUILD_TAG "\(.*\)".*/\1/p')"
[ -n "${BUILD_TAG}" ] || die "smoke 3 FAIL: could not read BUILD_TAG from build/build_tag.h"
[ "${BUILD_TAG}" = "${UPSTREAM_COMMIT:0:7}" ] \
	|| die "smoke 3 FAIL: BUILD_TAG '${BUILD_TAG}' != abbreviated pin '${UPSTREAM_COMMIT:0:7}' (clone drifted?)"
for a in m1n1.bin m1n1.macho; do
	strings -n 8 "${OUT_DIR}/${a}" > "${SMOKE_STRINGS_DIR}/${a}.strings"
	grep -q "##m1n1_ver##${BUILD_TAG}" "${SMOKE_STRINGS_DIR}/${a}.strings" \
		|| die "smoke 3 FAIL: '##m1n1_ver##${BUILD_TAG}' magic not found in ${a}"
	grep -q "chosen.asahi,m1n1-stage1-version=${BUILD_TAG}" "${SMOKE_STRINGS_DIR}/${a}.strings" \
		|| die "smoke 3 FAIL: 'asahi,m1n1-stage1-version=${BUILD_TAG}' not found in ${a}"
done
log "smoke 3 PASS: '##m1n1_ver##${BUILD_TAG}' + 'asahi,m1n1-stage1-version' embedded in m1n1.bin + m1n1.macho (pin-traceable)"

# 4. Build configuration actually applied: the Makefile stamps RELEASE and
#    CHAINLOADING into build/build_cfg.h; assert both, since CHAINLOADING=1
#    is exactly the pmaports knob and the whole reason this stage exists.
CFG_CONTENT="$(cat "${UPSTREAM_DIR}/build/build_cfg.h")"
printf '%s\n' "${CFG_CONTENT}" | grep -qx "#define RELEASE" \
	|| die "smoke 4 FAIL: RELEASE not in build_cfg.h (${CFG_CONTENT})"
printf '%s\n' "${CFG_CONTENT}" | grep -qx "#define CHAINLOADING" \
	|| die "smoke 4 FAIL: CHAINLOADING not in build_cfg.h (${CFG_CONTENT})"
log "smoke 4 PASS: build_cfg.h = RELEASE + CHAINLOADING (pmaports build knobs)"

# 5. Size sanity: raw chainload image and Mach-O payloads must be non-trivial
#    and distinct (different link scripts => different binaries).
for a in "${ARTIFACTS[@]}"; do
	bytes="$(stat -c '%s' "${OUT_DIR}/${a}")"
	[ "${bytes}" -gt 10240 ] || die "smoke 5 FAIL: ${a} suspiciously small (${bytes} bytes)"
	[ "${bytes}" -lt $((16 * 1024 * 1024)) ] || die "smoke 5 FAIL: ${a} suspiciously large (${bytes} bytes)"
done
[ "$(sha256sum "${OUT_DIR}/m1n1.bin" | awk '{print $1}')" != "$(sha256sum "${OUT_DIR}/m1n1.macho" | awk '{print $1}')" ] \
	|| die "smoke 5 FAIL: m1n1.bin and m1n1.macho are identical (link scripts not applied?)"
log "smoke 5 PASS: sizes sane, m1n1.bin != m1n1.macho"

# ------------------------------------------------- resolved crate versions
# From the locked Cargo.lock (build never modifies it — the pristine-tree
# assertion before the build and this read bracket that guarantee).
crate_ver() { awk -v name="$1" '$0 == "name = \"" name "\"" { getline; gsub(/[[:space:]]*version = "|"/, ""); print; exit }' "${UPSTREAM_DIR}/rust/Cargo.lock"; }
CRATE_UUID="$(crate_ver uuid)"
CRATE_BITFLAGS="$(crate_ver bitflags)"
CRATE_LOG="$(crate_ver log)"
CRATE_FATFS="$(crate_ver fatfs)"
log "cargo deps (Cargo.lock): uuid ${CRATE_UUID}, bitflags ${CRATE_BITFLAGS}, log ${CRATE_LOG}, fatfs ${CRATE_FATFS} (path: vendor/rust-fatfs)"

# -------------------------------------------------- generate provenance.json
# artifacts/m1n1/provenance.json is GENERATED here, from what this run
# actually did — never hand-maintained.
FILES_JSON="[]"
for a in "${ARTIFACTS[@]}"; do
	fsha="$(sha256sum "${OUT_DIR}/${a}" | awk '{print $1}')"
	fbytes="$(stat -c '%s' "${OUT_DIR}/${a}")"
	FILES_JSON="$(jq -c --arg path "artifacts/m1n1/${a}" --arg sha "${fsha}" --argjson bytes "${fbytes}" \
		'. + [{path: $path, sha256: $sha, bytes: $bytes}]' <<<"${FILES_JSON}")"
done

DET_OBJECT="$(jq -n \
	--arg method "full clean rebuild of the same pinned tree with the identical recipe (make clean + make RELEASE=1 CHAINLOADING=1, cross-gcc+rustc); all four artifacts sha256-compared between passes" \
	--argjson match "${DET_MATCH}" \
	--arg lines "${DET_LINES%$'\n'}" \
	'{method: $method, match: $match, per_artifact: ($lines | split("\n") | map(split(" ") | {artifact: .[0], pass1_sha256: .[1], pass2_sha256: .[3]}))}')"

LIMITATIONS_JSON='[
  "builds-not-boots: no artifact of the pomme pipeline, including m1n1, has ever been booted on hardware by this project",
  "A12 and newer Apple SoCs are permanently unsupported: no public checkm8-equivalent bootROM exploit exists; this stage does not change that",
  "device coverage is exactly what the pinned HoolockLinux fork implements (Apple Generic iDevice, 4K-page A7/A8-class chain via pongoOS bootm); no additional device support is claimed",
  "BUILD_TAG is git describe output of the pinned clone (abbreviated commit sha here: the depth-1 clone carries no tags); a full-history reclone could change the embedded tag and thus the artifact bytes",
  "the pmaports APKBUILD additionally generates postmarketOS boot logos (inkscape/imagemagick) and renames outputs for Alpine packaging; this stage builds upstream logos/fonts as committed in the clone and keeps upstream output names — deliberate deviation, no functional impact on the pongoOS bootm chain",
  "the pmaports check() step (pytest of the proxyclient against live hardware) is not run here: it requires a device and this pipeline is builds-not-boots"
]'

jq -n \
	--arg stage "m1n1" \
	--arg version "${VERSION}" \
	--arg url "${UPSTREAM_URL}" \
	--arg commit "${UPSTREAM_COMMIT}" \
	--arg commit_date "${PIN_DATE}" \
	--arg license "${UPSTREAM_LICENSE}" \
	--arg built_by "tooling/m1n1/build.sh (pomme m1n1 stage — generated by the build, never hand-maintained)" \
	--arg host "$(uname -s -r -m)$([ -r /etc/os-release ] && printf '; %s' "$(. /etc/os-release && printf '%s' "${PRETTY_NAME}")")" \
	--arg epoch "${SOURCE_DATE_EPOCH}" \
	--arg gcc "${TC_GCC_VERSION}" \
	--arg binutils "${TC_LD_VERSION}" \
	--arg objcopy "${TC_OBJCOPY_VERSION}" \
	--arg rustc "${RUSTC_VERSION}" \
	--arg cargo "${CARGO_VERSION}" \
	--arg rust_target "${RUST_TARGET}" \
	--arg tc_dir "${TC_DIR}" \
	--arg fatfs_rev "${RUST_FATFS_REV}" \
	--arg crates "uuid ${CRATE_UUID}, bitflags ${CRATE_BITFLAGS}, log ${CRATE_LOG}, fatfs ${CRATE_FATFS} (path dep: rust/vendor/rust-fatfs @ ${RUST_FATFS_REV})" \
	--arg build_cmd "make RELEASE=1 CHAINLOADING=1 TOOLCHAIN=${TC_DIR} ARCH=${TC_ARCH} -j\$(nproc)" \
	--argjson patches "${PATCHES_JSON}" \
	--argjson files "${FILES_JSON}" \
	--arg build_log "${BUILD_LOG_REL}" \
	--arg tag "${BUILD_TAG}" \
	--argjson det "${DET_OBJECT}" \
	--argjson limitations "${LIMITATIONS_JSON}" \
	'{stage: $stage, version: $version,
	  upstream_url: $url, upstream_commit: $commit, upstream_commit_date: $commit_date, upstream_license: $license,
	  built_by: $built_by, build_host_os: $host, generated_utc: (now | todateiso8601),
	  pipeline_mode: "builds-not-boots",
	  target: "A7/A8-class 4K-page iDevices: pongoOS-palera1n bootm -> m1n1 -> Linux Image+DTBs+initramfs concatenated as m1n1-linux.bin (pmOS device/testing/device-apple-idevice); A12+ permanently unsupported",
	  artifact_files: $files,
	  build_log: $build_log,
	  toolchain: {
	    cross_gcc: $gcc, cross_binutils_ld: $binutils, cross_objcopy: $objcopy,
	    cross_toolchain_path: $tc_dir,
	    rustc: $rustc, cargo: $cargo, rust_target: $rust_target,
	    source_date_epoch: $epoch,
	    source_date_epoch_note: "set from the pin commit date; nothing in this build chain consumes it (no __DATE__/__TIME__ in upstream src/ or sysinc/; BUILD_TAG comes from git describe)"
	  },
	  sources: {
	    upstream_clone: "upstream/m1n1-apple-idevice (gitignored, depth-1 at the pin, branch state detached)",
	    git_submodule: {path: "rust/vendor/rust-fatfs", rev: $fatfs_rev},
	    cargo_crates_locked: $crates,
	    upstream_tree_pristine: true
	  },
	  build_commands: ["make clean (with toolchain vars)", $build_cmd],
	  make_knobs: ["RELEASE=1", "CHAINLOADING=1"],
	  embedded_build_tag: $tag,
	  patches_applied: $patches,
	  determinism: $det,
	  limitations: $limitations
	}' > "${PROV_FILE}.tmp"
mv "${PROV_FILE}.tmp" "${PROV_FILE}"
jq empty "${PROV_FILE}" || die "provenance.json is not valid JSON"
python3 -m json.tool "${PROV_FILE}" >/dev/null || die "provenance.json failed python3 json.tool validation"
PROV_SHA="$(sha256sum "${PROV_FILE}" | awk '{print $1}')"
log "generated provenance: artifacts/m1n1/provenance.json sha256=${PROV_SHA} ($(stat -c '%s' "${PROV_FILE}") bytes) — valid JSON"

# Provenance vs disk self-check: every recorded artifact path/sha/bytes must
# match the file on disk right now (guards a half-finished install).
while IFS=$'\t' read -r p sha bytes; do
	f="${REPO_ROOT}/${p}"
	[ -f "${f}" ] || die "provenance self-check: ${p} missing on disk"
	[ "$(sha256sum "${f}" | awk '{print $1}')" = "${sha}" ] || die "provenance self-check: ${p} sha mismatch"
	[ "$(stat -c '%s' "${f}")" = "${bytes}" ] || die "provenance self-check: ${p} size mismatch"
done < <(jq -r '.artifact_files[] | [.path, .sha256, (.bytes|tostring)] | @tsv' "${PROV_FILE}")
log "provenance self-check PASS: artifact_files match disk (paths, sha256, bytes)"

if [ "${DET_MATCH}" != "true" ]; then
	die "determinism gate failed — see the determinism section above and in artifacts/m1n1/provenance.json"
fi

log "---------------------------------------- final artifact listing"
( cd "${REPO_ROOT}" && for a in "${ARTIFACTS[@]}"; do
	printf '%s  %s  %s\n' "$(sha256sum "artifacts/m1n1/${a}" | cut -d' ' -f1)" \
		"$(wc -c < "artifacts/m1n1/${a}" | tr -d ' ') bytes" "artifacts/m1n1/${a}"
done )
log "build host disk after: $(df -h "${REPO_ROOT}" | awk 'NR==2{print $4" free ("$5" used)"}')"
log "done (stage=m1n1 version=${VERSION})"
