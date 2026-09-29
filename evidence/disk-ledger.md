# Disk ledger — multi-gigabyte operations

Kept honest per the release runbook: checked before and after every
multi-gigabyte build. The host is a single 771 GB volume that was already
**98% full (≈22 GB free)** when this phase started; every entry below says
what ran, what it cost, and what is on disk because of it.

| When (UTC) | Operation | Free before | Free after | Net | Notes |
|---|---|---|---|---|---|
| 2026-09-29 18:45 | phase start (repo public, pre-4K) | 22 GB | 22 GB | — | baseline; upstream/ holds 16K build trees: `out/` 3.5 GB + `out-initramfs/` 2.1 GB |
| 2026-09-29 19:30 | 4K kernel flavor build #1 (aborted mid-run — build.sh edited while bash was executing; restarted warm) | 23 GB | (aborted) | — | `upstream/linux-hoolock/out-4k/` |
| 2026-09-29 22:50 | 4K kernel flavor complete (bare + rebundle) + images-4k | 23 GB | 19 GB | ~+4 GB | `out-4k/` + `out-4k-initramfs/` + artifacts/kernel-4k + artifacts/images-4k |
| 2026-09-29 23:40 | release staging (out/release, 608 MB) | 17 GB | 17 GB | +0.6 GB | 20 assets, SHA256SUMS cross-checked against the manifest (18/18 loose files + 2 dtbs tarballs) |
| 2026-09-29 23:4x | CI hosted runs | n/a (GH-hosted) | — | 0 local | stage builds run on GitHub runners, not this disk; runs 1–6 (3 cancelled by newer pushes under the concurrency group) |

Standing notes:

- Largest local residents: `upstream/linux-hoolock` (7.5 GB incl. 16K build
  trees), `upstream/linux-sandcastle` (1.2 GB), `upstream/pmaports` (120 MB),
  `artifacts/images/rootfs.img` (256 MB). The 4K flavor adds a second
  `out-4k` tree (~5–6 GB) plus artifacts (~50 MB).
- If space runs short, the **first** things to delete are build trees under
  `upstream/linux-hoolock/out*` (gitignored scratch; artifacts + provenance +
  logs in `artifacts/` and `evidence/builds/` are what the pipeline ships).
  Never delete `evidence/` to free space — evidence is the deliverable.
- The Mimosa security scanner could not complete a full audit on this host
  (out-of-buffer at 98% disk; see the git hook notes on the go-public and
  ci-fix commits). No security-audit claims are made anywhere in the
  release materials for that reason.
