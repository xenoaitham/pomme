#!/usr/bin/env bash
#
# pomme — pongoOS stage builder (Linux host, no sudo, non-interactive).
#
# Builds palera1n's pongoOS from pinned upstream sources:
#   https://github.com/palera1n/pongoOS @ e98323f8a09abd80fc4cbcd74dee023b91a1ec22
# using the upstream-documented Linux path (README.md "Building on Linux"):
#   clang (LLVM) + Apple ld64 + Apple cctools-strip.
#
# The Apple linker/strip come from checkra1n's own Debian repo as checksum-pinned
# .deb packages extracted into a local prefix (no apt, no root). ld64-530 links
# -flto bitcode by dlopen-ing the bare soname "libLTO.so"; we resolve ONE LLVM
# version from the clang on PATH (section 0b), then publish that exact libLTO
# under the name ld64 looks up (section 5). See tooling/pongoos/README.md.
#
# Re-runnable: every step is idempotent, including the patch mechanism
# (pristine reset + apply --check + apply). Logs to stdout/stderr.
set -euo pipefail

POMME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_DIR="${POMME_ROOT}/upstream/pongoOS-palera1n"
PATCH_DIR="${POMME_ROOT}/patches/pongoos"
ART_DIR="${POMME_ROOT}/artifacts/pongoos"

# --- Pins (recorded in evidence/upstream-pins/) -------------------------------
PONGO_URL="https://github.com/palera1n/pongoOS"
PONGO_PIN="e98323f8a09abd80fc4cbcd74dee023b91a1ec22"   # 2026-07-19, branch iOS15
NEWLIB_URL="https://github.com/checkra1n/newlib"
NEWLIB_PIN="f9ea5054de8fb51dff6f6d3c2e7cdd4aa89744b8"   # gitlink recorded in pongoOS@PONGO_PIN

# --- Pinned toolchain debs (checkra1n Debian repo, sha256 from its Packages) --
TOOLCHAIN_DIR="${POMME_TOOLCHAIN_DIR:-/home/potato/toolchains/checkra1n-cctools}"
LD64_DEB_URL="https://assets.checkra.in/debian/ld64_530-2_amd64.deb"
LD64_DEB_SHA256="a2c017ca05d33325d4a39ba906ee2a535327d136adea5fd029fdc9407a4b7d31"
STRIP_DEB_URL="https://assets.checkra.in/debian/cctools-strip_949.0.1-2_amd64.deb"
STRIP_DEB_SHA256="8d0e99921de851faefcb1fc867ada0a2348605f3f279e24131b5a424df9fa700"

log() { printf '[pongoos-build] %s\n' "$*"; }
die() { printf '[pongoos-build] FATAL: %s\n' "$*" >&2; exit 1; }

# --- 0. Host tool sanity ------------------------------------------------------
command -v git      >/dev/null || die "git not found"
command -v clang    >/dev/null || die "clang not found"
command -v curl     >/dev/null || die "curl not found"
command -v dpkg-deb >/dev/null || die "dpkg-deb not found"
command -v make     >/dev/null || die "make not found"
command -v cc       >/dev/null || die "host cc not found (needed for tools/vmacho.c)"
log "clang: $(clang --version | head -n1)"

# --- 0b. Single resolved LLVM version (clang == libLTO == llvm-ar) -------------
# Every LLVM component this build touches is derived from ONE number: the major
# version of the clang actually on PATH. Hosts routinely carry several LLVM
# toolchains (/usr/lib/llvm-16, -17, -18 ...); "first libLTO found wins" globbing
# has picked a mismatched one before. A clang-18 producer feeding a libLTO-16
# consumer through ld64's dlopen is silent miscompilation territory, so we
# resolve the exact same-version triple up front and die on any mismatch.
CLANG_MAJOR="$(clang --version | head -n1 | grep -oP 'version \K[0-9]+' || true)"
[ -n "${CLANG_MAJOR}" ] || die "cannot parse clang major from: $(clang --version | head -n1)"
# cross-check against the resource dir clang itself reports (.../lib/clang/<N>)
clang_resdir="$(clang -print-resource-dir 2>/dev/null || true)"
if [ -n "${clang_resdir}" ]; then
    resdir_major="$(basename "${clang_resdir}")"
    [ "${resdir_major}" = "${CLANG_MAJOR}" ] \
        || die "clang self-report mismatch: --version says ${CLANG_MAJOR}, resource dir says ${resdir_major}"
