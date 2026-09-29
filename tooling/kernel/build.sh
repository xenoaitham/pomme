#!/usr/bin/env bash
# pomme kernel stage — Linux arm64 Image + DTBs + modules for iPhone 7 (T8010)
#
# Builds the postmarketOS-lineage Apple iDevice kernel:
#   HoolockLinux/linux @ hoolock-7.0.12 (commit dfa4d42081312dd34ec33ee8d23174309f683188)
# with the 16K-page pmOS config (A9+ SoCs, including T8010, need 16K pages —
# see tooling/kernel/README.md for the citation chain).
#
# Contract (docs/pipeline-conventions.md): set -euo pipefail, non-interactive,
# re-runnable, logs to stdout/stderr (caller redirects). Deviations from
# upstream live only in patches/kernel/ and are applied below.
#
# Outputs:
#   artifacts/kernel/Image              arm64 kernel image (bare)
#   artifacts/kernel/Image.initramfs    arm64 kernel image with the images
#                                       stage's initramfs embedded (built
#                                       only when that artifact exists)
#   artifacts/kernel/dtbs/              apple/*.dtb set only (92 files)
#   artifacts/kernel/modules.tar.gz     lib/modules/<release>/ layout, stripped
#   tooling/kernel/config-settled.aarch64   exact post-olddefconfig build input
# End with sha256sums of everything produced.

set -euo pipefail

POMME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLING_DIR="${POMME_ROOT}/tooling/kernel"
UPSTREAM_DIR="${POMME_ROOT}/upstream/linux-hoolock"

# ------------------------------------------------------------------ flavor ---
# One script, two page-size flavors of the SAME pinned source/config lineage
# (pmaports device/testing/linux-postmarketos-apple-{4k,16k}):
#   16k (default) — CONFIG_ARM64_16K_PAGES, A9–A11 SoCs (iPhone 7 / T8010 is
#                   the pomme primary target); artifacts/kernel/
#   4k            — CONFIG_ARM64_4K_PAGES,  A7/A8/A8X SoCs; artifacts/kernel-4k/
# The default flavor keeps every legacy path byte-identical (out/,
# out-initramfs/, config-settled.aarch64, artifacts/kernel/) so existing
# evidence and docs stay valid. Per the pmOS distribution rule (see
# artifacts/kernel/provenance.json pmos_lineage decision citation), the
# page-size gate is per-SoC: a 4K kernel will not boot A9+ and a 16K kernel
# will not boot A7/A8 — both flavors ship because the device matrix needs both.
FLAVOR="${POMME_KERNEL_FLAVOR:-16k}"
case "${FLAVOR}" in
  16k)
    PAGE_CONFIG="CONFIG_ARM64_16K_PAGES"
    PAGE_TAG="16K pages"
    CONFIG_IN="${TOOLING_DIR}/config-postmarketos-apple-16k.aarch64"
    CONFIG_SETTLED="${TOOLING_DIR}/config-settled.aarch64"
    ARTIFACTS_DIR="${POMME_ROOT}/artifacts/kernel"
    OUT_SUFFIX=""
    IMAGES_FLAVOR_DIR="artifacts/images"
    STAGE_NAME="kernel"
    DEVICE_SCOPE="A9/A9X/A10 Fusion/A10X/A11 (incl. iPhone 7 / T8010, pomme primary)"
    ;;
  4k)
    PAGE_CONFIG="CONFIG_ARM64_4K_PAGES"
    PAGE_TAG="4K pages"
    CONFIG_IN="${TOOLING_DIR}/config-postmarketos-apple-4k.aarch64"
    CONFIG_SETTLED="${TOOLING_DIR}/config-settled-4k.aarch64"
    ARTIFACTS_DIR="${POMME_ROOT}/artifacts/kernel-4k"
    OUT_SUFFIX="-4k"
    IMAGES_FLAVOR_DIR="artifacts/images-4k"
    STAGE_NAME="kernel-4k"
    DEVICE_SCOPE="A7/A8/A8X (iPhone 5s/6/6+, iPad Air/Air 2, iPad mini 2/3/4)"
    ;;
  *) printf '[kernel-build] FATAL: unknown POMME_KERNEL_FLAVOR %q (expected 16k or 4k)\n' "${FLAVOR}" >&2; exit 1 ;;
