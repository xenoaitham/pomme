#!/usr/bin/env python3
"""Sync the doc hash tables with artifacts/manifest.json.

The three shipped docs (README.md, docs/bring-up.md, RESUME.md) quote
truncated artifact hashes. Hand-copying them guarantees drift: any
images-stage re-run ships a new rootfs.img hash (ext4 UUID/superblock are
randomized per run) and the docs lag behind — the exact defect the
integration review caught. This script makes the tables GENERATED state:

  1. every hex token in the docs that prefix-matches a CURRENT manifest
     hash is already correct and left alone;
  2. every token that matches only an EARLIER COMMITTED manifest hash is
     rewritten to the same artifact's (matched by path) current hash,
     preserving the token's length and its trailing ellipsis — idempotently
     (the ellipsis is consumed by the token match, never duplicated);
  3. the "manifest regenerated <ts>" stamp is rewritten to one canonical
     idempotent form pointing at artifacts/manifest.json; no repo-commit
     sha is paired with it (the manifest always trails HEAD — that pairing
     can never stay in sync).

Modes:
  default      apply changes to the docs (used by `make docs-sync`)
  --check      fail (rc 1) if anything would change (CI: docs must already
               be in sync with the manifest on disk)

Note on scope: only hashes that passed through a committed manifest are
policed. Upstream commit pins etc. live in a different namespace and are
never touched.
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
CANONICAL_STAMP = (
    "manifest regenerated {ts} (authoritative copy: artifacts/manifest.json)"
)
# One idempotent stamp regex: `manifest regenerated <ts>` plus ANY ORDER /
# ANY NUMBER of trailing clauses left by earlier hand-written or generated
# variants (parenthesized authoritative-copy / repo-commit clauses, em-dash
# authoritative clauses, line wraps). Canonical output matches again and is
# rewritten to itself — safe to run forever.
STAMP = re.compile(
    r"manifest regenerated \d{4}-\d{2}-\d{2}T[0-9:]+Z"
    r"(?:[ \t]*(?:\([^)\n]*authoritative[^)\n]*\)"
    r"|[—–-][ \t]*`?authoritative[^)\n]*`?"
    r"|, repo commit[^\n):]*"
    r"))*"
)
TOKEN = re.compile(r"(?<![0-9a-f])([0-9a-f]{8,64})(…+)?")


def manifest_map(text: str) -> dict[str, str]:
    """artifact path -> sha256"""
    out: dict[str, str] = {}
    for stage in json.loads(text).get("artifacts", []):
        for f in stage.get("files", []):
            out[f["path"]] = f["sha256"]
    return out


def historical_maps() -> list[dict[str, str]]:
    """Artifact maps from the last committed manifests (up to 6 commits)."""
    out: list[dict[str, str]] = []
    try:
        revs = subprocess.run(
            ["git", "-C", str(ROOT), "rev-list", "--max-count=6", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
        for rev in revs:
            try:
                blob = subprocess.run(
                    ["git", "-C", str(ROOT), "show", f"{rev}:artifacts/manifest.json"],
                    capture_output=True, text=True, check=True,
                ).stdout
                out.append(manifest_map(blob))
            except subprocess.CalledProcessError:
                continue  # manifest not present at that commit
    except subprocess.CalledProcessError:
        pass
    return out


PATH_REF = re.compile(r"artifacts/[A-Za-z0-9_./-]+")
# tokens that match neither the current nor any committed manifest hash are
# resolved by LINE CONTEXT: doc tables (and prose) state the artifact path on
# the same line, so an orphan token on a line referencing exactly the
# unclaimed artifacts of that line is remapped to those paths' current hashes.


def evidence_hashes() -> set[str]:
    """Every hash quotable as non-artifact evidence: upstream pins (commits,
    submodule pins, checksums) + per-stage provenance values. Tokens in this
    set are NEVER remapping candidates — they are pins, not artifact hashes."""
    out: set[str] = set()
    pins = ROOT / "evidence" / "upstream-pins"
    if pins.is_dir():
        for p in sorted(pins.glob("*.json")):
            out |= recursive_str_hashes(json.loads(p.read_text()))
    for p in sorted((ROOT / "artifacts").glob("*/provenance.json")):
        try:
            out |= recursive_str_hashes(json.loads(p.read_text()))
        except json.JSONDecodeError:
            pass
    return out


def recursive_str_hashes(obj) -> set[str]:
    out: set[str] = set()
    if isinstance(obj, dict):
        for v in obj.values():
            out |= recursive_str_hashes(v)
    elif isinstance(obj, list):
        for v in obj:
            out |= recursive_str_hashes(v)
    elif isinstance(obj, str) and re.fullmatch(r"[0-9a-f]{8,128}", obj):
        out.add(obj)
    return out


def main() -> int:
    check_only = "--check" in sys.argv
    current = manifest_map(MANIFEST.read_text())
    history = historical_maps()
    evidence = evidence_hashes()
    ts = json.loads(MANIFEST.read_text())["generated_utc"]

    total_changes = 0
    for doc in DOC_FILES:
        orig = doc.read_text()
        text = orig
        changes: list[tuple[str, str]] = []

        def fix_token(m: re.Match) -> str:
            tok, ells = m.group(1), m.group(2) or ""
            if any(c.startswith(tok) for c in current.values()):
                # already current — but still normalize doubled ellipses
                return tok + ("…" if ells else "")
            for hmap in history:
                for path, old in hmap.items():
                    if old.startswith(tok):
                        new = current.get(path)
                        if new and not new.startswith(tok):
                            repl = new[: len(tok)] + ("…" if ells else "")
                            changes.append((tok + ells, repl))
                            return repl
                        return tok + ("…" if ells else "")
            return tok + ells  # unresolved here; line pass below decides

        lines = text.split("\n")
        for i, line in enumerate(lines):
            if not any(c in line for c in ("`", "|")):
                continue
            probes = [(m.start(), m.group(1)) for m in TOKEN.finditer(line)]
            # an 8-char all-digit token is a date (log filenames), not a hash
            def orphan(tok: str) -> bool:
                if tok.isdigit() and len(tok) == 8:
                    return False
                if any(c.startswith(tok) for c in current.values()):
                    return False
                # upstream pins / provenance values are evidence, never
                # artifact-hash mapping candidates
                if any(e.startswith(tok) for e in evidence):
                    return False
                return not any(
                    old.startswith(tok) for hmap in history for old in hmap.values()
                )

            orphans = [(pos, tok) for pos, tok in probes if orphan(tok)]
            if not orphans:
                continue
            # candidate artifact paths: full artifacts/… references on the
            # line, plus any manifest path whose basename is mentioned
            cand: list[str] = []
            for p in PATH_REF.finditer(line):
                name = p.group(0).rstrip(".,`;")
                if name in current and name not in cand:
                    cand.append(name)
            for path in current:
                base = path.rsplit("/", 1)[-1]
                # delimited mention only: `rootfs.img`, not a substring of
                # another name (`Image` inside `Image.initramfs`)
                if (f"`{base}`" in line or path in line) and path not in cand:
                    cand.append(path)
            claimed = set()
            for _, tok in probes:
                if tok not in [t for _, t in orphans]:
                    for path in cand:
                        if current[path].startswith(tok):
                            claimed.add(path)
            unclaimed = [p for p in cand if p not in claimed]
            if len(orphans) == 1:
                if not unclaimed:
                    continue
                # proximity: the token belongs to the candidate mentioned
                # closest BEFORE it on the line (else the first after)
                pos = orphans[0][0]

                def mention(p: str) -> int:
                    base = p.rsplit("/", 1)[-1]
                    return max(line.rfind(f"`{base}`"), line.rfind(p))

                before = sorted(
                    (p for p in unclaimed if 0 <= mention(p) < pos),
                    key=mention, reverse=True,
                )
                target = before[0] if before else (unclaimed or cand)[0]
                new = current[target]
                old_line = lines[i]
                m = re.search(re.escape(orphans[0][1]) + "(…+)?", old_line)
                ell = (m.group(1) or "") if m else ""
                repl = new[: len(orphans[0][1])] + ("…" if ell else "")
                lines[i] = (old_line[:orphans[0][0]] + repl
                            + old_line[orphans[0][0] + len(orphans[0][1]) + len(ell):])
                changes.append((orphans[0][1] + ell, repl))
            elif len(unclaimed) == len(orphans):
                for (pos, tok), path in zip(orphans, unclaimed):
                    new = current[path]
                    old_line = lines[i]
                    m = re.search(re.escape(tok) + "(…+)?", old_line)
                    ell = (m.group(1) or "") if m else ""
                    repl = new[: len(tok)] + ("…" if ell else "")
                    lines[i] = old_line[:pos] + repl + old_line[pos + len(tok) + len(ell):]
                    changes.append((tok + ell, repl))
                    delta = len(repl) - (len(tok) + len(ell))
                    orphans = [(p + delta, t) if p > pos else (p, t) for p, t in orphans]
        text = "\n".join(lines)

        new_text = TOKEN.sub(fix_token, text)
        new_text = STAMP.sub(CANONICAL_STAMP.format(ts=ts), new_text)

        if new_text != orig:
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
    if total_changes:
        print(f"doc-hash-sync: ok ({total_changes} token(s) updated)")
    else:
        print("doc-hash-sync: ok (docs already in sync)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
