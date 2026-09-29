# pomme device compatibility matrix (checkm8 era, A7–A11)

Source of truth for the per-device evidence in this file is
`docs/matrix-data.md` (research pass, every cell cited there). This document
repackages it as the operator-facing matrix. pomme is **builds-not-boots**
(`docs/pipeline-conventions.md`): **no row below has been booted on hardware by
pomme.** A "covers" in the pomme column means the built artifacts support the
device on paper — nothing more.

## Evidence legend

| Marker | Evidence | Pin / URL |
|---|---|---|
| `[I]` | checkm8 applicability — ipwndfu README SoC list (`s5l8947x, s5l8950x, s5l8955x, s5l8960x, t8002, t8004, t8010, t8011, t8015`; t7000-class named "future" at announcement), "permanent unpatchable bootrom exploit" | https://github.com/axi0mX/ipwndfu (retrieved 2026-09-29) |
| `[Gn]` | gaster exploit support — `gaster.c:<n>` in `palera1n/gaster` @ `20958256a4706b6396e2d9ee9ca742618459980b` (SRTG match → CPID + exploit offsets). Corroborating table with SRTG strings: `tooling/gaster/SUPPORT.md` | `evidence/upstream-pins/gaster.json` |
| `[P]` | pongoOS platform driver — `src/drivers/plat/<file>` in `palera1n/pongoOS` @ `e98323f8a09abd80fc4cbcd74dee023b91a1ec22` (dispatch: `src/kernel/entry.c:136-158`) | `evidence/upstream-pins/pongoos.json` |
| `[K]` | pomme-built kernel DTS — the named `.dtb` exists in `artifacts/kernel/dtbs/` (92 files, sha256s in `artifacts/kernel/provenance.json`); `model =` strings from `HoolockLinux/linux` @ `dfa4d42081312dd34ec33ee8d23174309f683188` (`hoolock-7.0.12`), catalogued in `tooling/kernel/SUPPORT.md` | `artifacts/kernel/provenance.json` |
| `[S]` | Sandcastle kernel DTS — `corellium/linux-sandcastle` @ `0c2f7dda13d67bb7e06123df516f8bdb1000a79b`, `arch/arm64/boot/dts/hx/` | `evidence/upstream-pins/linux-sandcastle.json` |
| `[W]` | pmOS "Apple Generic iDevice" wiki — tested-device list, works/broken table, page-size rule | https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice) (retrieved 2026-09-29; wiki.postmarketos.org 301-redirects there) |
| `[W-d10]` | pmOS iPhone 7/7+ (`apple-d10`) device page | https://wiki.nura.eco/wiki/Apple_iPhone_7/7%2B_(apple-d10) (retrieved 2026-09-29) |
| UNKNOWN | No verifiable evidence found. The missing evidence is named next to it. | — |

`file:line` citations refer to the pinned commit; verify with
`git -C upstream/<repo> show <sha>:<file> | sed -n '<line>p'` (method per
`tooling/gaster/SUPPORT.md`).

## The page-size gate (read before interpreting any row)

The shipped kernel Image is the **16K-page** build
(`CONFIG_ARM64_16K_PAGES=y`; page size is visible to `file(1)` as
"…16K pages" — `tooling/kernel/SUPPORT.md`, config lineage in
`artifacts/kernel/provenance.json`). Page size is per **SoC generation**
`[W]` (pmOS wiki, Booting step 1):

- **4K** = A7 / A8 / A8X (`s5l8960x` / `t7000` / `t7001`)
- **16K** = A9 / A9X / A10 / A10X / A11 / T2 (`s8000`/`s8003`/`s8001`/`t8010`/`t8011`/`t8015`/`t8012`)