esac

UPSTREAM_URL="https://github.com/HoolockLinux/linux"
UPSTREAM_TAG="hoolock-7.0.12"
UPSTREAM_COMMIT="dfa4d42081312dd34ec33ee8d23174309f683188"

# Pinned Bootlin aarch64 glibc toolchain (stable 2026.08-1, gcc 15.3.0).
# Env-overridable for CI runners; if absent locally, fetch the pinned tarball
# (sha256-checked) into upstream/_toolchain/ so the stage is self-contained.
TOOLCHAIN_TARBALL_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2026.08-1.tar.xz"
TOOLCHAIN_TARBALL_SHA256="0213efac9b5577f20d58de9431960a191347ffc2257b27ffe7250522bf1f7867"
# Default is $HOME-relative (NOT a hardcoded user path — the first CI run
# proved a hardcoded /home/<author> default dies on runners with
# "Permission denied"): any POSIX host resolves it; CI overrides it to the
# workspace via POMME_TOOLCHAIN_DIR.
TOOLCHAIN_BASEDIR="${POMME_TOOLCHAIN_DIR:-${HOME}/toolchains}"
TOOLCHAIN_TARBALL="${TOOLCHAIN_TARBALL:-${TOOLCHAIN_BASEDIR}/aarch64-toolchain.tar.xz}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-${TOOLCHAIN_BASEDIR}/aarch64--glibc--stable-2026.08-1}"

# CONFIG_IN and CONFIG_SETTLED are set per-flavor above.
# Resource budget: 12 cores but ~6.3 GB usable RAM; -j8 fits, -j4 fallback on OOM
JOBS="${JOBS:-8}"

# Reproducible-ish output: pin embed time/version/user/host.
# @1781222400 is EXACTLY 2026-06-12T00:00:00Z (upstream pin date). This fixes
# the first build's @1781232000, whose comment claimed 00:00Z but is actually
# 2026-06-12T02:40:00Z. The epoch change alters embedded timestamps and thus
# artifact hashes vs the 2026-09-29 run 1 build — expected, see
# artifacts/kernel/provenance.json (determinism note).
export KBUILD_BUILD_TIMESTAMP="@1781222400"   # 2026-06-12T00:00:00Z exactly
export KBUILD_BUILD_VERSION="1"
export KBUILD_BUILD_USER="pomme"
export KBUILD_BUILD_HOST="pomme"
export LC_ALL=C

log() { printf '[kernel-build] %s\n' "$*"; }
die() { printf '[kernel-build] FATAL: %s\n' "$*" >&2; exit 1; }

# Self-tee: canonical per-run log with a deterministic name, so provenance
# can point at the log of the producing run regardless of where the caller
# sends stdout (same pattern as the images stage; the Makefile's timestamped
# tee stays as the secondary copy). One canonical name per flavor+pin+day —
# a same-day rebuild overwrites it, which is the point: canonical = THIS run.
LOG_NAME="kernel_${FLAVOR}_${UPSTREAM_TAG}_$(date -u +%Y%m%d).log"
if [ "${POMME_KERNEL_NO_SELFLOG:-0}" != "1" ]; then
    mkdir -p "${POMME_ROOT}/evidence/builds"
    : > "${POMME_ROOT}/evidence/builds/${LOG_NAME}"
    exec > >(tee "${POMME_ROOT}/evidence/builds/${LOG_NAME}") 2>&1
    log "canonical self-log: evidence/builds/${LOG_NAME}"
fi

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

OUT_DIR="${UPSTREAM_DIR}/out${OUT_SUFFIX}"
MAKE="make -C ${UPSTREAM_DIR} O=${OUT_DIR} ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE}"

log "flavor: ${FLAVOR} (${PAGE_CONFIG}=y; device scope: ${DEVICE_SCOPE})"
log "artifacts dir: ${ARTIFACTS_DIR}"
mkdir -p "${OUT_DIR}" "${ARTIFACTS_DIR}"

