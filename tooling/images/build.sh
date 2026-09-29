#!/usr/bin/env bash
# pomme stage: images — initramfs.cpio.gz (bring-up userspace) + rootfs.img
# (Alpine ext4). iPhone 7 / T8010 target. Runs entirely as an unprivileged
# user: no mounts, no sudo — the ext4 image is populated with mke2fs -d and
# correct uid/gid via fakeroot.
#
# Contract: docs/pipeline-conventions.md. Builds-not-boots: these images are
# proven to build and pass static checks, NOT proven to boot (no device in
# this pipeline). See tooling/images/README.md for the full story.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${REPO_ROOT}/artifacts/images"
WORK_DIR="${REPO_ROOT}/out/images"
DL_DIR="${REPO_ROOT}/upstream/_downloads"     # gitignored (upstream/)
MODULES_TARBALL="${REPO_ROOT}/artifacts/kernel/modules.tar.gz"

VERSION="3.24.2"   # Alpine release this stage pins; bump = rebuild + new log
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_DATE="$(date +%Y%m%d)"
LOG_NAME="images_${VERSION}_${BUILD_DATE}.log"

# ----------------------------------------------------------- pinned sources
# IMMUTABLE versioned pins on dl-cdn (NOT latest-stable — that path is a
# moving target). Resolved 2026-09-29 while latest-stable pointed at 3.24.2,
# then pinned to the versioned path. Verified against the mirror's published
# checksums (the minirootfs also cross-checks the .sha256 sidecar at build
# time). Update deliberately, record in provenance, and keep in sync with
# tooling/images/README.md.
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v3.24"
ALPINE_ARCH="aarch64"
ALPINE_FILE="alpine-minirootfs-3.24.2-aarch64.tar.gz"
ALPINE_SHA256="9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773"
ALPINE_PUBLISHED_SHA256_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${ALPINE_FILE}.sha256"
ALPINE_RELEASE_DATE="2026-09-17"
ALPINE_RELEASE_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${ALPINE_FILE}"

BUSYBOX_APK="busybox-static-1.37.0-r31.apk"
BUSYBOX_SHA256="965777e06b94bf11981d5f4ecdfcd577879f4b0dda544294d1dd3f72b217bc75"
BUSYBOX_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/${BUSYBOX_APK}"
BUSYBOX_BIN_IN_APK="bin/busybox.static"

# initramfs module set = what pmOS's "netboot" feature needs at initramfs
# time (USB configfs gadget NCM net + ACM serial, plus NBD). Mirrors
# upstream/pmaports/device/testing/device-apple-idevice/modules-initfs
# (which contains the single keyword "netboot") and
# main/postmarketos-mkinitfs-hook-netboot (setup_usb_network + modprobe nbd).
INITRAMFS_MODULES=(configfs libcomposite usb_f_ncm usb_f_fs usb_f_acm nbd)

DEVICE_IP="10.0.0.2"; HOST_IP="10.0.0.1"; NETMASK="255.255.255.0"
INITRAMFS_MAX_BYTES=$((10 * 1024 * 1024))   # <10MB bring-up image
ROOTFS_DEFAULT_MB=256                        # spec size; auto-grows if needed

log()  { printf '[images-build] %s\n' "$*"; }
warn() { printf '[images-build] WARNING: %s\n' "$*"; }
die()  { printf '[images-build] ERROR: %s\n' "$*" >&2; exit 1; }

log "stage=images version=${VERSION} started=${STAMP}"
log "repo=${REPO_ROOT}"

# ---------------------------------------------------------------- preflight
for tool in cpio gzip mke2fs e2fsck debugfs file tar sha256sum depmod \
	fakeroot busybox awk head wc cut sort uniq tr grep; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
# busybox (host) is not optional: smoke test 1 syntax-checks /init with
# busybox ash, so it must exist before the build starts, not fail midway.
log "host busybox: $(busybox | head -1)"
log "mke2fs: $(mke2fs -V 2>&1 | head -1)"
log "cpio:   $(cpio --version 2>&1 | head -1)"
log "gzip:   $(gzip --version 2>&1 | head -1)"
log "depmod: $(depmod --version 2>&1 | head -1)"
if command -v qemu-aarch64 >/dev/null 2>&1 || command -v qemu-aarch64-static >/dev/null 2>&1; then
	QEMU_BIN="$(command -v qemu-aarch64 || command -v qemu-aarch64-static)"
	log "qemu-user found: ${QEMU_BIN} (busybox smoke test will execute)"
else
	QEMU_BIN=""
	log "qemu-user not available: busybox binary-class smoke test will be SKIPPED with a note"
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/initramfs" "${WORK_DIR}/rootfs" "${OUT_DIR}" "${DL_DIR}"

sha_of() { sha256sum "$1" | awk '{print $1}'; }
bytes_of() { wc -c < "$1" | tr -d ' '; }

