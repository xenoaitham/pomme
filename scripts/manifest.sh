#!/usr/bin/env bash
# pomme — artifacts/manifest.json generator.
#
# Walks artifacts/<stage>/provenance.json for every pipeline stage
# (gaster, pongoos, kernel, images) and emits a single manifest recording:
#   { version, generated_utc, repo_commit,
#     artifacts: [ { stage, files: [{path, sha256, bytes}],
#                    upstream_refs, build_log } ] }
#
# Contract (docs/pipeline-conventions.md):
#   - a stage whose provenance.json does not exist yet is SKIPPED
#     (kernel/images may legitimately not be built);
#   - a provenance.json that references an artifact file which is missing,
#     hash-mismatched, or size-mismatched is FATAL (the stage is lying).
#
# After writing, the manifest is re-parsed and internally validated, then a
# summary table is printed. Non-interactive, idempotent, exit 0 on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/artifacts/manifest.json"
PINS_DIR="${REPO_ROOT}/evidence/upstream-pins"
STAGES=(gaster pongoos kernel images m1n1 kernel-4k images-4k)

command -v python3 >/dev/null 2>&1 || { echo "manifest: python3 required" >&2; exit 1; }

VERSION="unknown"
if [ -f "${REPO_ROOT}/VERSION" ]; then
	VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
fi

REPO_COMMIT="unknown"
if git -C "${REPO_ROOT}" rev-parse HEAD >/dev/null 2>&1; then
	REPO_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
fi

# find_pin <url> -> prints pin filename stem (without .json) or nothing.
# Matches evidence/upstream-pins/*.json on their "url" field.
find_pin() {
	python3 - "$1" "${PINS_DIR}" <<'PYEOF'
import json, sys, pathlib
url, pins_dir = sys.argv[1], pathlib.Path(sys.argv[2])
if pins_dir.is_dir():
    for p in sorted(pins_dir.glob("*.json")):
        try:
            data = json.loads(p.read_text())
        except Exception:
            continue
        if data.get("url") == url:
            print(p.stem)
            break
PYEOF
}

# stage_entry <stage> -> emits the manifest JSON object for one stage on
# stdout, or nothing when the stage has no provenance yet. Dies on any
# artifact file that is missing or whose sha256/size does not match
# what the provenance claims.
stage_entry() {
	python3 - "$1" "${REPO_ROOT}" <<'PYEOF'
import hashlib, json, os, sys

stage, root = sys.argv[1], sys.argv[2]
prov_path = os.path.join(root, "artifacts", stage, "provenance.json")
if not os.path.isfile(prov_path):
    sys.exit(0)  # stage not built yet -> skipped by caller

with open(prov_path, "r", encoding="utf-8") as f:
    prov = json.load(f)

def die(msg):
    print(f"manifest: FATAL ({stage}): {msg}", file=sys.stderr)
    sys.exit(1)

# Accept both provenance layouts seen in this repo:
#   gaster/pongoos:  "artifact_files": [ {path, sha256, bytes}, ... ]
#   images:          "artifacts": { "<name>": {path, sha256, bytes}, ... }
entries = prov.get("artifact_files")
if entries is None:
    arts = prov.get("artifacts")
    if isinstance(arts, dict):
        entries = list(arts.values())
    elif isinstance(arts, list):
        entries = arts
if not isinstance(entries, list) or not entries:
    die(f"{prov_path}: no artifact_files[]/artifacts{{}} entries")

files = []
for e in entries:
    rel = e.get("path")
    if not rel:
        die(f"artifact_files entry without 'path': {e}")
    apath = os.path.join(root, rel)
    if not os.path.isfile(apath):
        die(f"referenced artifact missing: {rel}")
    raw = open(apath, "rb").read()
    got_sha = hashlib.sha256(raw).hexdigest()
    want_sha = e.get("sha256")
    got_bytes = len(raw)
    want_bytes = e.get("bytes")
    if want_sha and got_sha != want_sha:
        die(f"sha256 mismatch for {rel}: provenance says {want_sha}, file is {got_sha}")
    if isinstance(want_bytes, int) and got_bytes != want_bytes:
        die(f"size mismatch for {rel}: provenance says {want_bytes}, file is {got_bytes}")
    files.append({"path": rel, "sha256": got_sha, "bytes": got_bytes})

# Upstream refs: walk the whole provenance JSON and collect every upstream
# (url, commit) pair — either as a nested object carrying "url"+"commit"
# (submodules) or as flat "upstream_url"+"upstream_commit" keys (top level).
refs, seen = [], set()
def add_ref(url, commit):
    if isinstance(url, str) and isinstance(commit, str) and url not in seen:
        seen.add(url)
        refs.append({"url": url, "commit": commit})
def walk(node):
    if isinstance(node, dict):
        add_ref(node.get("url"), node.get("commit"))
        add_ref(node.get("upstream_url"), node.get("upstream_commit"))
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(prov)

# Resolve each ref to a pin file: direct match on the pin's "url" field
# (kind=primary), else as a submodule entry of some pin (kind=submodule),
# else unresolved (verify.sh will fail on that).
pins = []
if os.path.isdir(os.path.join(root, "evidence", "upstream-pins")):
    for p in sorted(os.listdir(os.path.join(root, "evidence", "upstream-pins"))):
        if p.endswith(".json"):
            try:
                with open(os.path.join(root, "evidence", "upstream-pins", p), encoding="utf-8") as f:
                    pins.append((p[:-5], json.load(f)))
            except Exception:
                pass

named_refs = []
for r in refs:
    kind, pin = "unresolved", r["url"].rstrip("/").split("/")[-1].lower()
    for stem, pdata in pins:
        if pdata.get("url") == r["url"]:
            kind, pin = "primary", stem
            break
    if kind == "unresolved":
        for stem, pdata in pins:
            subs = pdata.get("submodules") or []
            if any(isinstance(s, dict) and s.get("url") == r["url"] and s.get("commit") == r["commit"] for s in subs):
                kind, pin = "submodule", stem
                break
    named_refs.append({**r, "pin": pin, "kind": kind})

build_log = prov.get("build_log")
if not isinstance(build_log, str) or not build_log:
    print(f"manifest: WARNING ({stage}): provenance has no build_log field", file=sys.stderr)
    build_log = ""

print(json.dumps({
    "stage": stage,
    "files": files,
    "upstream_refs": named_refs,
    "build_log": build_log,
}))
PYEOF
}