Corroboration: pmaports
`device/testing/linux-postmarketos-apple-16k/config-postmarketos-apple-16k.aarch64:462`
(`CONFIG_ARM64_16K_PAGES=y`) vs the 4K flavor's inverse at line 461
(citation chain in `tooling/kernel/README.md`, "Config provenance").
**Consequence: A7/A8/A8X devices are NOT servable by the shipped kernel
Image.** Their DTBs are built and shipped, but this Image will not run on
them; pomme does not build the 4K flavor (primary target is T8010).

The in-tree reason why A9+ wants 16K pages is not documented in the kernel
source; the rule is established at the distribution level (pmOS) — noted in
`tooling/kernel/README.md` and `docs/matrix-data.md`.

## Matrix

"pmOS status" states what the wiki says about *postmarketOS-on-hardware* —
that is pmOS' evidence, not pomme's. "pomme boot-chain status" is pomme's own
honest column.

| Device | Boards | SoC (CPID) | checkm8 | gaster | pongoOS | Kernel DTS in shipped build | pmOS status | pomme boot-chain status |
|---|---|---|---|---|---|---|---|---|
| iPhone 5s | N51, N53 | A7 (0x8960) | yes `[I]` (`s5l8960x`) | `gaster.c:565` `[G]` | `plat/s5l8960.c` `[P]` | `s5l8960x-n51.dtb`, `s5l8960x-n53.dtb` "iPhone 5s (GSM/LTE)" `[K]` | **tested** ("iPhone 5s (LTE)"): USB net works; screen partial; storage via netboot (4K page) `[W]` | **NOT servable by shipped kernel** (4K SoC, 16K Image); gaster+pongoOS cover the SoC; untested on hardware |
| iPhone 6 | N61 | A8 (0x7000) | yes `[I]` (A8-class; ipwndfu listed t7000 only as "future" at announcement) | `gaster.c:596` `[G]` | `plat/t7000.c` `[P]` | `t7000-n61.dtb` "Apple iPhone 6" `[K]`; archived pmOS port `device/archived/device-apple-n61` existed (Sandcastle era) `[W]` | **tested** per wiki; A8 devices netboot-only (4K page) `[W]` | **NOT servable by shipped kernel** (4K); gaster+pongoOS cover; untested on hardware |
| iPhone 6 Plus | N56 | A8 (0x7000) | yes `[I]` | `gaster.c:596` `[G]` | `plat/t7000.c` `[P]` | `t7000-n56.dtb` "Apple iPhone 6 Plus" `[K]` | not in tested list — kernel DTS only `[W]` | **NOT servable by shipped kernel** (4K); display path UNKNOWN |
| iPhone 6s | N71 (+M) | A9 (0x8000 Samsung / 0x8003 TSMC) | yes `[I]` | `gaster.c:642` (0x8000), `gaster.c:625` (0x8003) `[G]` | `plat/s8000.c`, `plat/s8003.c` `[P]` | `s8000-n71.dtb` / `s8003-n71m.dtb` `[K]` | **tested** ("iPhone 6s (S8003)"); 16K page `[W]` | covered (16K) — build covers, UNTESTED ON HARDWARE; Samsung-fab 0x8000 variant not explicitly wiki-tested — UNKNOWN whether only S8003 verified |
| iPhone 6s Plus | N66 (+M) | A9 (0x8000/0x8003) | yes `[I]` | `gaster.c:642` / `gaster.c:625` `[G]` | `plat/s8000.c` / `plat/s8003.c` `[P]` | `s8000-n66.dtb` / `s8003-n66m.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; display path UNKNOWN |
| iPhone SE (1st gen) | N69u | A9 (0x8000/0x8003) | yes `[I]` | `gaster.c:642` / `gaster.c:625` `[G]` | `plat/s8000.c` / `plat/s8003.c` `[P]` | `s8000-n69u.dtb` / `s8003-n69.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; SE touch/sensor config UNKNOWN |
| **iPhone 7 (pomme primary)** | D10, D101 | A10 (0x8010) | yes `[I]` (`t8010`) | `gaster.c:713` `[G]` (SRTG `iBoot-2696.0.0.1.33`, `tooling/gaster/SUPPORT.md`) | `plat/t8010.c` (probes `cpid == 0x8010` at `t8010.c:30`) `[P]` | `t8010-d10.dtb` "iPhone 7 (Qualcomm)", `t8010-d101.dtb` "iPhone 7 (Intel)" `[K]`; Sandcastle: `hx-h9p-d10.dts`, `hx-h9p-d101.dts` `[S]` | **tested**; d10 page: works = USB net, battery, touchscreen, WiFi, BT; partial = flash/screen/OTG; broken = GPU, audio; storage "need apfs driver, apfs-linux-rw"; archived Sandcastle port `device/archived/device-apple-iphone7` `[W-d10]`, `[W]` | **primary target** — chain covers (gaster→pongoOS→16K kernel→images all built for T8010); UNTESTED ON HARDWARE; sequenced by `RESUME.md` |
| iPhone 7 Plus | D11, D111 | A10 (0x8010) | yes `[I]` | `gaster.c:713` `[G]` | `plat/t8010.c` `[P]` | `t8010-d11.dtb`, `t8010-d111.dtb` `[K]`; `hx-h9p-d11.dts`, `hx-h9p-d111.dts` `[S]` | covered by the d10 page (7/7+) `[W-d10]` | covered (16K), untested on hardware; 3 GB-variant DTB memory config to verify at boot |
| iPhone 8 | D20, D201 | A11 (0x8015) | yes `[I]` (`t8015`) | `gaster.c:761` `[G]` | `plat/t8015.c` `[P]` | `t8015-d20.dtb`, `t8015-d201.dtb` `[K]` | **tested**; A11 = the one SoC class with working internal storage `[W]` | covered (16K), untested on hardware; passcode must be disabled in jailbroken state (palera1n README, `docs/bars.md` bar 2) |
| iPhone 8 Plus | D21, D211 | A11 (0x8015) | yes `[I]` | `gaster.c:761` `[G]` | `plat/t8015.c` `[P]` | `t8015-d21.dtb`, `t8015-d211.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware |
| iPhone X | D22, D221 | A11 (0x8015) | yes `[I]` | `gaster.c:761` `[G]` | `plat/t8015.c` `[P]` | `t8015-d22.dtb`, `t8015-d221.dtb` `[K]` | **tested** ("iPhone X (Global)"); archived port `device/archived/device-apple-d22` existed `[W]` | covered (16K), untested on hardware; OLED path on generic port UNKNOWN |
| iPod touch 6 | N102 | A8 (0x7000) | yes `[I]` | `gaster.c:596` `[G]` | `plat/t7000.c` `[P]` | `t7000-n102.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | **NOT servable by shipped kernel** (4K); netboot-only likely — UNKNOWN |
| iPod touch 7 | N112 | A10 (0x8010) | yes `[I]` | `gaster.c:713` `[G]` | `plat/t8010.c` `[P]` | `t8010-n112.dtb` `[K]`; `hx-h9p-n112.dts` `[S]` | not in tested list — kernel DTS only; Sandcastle supported it officially (projectsandcastle.org/status) `[W]`, `[S]` | covered (16K), untested on hardware; pmOS status UNKNOWN |
| iPad mini 2 | J85, J86, J87 | A7 (0x8960) | yes `[I]` | `gaster.c:565` `[G]` | `plat/s5l8960.c` `[P]` | `s5l8960x-j85/j86/j87.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | **NOT servable by shipped kernel** (4K); PMIC/display variant vs Air UNKNOWN |
| iPad mini 3 | J85m, J86m, J87m | A7 (0x8960) | yes `[I]` | `gaster.c:565` `[G]` | `plat/s5l8960.c` `[P]` | `s5l8960x-j85m/j86m/j87m.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | **NOT servable by shipped kernel** (4K) |
| iPad mini 4 | J96, J97 | A8 (0x7000) | yes `[I]` | `gaster.c:596` `[G]` | `plat/t7000.c` `[P]` | `t7000-j96.dtb`, `t7000-j97.dtb` `[K]` | **tested** ("iPad Mini 4 (Wi-Fi/LTE)"); A8 netboot-only `[W]` | **NOT servable by shipped kernel** (4K) |
| iPad Air | J71, J72, J73 | A7 (0x8960) | yes `[I]` | `gaster.c:565` `[G]` | `plat/s5l8960.c` `[P]` | `s5l8960x-j71/j72/j73.dtb` `[K]` | **tested** ("iPad Air (Wi-Fi)"); cellular variants untested `[W]` | **NOT servable by shipped kernel** (4K) |
| iPad Air 2 | J81, J82 | A8X (0x7001) | yes `[I]` (A8X in A5–A11 range) | `gaster.c:581` `[G]` | `plat/t7001.c` `[P]` | `t7001-j81.dtb`, `t7001-j82.dtb` `[K]` | **tested** ("iPad Air 2 (Wi-Fi/LTE)"); 16K page but A8X = netboot-only per wiki `[W]` | **NOT servable by shipped kernel** (4K SoC class per the wiki split; A8X needs the 4K flavor) |
| iPad (5th gen, 2017) | J71s, J72s, J71t, J72t | A9 (0x8000/0x8003) | yes `[I]` | `gaster.c:642` / `gaster.c:625` `[G]` | `plat/s8000.c` / `plat/s8003.c` `[P]` | `s8000-j71s/j72s.dtb` "iPad 5 (Samsung)", `s8003-j71t/j72t.dtb` "iPad 5 (TSMC)" `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; fab split untested — UNKNOWN |
| iPad (6th gen, 2018) | J71b, J72b | A10 (0x8010) | yes `[I]` | `gaster.c:713` `[G]` | `plat/t8010.c` `[P]` | `t8010-j71b.dtb`, `t8010-j72b.dtb` `[K]` | **tested** ("iPad 6 (Wi-Fi)") `[W]` | covered (16K), untested on hardware; internal storage on A10 UNKNOWN (wiki: A11-only) |
| iPad (7th gen, 2019) | J171, J172 | A10 (0x8010) | yes `[I]` | `gaster.c:713` `[G]` | `plat/t8010.c` `[P]` | `t8010-j171.dtb`, `t8010-j172.dtb` `[K]` | **tested** ("iPad 7 (Wi-Fi)") `[W]` | covered (16K), untested on hardware; same storage UNKNOWN as iPad 6 |
| iPad Pro (9.7", 2016) | J127, J128 | A9X (0x8001 vs 0x8002 — **CONFLICT, unresolved**) | yes `[I]` (README lists `t8002`) | 0x8001: `gaster.c:659`; 0x8002: `gaster.c:683` `[G]` | `plat/s8001.c` only — **no s8002 plat driver in either pongoOS fork** `[P]` | `s8001-j127.dtb`, `s8001-j128.dtb` (hoolock files 9.7" under `s8001`) `[K]` | not in tested list — kernel DTS only `[W]` | covered on paper (16K), untested; **UNKNOWN which CPID a real 9.7" reports** — resolve with theapplewiki CPID table or one DFU SRTG read (see below) |
| iPad Pro (12.9", 1st gen, 2015) | J98a, J99a | A9X (0x8001) | yes `[I]` | `gaster.c:659` `[G]` | `plat/s8001.c` `[P]` | `s8001-j98a.dtb`, `s8001-j99a.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; netboot-only likely — UNKNOWN |
| iPad Pro (10.5", 2017) | J207, J208 | A10X (0x8011) | yes `[I]` (`t8011`) | `gaster.c:737` `[G]` | `plat/t8011.c` `[P]` | `t8011-j207.dtb`, `t8011-j208.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; ProMotion path UNKNOWN |
| iPad Pro (12.9", 2nd gen, 2017) | J120, J121 | A10X (0x8011) | yes `[I]` | `gaster.c:737` `[G]` | `plat/t8011.c` `[P]` | `t8011-j120.dtb`, `t8011-j121.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | covered (16K), untested on hardware; as 10.5" |
| Apple TV HD | J42d | A8 (0x7000) | yes `[I]` | `gaster.c:596` `[G]` | `plat/t7000.c` `[P]` | `t7000-j42d.dtb` `[K]` | **tested** per wiki `[W]` | outside phone scope; listed for completeness; **NOT servable by shipped kernel** (4K) |
| Apple TV 4K (1st gen) | J105a | A10X (0x8011) | yes `[I]` | `gaster.c:737` `[G]` | `plat/t8011.c` `[P]` | `t8011-j105a.dtb` `[K]` | not in tested list — kernel DTS only `[W]` | outside phone scope; covered (16K), untested on hardware |

Rows deliberately not in the matrix:

- **A12 and newer** (iPhone XS/XR and on): permanently unsupported — no public
  checkm8-equivalent bootROM exploit exists (`docs/pipeline-conventions.md`
  honesty rule; gaster's pinned SRTG table contains no A12+ CPID —
  `tooling/gaster/SUPPORT.md`). pomme does not support them and does not
  pretend to.
- **A5/A6-era SoCs** (0x8947 / 0x8950 / 0x8955): gaster recognizes them
  (`gaster.c:550,520,535`) but they are outside the command-exec gate
  (`gaster.c:1525` set, `tooling/gaster/SUPPORT.md`) and have **no pongoOS
  platform driver and no hoolock DTS** — a known chain gap, not a matrix row
  (`docs/matrix-data.md`).
- **T2 Macs** (t8012): dtbs ship (`artifacts/kernel/dtbs/t8012-*.dtb`, 15
  files) but no iDevice chain applies; see `tooling/kernel/SUPPORT.md`.

## Open UNKNOWNs (and the evidence that would resolve each)

Carried verbatim from `docs/matrix-data.md` — each is a concrete cell that
current evidence cannot fill:

1. **iPad Pro 9.7" true CPID** (0x8001 vs 0x8002): gaster distinguishes
   `iBoot-2481.0.0.2.1` → 0x8001 (`gaster.c:658-659`) from
   `iBoot-2651.0.0.1.31` → 0x8002 (`gaster.c:682-683`), hoolock names the
   boards `s8001-*`, ipwndfu lists `t8002`. Resolves with a theapplewiki /
   theiphonewiki CPID table check, or one DFU-mode SRTG read on hardware.
2. **Devices behind gaster CPIDs 0x7002 / 0x8002 / 0x8004** (`gaster.c:611,
   683, 698`): no hoolock DTS, no verified retail mapping.
3. **Per-device touch/display/GPU status outside the 14 pmOS-tested
   devices** (`[W]` tested list): kernel `compatible` strings do not prove
   working drivers; resolves only with hardware runs.
4. **Internal storage on A9/A10-class devices** (wiki says A11-only `[W]`):
   resolves by booting on hardware and reading `nvme`/APFS state — iPhone 7
   is the first probe (`RESUME.md` sequences it; the d10 page hints APFS rw
   via `apfs-linux-rw` is achievable `[W-d10]`).
5. **palera1n docs-site device list**: https://palera.in/docs/ returned 404
   at retrieval (2026-09-29); the pinned README device table
   (`palera1n` pin, "Device Support") is used instead (`docs/bars.md` bar 2).

## How this matrix gets updated

Hardware-session procedure, including which cells a successful iPhone 7 boot
resolves, is specified in `RESUME.md` (section "After the session"). Every
status change must land with new evidence under `evidence/` per the
provenance rule in `docs/pipeline-conventions.md` — no vibes.