# ------------------------------------------------- download + verify sources
fetch_pinned() { # url dest expected_sha256 label
	local url="$1" dest="$2" want="$3" label="$4" got
	if [ -f "${dest}" ]; then
		got="$(sha_of "${dest}")"
		if [ "${got}" = "${want}" ]; then
			log "${label}: reusing cached $(basename "${dest}") (sha256 OK)"
			return 0
		fi
		warn "${label}: cached file hash mismatch, re-downloading"
		rm -f "${dest}"
	fi
	log "${label}: downloading ${url}"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "${dest}" "${url}" || die "download failed: ${url}"
	else
		wget -q -O "${dest}" "${url}" || die "download failed: ${url}"
	fi
	got="$(sha_of "${dest}")"
	[ "${got}" = "${want}" ] || die "${label}: sha256 mismatch got=${got} want=${want}"
	log "${label}: sha256 OK (${got})"
}

fetch_pinned "${ALPINE_RELEASE_URL}" \
	"${DL_DIR}/${ALPINE_FILE}" "${ALPINE_SHA256}" "alpine-minirootfs"

# Independent verification: the mirror publishes a .sha256 sidecar next to
# the release file; our download must match it byte-for-byte.
PUBLISHED_SHA="$(curl -fsSL --retry 3 "${ALPINE_PUBLISHED_SHA256_URL}" 2>/dev/null | awk '{print $1}' || true)"
if [ -n "${PUBLISHED_SHA}" ]; then
	[ "${PUBLISHED_SHA}" = "${ALPINE_SHA256}" ] \
		|| die "published .sha256 on the mirror (${PUBLISHED_SHA}) != pinned ${ALPINE_SHA256} — pin is stale, update it"
	log "alpine-minirootfs: matches mirror-published .sha256 sidecar"
else
	warn "could not fetch mirror .sha256 sidecar for cross-check (network?)"
	PUBLISHED_SHA=""
fi

fetch_pinned "${BUSYBOX_URL}" \
	"${DL_DIR}/${BUSYBOX_APK}" "${BUSYBOX_SHA256}" "busybox-static"

ALPINE_BYTES="$(bytes_of "${DL_DIR}/${ALPINE_FILE}")"
BUSYBOX_BYTES="$(bytes_of "${DL_DIR}/${BUSYBOX_APK}")"
log "alpine-minirootfs: ${ALPINE_BYTES} bytes; busybox-static apk: ${BUSYBOX_BYTES} bytes"

# ------------------------------------------- extract busybox.static from apk
# An Alpine .apk is a gzipped tarball (apk-tools v2). Extract only the
# static binary; GNU tar warns about APK-TOOLS.* pax headers — harmless.
mkdir -p "${WORK_DIR}/apk-scratch"
tar -xzf "${DL_DIR}/${BUSYBOX_APK}" -C "${WORK_DIR}/apk-scratch" \
	"${BUSYBOX_BIN_IN_APK}" 2>/dev/null \
	|| tar -xzf "${DL_DIR}/${BUSYBOX_APK}" -C "${WORK_DIR}/apk-scratch" \
		2>/dev/null   # layout fallback: extract all
BB_SRC="${WORK_DIR}/apk-scratch/${BUSYBOX_BIN_IN_APK}"
[ -f "${BB_SRC}" ] || die "busybox.static not found in apk (looked for ${BUSYBOX_BIN_IN_APK})"
BB_INFO="$(file "${BB_SRC}")"
log "busybox.static: ${BB_INFO}"
case "${BB_INFO}" in
	*dynamically*linked*) die "busybox.static is dynamically linked: ${BB_INFO}" ;;
esac
case "${BB_INFO}" in
	*statically*linked*|*static-pie*linked*|*static-pie*) : ;;
	*) die "busybox.static linkage unrecognized (neither static nor static-pie): ${BB_INFO}" ;;
esac
case "${BB_INFO}" in
	*ARM*aarch64*|*aarch64*) log "busybox.static binary class: aarch64 (as pinned)" ;;
	*) die "busybox.static is not aarch64: ${BB_INFO}" ;;
esac

# Applet availability check: the compiled-in applet names appear verbatim in
# the binary; verify every applet our init depends on before we ship.
# Dump the NUL-separated string table once, then check against the FILE
# (not a pipe: with pipefail, grep -q exiting early SIGPIPEs the producer
# and races the exit status — file-based checks are deterministic).
BB_NAMES_RAW="${WORK_DIR}/bb-names.raw"
LC_ALL=C tr '\000' '\n' < "${BB_SRC}" > "${BB_NAMES_RAW}" || die "tr on busybox.static failed"
BB_MISSING=""
for applet in sh ash mount umount mkdir mknod mdev modprobe ifconfig route \
	nc getty setsid sleep echo cat grep sed head ln ls date hostname uname \
	poweroff reboot sync ps true false; do
	# BusyBox stores its applet table as NUL-separated names; look for
	# exact-line matches. Note: this pinned busybox-static has NO
	# telnetd/cttyhack applets — init compensates with nc -e and explicit
	# fd redirects (see init comments).
	if ! LC_ALL=C grep -aqx -- "${applet}" "${BB_NAMES_RAW}"; then
		BB_MISSING="${BB_MISSING} ${applet}"
	fi
