#!/usr/bin/env bash
# pomme — independent re-verification of artifacts/manifest.json.
#
# Does NOT trust the generator: recomputes every sha256 and size listed in
# the manifest, resolves provenance cross-references, and validates every
# upstream pin file. Checks performed:
#
#   1. VERSION exists and is MAJOR.MINOR.PATCH
#   2. docs/pipeline-conventions.md exists
#   3. artifacts/manifest.json exists and parses as JSON
#   4. every manifest file entry: exists, sha256 matches, byte size matches
#   5. each manifest stage: artifacts/<stage>/provenance.json exists and
#      its manifest build_log resolves to a real file under evidence/builds/
#   6. each manifest upstream_ref has a matching evidence/upstream-pins/<pin>.json
#   7. every evidence/upstream-pins/*.json parses as JSON
#
# Prints a PASS/FAIL report and exits nonzero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/artifacts/manifest.json"
PINS_DIR="${REPO_ROOT}/evidence/upstream-pins"

command -v python3 >/dev/null 2>&1 || { echo "verify: python3 required" >&2; exit 1; }

FAILURES=0
declare -a REPORT=()
note() { REPORT+=("$1"); printf '%s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); REPORT+=("FAIL: $1"); printf 'FAIL: %s\n' "$1" >&2; }

# ---- shell-level checks (1, 2) ----------------------------------------------
if [ -f "${REPO_ROOT}/VERSION" ] \
	&& grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "${REPO_ROOT}/VERSION"; then
	note "PASS: VERSION present ($(tr -d '[:space:]' < "${REPO_ROOT}/VERSION"))"
else
	fail "VERSION missing or not MAJOR.MINOR.PATCH (${REPO_ROOT}/VERSION)"
fi

if [ -f "${REPO_ROOT}/docs/pipeline-conventions.md" ]; then
	note "PASS: docs/pipeline-conventions.md present"
else
	fail "docs/pipeline-conventions.md missing"
fi

# ---- manifest + evidence checks (3-7) ---------------------------------------
if [ ! -f "${MANIFEST}" ]; then
	fail "artifacts/manifest.json missing (run scripts/manifest.sh after a build)"
else
	# Everything JSON/hash-related in one python pass; human-readable output.
	OUT="$(python3 - "${REPO_ROOT}" <<'PYEOF'
import hashlib, json, os, sys

root = sys.argv[1]
manifest_path = os.path.join(root, "artifacts", "manifest.json")
pins_dir = os.path.join(root, "evidence", "upstream-pins")
fails = 0
def ok(msg): print("PASS:", msg)
def bad(msg):
    global fails
    fails += 1
    print("FAIL:", msg)

try:
    with open(manifest_path, "r", encoding="utf-8") as f:
        m = json.load(f)
    ok("artifacts/manifest.json parses as JSON")
except Exception as e:
    bad(f"artifacts/manifest.json unreadable/unparseable: {e}")
    print(f"__VERIFY_RC__ {fails}")
    sys.exit(0)

if m.get("version") != open(os.path.join(root, "VERSION")).read().strip():
    bad(f"manifest version {m.get('version')!r} != VERSION file")
else:
    ok(f"manifest version matches VERSION file ({m.get('version')})")

stages = m.get("artifacts")
if not isinstance(stages, list) or not stages:
    bad("manifest has no artifacts[] entries")
    stages = []

for a in stages:
    stage = a.get("stage", "<no-stage>")
    prov_rel = os.path.join("artifacts", stage, "provenance.json")
    if os.path.isfile(os.path.join(root, prov_rel)):
        ok(f"{stage}: {prov_rel} present")
    else:
        bad(f"{stage}: {prov_rel} missing (manifest entry without provenance)")

    for fe in a.get("files", []):
        rel = fe.get("path", "<none>")
        apath = os.path.join(root, rel)
        if not os.path.isfile(apath):
            bad(f"{stage}: artifact missing: {rel}")
            continue
        raw = open(apath, "rb").read()
        got = hashlib.sha256(raw).hexdigest()
        if got != fe.get("sha256"):
            bad(f"{stage}: sha256 mismatch: {rel} (manifest {fe.get('sha256')}, actual {got})")
        else:
            ok(f"{stage}: sha256 OK: {rel}")
        if isinstance(fe.get("bytes"), int) and len(raw) != fe["bytes"]:
            bad(f"{stage}: size mismatch: {rel} (manifest {fe['bytes']}, actual {len(raw)})")

    log = a.get("build_log", "")
    if not log:
        bad(f"{stage}: manifest entry has no build_log")
    elif not os.path.isfile(os.path.join(root, log)):
        bad(f"{stage}: build_log missing: {log}")
    else:
        ok(f"{stage}: build_log present: {log}")
        # the cited log must be the log of the producing run: at least one
        # shipped artifact's sha256 must appear in it (catches the stale-
        # log-pointer class — a rebuild that moved hashes but not the log)
        try:
            logtext = open(os.path.join(root, log), encoding="utf-8", errors="replace").read()
            hashes = [f["sha256"] for f in a.get("files", [])]
            if hashes and not any(h in logtext for h in hashes):
                bad(f"{stage}: build_log {log} contains none of this stage's shipped artifact hashes (stale log pointer?)")
            elif hashes:
                ok(f"{stage}: build_log cites shipped artifact hash(es)")
        except Exception as e:
            bad(f"{stage}: build_log unreadable: {log}: {e}")

    for r in a.get("upstream_refs", []):
        pin = r.get("pin", "")
        kind = r.get("kind", "primary")
        pin_path = os.path.join(pins_dir, f"{pin}.json")
        if kind == "unresolved":
            bad(f"{stage}: upstream pin unresolvable for url {r.get('url')} (no evidence/upstream-pins match, direct or as submodule)")
            continue
        if not pin:
            bad(f"{stage}: upstream_ref without pin name: {r}")
            continue
        if not os.path.isfile(pin_path):
            bad(f"{stage}: upstream pin missing: {pin_path} (url {r.get('url')})")
            continue
        try:
            pdata = json.load(open(pin_path, encoding="utf-8"))
        except Exception as e:
            bad(f"{stage}: upstream pin {pin}.json unparseable: {e}")
            continue
        if kind == "submodule":
            subs = pdata.get("submodules") or []
            if any(isinstance(s, dict) and s.get("url") == r.get("url") and s.get("commit") == r.get("commit") for s in subs):
                ok(f"{stage}: upstream pin resolves (submodule of {pin}.json): {r.get('url')} ({r.get('commit', '')[:12]})")
            else:
                bad(f"{stage}: pin {pin}.json lists no submodule matching {r.get('url')} @ {r.get('commit')}")
        elif pdata.get("commit") != r.get("commit") or pdata.get("url") != r.get("url"):
            bad(f"{stage}: pin {pin}.json ({pdata.get('commit')} @ {pdata.get('url')}) != manifest ref ({r.get('commit')} @ {r.get('url')})")
        else:
            ok(f"{stage}: upstream pin resolves: {pin}.json ({pdata.get('commit')[:12]})")

# every pin file in evidence/ must parse, whether referenced or not
if os.path.isdir(pins_dir):
    for name in sorted(os.listdir(pins_dir)):
        if not name.endswith(".json"):
            continue
        try:
            json.load(open(os.path.join(pins_dir, name), encoding="utf-8"))
            ok(f"upstream pin parses: {name}")
        except Exception as e:
            bad(f"upstream pin unparseable: {name}: {e}")
else:
    bad(f"evidence/upstream-pins/ directory missing")

print(f"__VERIFY_RC__ {fails}")
PYEOF
)"
	printf '%s\n' "${OUT}"
	RC_LINE="$(printf '%s\n' "${OUT}" | grep '^__VERIFY_RC__' | tail -1 | awk '{print $2}')"
	if [ -n "${RC_LINE}" ] && [ "${RC_LINE}" -gt 0 ]; then
		FAILURES=$((FAILURES + RC_LINE))
	fi
fi

# shipped docs must never quote artifact hashes superseded by the current
# manifest (scripts/check_doc_hashes.py; failure mode caught by integration
# review: doc hash tables lagging an images-stage re-run)
if ! DOC_DRIFT="$(python3 "${REPO_ROOT}/scripts/check_doc_hashes.py" 2>&1)"; then
	printf '%s\n' "${DOC_DRIFT}"
	FAILURES=$((FAILURES + 1))
	REPORT+=("doc-hash-drift: FAIL")
else
	printf '%s\n' "${DOC_DRIFT}"
	REPORT+=("doc-hash-drift: OK")
fi

echo
echo "== verify summary =="
TOTAL=${#REPORT[@]}
echo "shell-level check groups: ${TOTAL}, failures: ${FAILURES} (per-artifact counts above)"
if [ "${FAILURES}" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
else
	echo "RESULT: FAIL"
	exit 1
fi