TMP="$(mktemp "${MANIFEST}.tmp.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

{
	printf '{\n'
	printf '  "version": "%s",\n' "${VERSION}"
	printf '  "generated_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '  "repo_commit": "%s",\n' "${REPO_COMMIT}"
	printf '  "artifacts": ['
	first_stage=1
	skipped=""
	for stage in "${STAGES[@]}"; do
		entry="$(stage_entry "${stage}")" || exit 1
		if [ -z "${entry}" ]; then
			skipped="${skipped} ${stage}"
			continue
		fi
		[ "${first_stage}" -eq 1 ] || printf ','
		first_stage=0
		printf '\n    %s' "${entry}"
	done
	printf '\n  ]\n}\n'
} > "${TMP}"

# ---- internal validation: re-parse what we just wrote -----------------------
python3 - "${TMP}" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    m = json.load(f)
for key in ("version", "generated_utc", "repo_commit", "artifacts"):
    assert key in m, f"manifest missing key: {key}"
assert isinstance(m["artifacts"], list)
for a in m["artifacts"]:
    for key in ("stage", "files", "upstream_refs", "build_log"):
        assert key in a, f"{a.get('stage')}: manifest entry missing key: {key}"
    assert a["files"], f"{a['stage']}: empty files[]"
print(f"manifest: internal validation OK ({len(m['artifacts'])} stage entries)")
PYEOF

mkdir -p "$(dirname "${MANIFEST}")"
mv "${TMP}" "${MANIFEST}"
trap - EXIT

# ---- summary table ----------------------------------------------------------
echo
echo "== artifacts/manifest.json summary =="
printf '%-10s %-28s %-12s %-46s %s\n' "STAGE" "FILES" "BYTES" "UPSTREAM COMMIT" "BUILD LOG"
python3 - "${MANIFEST}" "${REPO_ROOT}" <<'PYEOF'
import json, os, sys
m = json.load(open(sys.argv[1]))
root = sys.argv[2]
for a in m["artifacts"]:
    nfiles = len(a["files"])
    total = sum(f["bytes"] for f in a["files"])
    commits = ", ".join(r["commit"][:12] for r in a["upstream_refs"]) or "-"
    log = a["build_log"] or "-"
    log_ok = "OK" if (log == "-" or os.path.isfile(os.path.join(root, log))) else "MISSING"
    print(f"{a['stage']:<10} {nfiles:<28} {total:<12} {commits:<46} {log} [{log_ok}]")
PYEOF
echo
[ -n "${skipped}" ] && echo "manifest: skipped (no provenance yet):${skipped}" || true
echo "manifest: wrote ${MANIFEST}"
