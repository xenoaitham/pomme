# pomme pipeline conventions

Every stage in this repository follows the same contract. A stage that breaks
this contract is not shippable, no matter how well it builds.

## Stages

```
gaster   (checkm8 exploit tool, Linux host binary)
pongoos  (pongoOS bootloader, Mach-O arm64 payload)
kernel   (Linux arm64 Image + DTBs + modules, iPhone 7 / T8010 target)
images   (initramfs.cpio.gz + rootfs.img)
```

## Directory contract

- `tooling/<stage>/build.sh` — the one command that builds the stage from
  pinned upstream sources. `set -euo pipefail` at the top. Fully
  non-interactive. Logs everything to stdout/stderr (the caller redirects).
- `tooling/<stage>/README.md` — what the stage is, which upstream it builds,
  why any patch exists, known limitations.
- `patches/<stage>/*.patch` — every deviation from upstream, applied by
  build.sh, never edited into a vendored copy of upstream source.
- `upstream/<name>/` — upstream clones (gitignored, never committed). Pins
  live in `evidence/upstream-pins/<name>.json`.
- `evidence/builds/<stage>_<version>_<date>.log[.gz]` — committed full build
  log of the artifact we ship. If a log exceeds 2 MB, gzip it.
- `artifacts/<stage>/` — build outputs. Large binaries are gitignored; the
  committed `artifacts/manifest.json` records their sha256, size, source
  stage, upstream ref, and build-log path. CI re-uploads them on every push.

## Provenance rule

Every shipped artifact must trace to ONE of:

1. a pinned upstream commit (`evidence/upstream-pins/*.json` records the
   upstream URL, commit SHA, commit date, and role), or
2. a committed build log produced by this pipeline
   (`evidence/builds/*.log`), or both.

A claim in `docs/` must cite one of those two, or an external primary source
(URL + what exactly it establishes). No vibes.

## Honesty rules (non-negotiable)

- This pipeline is **builds-not-boots**: no artifact here has been booted on
  hardware in this project. Docs must never imply otherwise.
- **A12 and newer are unsupported.** No public checkm8-equivalent bootROM
  exploit exists for A12+; we do not support it, and we do not pretend to.
- macOS SDK licensing: if a stage needs an Apple SDK (pongoOS builds), the
  SDK is fetched at build time with a pinned checksum and never committed,
  with the licensing situation stated plainly in the stage README.

## Versioning

- `VERSION` at repo root: `MAJOR.MINOR.PATCH`, bumped when any stage's
  output changes.
- `artifacts/manifest.json` records the repo VERSION and per-artifact
  upstream refs, so any artifact can be tied back to source.
