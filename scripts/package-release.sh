#!/usr/bin/env bash
# pomme — stage the v0.1.0 GitHub Release artifacts from the local build.
#
# Packages every manifest stage's shipped files into release-asset form:
#   - loose binaries for the small artifacts
#   - dtbs-<flavor>.tar.gz for the DTB sets
#   - SHA256SUMS covering every staged file (must equal artifacts/manifest.json)
#
# The released bytes are the LOCAL artifacts whose hashes the committed
# manifest pins (hosted-CI rebuilds are byte-different for pongoos by
# design — see tooling/pongoos/README.md reproducibility notes).
# Usage: bash scripts/package-release.sh [dest-dir]   (default out/release)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-${REPO_ROOT}/out/release}"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# Guard the destructive reset: DEST must be an absolute path of sane length,
# not the repo root or anything above it (the default is <repo>/out/release).
case "${DEST}" in
	"${REPO_ROOT}"|/|/home|/tmp|"$(dirname "${REPO_ROOT}")"|/) echo "refusing DEST=${DEST}" >&2; exit 1 ;;
	/*) : ;;
	*) echo "DEST must be an absolute path" >&2; exit 1 ;;
esac
[ "$(printf '%s' "${DEST}" | wc -c)" -lt 200 ] || { echo "refusing implausible DEST" >&2; exit 1; }

rm -rf "${DEST}"
mkdir -p "${DEST}"

# Copy each manifest-listed file, renamed <stage>-<basename> to keep assets flat.
python3 - "${REPO_ROOT}" "${DEST}" <<'PYEOF'
import json, os, shutil, subprocess, sys

root, dest = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(root, "artifacts", "manifest.json"), encoding="utf-8"))
copied = []
for stage in m["artifacts"]:
    name = stage["stage"]
    for f in stage["files"]:
        rel = f["path"]
        src = os.path.join(root, rel)
        base = os.path.basename(rel)
        if base.endswith(".dtb"):
            continue  # DTBs ship as one tarball per flavor (below)
        dst = os.path.join(dest, f"{name}-{base}" if not base.startswith(name) else base)
        shutil.copy2(src, dst)
        copied.append((os.path.basename(dst), f["sha256"], f["bytes"]))
# DTB tarballs, deterministic flags, per flavor
for flavor, artdir in (("16k", "artifacts/kernel"), ("4k", "artifacts/kernel-4k")):
    dtbdir = os.path.join(root, artdir, "dtbs")
    out = os.path.join(dest, f"dtbs-{flavor}.tar.gz")
    subprocess.run(["tar", "-C", dtbdir, "--sort=name", "--owner=0", "--group=0",
                    "--numeric-owner", "--mtime=@1781222400", "-czf", out, "."], check=True)
    raw = open(out, "rb").read()
    import hashlib
    copied.append((f"dtbs-{flavor}.tar.gz", hashlib.sha256(raw).hexdigest(), len(raw)))
with open(os.path.join(dest, "SHA256SUMS.copied"), "w") as f:
    for name, sha, _ in sorted(copied):
        f.write(f"{sha}  {name}\n")
print(f"staged {len(copied)} assets in {dest}")
PYEOF

# SHA256SUMS over the staged bytes (ground truth of what is uploaded)
( cd "${DEST}" && sha256sum -- *.gz *.bin *.img * 2>/dev/null | grep -v SHA256SUMS | sort -k2 > SHA256SUMS )
rm -f "${DEST}/SHA256SUMS.copied"

echo "== release staging =="
ls -la "${DEST}"
echo
echo "total upload size:"
du -sh "${DEST}"
