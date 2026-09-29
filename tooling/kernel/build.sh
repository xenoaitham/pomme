#!/usr/bin/env bash
# pomme kernel stage — Linux arm64 Image + DTBs + modules for iPhone 7 (T8010)
#
# Builds the postmarketOS-lineage Apple iDevice kernel:
#   HoolockLinux/linux @ hoolock-7.0.12 (commit dfa4d42081312dd34ec33ee8d23174309f683188)
# with the 16K-page pmOS config (A9+ SoCs, including T8010, need 16K pages —
# see tooling/kernel/README.md for the citation chain).
#
# Contract (docs/pipeline-conventions.md): set -euo pipefail, non-interactive,
# re-runnable, logs to stdout/stderr (caller redirects). No patches: upstream
# is built as-is.
#
# Outputs:
#   artifacts/kernel/Image            arm64 kernel image
#   artifacts/kernel/dtbs/            apple/*.dtb set only
#   artifacts/kernel/modules.tar.gz   lib/modules/<release>/ layout, stripped
#   tooling/kernel/config-settled.aarch64   exact post-olddefconfig build input
# End with sha256sums of everything produced.

set -euo pipefail

POMME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLING_DIR="${POMME_ROOT}/tooling/kernel"
ARTIFACTS_DIR="${POMME_ROOT}/artifacts/kernel"
UPSTREAM_DIR="${POMME_ROOT}/upstream/linux-hoolock"

UPSTREAM_URL="https://github.com/HoolockLinux/linux"
UPSTREAM_TAG="hoolock-7.0.12"
UPSTREAM_COMMIT="dfa4d42081312dd34ec33ee8d23174309f683188"

# Pinned Bootlin aarch64 glibc toolchain (stable 2026.08-1, gcc 15.3.0).
# Env-overridable for CI runners; if absent locally, fetch the pinned tarball
# (sha256-checked) into upstream/_toolchain/ so the stage is self-contained.
TOOLCHAIN_TARBALL_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2026.08-1.tar.xz"
TOOLCHAIN_TARBALL_SHA256="0213efac9b5577f20d58de9431960a191347ffc2257b27ffe7250522bf1f7867"
TOOLCHAIN_BASEDIR="${POMME_TOOLCHAIN_DIR:-/home/potato/toolchains}"
TOOLCHAIN_TARBALL="${TOOLCHAIN_TARBALL:-${TOOLCHAIN_BASEDIR}/aarch64-toolchain.tar.xz}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-${TOOLCHAIN_BASEDIR}/aarch64--glibc--stable-2026.08-1}"

CONFIG_IN="${TOOLING_DIR}/config-postmarketos-apple-16k.aarch64"
CONFIG_SETTLED="${TOOLING_DIR}/config-settled.aarch64"

# Resource budget: 12 cores but ~6.3 GB usable RAM; -j8 fits, -j4 fallback on OOM
JOBS="${JOBS:-8}"

# Reproducible-ish output: pin embed time/version/user/host
export KBUILD_BUILD_TIMESTAMP="@1781232000"   # 2026-06-12T00:00:00Z (kernel upstream pin date, UTC)
export KBUILD_BUILD_VERSION="1"
export KBUILD_BUILD_USER="pomme"
export KBUILD_BUILD_HOST="pomme"
export LC_ALL=C

log() { printf '[kernel-build] %s\n' "$*"; }
die() { printf '[kernel-build] FATAL: %s\n' "$*" >&2; exit 1; }

command -v make >/dev/null || die "make not found"
command -v bc >/dev/null || die "bc not found"
command -v bison >/dev/null || die "bison not found"
command -v flex >/dev/null || die "flex not found"
command -v depmod >/dev/null || die "depmod (kmod) not found"
command -v zstd >/dev/null || die "zstd not found (needed for CONFIG_MODULE_COMPRESS_ZSTD)"

# Self-contained toolchain: fetch the pinned tarball (sha256-checked) if the
# cross gcc is not already on disk. Never trusts the download without hashing.
CROSS_COMPILE="${TOOLCHAIN_ROOT}/bin/aarch64-buildroot-linux-gnu-"
if [ ! -x "${CROSS_COMPILE}gcc" ]; then
    log "cross toolchain not found at ${TOOLCHAIN_ROOT}; fetching pinned tarball"
    mkdir -p "${TOOLCHAIN_BASEDIR}"
    if [ ! -f "${TOOLCHAIN_TARBALL}" ]; then
        curl -fSL --retry 3 -o "${TOOLCHAIN_TARBALL}" "${TOOLCHAIN_TARBALL_URL}"
    fi
    echo "${TOOLCHAIN_TARBALL_SHA256}  ${TOOLCHAIN_TARBALL}" | sha256sum -c - \
        || die "toolchain tarball sha256 mismatch: ${TOOLCHAIN_TARBALL}"
    tar -xf "${TOOLCHAIN_TARBALL}" -C "${TOOLCHAIN_BASEDIR}"
    [ -x "${CROSS_COMPILE}gcc" ] || die "cross gcc still missing after fetch at ${CROSS_COMPILE}gcc"
