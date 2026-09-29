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
# .deb packages extracted into a local prefix (no apt, no root). ld64-530 needs a
# libLTO.so at <prefix>/lib/llvm/libLTO.so to link -flto bitcode; we expose the
# system LLVM's libLTO there (see tooling/pongoos/README.md for details).
#
# Re-runnable: every step is idempotent. Logs to stdout/stderr (caller redirects).
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

# --- 3. Patches (none currently; contract-ready) -------------------------------
shopt -s nullglob
for p in "${PATCH_DIR}"/*.patch; do
    log "applying patch $(basename "${p}")"
    git -C "${UPSTREAM_DIR}" apply "${p}"
done
shopt -u nullglob

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

# shim dir: llvm-ar / llvm-ranlib (newlib build needs them on PATH, Makefile:1034 area of newlib)
if ! command -v llvm-ar >/dev/null; then
    found_ar="$(command -v llvm-ar-18 || command -v llvm-ar-17 || command -v llvm-ar-16 || true)"
    [ -n "${found_ar}" ] || die "llvm-ar not found on PATH or as llvm-ar-16/17/18"
    ln -sf "${found_ar}" "${TOOLCHAIN_DIR}/shim/llvm-ar"
    ln -sf "$(dirname "${found_ar}")/$(basename "${found_ar}" | sed 's/llvm-ar/llvm-ranlib/')" "${TOOLCHAIN_DIR}/shim/llvm-ranlib"
    log "shimmed llvm-ar/llvm-ranlib from ${found_ar}"
fi

# --- 5. libLTO wiring for ld64-530 (links -flto bitcode via dlopen) -----------
# ld64 looks for $0/../lib/llvm/libLTO.so  ->  <root>/lib/llvm/libLTO.so
LTO_LINK="${TOOLCHAIN_DIR}/root/lib/llvm/libLTO.so"
mkdir -p "$(dirname "${LTO_LINK}")"
if [ ! -e "${LTO_LINK}" ]; then
    lto_src=""
    for d in /usr/lib/llvm-*/lib "$(dirname "$(readlink -f "$(command -v clang)")")/../lib"; do
        cand="$(ls -1v "${d}"/libLTO.so.* 2>/dev/null | tail -n1 || true)"
        if [ -n "${cand}" ]; then lto_src="${cand}"; break; fi
    done
    [ -n "${lto_src}" ] || die "no system libLTO.so.* found (install an LLVM runtime)"
    ln -s "${lto_src}" "${LTO_LINK}"
    log "linked libLTO: ${LTO_LINK} -> ${lto_src}"
fi
LTO_LIBDIR="$(readlink -f "${LTO_LINK}" | xargs dirname)"

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
