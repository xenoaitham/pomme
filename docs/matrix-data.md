# Per-device compatibility evidence (checkm8-era matrix data)

Raw evidence rows backing a future device-support matrix. Every cell cites
pinned code (`evidence/upstream-pins/*.json`) or a primary URL. Cells without
verifiable evidence say **UNKNOWN** and name the missing evidence. This
project is builds-not-boots: no row below has been confirmed on hardware by
pomme.

## Evidence sources (pinned)

| Source | Pin | What it establishes for this matrix |
|---|---|---|
| gaster | `palera1n/gaster` @ `20958256a4706b6396e2d9ee9ca742618459980b` | Which CPIDs the open checkm8 tool handles, keyed by DFU SRTG string (`gaster.c:519-786`) |
| pongoOS (palera1n fork) | `palera1n/pongoOS` @ `e98323f8a09abd80fc4cbcd74dee023b91a1ec22` | Which SoCs pongoOS has platform drivers for (`src/drivers/plat/*.c`, dispatch `src/kernel/entry.c:136-158`) |
| linux-sandcastle | `corellium/linux-sandcastle` @ `0c2f7dda13d67bb7e06123df516f8bdb1000a79b` (5.4.14) | Sandcastle kernel device coverage (`arch/arm64/boot/dts/hx/`) |
| linux-hoolock | `HoolockLinux/linux` @ `dfa4d42081312dd34ec33ee8d23174309f683188` (tag hoolock-7.0.12, v7.0.12) | Mainline-based kernel DTS coverage, device models read from `model = ` in `arch/arm64/boot/dts/apple/*.dts` |
| pmaports | `postmarketOS/pmaports` @ `34a4e3c3a38c88f52319ecce80f02b561d2eeee2` | Which devices have pmOS packages (archived + testing) |
| ipwndfu README | https://github.com/axi0mX/ipwndfu (retrieved 2026-09-29) | checkm8 announcement: "permanent unpatchable bootrom exploit"; SoC list s5l8947x, s5l8950x, s5l8955x, s5l8960x, t8002, t8004, t8010, t8011, t8015 (with t7000 et al. under "future SoC support" at announcement time) |
| pmOS idevice wiki | https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice) (wiki.postmarketos.org 301-redirects; retrieved 2026-09-29) | Tested device list, works/broken table, boot flow, 4k/16k page-size split |
| pmOS d10 wiki | https://wiki.nura.eco/wiki/Apple_iPhone_7/7%2B_(apple-d10) (retrieved 2026-09-29) | iPhone 7/7+ per-device feature status |
| pmOS archived wiki | https://web.archive.org/web/2023/https://wiki.postmarketos.org/wiki/Apple_iPhone_7_(apple-iphone7) (retrieved 2026-09-29) | Archived Sandcastle-era port status |

## CPID ↔ SoC ↔ board-code key (pinned DTS, hoolock `arch/arm64/boot/dts/apple/`)

- A7 = `s5l8960x` (CPID 0x8960); A8 = `t7000` (0x7000); A8X = `t7001` (0x7001);
  A9 = `s8000` (0x8000) / `s8003` (0x8003) Samsung/TSMC fab variants;
  A9X = `s8001` (0x8001); A10 = `t8010` (0x8010); A10X = `t8011` (0x8011);
  A11 = `t8015` (0x8015). SoC↔CPID mapping above is how hoolock names its
  DTS and how gaster's dispatch groups chips; the wiki adds the page-size
  split: **4K kernels for A7/A8/A8X, 16K kernels for A9/A9X/A10/A10X/A11/T2**
  (idevice wiki, Booting step 1).
- gaster handles additional CPIDs with no device mapping verified here:
  0x7002 (`gaster.c:611`), 0x8002 (`gaster.c:683`), 0x8004 (`gaster.c:698`),
  plus pre-A7 0x8947/0x8950/0x8955 (`gaster.c:520,535,550`). UNKNOWN what
  retail devices these correspond to (candidates per the ipwndfu README's
  `t8002`/`t8004` entries); resolving evidence: theapplewiki CPID table or
  hardware. hoolock has no `s8002`/`s8004` DTS, so no Linux-side consumer
  exists for them in this pin.