fi
# The LLVM prefix owning the resolved clang binary (Debian/Ubuntu layout:
# /usr/bin/clang -> /usr/lib/llvm-<N>/bin/clang); fallback for other layouts.
CLANG_REAL="$(readlink -f "$(command -v clang)")"
LLVM_PREFIX="$(dirname "$(dirname "${CLANG_REAL}")")"     # strip /bin/clang
[ -d "${LLVM_PREFIX}/lib" ] || LLVM_PREFIX="/usr/lib/llvm-${CLANG_MAJOR}"
[ -d "${LLVM_PREFIX}/lib" ] || die "no lib/ under resolved LLVM prefix (${LLVM_PREFIX})"
LTO_EXACT="${LLVM_PREFIX}/lib/libLTO.so.${CLANG_MAJOR}"
if [ ! -e "${LTO_EXACT}" ]; then
    # Ubuntu names the runtime libLTO.so.<major>.<minor> (e.g. libLTO.so.18.1)
    # with no <major>-only alias; accept <major>.x forms, but ONLY inside the
    # prefix clang itself selected — never a cross-prefix "newest found" glob.
    lto_cand="$(ls -1v "${LLVM_PREFIX}/lib/libLTO.so.${CLANG_MAJOR}."* 2>/dev/null | head -n1 || true)"
    [ -n "${lto_cand}" ] || die "version enforcement: clang is ${CLANG_MAJOR} but no libLTO.so.${CLANG_MAJOR}* exists in ${LLVM_PREFIX}/lib (install llvm-${CLANG_MAJOR}); refusing an unmatched libLTO"
    LTO_EXACT="${lto_cand}"
fi
AR_FROM_PREFIX="${LLVM_PREFIX}/bin/llvm-ar"
[ -x "${AR_FROM_PREFIX}" ] || die "version enforcement: no ${AR_FROM_PREFIX} in the same llvm-${CLANG_MAJOR} prefix as clang"
RANLIB_FROM_PREFIX="${LLVM_PREFIX}/bin/llvm-ranlib"
[ -x "${RANLIB_FROM_PREFIX}" ] || die "version enforcement: no ${RANLIB_FROM_PREFIX} in the same llvm-${CLANG_MAJOR} prefix as clang"
ar_major="$("${AR_FROM_PREFIX}" --version 2>/dev/null | head -n1 | grep -oP 'version \K[0-9]+' || true)"
[ "${ar_major}" = "${CLANG_MAJOR}" ] || die "llvm-ar major (${ar_major:-unparsed}) != clang major (${CLANG_MAJOR}) at ${AR_FROM_PREFIX}"
log "LLVM version enforcement OK: clang=${CLANG_MAJOR} libLTO=${LTO_EXACT} llvm-ar=${AR_FROM_PREFIX}"

# --- 1. Upstream clone at pinned commit ---------------------------------------
if [ ! -d "${UPSTREAM_DIR}/.git" ]; then
    log "cloning ${PONGO_URL} at ${PONGO_PIN}"
    git init -q "${UPSTREAM_DIR}"
    git -C "${UPSTREAM_DIR}" remote add origin "${PONGO_URL}"
    git -C "${UPSTREAM_DIR}" fetch -q --depth 1 origin "${PONGO_PIN}" \
        || die "git fetch of pinned sha failed (network?)"
    git -C "${UPSTREAM_DIR}" checkout -q -f FETCH_HEAD
else
    log "upstream clone present at ${UPSTREAM_DIR}"
fi
HEAD_SHA="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)"
[ "${HEAD_SHA}" = "${PONGO_PIN}" ] || die "upstream HEAD ${HEAD_SHA} != pin ${PONGO_PIN}"
log "upstream HEAD verified: ${HEAD_SHA}"

