#!/usr/bin/env python3
"""Drift catcher: shipped docs must never quote a stale artifact hash.

Rule: collect every hex token (>=8 chars) from README.md, RESUME.md and
docs/*.md. A token is STALE iff it does NOT prefix-match any hash in the
current artifacts/manifest.json but DOES prefix-match a hash in the
last committed manifest (git HEAD). That is exactly the defect class the
integration critic caught: an images-stage re-run ships new bytes, the
manifest moves on, and a hand-copied doc table keeps quoting the old hash.

Tokens unrelated to the manifest (upstream commit pins, short flags) are
ignored: they never matched any manifest hash, past or present.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC_FILES = [
    ROOT / "README.md",
    ROOT / "RESUME.md",
    *sorted((ROOT / "docs").glob("*.md")),
]
MANIFEST = ROOT / "artifacts" / "manifest.json"
HEX = re.compile(r"\b[0-9a-f]{8,64}\b")


def manifest_hashes(text: str) -> set[str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return set()
    out: set[str] = set()
    for stage in data.get("artifacts", []):
        for f in stage.get("files", []):
            out.add(f["sha256"])
    return out


def main() -> int:
    current = manifest_hashes(MANIFEST.read_text())
    try:
        head = subprocess.run(
            ["git", "-C", str(ROOT), "show", "HEAD:artifacts/manifest.json"],
            capture_output=True, text=True, check=True,
        ).stdout
        historical = manifest_hashes(head) - current
    except subprocess.CalledProcessError:
        historical = set()

    if not historical:
        print("doc-hash-drift: PASS (no superseded manifest hashes to check against yet)")
        return 0

    failures: list[str] = []
    checked = 0
    for doc in DOC_FILES:
        if not doc.exists():
            continue
        for tok in HEX.findall(doc.read_text()):
            for old in historical:
                if old.startswith(tok) or tok.startswith(old):
                    checked += 1
                    ok = any(cur.startswith(tok) for cur in current)
                    if not ok:
                        failures.append(
                            f"{doc.relative_to(ROOT)}: stale hash {tok} "
                            f"(superseded {old[:12]}…)"
                        )
                    break

    if failures:
        print("doc-hash-drift: FAIL — shipped docs quote artifact hashes that "
              "were superseded by the current manifest; regenerate the doc "
              "hash tables:")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"doc-hash-drift: PASS ({checked} doc tokens matched, none stale)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