## Device rows

Legend — gaster: file:line of the CPID's SRTG match; pongoOS: plat driver
file; hoolock: DTS file(s) + `model` string; pmOS: package/wiki status.
"kernel DTS only" = kernel boot object exists in the pin, no pmOS testing
reported.

| Device | Board code(s) | SoC (CPID) | checkm8 | gaster | pongoOS | Sandcastle kernel | hoolock kernel (v7.0.12) | pmOS apple-idevice | Gaps / UNKNOWN |
|---|---|---|---|---|---|---|---|---|---|
| iPhone 5s | N51, N53 | A7 (0x8960) | yes — `s5l8960x` in ipwndfu list | `gaster.c:565` | `src/drivers/plat/s5l8960.c` | no | `s5l8960x-n51.dts` "iPhone 5s (GSM)", `s5l8960x-n53.dts` "iPhone 5s (LTE)" | **tested** per wiki ("iPhone 5s (LTE)"); works: USB net; screen partial; storage netboot (4k page) | iPad-touch-class bugs on A7 UNKNOWN; no 7-compatible touch driver (wiki: touchscreen broken on generic port) |
| iPhone 6 | N61 | A8 (0x7000) | yes — A9-A11 range; ipwndfu README listed t7000 only as "future" at announcement | `gaster.c:596` | `src/drivers/plat/t7000.c` | no | `t7000-n61.dts` "Apple iPhone 6" | **tested** per wiki; had archived pmOS port `device/archived/device-apple-n61` (Sandcastle-era) | same as 5s; A8 devices netboot-only (wiki) |
| iPhone 6 Plus | N56 | A8 (0x7000) | yes (same SoC as iPhone 6) | `gaster.c:596` | `src/drivers/plat/t7000.c` | no | `t7000-n56.dts` "Apple iPhone 6 Plus" | not in wiki tested list — kernel DTS only | screen/touch on 6+ display UNKNOWN |
| iPhone 6s | N71 (+M) | A9 (0x8000 Samsung / 0x8003 TSMC) | yes — `s5l8960x`-class successors in list; both fab CPIDs in gaster | `gaster.c:642` (0x8000), `gaster.c:625` (0x8003) | `src/drivers/plat/s8000.c`, `s8003.c` | no | `s8000-n71.dts` / `s8003-n71m.dts` "iPhone 6s (Samsung/TSMC)" | **tested** (wiki: "iPhone 6s (S8003)"); 16k page | 0x8000 variant not explicitly wiki-tested — UNKNOWN if only S8003 verified |
| iPhone 6s Plus | N66 (+M) | A9 (0x8000/0x8003) | yes (A9) | `gaster.c:642` / `gaster.c:625` | `s8000.c` / `s8003.c` | no | `s8000-n66.dts` / `s8003-n66m.dts` "iPhone 6s Plus (Samsung/TSMC)" | not in tested list — kernel DTS only | 6s+ display path UNKNOWN |
| iPhone SE (1st gen) | N69u | A9 (0x8000/0x8003) | yes (A9) | `gaster.c:642` / `gaster.c:625` | `s8000.c` / `s8003.c` | no | `s8000-n69u.dts` / `s8003-n69.dts` "iPhone SE (Samsung/TSMC)" | not in tested list — kernel DTS only | SE-specific touch/sensor config UNKNOWN |
| **iPhone 7 (pomme primary)** | D10, D101 | A10 (0x8010) | yes — `t8010` in ipwndfu list | `gaster.c:713` | `src/drivers/plat/t8010.c` (`t8010.c:30` probes `cpid == 0x8010`) | **yes — primary target**: `hx-h9p-d10.dts`, `hx-h9p-d101.dts` | `t8010-d10.dts` "iPhone 7 (Qualcomm)", `t8010-d101.dts` "iPhone 7 (Intel)" | **tested** per wiki; d10 wiki page: works = USB net, battery, touchscreen, WiFi, BT; partial = flash/screen/OTG; broken = GPU, audio; storage "need apfs driver, apfs-linux-rw"; archived sandcastle port `device/archived/device-apple-iphone7` | per the d10 wiki: "Boot directly without PC,USB and pongoOS needed — not implemented"; abnormal screen color unfixed |
| iPhone 7 Plus | D11, D111 | A10 (0x8010) | yes — `t8010` in list | `gaster.c:713` | `src/drivers/plat/t8010.c` | **yes**: `hx-h9p-d11.dts`, `hx-h9p-d111.dts` | `t8010-d11.dts` "iPhone 7 Plus (Qualcomm)", `t8010-d111.dts` "iPhone 7 Plus (Intel)" | covered by d10 wiki page (iPhone 7/7+) | 3 GB variant DTB memory config differs — verify at build time |
| iPhone 8 | D20, D201 | A11 (0x8015) | yes — `t8015` in list | `gaster.c:761` | `src/drivers/plat/t8015.c` | no | `t8015-d20.dts` "iPhone 8 (Global)", `t8015-d201.dts` "iPhone 8 (GSM)" | **tested** per wiki; A11 = the one SoC class with working internal storage (wiki) | A11 passcode/Secure Enclave constraint (palera1n README: passcode must be disabled in jailbroken state) |
| iPhone 8 Plus | D21, D211 | A11 (0x8015) | yes (A11) | `gaster.c:761` | `t8015.c` | no | `t8015-d21.dts` "iPhone 8 Plus (Global)", `t8015-d211.dts` "(GSM)" | not in tested list — kernel DTS only | internal storage likely works like iPhone 8 (A11) — UNTESTED, wiki silent |
| iPhone X | D22, D221 | A11 (0x8015) | yes (A11) | `gaster.c:761` | `t8015.c` | no | `t8015-d22.dts` "iPhone X (Global)", `t8015-d221.dts` "(GSM)" | **tested** (wiki: "iPhone X (Global)"); had archived pmOS port `device/archived/device-apple-d22` (deviceinfo: `rootfs_image_sector_size=4096`, getty `ttySAC0`) | OLED display path status on generic port UNKNOWN |
| iPod touch 6 | N102 | A8 (0x7000) | yes (A8-class) | `gaster.c:596` | `t7000.c` | no | `t7000-n102.dts` "Apple iPod touch 6" | not in tested list — kernel DTS only | netboot-only likely (A8) — UNKNOWN |
| iPod touch 7 | N112 | A10 (0x8010) | yes — `t8010` in list | `gaster.c:713` | `t8010.c` | **yes**: `hx-h9p-n112.dts` | `t8010-n112.dts` "Apple iPod touch 7" | not in tested list — kernel DTS only; Sandcastle supported it officially (projectsandcastle.org/status) | touch daemon config for N112 exists in sandcastle overlay (`hx-touch.fwlist:3`) — pmOS status UNKNOWN |
| iPad mini 2 | J85, J86, J87 | A7 (0x8960) | yes — `s5l8960x` in list | `gaster.c:565` | `s5l8960.c` | no | `s5l8960x-j85.dts` "iPad mini 2 (Wi-Fi)", `j86` (Cellular), `j87` (Cellular, China) | not in tested list — kernel DTS only | mini 2 PMIC/display variant vs Air UNKNOWN |
| iPad mini 3 | J85m, J86m, J87m | A7 (0x8960) | yes (A7) | `gaster.c:565` | `s5l8960.c` | no | `s5l8960x-j85m.dts` "iPad mini 3 (Wi-Fi)", `j86m`, `j87m` | not in tested list — kernel DTS only | same as mini 2 |
| iPad mini 4 | J96, J97 | A8 (0x7000) | yes (A8-class) | `gaster.c:596` | `t7000.c` | no | `t7000-j96.dts` "iPad mini 4 (Wi-Fi)", `t7000-j97.dts` (Cellular) | **tested** per wiki ("iPad Mini 4 (Wi-Fi/LTE)") | A8 netboot-only (wiki) |
| iPad Air | J71, J72, J73 | A7 (0x8960) | yes (A7) | `gaster.c:565` | `s5l8960.c` | no | `s5l8960x-j71.dts` "iPad Air (Wi-Fi)", `j72` (Cellular), `j73` (Cellular, China) | **tested** per wiki ("iPad Air (Wi-Fi)") | cellular variants untested per wiki |
| iPad Air 2 | J81, J82 | A8X (0x7001) | yes — A8X in A5-A11 range | `gaster.c:581` | `src/drivers/plat/t7001.c` | no | `t7001-j81.dts` "iPad Air 2 (Wi-Fi)", `t7001-j82.dts` (Cellular) | **tested** per wiki ("iPad Air 2 (Wi-Fi/LTE)") | 16k page; A8X netboot-only (wiki) |
| iPad (5th gen, 2017) | J71s, J72s, J71t, J72t | A9 (0x8000/0x8003) | yes (A9) | `gaster.c:642` / `gaster.c:625` | `s8000.c` / `s8003.c` | no | `s8000-j71s.dts`/`s8000-j72s.dts` "iPad 5 (Samsung)", `s8003-j71t.dts`/`s8003-j72t.dts` "iPad 5 (TSMC)" | not in tested list — kernel DTS only | fab-split on iPad5 (j71s Samsung vs j71t TSMC) — both DTS present; device testing UNKNOWN |
| iPad (6th gen, 2018) | J71b, J72b | A10 (0x8010) | yes — `t8010` in list | `gaster.c:713` | `t8010.c` | no | `t8010-j71b.dts` "iPad 6 (Wi-Fi)", `t8010-j72b.dts` (Cellular) | **tested** per wiki ("iPad 6 (Wi-Fi)") | 16k page; internal storage on A10 UNKNOWN (wiki: only A11 storage works) |
| iPad (7th gen, 2019) | J171, J172 | A10 (0x8010) | yes (A10) | `gaster.c:713` | `t8010.c` | no | `t8010-j171.dts` "iPad 7 (Wi-Fi)", `t8010-j172.dts` (Cellular) | **tested** per wiki ("iPad 7 (Wi-Fi)") | same as iPad 6 |
| iPad Pro (9.7", 2016) | J127, J128 | A9X (CPID: see gap) | yes — A9X-class; ipwndfu README lists `t8002` as supported at announcement | 0x8001: `gaster.c:659`; 0x8002: `gaster.c:683` | `src/drivers/plat/s8001.c` only (no s8002 plat in either pongoOS fork) | no | `s8001-j127.dts` "iPad Pro (9.7-inch) (Wi-Fi)", `s8001-j128.dts` (Cellular) — hoolock files it under `s8001` | not in tested list — kernel DTS only | **CONFLICT, unresolved:** hoolock names the 9.7" A9X boards `s8001-*`, but gaster distinguishes 0x8001 (iBoot-2481, `gaster.c:659`) from 0x8002 (iBoot-2651, `gaster.c:683`) and the ipwndfu README lists `t8002`. Which CPID a real 9.7" reports is UNKNOWN until checked on hardware or against theapplewiki CPID table |
| iPad Pro (12.9", 1st gen, 2015) | J98a, J99a | A9X (0x8001) | yes (A9X) | `gaster.c:659` | `s8001.c` | no | `s8001-j98a.dts` "iPad Pro (12.9-inch) (Wi-Fi)", `s8001-j99a.dts` (Cellular) | not in tested list — kernel DTS only | 16k page; netboot-only likely — UNKNOWN |
| iPad Pro (10.5", 2017) | J207, J208 | A10X (0x8011) | yes — `t8011` in list | `gaster.c:737` | `src/drivers/plat/t8011.c` | no | `t8011-j207.dts` "iPad Pro 2 (10.5-inch) (Wi-Fi)", `t8011-j208.dts` (Cellular) | not in tested list — kernel DTS only | ProMotion display path UNKNOWN |
| iPad Pro (12.9", 2nd gen, 2017) | J120, J121 | A10X (0x8011) | yes (A10X) | `gaster.c:737` | `t8011.c` | no | `t8011-j120.dts` "iPad Pro 2 (12.9-inch) (Wi-Fi)", `t8011-j121.dts` (Cellular) | not in tested list — kernel DTS only | as 10.5" |
| Apple TV HD (extra) | J42d | A8 (0x7000) | yes | `gaster.c:596` | `t7000.c` | no | `t7000-j42d.dts` "Apple TV HD" | **tested** per wiki | outside phone scope; listed for completeness |
| Apple TV 4K 1g (extra) | J105a | A10X (0x8011) | yes | `gaster.c:737` | `t8011.c` | no | `t8011-j105a.dts` "Apple TV 4K (1st Generation)" | not in tested list — kernel DTS only | outside phone scope |

Rows not covered (deliberately): A12+ devices (iPhone XS onward, iPad Pro
2018+) — no public checkm8-equivalent exists; pomme does not support them
(pipeline-conventions honesty rule). A5/A6-era SoCs (0x8947/0x8950/0x8955) are
handled by gaster (`gaster.c:550,520,535`) but have **no pongoOS platform
driver** (`src/drivers/plat/` has none) and **no hoolock DTS** — out of scope
until someone writes both; marked as a known chain gap, not a matrix row.

## Cross-cutting observations (verified)

1. **gaster is the widest open checkm8 implementation**: 16 CPIDs from A5 to
   A11 + T2 (`gaster.c:519-786`), with a dedicated A9 exploit path
   (`payload_A9.bin`, branch at `gaster.c:1059`) vs the arm64 `notA9` path
   (`gaster.c:1067`).
2. **pongoOS covers A7-A11 + T2 only** — 10 plat drivers, no A5/A6
   (`src/drivers/plat/` in both `pongoos-checkra1n` and `pongoos` pins;
   dispatch `src/kernel/entry.c:136-158`).
3. **Sandcastle kernel = iPhone 7/7+/iPod 7 only** (five DTS boards,
   `hardware-model` D10/D101/D11/D111/N112 in `arch/arm64/boot/dts/hx/`).
4. **hoolock kernel = every device class in this matrix** — 25+ checkm8-era
   DTS boards with explicit `model` strings, plus T2 and Apple Silicon.
5. **pmOS tested list is much narrower than kernel coverage**: 14 devices
   tested (idevice wiki), everything else rides on "most likely boot, but are
   untested".
6. **Internal storage**: only A11 devices per the idevice wiki; everyone else
   netboots. The d10 wiki page hints APFS rw via `apfs-linux-rw` is achievable
   on iPhone 7 — the exact seam pomme's initramfs work should probe.

## UNKNOWNs that block a final matrix (and the evidence that would resolve each)

1. **iPad Pro 9.7" true CPID** (0x8001 vs 0x8002) — resolve with
   theapplewiki/theiphonewiki CPID table or one DFU-mode serial read
   (`SRTG:[iBoot-…]` string maps via `gaster.c:659/683`).
2. **Devices behind gaster CPIDs 0x7002 / 0x8002 / 0x8004** (`gaster.c:611,
   683, 698`) — no hoolock DTS, no verified retail mapping.
3. **Per-device touch/display/GPU status outside the 14 pmOS-tested devices**
   — resolve only with hardware runs; kernel `compatible` strings alone do
   not prove working drivers (hoolock has full DTS for untested devices).
4. **Internal storage on A9/A10-class devices** (wiki says A11-only) — resolve
   by booting hoolock on an iPhone 7 and reading `nvme`/APFS status.
5. **palera1n docs-site device list** — https://palera.in/docs/ returned 404
   at retrieval time (2026-09-29); the pinned README device table
   (`palera1n` pin, "Device Support") is used instead.