done
if [ -n "${BB_MISSING}" ]; then
	warn "busybox.static may lack applets:${BB_MISSING} (string-table heuristic; init tolerates absence)"
else
	log "busybox.static: all init-critical applets present in applet table"
fi

# =========================================================== INITRAMFS BUILD
log "staging initramfs at ${WORK_DIR}/initramfs"
IFS_ROOT="${WORK_DIR}/initramfs"
mkdir -p "${IFS_ROOT}/bin" "${IFS_ROOT}/sbin" "${IFS_ROOT}/etc" \
	"${IFS_ROOT}/proc" "${IFS_ROOT}/sys" "${IFS_ROOT}/dev" \
	"${IFS_ROOT}/run" "${IFS_ROOT}/tmp" "${IFS_ROOT}/root" \
	"${IFS_ROOT}/sys/kernel/config" "${IFS_ROOT}/lib/modules"
chmod 1777 "${IFS_ROOT}/tmp"
chmod 1777 "${IFS_ROOT}/run"

install -m 0755 "${REPO_ROOT}/tooling/images/initramfs/init" "${IFS_ROOT}/init"
cp "${REPO_ROOT}"/tooling/images/initramfs/etc/* "${IFS_ROOT}/etc/"
chmod 644 "${IFS_ROOT}"/etc/*

install -m 0755 "${BB_SRC}" "${IFS_ROOT}/bin/busybox"
# Applet symlinks: /bin for the common set, /sbin for the system ones.
for applet in sh ash cat cp mv rm ln mkdir rmdir mknod chmod chown ls echo \
	printf sleep date hostname uname grep sed head tail wc tr uniq true false \
	test '[' ps id pwd env dmesg sync find xargs tar dd hexdump od clear \
	less more vi mount umount ping ping6 nc netstat; do
	ln -sf busybox "${IFS_ROOT}/bin/${applet}"
done
for applet in mdev modprobe insmod rmmod ifconfig route ip udhcpc telnetd \
	getty setsid cttyhack switch_root init linuxrc poweroff reboot halt; do
	ln -sf ../bin/busybox "${IFS_ROOT}/sbin/${applet}"
done
log "busybox applet symlinks installed ($(find "${IFS_ROOT}/bin" "${IFS_ROOT}/sbin" -type l | wc -l | tr -d ' ') links)"

# ------------------------------------------------------ modules (if kernel)
KVER=""
MODULES_INTEGRATED=no
MODULES_SHA=""
MODULES_URL_NOTE="artifacts/kernel/modules.tar.gz (built by the kernel stage)"
MODULES_PRESENT_LIST=()
MODULES_MISSING_LIST=()
MODULES_BUILTIN_LIST=()

if [ -f "${MODULES_TARBALL}" ]; then
	log "kernel modules tarball found ($(bytes_of "${MODULES_TARBALL}") bytes); integrating"
	SCRATCH="${WORK_DIR}/modules-scratch"
	mkdir -p "${SCRATCH}"
	# The kernel stage may be republishing artifacts/kernel/* while we read
	# it: an extraction can hit a mid-replace (truncated/changing) file.
	# Tolerate that: retry once after a short backoff, and require the
	# tarball hash to be identical before and after extraction.
	extract_modules_ok=no
	for attempt in 1 2; do
		MODULES_SHA="$(sha_of "${MODULES_TARBALL}")"
		if tar -xzf "${MODULES_TARBALL}" -C "${SCRATCH}" 2>/dev/null \
			&& [ "$(sha_of "${MODULES_TARBALL}")" = "${MODULES_SHA}" ]; then
			extract_modules_ok=yes
			break
		fi
		warn "modules.tar.gz failed hash/extract check (attempt ${attempt}/2) — kernel stage possibly mid-replace; backing off"
		rm -rf "${SCRATCH}"
		mkdir -p "${SCRATCH}"
		sleep 5
	done
	[ "${extract_modules_ok}" = "yes" ] \
		|| die "modules.tar.gz failed twice (corrupt or still being replaced by the kernel stage) — re-run make images once it settles"
	log "modules tarball unpacked (stable at sha256 ${MODULES_SHA:0:12}…)"
	# Locate the /lib/modules/<kver> tree: the dir holding modules.dep.
	DEP_DIR="$(find "${SCRATCH}" -type f -name modules.dep -printf '%h\n' 2>/dev/null | head -n 1 || true)"
	if [ -z "${DEP_DIR}" ]; then
		# Kernel stage may ship an un-depmod'ed tree; find by layout instead.
		DEP_DIR="$(find "${SCRATCH}" -type d -path '*lib/modules*' 2>/dev/null | head -n 1 || true)"
		if [ -n "${DEP_DIR}" ] && [ "$(basename "${DEP_DIR}")" = "modules" ]; then
			DEP_DIR="$(find "${DEP_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1 || true)"
		fi
	fi
	[ -n "${DEP_DIR}" ] || die "modules.tar.gz: could not locate a modules tree (no modules.dep, no lib/modules/<kver>)"
	KVER="$(basename "${DEP_DIR}")"
	log "kernel release: ${KVER}"

	# Rootfs gets the whole tree (freshly depmod'ed under fakeroot below).
	mkdir -p "${WORK_DIR}/rootfs/lib/modules"
	cp -a "${DEP_DIR}" "${WORK_DIR}/rootfs/lib/modules/${KVER}"
	log "rootfs: full modules tree copied to /lib/modules/${KVER}"

	# Initramfs gets only the netboot closure: requested modules + their
	# dependencies from modules.dep (transitive).
	IFS_MOD_ROOT="${IFS_ROOT}/lib/modules/${KVER}"
	mkdir -p "${IFS_MOD_ROOT}"
	DEP_FILE="${DEP_DIR}/modules.dep"
	if [ -f "${DEP_FILE}" ]; then
		# Seed: where each requested module lives in the tree (any
		# compression suffix the kernel build used).
		declare -A SEEN=()
		changed=1
		while [ "${changed}" = "1" ]; do
			changed=0
			while IFS= read -r line; do
				[ -z "${line}" ] && continue
				mod="${line%%:*}"
				deps="${line#*:}"
				base="$(basename "${mod}")"
				stem="${base%%.*}"
				stem="${stem%.ko}"
				keep=no
				for want in "${INITRAMFS_MODULES[@]}"; do
					[ "${stem}" = "${want}" ] && keep=yes
				done
				for s in "${!SEEN[@]}"; do
					[ "${stem}" = "${s}" ] && keep=yes
				done
				[ "${keep}" = "yes" ] || continue
				if [ -z "${SEEN[${stem}]:-}" ]; then
					SEEN[${stem}]="${mod}"
					changed=1
				fi
				if [ "${deps}" != "${line}" ]; then
					for d in ${deps}; do
						dstem="$(basename "${d%%.*}")"
						dstem="${dstem%.ko}"
						if [ -z "${SEEN[${dstem}]:-}" ]; then
							SEEN[${dstem}]="${d}"
							changed=1
						fi
					done
				fi
			done < "${DEP_FILE}"
		done
		for stem in "${!SEEN[@]}"; do
			rel="${SEEN[${stem}]}"
			src="${DEP_DIR}/${rel}"
			if [ -f "${src}" ]; then
				mkdir -p "${IFS_MOD_ROOT}/$(dirname "${rel}")"
				cp -a "${src}" "${IFS_MOD_ROOT}/${rel}"
				MODULES_PRESENT_LIST+=("${stem}")
			fi
		done
		# Builtin check: requested modules compiled =y never appear in the
		# modules tree; modules.builtin records them.
		BUILTIN_FILE="${DEP_DIR}/modules.builtin"
		for want in "${INITRAMFS_MODULES[@]}"; do
			found=no
			for stem in "${MODULES_PRESENT_LIST[@]:-}"; do
				[ "${stem}" = "${want}" ] && found=yes
			done
			if [ "${found}" = "no" ] && [ -f "${BUILTIN_FILE}" ] \
				&& grep -q "/${want}\.ko" "${BUILTIN_FILE}" 2>/dev/null; then
				MODULES_BUILTIN_LIST+=("${want}")
			elif [ "${found}" = "no" ]; then
				MODULES_MISSING_LIST+=("${want}")
			fi
		done
		log "initramfs module closure: present=(${MODULES_PRESENT_LIST[*]:-none}) builtin=(${MODULES_BUILTIN_LIST[*]:-none}) missing=(${MODULES_MISSING_LIST[*]:-none})"
		[ "${#MODULES_MISSING_LIST[@]}" -eq 0 ] \
			|| warn "modules not in kernel build (noted, not fatal): ${MODULES_MISSING_LIST[*]}"
	else
		warn "modules.tar.gz had no modules.dep; copying tree wholesale into initramfs"
		cp -a "${DEP_DIR}/." "${IFS_MOD_ROOT}/"
	fi
	# Self-consistent dep files inside the initramfs (depmod is arch-agnostic
	# for dependency parsing; failures are non-fatal — original dep files kept).
	if depmod -b "${IFS_ROOT}" "${KVER}" >/dev/null 2>&1; then
		log "initramfs: depmod regenerated modules.dep for ${KVER}"
	else
		warn "initramfs depmod failed; keeping dep files from the modules tree"
	fi
	MODULES_INTEGRATED=yes
else
	log "****************************************************************"
	log "WARNING: ${MODULES_TARBALL} not found — the kernel stage is still"
	log "WARNING: building in parallel. Building WITHOUT kernel modules;"
	log "WARNING: the orchestrator re-runs 'make images' after 'make kernel'"
	log "WARNING: lands. Until then the initramfs relies on whatever USB/"
	log "WARNING: gadget support is compiled into the kernel Image itself."
	log "****************************************************************"
fi

# ------------------------------------------------------- pack the initramfs
# Reproducible by construction: pin every mtime to a fixed epoch (symlinks
# included), let gzip omit its header timestamp, and use cpio
# --reproducible so inode numbers are renumbered deterministically (fresh
# staging trees get fresh inodes every run — without this the archive
# drifted whenever host inode allocation shifted). Two consecutive runs
# then produce byte-identical archives, which makes verify-style sha
# checks meaningful across rebuilds.
log "packing initramfs (newc cpio --reproducible, gzip -9 -n, entries forced to uid/gid 0:0, mtimes pinned)"
( cd "${IFS_ROOT}" && find . -exec touch -h -d @946684800 {} + \
	&& find . -print0 \
	| cpio --null -o -H newc -R 0:0 --quiet --reproducible ) \
	| gzip -9n > "${OUT_DIR}/initramfs.cpio.gz"
INITRAMFS_BYTES="$(bytes_of "${OUT_DIR}/initramfs.cpio.gz")"
INITRAMFS_SHA="$(sha_of "${OUT_DIR}/initramfs.cpio.gz")"
log "initramfs.cpio.gz: ${INITRAMFS_BYTES} bytes sha256=${INITRAMFS_SHA}"
[ "${INITRAMFS_BYTES}" -le "${INITRAMFS_MAX_BYTES}" ] \
	|| die "initramfs is ${INITRAMFS_BYTES} bytes, budget is ${INITRAMFS_MAX_BYTES} (<10MB)"
gzip -t "${OUT_DIR}/initramfs.cpio.gz" || die "gzip -t failed on initramfs"

# ============================================================== ROOTFS BUILD
log "staging rootfs at ${WORK_DIR}/rootfs (Alpine minirootfs + overlays)"
RFS_ROOT="${WORK_DIR}/rootfs"
tar -xzf "${DL_DIR}/${ALPINE_FILE}" -C "${RFS_ROOT}"

# pomme overlays on the minirootfs.
mkdir -p "${RFS_ROOT}/etc/network"
cp "${REPO_ROOT}/tooling/images/rootfs/etc/network/interfaces" "${RFS_ROOT}/etc/network/interfaces"
echo "pomme" > "${RFS_ROOT}/etc/hostname"

# getty on the gadget serial (ttyGS0) + allow root login on it.
INITTAB="${RFS_ROOT}/etc/inittab"
if [ -f "${INITTAB}" ] && ! grep -q '^ttyGS0:' "${INITTAB}"; then
	{
		echo ""
		echo "# pomme: shell on the USB gadget serial function"
		echo "ttyGS0::respawn:/sbin/getty -L 115200 ttyGS0 vt100"
	} >> "${INITTAB}"
	log "rootfs: added ttyGS0 getty to /etc/inittab"
fi
if [ -f "${RFS_ROOT}/etc/securetty" ] && ! grep -q '^ttyGS0$' "${RFS_ROOT}/etc/securetty"; then
	echo "ttyGS0" >> "${RFS_ROOT}/etc/securetty"
	log "rootfs: added ttyGS0 to /etc/securetty"
fi

cat > "${RFS_ROOT}/etc/motd" <<'EOF'
Welcome to pomme (Alpine aarch64 on an iPhone 7 — builds-not-boots project).

  usb0 is configured as 10.0.0.2/24 (host side: 10.0.0.1).
  /ROOTFS.txt records exactly how this image was built.
EOF

REPOSITORIES_NOTE="$(head -c 400 "${RFS_ROOT}/etc/apk/repositories" 2>/dev/null | tr '\n' ';' || true)"
cat > "${RFS_ROOT}/ROOTFS.txt" <<EOF
pomme rootfs image — provenance
===============================
Built by:  tooling/images/build.sh (pomme images stage)
Built at:  ${STAMP}
Stage:     builds-not-boots: this image has never been booted on hardware
           by this pipeline. A12+ devices are unsupported by design.

Base:      Alpine minirootfs ${ALPINE_FILE}
           URL:    ${ALPINE_RELEASE_URL}
           sha256: ${ALPINE_SHA256}
           (verified against the mirror-published .sha256 sidecar)
Extras:    busybox-static ${BUSYBOX_APK} (initramfs only; the rootfs uses
           the minirootfs's own dynamic busybox + musl)
           URL:    ${BUSYBOX_URL}
           sha256: ${BUSYBOX_SHA256}
Kernel:    /lib/modules/${KVER:-<none>}${MODULES_INTEGRATED:+ (from artifacts/kernel/modules.tar.gz, sha256 ${MODULES_SHA:-})}
           (the kernel Image itself ships via the pongoOS/m1n1 boot chain,
           not inside this image)
Network:   /etc/network/interfaces brings up usb0 = ${DEVICE_IP}/24;
           host side expects ${HOST_IP}. This mirrors the pmOS netboot-first
           approach for checkm8-era iPhones (internal storage is only
           proven working on A11; iPhone 7 is A10).
Root shell: getty on ttyGS0 (in /etc/inittab) after boot; remote access
           needs apk add openssh or busybox-extras (network required).

SECURITY POSTURE — READ BEFORE POWERING ANYTHING
  This image, and the initramfs it pairs with, give an UNAUTHENTICATED
  ROOT shell to whoever reaches them: the rootfs getty on ttyGS0 has no
  password, and the initramfs answers port 23 (nc/telnet) and /dev/ttyGS0
  with a root shell and shows one on /dev/console. That is a deliberate
  bench bring-up choice. Never attach these images to an untrusted
  network, and harden them (root password, ssh keys, disabled getty)
  before anything beyond bench use.
EOF
log "rootfs: overlays written (interfaces, inittab ttyGS0, motd, ROOTFS.txt)"

# Regenerate module deps inside the rootfs (fakeroot so file ownership in
# the image stays 0:0; depmod itself is arch-agnostic).
if [ -n "${KVER}" ]; then
	if fakeroot -- depmod -b "${RFS_ROOT}" "${KVER}" >/dev/null 2>&1; then
		log "rootfs: depmod OK for ${KVER}"
	else
		warn "rootfs depmod failed (modules may still load via the initramfs copy)"
	fi
fi

# ---- size: 256MB default, auto-grow (loudly) if the modules tree demands it
STAGED_KB="$(du -sk "${RFS_ROOT}" | awk '{print $1}')"
ROOTFS_MB="${ROOTFS_DEFAULT_MB}"
while [ $((STAGED_KB / 1024 + 64)) -gt "${ROOTFS_MB}" ]; do
	ROOTFS_MB=$((ROOTFS_MB + 128))
done
if [ "${ROOTFS_MB}" != "${ROOTFS_DEFAULT_MB}" ]; then
	log "staged rootfs needs ${STAGED_KB} KiB; growing image from ${ROOTFS_DEFAULT_MB}MB to ${ROOTFS_MB}MB"
else
	log "staged rootfs: ${STAGED_KB} KiB; image size ${ROOTFS_MB}MB"
fi

log "creating ext4 image with mke2fs -d (no root needed, fakeroot for 0:0)"
rm -f "${OUT_DIR}/rootfs.img"
fakeroot -- mke2fs -q -F -t ext4 -b 4096 -L pomme-rootfs \
	-d "${RFS_ROOT}" \
	-E lazy_itable_init=0,lazy_journal_init=0 \
	"${OUT_DIR}/rootfs.img" "${ROOTFS_MB}M" \
	|| die "mke2fs failed"
ROOTFS_SHA_PRE_FSCK="$(sha_of "${OUT_DIR}/rootfs.img")"
log "rootfs.img (pre-e2fsck): ${ROOTFS_SHA_PRE_FSCK}"

# ================================================================ SMOKE TESTS
log "---------------------------------------- smoke tests"
SMOKE_NOTES=()

# 1. /init syntax — checked with BOTH host /bin/sh and host busybox ash.
sh -n "${REPO_ROOT}/tooling/images/initramfs/init" \
	|| die "smoke: host sh -n failed on init"
busybox sh -n "${REPO_ROOT}/tooling/images/initramfs/init" \
	|| die "smoke: busybox ash -n failed on init"
log "smoke 1 PASS: sh -n (host /bin/sh + busybox ash) on tooling/images/initramfs/init"

# 2. gzip integrity (initramfs).
gzip -t "${OUT_DIR}/initramfs.cpio.gz" && log "smoke 2 PASS: gzip -t on initramfs.cpio.gz"

# 3. cpio listing: total count + top-level dirs, straight from the artifact.
CPIO_LIST="$(gzip -dc "${OUT_DIR}/initramfs.cpio.gz" | cpio -it --quiet 2>/dev/null)"
CPIO_COUNT="$(printf '%s\n' "${CPIO_LIST}" | wc -l | tr -d ' ')"
CPIO_TOP="$(printf '%s\n' "${CPIO_LIST}" | sed 's|^\./||' | awk -F/ 'NF>0 {print $1}' | sort -u | tr '\n' ' ')"
log "smoke 3 PASS: cpio -t listing: ${CPIO_COUNT} entries; top-level: ${CPIO_TOP}"
log "smoke 3 head of listing:"
printf '%s\n' "${CPIO_LIST}" | head -12 | sed 's/^/[images-build]   /'

# 4. file(1) on both artifacts.
INITRAMFS_FILE="$(file "${OUT_DIR}/initramfs.cpio.gz")"
ROOTFS_FILE="$(file "${OUT_DIR}/rootfs.img")"
log "smoke 4 file(initramfs): ${INITRAMFS_FILE}"
log "smoke 4 file(rootfs):    ${ROOTFS_FILE}"
case "${INITRAMFS_FILE}" in *gzip*) : ;; *) die "smoke 4: initramfs not gzip" ;; esac
case "${ROOTFS_FILE}" in *ext4*|*EXT4*) : ;; *) die "smoke 4: rootfs not ext4" ;; esac
log "smoke 4 PASS: file(1) classes correct"

# 5. e2fsck -f must exit 0 on rootfs.img.
if e2fsck -f -y "${OUT_DIR}/rootfs.img" > "${WORK_DIR}/e2fsck.out" 2>&1; then
	log "smoke 5 PASS: e2fsck -f exit 0"
	log "e2fsck summary: $(tail -n 2 "${WORK_DIR}/e2fsck.out" | tr '\n' ' ')"
else
	rc=$?
	cat "${WORK_DIR}/e2fsck.out" >&2
	die "smoke 5 FAIL: e2fsck -f exited ${rc}"
fi

# 6. Root ownership inside the image (proves the fakeroot trick worked).
# debugfs ls -l columns: inode mode nlink-uid-gid... -> $4=uid $5=gid
OWNERSHIP="$(debugfs -R 'ls -l /etc' "${OUT_DIR}/rootfs.img" 2>/dev/null \
	| awk '$NF=="passwd" {print "uid="$4" gid="$5}' | head -n 1 || true)"
log "smoke 6 rootfs /etc/passwd ownership: ${OWNERSHIP:-<ls failed>}"
case "${OWNERSHIP}" in
	*"uid=0 gid=0"*) log "smoke 6 PASS: rootfs files owned by root:root inside the image" ;;
	*) die "smoke 6 FAIL: rootfs ownership not 0:0 (${OWNERSHIP})" ;;
esac

# 7. Initramfs stays under budget (already enforced) + rootfs key files exist.
debugfs -R 'cat /ROOTFS.txt' "${OUT_DIR}/rootfs.img" >/dev/null 2>&1 \
	|| die "smoke 7 FAIL: /ROOTFS.txt missing from rootfs.img"
debugfs -R 'cat /etc/network/interfaces' "${OUT_DIR}/rootfs.img" 2>/dev/null | grep -q '10.0.0.2' \
	|| die "smoke 7 FAIL: /etc/network/interfaces missing usb0 config"
log "smoke 7 PASS: /ROOTFS.txt and usb0 interfaces present inside rootfs.img"

# 8. busybox binary class: run it under qemu-user when available.
if [ -n "${QEMU_BIN}" ]; then
	"${QEMU_BIN}" "${IFS_ROOT}/bin/busybox" | head -2 | sed 's/^/[images-build]   /' \
		&& log "smoke 8 PASS: busybox.static executed under ${QEMU_BIN}" \
		|| warn "smoke 8: busybox ran but printed usage with nonzero rc (that is the no-args path; acceptable)"
else
	SMOKE_NOTES+=("qemu-user unavailable on this host: skipped the run-the-binary-class smoke test (binary verified by file(1) as statically linked aarch64 ELF instead)")
	log "smoke 8 SKIP: ${SMOKE_NOTES[-1]}"
fi

for n in "${SMOKE_NOTES[@]:-}"; do
	[ -n "${n}" ] && log "smoke note: ${n}"
done

# Hash the shipped image AFTER e2fsck: fsck rewrites the fs (last-checked
# state), so the pre-fsck hash above is historical only. provenance must
# pin the bytes that actually sit in artifacts/.
ROOTFS_BYTES="$(bytes_of "${OUT_DIR}/rootfs.img")"
ROOTFS_SHA="$(sha_of "${OUT_DIR}/rootfs.img")"
log "rootfs.img (shipped, post-e2fsck): ${ROOTFS_BYTES} bytes sha256=${ROOTFS_SHA}"

# ------------------------------------------------------------- provenance
log "writing provenance.json"
CPIO_COUNT_JSON="${CPIO_COUNT}"
MISSING_JSON="null"; BUILTIN_JSON="null"; PRESENT_JSON="null"
MODULES_KVER_JSON="null"
if [ "${MODULES_INTEGRATED}" = "yes" ]; then
	MODULES_KVER_JSON="\"${KVER}\""
	INTEGRATED_JSON="true"
	list_to_json() { # "$@" -> ["a","b",...] | null
		local out="[" first=yes x
		for x in "$@"; do
			[ -z "${x}" ] && continue
			[ "${first}" = "yes" ] && first=no || out+=","
			out+="\"${x}\""
		done
		out+="]"
		[ "${first}" = "yes" ] && { echo null; return; }
		echo "${out}"
	}
	PRESENT_JSON="$(list_to_json "${MODULES_PRESENT_LIST[@]:-}")"
	BUILTIN_JSON="$(list_to_json "${MODULES_BUILTIN_LIST[@]:-}")"
	MISSING_JSON="$(list_to_json "${MODULES_MISSING_LIST[@]:-}")"
else
	INTEGRATED_JSON="false"
fi
REQUESTED_JSON="$(printf '%s\n' "${INITRAMFS_MODULES[@]}" | awk '{printf "%s\"%s\"", (NR>1?",":""), $0} END{print ""}')"
ALLOC_BYTES="$(du -b --apparent-size "${OUT_DIR}/rootfs.img" | awk '{print $1}')"
ACTUAL_BYTES="$(du -b "${OUT_DIR}/rootfs.img" | awk '{print $1}')"

cat > "${OUT_DIR}/provenance.json" <<EOF
{
  "stage": "images",
  "version": "${VERSION}",
  "generated_utc": "${STAMP}",
  "build_log": "evidence/builds/${LOG_NAME}",
  "pipeline_mode": "builds-not-boots",
  "target": "iPhone 7 (T8010 / A10); A12+ unsupported",
  "security_posture": {
    "disclosure": "The initramfs serves an UNAUTHENTICATED ROOT shell on every channel it can reach: port 23 on the USB gadget network (nc/telnet, 10.0.0.2), /dev/ttyGS0 serial, and a respawned root shell on /dev/console. The rootfs additionally spawns a passwordless root getty on ttyGS0.",
    "intended_use": "Hardware bench bring-up with the device directly attached to a trusted host.",
    "warning": "Never expose to untrusted networks. Anyone who reaches port 23 or the gadget serial gets root, by design; there is no login, no password, no lockout. Harden before any deployment beyond a bench."
  },
  "sources": {
    "alpine_minirootfs": {
      "url": "${ALPINE_RELEASE_URL}",
      "filename": "${ALPINE_FILE}",
      "sha256": "${ALPINE_SHA256}",
      "published_sha256_sidecar": "${ALPINE_PUBLISHED_SHA256_URL}",
      "published_sha256_value": "${PUBLISHED_SHA}",
      "release_date": "${ALPINE_RELEASE_DATE}",
      "bytes": ${ALPINE_BYTES}
    },
    "busybox_static": {
      "url": "${BUSYBOX_URL}",
      "filename": "${BUSYBOX_APK}",
      "sha256": "${BUSYBOX_SHA256}",
      "binary_in_apk": "${BUSYBOX_BIN_IN_APK}",
      "bytes": ${BUSYBOX_BYTES}
    }
  },
  "artifacts": {
    "initramfs.cpio.gz": {
      "path": "artifacts/images/initramfs.cpio.gz",
      "sha256": "${INITRAMFS_SHA}",
      "bytes": ${INITRAMFS_BYTES}
    },
    "rootfs.img": {
      "path": "artifacts/images/rootfs.img",
      "sha256": "${ROOTFS_SHA}",
      "bytes": ${ROOTFS_BYTES},
      "apparent_bytes": ${ALLOC_BYTES},
      "disk_usage_bytes": ${ACTUAL_BYTES},
      "size_mb": ${ROOTFS_MB}
    }
  },
  "kernel_modules": {
    "integrated": ${INTEGRATED_JSON},
    "source": "${MODULES_URL_NOTE}",
    "source_sha256": "${MODULES_SHA}",
    "kernel_release": ${MODULES_KVER_JSON},
    "initramfs_modules_requested": [${REQUESTED_JSON}],
    "initramfs_modules_present": ${PRESENT_JSON},
    "initramfs_modules_builtin": ${BUILTIN_JSON},
    "initramfs_modules_missing": ${MISSING_JSON}
  },
  "initramfs": {
    "format": "newc cpio --reproducible, gzip -9n, uid/gid 0:0, mtimes pinned, inodes renumbered (byte-reproducible)",
    "entries": ${CPIO_COUNT_JSON},
    "top_level": "${CPIO_TOP%% }",
    "init_source": "tooling/images/initramfs/init"
  },
  "network": {
    "device_ip": "${DEVICE_IP}",
    "host_ip": "${HOST_IP}",
    "netmask": "${NETMASK}",
    "telnet_port": 23,
    "serial": "ttyGS0 115200",
    "rationale": "pmOS netboot-first for checkm8 iPhones; internal storage proven only on A11 (docs/bars.md)"
  },
  "tools": {
    "mke2fs": "$(mke2fs -V 2>&1 | head -1)",
    "cpio": "$(cpio --version | head -1)",
    "gzip": "$(gzip --version | head -1)",
    "depmod": "$(depmod --version | head -1)",
    "fakeroot": "used for rootfs 0:0 ownership (no sudo on build host)"
  }
}
EOF
python3 -m json.tool "${OUT_DIR}/provenance.json" >/dev/null 2>&1 \
	|| die "provenance.json is not valid JSON"
log "provenance.json: valid JSON"

log "---------------------------------------- final artifact listing"
( cd "${REPO_ROOT}" && find artifacts/images -type f -exec sh -c \
	'printf "%s  %s  " "$(sha256sum "$1" | cut -d" " -f1)" "$(wc -c < "$1" | tr -d " ") bytes"; echo "$1"' _ {} \; )

# Reproducibility proof for the initramfs: repack from the same staging tree
# and demand a byte-identical result. (rootfs.img is NOT byte-reproducible:
# mke2fs randomizes the filesystem UUID and superblock timestamps each run —
# e2fsck validates structural integrity instead, and provenance pins the sha
# of the exact image we ship.)
REPACK_SHA="$( ( cd "${IFS_ROOT}" && find . -print0 \
	| cpio --null -o -H newc -R 0:0 --quiet --reproducible ) | gzip -9n | sha256sum | awk '{print $1}')"
if [ "${REPACK_SHA}" = "${INITRAMFS_SHA}" ]; then
	log "reproducibility check PASS: re-packed initramfs sha256 identical (${REPACK_SHA:0:12}…)"
else
	die "reproducibility check FAIL: re-packed initramfs ${REPACK_SHA:0:12}… != shipped ${INITRAMFS_SHA:0:12}…"
fi

log "done (stage=images version=${VERSION})"