fi
[ -x "${CROSS_COMPILE}gcc" ] || die "cross gcc missing at ${CROSS_COMPILE}gcc"

log "host: $(uname -sr), $(nproc) cores"
log "cross gcc: $(${CROSS_COMPILE}gcc --version | head -1)"

# ---------------------------------------------------------------- upstream ---
log "checking upstream tree ${UPSTREAM_DIR}"
if [ ! -d "${UPSTREAM_DIR}/.git" ]; then
    log "upstream missing -> shallow clone ${UPSTREAM_URL} at tag ${UPSTREAM_TAG}"
    rm -rf "${UPSTREAM_DIR}"
    git clone --depth 1 --branch "${UPSTREAM_TAG}" "${UPSTREAM_URL}" "${UPSTREAM_DIR}"
else
    log "upstream present; verifying pin"
fi
ACTUAL_SHA="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)"
[ "${ACTUAL_SHA}" = "${UPSTREAM_COMMIT}" ] || die "upstream SHA mismatch: have ${ACTUAL_SHA}, want ${UPSTREAM_COMMIT} (delete ${UPSTREAM_DIR} or fix the pin)"
log "upstream verified: ${ACTUAL_SHA} ($(git -C "${UPSTREAM_DIR}" log -1 --format=%ci HEAD))"