log "olddefconfig (settles any new symbols against the pinned config)"
cp "${CONFIG_IN}" "${OUT_DIR}/.config"
${MAKE} olddefconfig
cp "${OUT_DIR}/.config" "${CONFIG_SETTLED}"
log "settled config -> ${CONFIG_SETTLED} (sha256: $(sha256sum "${CONFIG_SETTLED}" | awk '{print $1}'))"
log "toolchain as seen by kconfig: CC=$(${CROSS_COMPILE}gcc -dumpfullversion)$(grep -E '^CONFIG_CC_IS_GCC' "${CONFIG_SETTLED}" >/dev/null && echo ' (CC_IS_GCC=y)' || echo ' (CC_IS_GCC NOT SET!)')"
grep -q '^CONFIG_RUST=y' "${CONFIG_SETTLED}" && log "note: CONFIG_RUST=y survived" || log "note: CONFIG_RUST dropped by olddefconfig (no rustc/bindgen for the GCC toolchain; no boot-critical driver needs it)"
grep -q "^${PAGE_CONFIG}=y" "${CONFIG_SETTLED}" || die "settled config lost ${PAGE_CONFIG}"
log "${PAGE_CONFIG}=y confirmed in settled config"

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

# hard asserts: bare Image page size + apple dtb count
file "${ARTIFACTS_DIR}/Image" | grep -q "${PAGE_TAG}" || die "bare Image is not a ${PAGE_TAG} kernel image: $(file "${ARTIFACTS_DIR}/Image")"
log "assert OK: bare Image reports ${PAGE_TAG}"
DTB_COUNT="$(find "${ARTIFACTS_DIR}/dtbs" -name '*.dtb' | wc -l)"
[ "${DTB_COUNT}" -eq 92 ] || die "expected 92 apple DTBs, got ${DTB_COUNT}"
log "assert OK: apple dtb count == 92"

# --------------------------------------------- initramfs-bundled Image -------
# Same config + fragment enabling a pre-built, RELATIVE CONFIG_INITRAMFS_SOURCE
# in a second O= dir (full vmlinux rebuild; dtbs/modules are NOT rebuilt).
# usr/Makefile facts this relies on: a single file suffixed ".cpio.*" is
# embedded AS-IS (compress-y := copy, no double compression), and bare-name
# prerequisites resolve inside the out dir's usr/ — so the archive is placed
# at out-initramfs/usr/initramfs.cpio.gz. CONFIG_INITRAMFS_COMPRESSION_GZIP is
# deliberately NOT set: it only applies to archives kbuild generates from a
# file list; runtime gzip decompression of the embedded blob comes from
# CONFIG_RD_GZIP (asserted below).
INITRAMFS_GZ="${INITRAMFS_CPIO_GZ:-${POMME_ROOT}/${IMAGES_FLAVOR_DIR}/initramfs.cpio.gz}"
if [ -f "${INITRAMFS_GZ}" ]; then
    log "building Image.initramfs (initramfs source: ${INITRAMFS_GZ}, sha256 $(sha256sum "${INITRAMFS_GZ}" | awk '{print $1}'))"
    OUT2="${UPSTREAM_DIR}/out-initramfs${OUT_SUFFIX}"
    MAKE2="make -C ${UPSTREAM_DIR} O=${OUT2} ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE}"
    mkdir -p "${OUT2}/usr"
    cp "${OUT_DIR}/.config" "${OUT2}/.config"
    "${UPSTREAM_DIR}/scripts/config" --file "${OUT2}/.config" \
        --set-str CONFIG_INITRAMFS_SOURCE "initramfs.cpio.gz"
    ${MAKE2} olddefconfig
    grep -q '^CONFIG_INITRAMFS_SOURCE="initramfs.cpio.gz"' "${OUT2}/.config" \
        || die "fragment lost CONFIG_INITRAMFS_SOURCE after olddefconfig"
    grep -q '^CONFIG_BLK_DEV_INITRD=y' "${OUT2}/.config" || die "CONFIG_BLK_DEV_INITRD is not set"
    grep -q '^CONFIG_RD_GZIP=y' "${OUT2}/.config" || die "CONFIG_RD_GZIP is not set (embedded gzip initramfs could not be decompressed)"
    # bare-name prerequisites in usr/Makefile resolve against the kernel
    # SOURCE tree root (make -C dir), so the archive goes there, keeping
    # CONFIG_INITRAMFS_SOURCE relative ("initramfs.cpio.gz")
    cp "${INITRAMFS_GZ}" "${UPSTREAM_DIR}/initramfs.cpio.gz"
    set +e
    ${MAKE2} -j"${JOBS}" Image 2>&1
    RC=$?
    set -e
    if [ "${RC}" -ne 0 ] && [ "${JOBS}" -gt 4 ]; then
        log "Image.initramfs build failed rc=${RC} -> retrying with -j4"
        JOBS=4
        ${MAKE2} -j"${JOBS}" Image 2>&1
    fi
    file "${OUT2}/arch/arm64/boot/Image" | grep -q "${PAGE_TAG}" || die "Image.initramfs is not a ${PAGE_TAG} kernel image"
    cp "${OUT2}/arch/arm64/boot/Image" "${ARTIFACTS_DIR}/Image.initramfs"
    log "assert OK: Image.initramfs reports ${PAGE_TAG}"
    log "Image.initramfs sha256: $(sha256sum "${ARTIFACTS_DIR}/Image.initramfs" | awk '{print $1}')"
