#!/usr/bin/env bash
#
# pomme — local CI entry point.
#
# For each pipeline stage: build it (skipping gracefully — with a reason — if
# tooling/<stage>/build.sh does not exist yet), regenerate
# artifacts/manifest.json, run scripts/verify.sh, and grep each built stage's
# latest log for its success marker. Writes the full transcript plus a final
# PASS/FAIL summary to evidence/ci-local_<timestamp>.log (committed evidence).
#
# Usage:
#   scripts/ci-local.sh                        # all four stages
#   POMME_LOCAL_CI_STAGES="gaster pongoos" scripts/ci-local.sh
#
# Exit codes: 0 = PASS (or all-requested-stages skipped), nonzero = FAIL.
# Non-interactive, idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

LOGDIR="evidence/builds"
STAGES="${POMME_LOCAL_CI_STAGES:-gaster pongoos kernel images}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="evidence/ci-local_${TS}.log"
mkdir -p "${LOGDIR}"

RESULT=0
declare -a SUMMARY=()

hdr() { printf '\n═══ %s ═══\n' "$*"; }
ok()  { SUMMARY+=("PASS: $*"); printf 'ci-local: PASS: %s\n' "$*"; }
bad() { RESULT=1; SUMMARY+=("FAIL: $*"); printf 'ci-local: FAIL: %s\n' "$*"; }
skip() { SUMMARY+=("SKIP: $*"); printf 'ci-local: SKIP: %s\n' "$*"; }

# Success marker per stage: the exact line its build.sh prints on success.
# Stages whose build.sh does not exist yet use the generic fallback pattern.
stage_marker() {
	case "$1" in
		gaster)  printf '%s' 'smoke_test_result: PASS' ;;
		pongoos) printf '%s' '\[pongoos-build\] OK' ;;
		kernel)  printf '%s' '\[kernel-build\] DONE stage=kernel' ;;
		images)  printf '%s' 'done \(stage=images version=' ;;
		*)       printf '%s' 'smoke_test_result: PASS|\[.*-build\] OK|build OK' ;;
	esac
}

build_stage() {
	local stage="$1" latest marker
	hdr "stage: ${stage}"

	if [ ! -f "tooling/${stage}/build.sh" ]; then
		skip "${stage}: tooling/${stage}/build.sh absent — stage not implemented yet"
		return 0
	fi

	printf 'ci-local: building %s: make %s (log: %s/%s_<ts>.log)\n' \
		"${stage}" "${stage}" "${LOGDIR}" "${stage}"
	if ! make "${stage}"; then
		bad "${stage}: make failed (see latest ${LOGDIR}/${stage}_*.log)"
		return 0
	fi
	ok "${stage}: build completed"

	latest="$(ls -1t "${LOGDIR}/${stage}"_*.log 2>/dev/null | head -n1 || true)"
	if [ -z "${latest}" ]; then
		bad "${stage}: no build log written to ${LOGDIR}/"
		return 0
	fi

	marker="$(stage_marker "${stage}")"
	if grep -Eq "${marker}" "${latest}"; then
		ok "${stage}: success marker found in ${latest} (pattern: ${marker})"
	else
		bad "${stage}: success marker NOT found in ${latest} (pattern: ${marker})"
	fi
}

main() {
	hdr "pomme local CI — stages: ${STAGES} — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'ci-local: VERSION %s\n' "$(cat VERSION 2>/dev/null || echo 'MISSING')"

	for stage in ${STAGES}; do
		case "${stage}" in
			gaster|pongoos|kernel|images) build_stage "${stage}" ;;
			*) bad "unknown stage: ${stage} (valid: gaster pongoos kernel images)" ;;
		esac
	done

	hdr "manifest + doc-sync + verify"
	if bash scripts/manifest.sh; then
		ok "manifest: artifacts/manifest.json generated"
	else
		bad "manifest: scripts/manifest.sh failed"
	fi
	# Doc hash tables are generated state: after any stage re-run they must be
	# resynced BEFORE verification (rootfs.img is non-reproducible by design,
	# so a rebuild always moves its hash). Changes are left in the working
	# tree for the developer to commit; CI enforces the committed sync.
	if python3 scripts/update_doc_hashes.py; then
		ok "docs-sync: doc hash tables match the regenerated manifest"
	else
		bad "docs-sync: scripts/update_doc_hashes.py failed"
	fi
	if bash scripts/verify.sh; then
		ok "verify: scripts/verify.sh PASS"
	else
		bad "verify: scripts/verify.sh FAIL"
	fi

	hdr "summary"
	local line
	for line in "${SUMMARY[@]}"; do
		printf '  %s\n' "${line}"
	done
	if [ "${RESULT}" -eq 0 ]; then
		printf 'ci-local: RESULT: PASS\n'
	else
		printf 'ci-local: RESULT: FAIL\n'
	fi
}

mkdir -p "$(dirname "${OUT}")"
main 2>&1 | tee "${OUT}"
rc=${PIPESTATUS[0]}
printf 'ci-local: transcript: %s\n' "${OUT}" >&2
exit "${rc}"
