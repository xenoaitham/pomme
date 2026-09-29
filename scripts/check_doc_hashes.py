#!/usr/bin/env python3
"""Gate: shipped docs may only quote artifact hashes traceable to evidence
in this repository.

Rule: collect every hex token (>=8 chars) from README.md, RESUME.md and
docs/*.md. Each token must prefix-match at least one hash that exists in
the in-tree evidence set:

  - artifacts/manifest.json (current shipped artifact hashes)
  - evidence/upstream-pins/*.json (upstream commit + submodule pins)
  - artifacts/*/provenance.json (toolchain shas, source-archive shas, …)

Anything else — a hash from a run that was never shipped, a typo, residue
from an uncommitted rebuild — fails. This is the strict form of the
doc-drift gate: it catches both "superseded by a re-run" and "never
shipped at all".
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC_FILES = [
    ROOT / "README.md",
    ROOT / "RESUME.md",
    *sorted((ROOT / "docs").glob("*.md")),
]
HEX = re.compile(r"(?<![0-9a-f])([0-9a-f]{8,64})")


def is_date_like(tok: str) -> bool:
    # 8-digit all-number tokens are dates in log filenames (e.g. 20260929)
    return tok.isdigit() and len(tok) == 8


def recursive_hashes(obj) -> set[str]:
    out: set[str] = set()
    if isinstance(obj, dict):
        for v in obj.values():
            out |= recursive_hashes(v)
    elif isinstance(obj, list):
        for v in obj:
            out |= recursive_hashes(v)
    elif isinstance(obj, str) and re.fullmatch(r"[0-9a-f]{8,128}", obj):
        out.add(obj)
    return out


def main() -> int:
    allowed: set[str] = set()

    manifest = ROOT / "artifacts" / "manifest.json"
    if manifest.exists():
        for stage in json.loads(manifest.read_text()).get("artifacts", []):
            for f in stage.get("files", []):
                allowed.add(f["sha256"])

    pins = ROOT / "evidence" / "upstream-pins"
    if pins.is_dir():
        for p in sorted(pins.glob("*.json")):
            allowed |= recursive_hashes(json.loads(p.read_text()))

    for p in sorted((ROOT / "artifacts").glob("*/provenance.json")):
        allowed |= recursive_hashes(json.loads(p.read_text()))

    if not allowed:
        print("doc-hash-gate: no evidence set found (run manifest.sh first?)")
        return 1

    failures: list[str] = []
    checked = 0
    for doc in DOC_FILES:
        if not doc.exists():
            continue
        rel = doc.relative_to(ROOT)
        for m in HEX.finditer(doc.read_text()):
            tok = m.group(1)
            if is_date_like(tok):
                continue
            checked += 1
            if not any(h.startswith(tok) for h in allowed):
                failures.append(f"{rel}: {tok} matches no in-tree evidence hash")

    if failures:
        print("doc-hash-gate: FAIL — docs quote hashes absent from the in-tree "
              "evidence set (never shipped, superseded, or stale):")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"doc-hash-gate: PASS ({checked} doc tokens, all traceable to in-tree evidence)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