# ---------------------------------------------------------------- patches ----
# Every deviation from upstream lives in patches/kernel/ and is applied here
# (conventions: never edit the vendored tree by hand).
PATCH_DIR="${POMME_ROOT}/patches/kernel"
for p in "${PATCH_DIR}"/*.patch; do
    [ -e "${p}" ] || break
    if git -C "${UPSTREAM_DIR}" apply --check "${p}" 2>/dev/null; then
        git -C "${UPSTREAM_DIR}" apply "${p}"
        log "applied patch: $(basename "${p}")"
    elif git -C "${UPSTREAM_DIR}" apply --reverse --check "${p}" 2>/dev/null; then
        log "patch already applied, skipping: $(basename "${p}")"
    else
        die "patch does not apply to pinned tree: ${p}"
    fi
done

BUILD_START="$(date +%s)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------------ config ---
log "config in: ${CONFIG_IN}"
[ -f "${CONFIG_IN}" ] || die "config missing: ${CONFIG_IN}"
log "config-in sha256: $(sha256sum "${CONFIG_IN}" | awk '{print $1}')"

OUT_DIR="${UPSTREAM_DIR}/out"
MAKE="make -C ${UPSTREAM_DIR} O=${OUT_DIR} ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE}"

mkdir -p "${OUT_DIR}" "${ARTIFACTS_DIR}"

log "olddefconfig (settles any new symbols against the pinned config)"
cp "${CONFIG_IN}" "${OUT_DIR}/.config"
${MAKE} olddefconfig
cp "${OUT_DIR}/.config" "${CONFIG_SETTLED}"
log "settled config -> ${CONFIG_SETTLED} (sha256: $(sha256sum "${CONFIG_SETTLED}" | awk '{print $1}'))"
log "toolchain as seen by kconfig: CC=$(${CROSS_COMPILE}gcc -dumpfullversion)$(grep -E '^CONFIG_CC_IS_GCC' "${CONFIG_SETTLED}" >/dev/null && echo ' (CC_IS_GCC=y)' || echo ' (CC_IS_GCC NOT SET!)')"
grep -q '^CONFIG_RUST=y' "${CONFIG_SETTLED}" && log "note: CONFIG_RUST=y survived" || log "note: CONFIG_RUST dropped by olddefconfig (no rustc/bindgen for the GCC toolchain; no boot-critical driver needs it)"
grep -q '^CONFIG_ARM64_16K_PAGES=y' "${CONFIG_SETTLED}" || die "settled config lost CONFIG_ARM64_16K_PAGES"
log "CONFIG_ARM64_16K_PAGES=y confirmed in settled config"

# ------------------------------------------------------------------- build ---
log "building Image + dtbs with -j${JOBS} (this is the long part; expect several GB of RAM use)"
set +e
${MAKE} -j"${JOBS}" Image dtbs modules 2>&1
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
    if [ "${JOBS}" -gt 4 ]; then
        log "build failed rc=${RC} (possibly OOM) -> retrying with -j4"
        JOBS=4
        ${MAKE} -j"${JOBS}" Image dtbs modules 2>&1
    else
        exit "${RC}"
    fi
fi

KERNEL_RELEASE="$(${MAKE} -s kernelrelease)"
log "kernel release: ${KERNEL_RELEASE}"

# ----------------------------------------------------------------- install ---
log "installing dtbs (full set to staging, apple/ subset shipped)"
DTB_STAGE="${OUT_DIR}/dtbs-install"
rm -rf "${DTB_STAGE}"
${MAKE} -j"${JOBS}" INSTALL_DTBS_PATH="${DTB_STAGE}" dtbs_install
[ -d "${DTB_STAGE}/apple" ] || die "no apple/ DTBs installed"
APPLE_DTBS="$(find "${DTB_STAGE}/apple" -name '*.dtb' | wc -l)"
log "apple DTBs installed: ${APPLE_DTBS}"

log "installing modules (stripped) to staging with INSTALL_MOD_PATH"
MOD_STAGE="${OUT_DIR}/modules-staging"
rm -rf "${MOD_STAGE}"
${MAKE} -j"${JOBS}" INSTALL_MOD_PATH="${MOD_STAGE}" INSTALL_MOD_STRIP=1 modules_install
[ -d "${MOD_STAGE}/lib/modules/${KERNEL_RELEASE}" ] || die "modules_install produced no lib/modules/${KERNEL_RELEASE}"

# ----------------------------------------------------------------- package ---
log "packaging artifacts into ${ARTIFACTS_DIR}"
rm -rf "${ARTIFACTS_DIR}/Image" "${ARTIFACTS_DIR}/dtbs" "${ARTIFACTS_DIR}/modules.tar.gz"
cp "${OUT_DIR}/arch/arm64/boot/Image" "${ARTIFACTS_DIR}/Image"
mkdir -p "${ARTIFACTS_DIR}/dtbs"
cp -a "${DTB_STAGE}/apple/." "${ARTIFACTS_DIR}/dtbs/"

# tarball keeps lib/modules/<release>/ as its layout (no leading /);
# deterministic flags (sorted names, fixed owner/mtime) so re-runs hash equal
tar -C "${MOD_STAGE}" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${KBUILD_BUILD_TIMESTAMP#@}" -czf "${ARTIFACTS_DIR}/modules.tar.gz" "lib/modules/${KERNEL_RELEASE}"
MODULE_COUNT="$(find "${MOD_STAGE}/lib/modules/${KERNEL_RELEASE}" -name '*.ko*' | wc -l)"
log "modules in tarball: ${MODULE_COUNT}"

BUILD_END="$(date +%s)"
WALL=$((BUILD_END - BUILD_START))

# ------------------------------------------------------------- sanity check ---
log "--- sanity checks ---"
file "${ARTIFACTS_DIR}/Image" || true
if command -v fdtdump >/dev/null; then
    log "t8010-d10.dtb model: $(fdtdump "${ARTIFACTS_DIR}/dtbs/t8010-d10.dtb" 2>/dev/null | grep -m1 'model =')"
    log "t8010-d101.dtb model: $(fdtdump "${ARTIFACTS_DIR}/dtbs/t8010-d101.dtb" 2>/dev/null | grep -m1 'model =')"
else
    log "fdtdump not available; skipping dtb model check (strings fallback):"
    log "t8010-d10.dtb: $(strings "${ARTIFACTS_DIR}/dtbs/t8010-d10.dtb" | grep -m1 'iPhone') "
fi
for want in t8010-d10.dtb t8010-d101.dtb; do
    [ -f "${ARTIFACTS_DIR}/dtbs/${want}" ] || die "expected DTB missing: ${want}"
done
log "iPhone 7 / 7+ DTBs present (t8010-d10.dtb, t8010-d101.dtb)"

log "toolchain tarball sha256: $(sha256sum "${TOOLCHAIN_TARBALL}" | awk '{print $1}')  (${TOOLCHAIN_TARBALL})"
log "wall time: ${WALL}s"

log "--- sha256sums of everything produced ---"
sha256sum "${CONFIG_IN}" "${CONFIG_SETTLED}" "${ARTIFACTS_DIR}/Image" "${ARTIFACTS_DIR}/modules.tar.gz"
find "${ARTIFACTS_DIR}/dtbs" -name '*.dtb' | sort | xargs sha256sum
log "artifact sizes:"
ls -l "${ARTIFACTS_DIR}/Image" "${ARTIFACTS_DIR}/modules.tar.gz"
du -sb "${ARTIFACTS_DIR}/dtbs"

log "DONE stage=kernel release=${KERNEL_RELEASE} wall=${WALL}s"
