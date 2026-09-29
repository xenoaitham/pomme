#!/usr/bin/env python3
"""Log↔hash cross-check against the PUSHED state (CI verify job, step b).

For every stage in artifacts/manifest.json, the cited build_log must
contain at least one of that stage's shipped artifact hashes. Run AFTER
restoring the pushed manifest (`git show HEAD:artifacts/manifest.json >
artifacts/manifest.json`) so it tests the committed evidence chain rather
than CI-rebuilt artifacts — verify.sh skips its inline copy of this check
under POMME_VERIFY_SKIP_DOC_GATE for exactly that reason.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "artifacts", "manifest.json")


def main() -> int:
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    failures = 0
    for stage in m.get("artifacts", []):
        name = stage.get("stage", "<no-stage>")
        log = stage.get("build_log", "")
        path = os.path.join(ROOT, log)
        hashes = [f["sha256"] for f in stage.get("files", [])]
        if not os.path.isfile(path):
            print(f"FAIL: {name}: build_log missing: {log}")
            failures += 1
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        if hashes and not any(h in text for h in hashes):
            print(f"FAIL: {name}: build_log {log} contains none of the shipped "
                  "artifact hashes (stale log pointer?)")
            failures += 1
        else:
            print(f"PASS: {name}: build_log cites shipped artifact hash(es)")
    print(f"log-hash-gate: {'PASS' if failures == 0 else 'FAIL'} ({failures} failure(s))")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