# --- 2. Submodules (newlib) ----------------------------------------------------
if [ "$(git -C "${UPSTREAM_DIR}" rev-parse HEAD:newlib 2>/dev/null)" != "${NEWLIB_PIN}" ] \
   || [ ! -e "${UPSTREAM_DIR}/newlib/.git" ]; then
    log "initializing submodule newlib (expect ${NEWLIB_PIN})"
    git -C "${UPSTREAM_DIR}" submodule update --init --recursive
fi
NEWLIB_HEAD="$(git -C "${UPSTREAM_DIR}/newlib" rev-parse HEAD)"
[ "${NEWLIB_HEAD}" = "${NEWLIB_PIN}" ] || die "newlib HEAD ${NEWLIB_HEAD} != pin ${NEWLIB_PIN}"
log "newlib submodule verified: ${NEWLIB_HEAD}"

# --- 3. Patches (patches/pongoos/*.patch; genuinely re-runnable) ---------------
# Contract: the tracked working tree is forced back to the pristine pinned
# commit on every run (git reset --hard; untracked build outputs in build/ and
# newlib/ survive), then each patch is validated against that pristine state
# with `git apply --check` before it is applied. A reused clone therefore always
# yields the same post-patch tree (a previously applied patch is reverted by the
# reset, never double-applied), and a patch that no longer applies to the pin
# dies loudly instead of half-applying.
mkdir -p "${PATCH_DIR}"
shopt -s nullglob
patch_list=("${PATCH_DIR}"/*.patch)
shopt -u nullglob
if [ "${#patch_list[@]}" -gt 0 ]; then
    log "resetting upstream tree to pristine pinned state before patching"
    git -C "${UPSTREAM_DIR}" reset -q --hard HEAD
    for p in "${patch_list[@]}"; do
        git -C "${UPSTREAM_DIR}" apply --check "${p}" \
            || die "patch does not apply to pristine pinned tree: ${p}"
        log "applying patch $(basename "${p}")"
        git -C "${UPSTREAM_DIR}" apply "${p}"
    done
else
    log "no patches in ${PATCH_DIR} (none currently)"
fi

# --- 4. Pinned Apple binutils (ld64 + cctools-strip debs, local extraction) ---
mkdir -p "${TOOLCHAIN_DIR}/debs" "${TOOLCHAIN_DIR}/root/usr/bin"
fetch_pinned_deb() { # url sha256 out
    local url="$1" want="$2" out="$3"
    if [ -f "${out}" ] && echo "${want}  ${out}" | sha256sum -c --quiet >/dev/null 2>&1; then
        log "deb cached + verified: ${out}"
    else
        log "fetching ${url}"
        curl -fsSL -m 120 -o "${out}" "${url}" || die "download failed: ${url}"
    fi
    echo "${want}  ${out}" | sha256sum -c --quiet \
        || die "sha256 mismatch for ${out} (want ${want})"
}
fetch_pinned_deb "${LD64_DEB_URL}"   "${LD64_DEB_SHA256}"   "${TOOLCHAIN_DIR}/debs/ld64_530-2_amd64.deb"
fetch_pinned_deb "${STRIP_DEB_URL}"  "${STRIP_DEB_SHA256}"  "${TOOLCHAIN_DIR}/debs/cctools-strip_949.0.1-2_amd64.deb"

if [ ! -x "${TOOLCHAIN_DIR}/root/usr/bin/ld64" ] || [ ! -x "${TOOLCHAIN_DIR}/root/usr/bin/cctools-strip" ]; then
    log "extracting debs into ${TOOLCHAIN_DIR}/root"
    dpkg-deb -x "${TOOLCHAIN_DIR}/debs/ld64_530-2_amd64.deb"        "${TOOLCHAIN_DIR}/root"
    dpkg-deb -x "${TOOLCHAIN_DIR}/debs/cctools-strip_949.0.1-2_amd64.deb" "${TOOLCHAIN_DIR}/root"
fi
"${TOOLCHAIN_DIR}/root/usr/bin/ld64" -v >/dev/null 2>&1 || die "extracted ld64 does not run"

# shim dir: Makefile calls bare `strip` (line 144) -> cctools-strip
mkdir -p "${TOOLCHAIN_DIR}/shim"
ln -sf "${TOOLCHAIN_DIR}/root/usr/bin/cctools-strip" "${TOOLCHAIN_DIR}/shim/strip"

# shim dir: llvm-ar / llvm-ranlib — ALWAYS shimmed from the resolved llvm-N
# prefix (same one as clang), never left to host PATH luck. The shim dir is
# first on PATH, so the newlib build's `AR='llvm-ar'` lands on the
# version-enforced tools regardless of what else the host has installed.
ln -sf "${AR_FROM_PREFIX}"     "${TOOLCHAIN_DIR}/shim/llvm-ar"
ln -sf "${RANLIB_FROM_PREFIX}" "${TOOLCHAIN_DIR}/shim/llvm-ranlib"
log "shimmed llvm-ar/llvm-ranlib from llvm-${CLANG_MAJOR} prefix (${LLVM_PREFIX}/bin)"

# --- 5. libLTO wiring for ld64-530 (links -flto bitcode via dlopen) -----------
# Verified by LD_PRELOAD interception: checkra1n's ld64-530 dlopens the BARE
# soname "libLTO.so" (its hardwired RUNPATH /usr/lib/llvm-10/lib never exists on
# modern hosts; the "<ld64>/../lib/llvm/libLTO.so" path in its error message is
# only cosmetic). Bare-soname dlopen resolves through the standard loader search
# (LD_LIBRARY_PATH first) and needs a file literally NAMED libLTO.so — the
# versioned runtime libLTO.so.<N>.x does NOT match, so hosts without a dev
# package's unversioned alias fail the link. We therefore publish the enforced
# libLTO under exactly that name in a build-owned dir, first on LD_LIBRARY_PATH.
# (The <root>/lib/llvm/libLTO.so link is kept too: source-built ld64 variants
# path-dlopen that location.)
LTO_SHIM_DIR="${TOOLCHAIN_DIR}/lto"
mkdir -p "${LTO_SHIM_DIR}"
ln -sfn "${LTO_EXACT}" "${LTO_SHIM_DIR}/libLTO.so"
LTO_LINK="${TOOLCHAIN_DIR}/root/lib/llvm/libLTO.so"
mkdir -p "$(dirname "${LTO_LINK}")"
ln -sfn "${LTO_EXACT}" "${LTO_LINK}"
log "libLTO wiring: soname shim ${LTO_SHIM_DIR}/libLTO.so -> ${LTO_EXACT} (+ path link for source-built ld64)"
LTO_LIBDIR="${LTO_SHIM_DIR}:${LLVM_PREFIX}/lib"   # shim dir first; LLVM dir holds libLLVM-<N>.so for the dlopen chain

# --- 6. Build -------------------------------------------------------------------
export PATH="${TOOLCHAIN_DIR}/shim:${TOOLCHAIN_DIR}/root/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${LTO_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
log "PATH head: $(dirname "$(command -v clang)") | ld64: $(command -v ld64) | strip: $(command -v strip)"
cd "${UPSTREAM_DIR}"
log "running make (PONGO_VERSION string embeds git rev; expect 2.6.3-$(git rev-parse --short=8 HEAD))"
make -j"$(nproc)"

# --- 7. Install artifacts -------------------------------------------------------
mkdir -p "${ART_DIR}"
install -m 0644 build/Pongo.bin             "${ART_DIR}/Pongo.bin"
install -m 0644 build/Pongo                 "${ART_DIR}/Pongo.macho"
install -m 0644 build/checkra1n-kpf-pongo   "${ART_DIR}/checkra1n-kpf-pongo.macho"

# --- 8. Report ------------------------------------------------------------------
log "artifacts installed to ${ART_DIR}"
( cd "${ART_DIR}" && sha256sum Pongo.bin Pongo.macho checkra1n-kpf-pongo.macho )
for f in Pongo.bin Pongo.macho checkra1n-kpf-pongo.macho; do
    log "$(file -b "${ART_DIR}/${f}")  <= ${f} ($(stat -c %s "${ART_DIR}/${f}") bytes)"
done
log "OK"
