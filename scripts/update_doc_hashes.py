#!/usr/bin/env python3
"""Sync the doc hash tables with artifacts/manifest.json.

The three shipped docs (README.md, docs/bring-up.md, RESUME.md) quote
truncated artifact hashes. Hand-copying them guarantees drift: any
images-stage re-run ships a new rootfs.img hash (ext4 UUID/superblock are
randomized per run) and the docs lag behind — the exact defect the
integration review caught. This script makes the tables GENERATED state:

  1. every hex token in the docs that prefix-matches a CURRENT manifest
     hash is already correct and left alone;
  2. every token that matches only the LAST COMMITTED manifest hash is
     rewritten to the same artifact's current hash, preserving the token's
     length and any trailing ellipsis;
  3. the "manifest regenerated <ts> (repo commit <sha>)" pairings are
     rewritten to the manifest's generated_utc, and the commit-sha pairing
     is dropped (it can never stay in sync — the manifest always trails
     HEAD); docs point at artifacts/manifest.json instead.

Exit 0 always when run as `--apply` (idempotent); run `--check` to fail if
anything would change (CI mode). `make docs-sync` applies; verify.sh's
doc-hash-drift gate plus a `git diff --exit-code` in CI enforce commit-time
sync.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC_FILES = [
    ROOT / "README.md",
    ROOT / "docs" / "bring-up.md",
    ROOT / "RESUME.md",
]
MANIFEST = ROOT / "artifacts" / "manifest.json"
HEX = re.compile(r"\b[0-9a-f]{8,64}\b")
# README/RESUME/bring-up phrase the regenerated-stamp slightly differently;
# normalize all of them to a manifest-pointer form.
STAMP_PATTERNS = [
    (
        re.compile(
            r"manifest regenerated\s+\d{4}-\d{2}-\d{2}T[0-9:]+Z(?:, repo commit `?[0-9a-f]+`?)?"
        ),
        "manifest regenerated {ts} (authoritative copy: artifacts/manifest.json)",
    ),
    (
        re.compile(
            r"regenerated \d{4}-\d{2}-\d{2}T[0-9:]+Z at repo commit `?[0-9a-f]+`?"
        ),
        "regenerated {ts} (authoritative copy: artifacts/manifest.json)",
    ),
    (
        re.compile(
            r"manifest regenerated \d{4}-\d{2}-\d{2}T[0-9:]+Z from repo\n  commit `?[0-9a-f]+`?"
        ),
        "manifest regenerated {ts}\n  (authoritative copy: `artifacts/manifest.json`)",
    ),
]


def manifest_map(text: str) -> dict[str, str]:
    """artifact path -> sha256"""
    out: dict[str, str] = {}
    for stage in json.loads(text).get("artifacts", []):
        for f in stage.get("files", []):
            out[f["path"]] = f["sha256"]
    return out


def main() -> int:
    check_only = "--check" in sys.argv
    current = manifest_map(MANIFEST.read_text())
    try:
        head = subprocess.run(
            ["git", "-C", str(ROOT), "show", "HEAD:artifacts/manifest.json"],
            capture_output=True, text=True, check=True,
        ).stdout
        historical = manifest_map(head)
    except subprocess.CalledProcessError:
        historical = {}
    ts = json.loads(MANIFEST.read_text())["generated_utc"]

    total_changes = 0
    for doc in DOC_FILES:
        text = doc.read_text()
        changes: list[tuple[str, str]] = []

        def fix_token(m: re.Match) -> str:
            tok = m.group(0)
            trail = "…" if text[m.end(): m.end() + 1] == "…" else ""
            if any(c.startswith(tok) for c in current.values()):
                return tok  # already current
            for path, old in historical.items():
                if old.startswith(tok):
                    new = current.get(path)
                    if new and not new.startswith(tok):
                        changes.append((tok, new[: len(tok)] + trail))
                        return new[: len(tok)] + trail
                    return tok  # unchanged artifact, or unknown in current
            return tok

        new_text = HEX.sub(fix_token, text)
        for pat, repl in STAMP_PATTERNS:
            new_text = pat.sub(lambda m: repl.format(ts=ts), new_text)

        if new_text != text:
            total_changes += len(changes)
            rel = doc.relative_to(ROOT)
            for old, new in changes:
                print(f"{rel}: {old} -> {new}")
            if check_only:
                continue
            doc.write_text(new_text)

    if check_only and total_changes:
        print(f"doc-hash-sync: {total_changes} doc hash table entries are stale; "
              "run `make docs-sync` and commit")
        return 1
    print(f"doc-hash-sync: {'CHECK ' if check_only else ''}ok "
          f"({total_changes} token(s) updated)" if total_changes else
          "doc-hash-sync: ok (docs already in sync)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