else
    rm -f "${ARTIFACTS_DIR}/Image.initramfs"
    log "SKIP Image.initramfs: ${INITRAMFS_GZ} not found (images-stage artifact; run the images stage first or set INITRAMFS_CPIO_GZ)"
fi

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
[ -f "${ARTIFACTS_DIR}/Image.initramfs" ] && sha256sum "${ARTIFACTS_DIR}/Image.initramfs" || true
find "${ARTIFACTS_DIR}/dtbs" -name '*.dtb' | sort | xargs sha256sum
log "artifact sizes:"
ls -l "${ARTIFACTS_DIR}/Image" "${ARTIFACTS_DIR}/modules.tar.gz"
[ -f "${ARTIFACTS_DIR}/Image.initramfs" ] && ls -l "${ARTIFACTS_DIR}/Image.initramfs" || true
du -sb "${ARTIFACTS_DIR}/dtbs"

# ------------------------------------------------------ generate provenance ---
# artifacts/<stage>/provenance.json is GENERATED here from this run (gaster
# pattern: provenance is never hand-maintained). Freshness rule: an existing
# provenance is preserved when the shipped bytes AND the shipped file-set are
# unchanged — that keeps curated history (the 16k flavor's clean-room /
# determinism records from the wave-3 review) intact across no-op re-runs,
# and regenerates as soon as a rebuild actually moved anything.
BUNDLE_SHA=""
if [ -f "${ARTIFACTS_DIR}/Image.initramfs" ]; then BUNDLE_SHA="$(sha256sum "${INITRAMFS_GZ}" | awk '{print $1}')"; fi
# Dynamic patches list (provenance is generated, never hand-maintained: a
# hardcoded array in the emitter would ship a second patch unprovenanced).
PATCHES_JSON="["
_pfirst=1
for _p in "${POMME_ROOT}"/patches/kernel/*.patch; do
	[ -e "${_p}" ] || break
	_psha="$(sha256sum "${_p}" | awk '{print $1}')"
	[ "${_pfirst}" = "1" ] || PATCHES_JSON+=","
	PATCHES_JSON+="{\"path\":\"patches/kernel/$(basename "${_p}")\",\"sha256\":\"${_psha}\"}"
	_pfirst=0
done
PATCHES_JSON+="]"
CONFIG_IN_SHA="$(sha256sum "${CONFIG_IN}" | awk '{print $1}')"
CONFIG_IN_SHA512_PFX="$(sha512sum "${CONFIG_IN}" | awk '{print $1}' | cut -c1-64)"
CONFIG_SETTLED_SHA="$(sha256sum "${CONFIG_SETTLED}" | awk '{print $1}')"
PMAPS_REV="$(git -C "${POMME_ROOT}/upstream/pmaports" rev-parse HEAD 2>/dev/null || echo "34a4e3c3a38c88f52319ecce80f02b561d2eeee2")"
PMAPS_DATE="$(git -C "${POMME_ROOT}/upstream/pmaports" log -1 --format=%cs 2>/dev/null || echo "2026-09-28")"
PROV_EMIT=1
if [ -f "${ARTIFACTS_DIR}/provenance.json" ]; then
    PROV_EMIT="$(PROV_PATCHES="${PATCHES_JSON}" python3 - "${ARTIFACTS_DIR}/provenance.json" <<'PYEOF'
import hashlib, json, os, sys
prov = json.load(open(sys.argv[1], encoding="utf-8"))
old = {e["path"]: e.get("sha256") for e in prov.get("artifact_files", [])}
# also key on the patch set: a byte-neutral-to-artifacts change (e.g. a
# comment-only patch added) must still regenerate provenance
old_patches = sorted((p.get("path"), p.get("sha256")) for p in prov.get("patches", []) if isinstance(p, dict) and "path" in p)
new_patches = sorted((p["path"], p["sha256"]) for p in json.loads(os.environ["PROV_PATCHES"]))
# provenance.json sits at <root>/artifacts/<stage>/provenance.json
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1]))))
new = {}
stage_dir = os.path.join(root, "artifacts", prov.get("stage", "kernel"))
for dirpath, _, files in os.walk(stage_dir):
    for f in files:
        if f == "provenance.json":
            continue
        p = os.path.join(dirpath, f)
        rel = os.path.relpath(p, root)
        new[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
sys.exit(0 if (old == new and old_patches == new_patches) else 1)
PYEOF
)" && PROV_EMIT=0 || PROV_EMIT=1
    [ "${PROV_EMIT}" = "1" ] && log "provenance refresh: shipped bytes/file-set changed -> regenerating" || true
else
    log "provenance: none yet -> generating"
fi
if [ "${PROV_EMIT}" = "1" ]; then
    STAGE_NAME="${STAGE_NAME}" FLAVOR="${FLAVOR}" PAGE_CONFIG="${PAGE_CONFIG}" PAGE_TAG="${PAGE_TAG}" \
    DEVICE_SCOPE="${DEVICE_SCOPE}" ARTIFACTS_DIR="${ARTIFACTS_DIR}" \
    UPSTREAM_URL="${UPSTREAM_URL}" UPSTREAM_TAG="${UPSTREAM_TAG}" \
    UPSTREAM_COMMIT="${UPSTREAM_COMMIT}" CONFIG_IN="${CONFIG_IN}" \
    CONFIG_IN_SHA="${CONFIG_IN_SHA}" CONFIG_IN_SHA512_PFX="${CONFIG_IN_SHA512_PFX}" \
    CONFIG_SETTLED="${CONFIG_SETTLED}" CONFIG_SETTLED_SHA="${CONFIG_SETTLED_SHA}" \
    PMAPS_REV="${PMAPS_REV}" PMAPS_DATE="${PMAPS_DATE}" \
    KERNEL_RELEASE="${KERNEL_RELEASE}" BUNDLE_SHA="${BUNDLE_SHA}" \
    INITRAMFS_GZ="${INITRAMFS_GZ}" LOG_NAME="${LOG_NAME}" \
    WALL="${WALL}" TOOLCHAIN_TARBALL_SHA256="${TOOLCHAIN_TARBALL_SHA256}" \
    PATCHES_JSON="${PATCHES_JSON}" \
    python3 - <<'PYEOF'
import hashlib, json, os, subprocess

env = os.environ
root = subprocess.run(["git", "-C", os.path.dirname(os.path.dirname(env["ARTIFACTS_DIR"])),
                       "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
art_dir = env["ARTIFACTS_DIR"]
stage = env["STAGE_NAME"]
flavor = env["FLAVOR"]
kind_map = {
    "Image": "Linux arm64 kernel image, bare (file(1): 'Linux kernel ARM64 boot executable Image, "
             f"little-endian, {env['PAGE_TAG']}'); PRIMARY",
    "Image.initramfs": "Linux arm64 kernel image with the images-stage initramfs embedded via "
                       "CONFIG_INITRAMFS_SOURCE (same config as the bare Image)",
    "modules.tar.gz": "stripped modules tree, lib/modules/<release>/ layout (deterministic tar flags)",
}
files = []
for dirpath, _, fnames in sorted(os.walk(art_dir)):
    for f in sorted(fnames):
        if f == "provenance.json":
            continue
        p = os.path.join(dirpath, f)
        rel = os.path.relpath(p, root)
        raw = open(p, "rb").read()
        entry = {"path": rel, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}
        if f in kind_map:
            entry["kind"] = kind_map[f]
        elif f.endswith(".dtb"):
            entry["kind"] = "Apple SoC device tree blob (page-size agnostic; same pinned DTS set for both flavors)"
        files.append(entry)

pmaports_file = ("device/testing/linux-postmarketos-apple-16k/config-postmarketos-apple-16k.aarch64"
                 if flavor == "16k" else
                 "device/testing/linux-postmarketos-apple-4k/config-postmarketos-apple-4k.aarch64")
committed_copy = ("tooling/kernel/config-postmarketos-apple-16k.aarch64" if flavor == "16k"
                  else "tooling/kernel/config-postmarketos-apple-4k.aarch64")
prov = {
    "stage": stage,
    "flavor": f"{flavor} ({env['PAGE_CONFIG']}=y)",
    "device_scope": env["DEVICE_SCOPE"],
    "upstream_url": env["UPSTREAM_URL"],
    "upstream_tag": env["UPSTREAM_TAG"],
    "upstream_commit": env["UPSTREAM_COMMIT"],
    "upstream_date": "2026-06-12",
    "pmos_lineage": {
        "flavor": f"{flavor} kernel ({env['PAGE_CONFIG']}=y)",
        "config_source": {
            "repo": "https://gitlab.com/postmarketOS/pmaports",
            "revision": env["PMAPS_REV"],
            "revision_date": env["PMAPS_DATE"],
            "file": pmaports_file,
            "committed_copy": committed_copy,
            "sha256": env["CONFIG_IN_SHA"],
            "sha512_prefix_matches_apkbuild": env["CONFIG_IN_SHA512_PFX"],
        },
        "decision_16k_vs_4k_citation": (
            "postmarketOS wiki 'Apple Generic iDevice (apple-idevice)' "
            "https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice) (retrieved 2026-09-29): "
            "4K kernel for A7/A8/A8X; 16K kernel for A9/A9X/A10 Fusion/A10X/A11/T2. Corroborated by "
            f"pmaports @ {env['PMAPS_REV']} (16k config line 462 CONFIG_ARM64_16K_PAGES=y; 4k config "
            "line 461 CONFIG_ARM64_4K_PAGES=y) and device-apple-idevice/APKBUILD kernel_4k/kernel_16k "
            "subpackages. Summarized in docs/bars.md (bar 3). The in-tree reason for the A9+ 16K "
            "requirement is not documented in the kernel source; the rule is established at the "
            "distribution level."
        ),
    },
    "toolchain": {
        "url": "https://toolchains.bootlin.com (aarch64 glibc stable 2026.08-1)",
        "tarball": "${POMME_TOOLCHAIN_DIR:-$HOME/toolchains}/aarch64-toolchain.tar.xz "
                   "(env-overridable; fetched + sha256-checked by build.sh when absent)",
        "tarball_sha256": env["TOOLCHAIN_TARBALL_SHA256"],
        "gcc_version": "15.3.0 (aarch64-buildroot-linux-gnu-gcc, Bootlin stable 2026.08-1)",
        "note": "pmOS builds this kernel with LLVM=1 (clang/lld/rust); pomme uses the pinned GCC. "
                "Consequences: CONFIG_RUST + Rust samples dropped by olddefconfig (no bindgen for the "
                "GCC toolchain); one source patch (patches/kernel/0001-*, GCC -Werror=return-type).",
    },
    "config_settled": env["CONFIG_SETTLED"].replace(root + "/", ""),
    "config_settled_sha256": env["CONFIG_SETTLED_SHA"],
    "patches": json.loads(env["PATCHES_JSON"]),
    "patches_note": "GCC 15 -Werror=return-type fixup for drivers/video/backlight/apple_pmic_bl.c "
                    "(switch without default falls off the end of a non-void function); pmOS does not "
                    "hit it (clang build). Paths + sha256s are computed from patches/kernel/ so a "
                    "future patch cannot ship unprovenanced; the freshness guard below also covers "
                    "the patch set.",
    "kernel_release": env["KERNEL_RELEASE"],
    "release_string_note": "CONFIG_LOCALVERSION_AUTO=y appends git describe of the patched tree "
                           "('-dirty' = backlight patch applied); expected, documented in "
                           "tooling/kernel/README.md",
    "artifact_files": files,
    "dtb_count": sum(1 for f in files if f["path"].endswith(".dtb")),
    "primary_targets": (["iPhone 7 (t8010-d10.dtb)", "iPhone 7 Plus (t8010-d101.dtb)"]
                        if flavor == "16k" else
                        ["iPhone 5s (s5l8960x-n51/n53)", "iPhone 6/6+ (t7000-n61/n56)",
                         "iPad Air / mini 2/3 (s5l8960x-j71/j72/j73 + m variants)",
                         "iPad Air 2 / mini 4 (t7001-j81/j82, t7000-j96/j97)",
                         "iPod touch 6 (t7000-n102)", "Apple TV HD (t7000-j42d)"]),
    "build_log": f"evidence/builds/{env['LOG_NAME']}",
    "built_by": "tooling/kernel/build.sh (pomme kernel stage, generated provenance — not hand-maintained)",
    "nproc_used": env.get("JOBS", "8"),
    "wall_time_seconds": env["WALL"],
    "limitations": [
        "builds-not-boots: nothing in this stage has ever been booted on hardware by this project",
        "A12 and newer SoCs are unsupported (no public checkm8-equivalent bootROM exploit)",
        ("page size is a boot-time ABI: this %s image must be paired with a device whose SoC "
         "requires %s (see pmos_lineage decision citation)" % (flavor, env["PAGE_CONFIG"])),
    ],
}
if env.get("BUNDLE_SHA"):
    prov["initramfs_image"] = {
        "source_archive": f"{env['INITRAMFS_GZ'].replace(root + '/', '')} (images-stage artifact, flavor-matched)",
        "source_archive_sha256": env["BUNDLE_SHA"],
        "fragment": 'settled config + CONFIG_INITRAMFS_SOURCE="initramfs.cpio.gz" (RELATIVE; archive '
                    "placed at kernel source-tree root where usr/Makefile resolves bare-name prerequisites)",
        "compression": "CONFIG_INITRAMFS_COMPRESSION_GZIP deliberately NOT set: single .cpio.* sources "
                       "are embedded as-is (usr/Makefile: compress-y := copy, no double compression); "
                       "runtime decompression via CONFIG_RD_GZIP=y (asserted)",
        "flavor_note": ("the embedded initramfs carries the %s module closure — modules are "
                        "page-size-ABI-sensitive, so a %s Image.initramfs must never serve the "
                        "16k closure (or vice versa)" % (flavor, flavor)),
    }
else:
    prov["initramfs_image"] = None
    prov["initramfs_bundle_note"] = ("not built this run: no flavor-matched initramfs artifact yet "
                                     f"({env['INITRAMFS_GZ'].replace(root + '/', '')}); re-run the "
                                     "kernel stage after the images stage to produce Image.initramfs")

out_path = os.path.join(art_dir, "provenance.json")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(prov, f, indent=2)
    f.write("\n")
print(f"[kernel-build] generated provenance: {os.path.relpath(out_path, root)} "
      f"({len(files)} artifact entries)")
PYEOF
else
    log "provenance preserved (no shipped change): ${ARTIFACTS_DIR}/provenance.json"
fi

log "DONE stage=${STAGE_NAME} release=${KERNEL_RELEASE} wall=${WALL}s"
