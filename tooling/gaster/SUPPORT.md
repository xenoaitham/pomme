# gaster stage — SoC / device support

Source of truth: `upstream/gaster` at pin `20958256a4706b6396e2d9ee9ca742618459980b`
(2023-01-21), file `gaster.c`. Verify any citation yourself with:

```
git -C upstream/gaster show 20958256a4706b6396e2d9ee9ca742618459980b:gaster.c | sed -n '<LINE>p'
```

Line numbers below are from that exact commit. CPIDs and SRTG strings are read
straight from the code; the human-readable SoC/device names are standard Apple
part-number mappings (S5L89xx = Samsung-fab era naming, T/S8xxx = newer) and
are annotated as **external knowledge**, not strings found in gaster.

## How support works

gaster identifies a device in Apple DFU mode (USB VID `0x05AC`, PID `0x1227`,
`gaster.c:31,38`) by parsing the bootROM SRTG string from the USB serial
number descriptor, then hardcodes per-SoC exploit offsets from an if/else
chain (`gaster.c:519-808`). Each branch sets the SRTG marker it matches and
the CPID plus gadget/memory addresses for that SoC. A device whose SRTG is not
in the table leaves `cpid == 0` and is refused (`gaster.c:809-811`).

## CPID table (SRTG recognition, gaster.c:519-808)

| SRTG (from code) | line | CPID | SoC (external) | Devices (external, best-effort) |
|---|---|---|---|---|
| `iBoot-1145.3` | 519 | 0x8950 | S5L8950 / A6 | iPhone 5 |
| `iBoot-1145.3.3` | 534 | 0x8955 | S5L8955 / A6X | iPad 4th gen |
| `iBoot-1458.2` | 549 | 0x8947 | S5L8947 / A5 var. | iPad 2 rev / Apple TV 3rd gen |
| `iBoot-1704.10` | 564 | 0x8960 | S5L8960 / **A7** | iPhone 5s, iPad Air, iPad mini 2 |
| `iBoot-1991.0.0.2.16` | 580 | 0x7001 | T7001 / **A8X** | iPad Air 2 |
| `iBoot-1992.0.0.1.19` | 595 | 0x7000 | T7000 / **A8** | iPhone 6 / 6 Plus, others |
| `iBoot-2098.0.0.2.4` | 610 | 0x7002 | S7002 / A8 var. | Apple TV HD (4th gen) |
| `iBoot-2234.0.0.2.22` | 624 | 0x8003 | S8003 / **A9** (TSMC) | iPhone 6s / 6s+, SE 1st gen |
| `iBoot-2234.0.0.3.3` | 641 | 0x8000 | S8000 / **A9** (Samsung) | iPhone 6s / 6s+, SE 1st gen |
| `iBoot-2481.0.0.2.1` | 658 | 0x8001 | S8001 / **A9X** | iPad Pro 1st gen |
| `iBoot-2651.0.0.1.31` | 682 | 0x8002 | S8002 / A9 var. | (no confident public mapping) |
| `iBoot-2651.0.0.3.3` | 697 | 0x8004 | S8004 / A9 var. | (no confident public mapping) |
| `iBoot-2696.0.0.1.33` | 712 | 0x8010 | T8010 / **A10** | **iPhone 7 / 7+ — pomme target**, iPad 2018, iPod touch 7 |
| `iBoot-3135.0.0.2.3` | 736 | 0x8011 | T8011 / **A10X** | iPad Pro 2017, Apple TV 4K |
| `iBoot-3332.0.0.1.23` | 760 | 0x8015 | T8015 / **A11** | iPhone 8 / 8+, iPhone X |
| `iBoot-3401.0.0.1.16` | 784 | 0x8012 | T8012 | (no confident public mapping) |

## Exploit-path gates (what "supported" means per stage)

- **Heap-spray method split** — `gaster.c:893`: the `config_large_leak == 0`
  branch (0x7001, 0x7000, 0x7002, 0x8003, 0x8000) uses the
  stall/leak/no-leak grooming loop; everything else in the table uses the
  stall + `config_hole` method.
- **Payload variant selection** — `gaster.c:1058-1059`: `payload_A9` blob for
  0x8003 / 0x8000; `gaster.c:1067`: `payload_notA9` (arm64) blob for 0x8960,
  0x7001, 0x7000, 0x8001, 0x8010, 0x8011, 0x8015, 0x8012; `gaster.c:1076`:
  `payload_notA9_armv7` fallback for the rest of the table.
- **Patch/command-exec step** — `gaster.c:1083` and `gaster.c:1525` gate the
  same 10-CPID set: 0x8960, 0x7001, 0x7000, 0x8003, 0x8000, 0x8001, 0x8010,
  0x8011, 0x8015, 0x8012. This is the arm64 exploit path that pomme depends
  on (pwned DFU that can execute commands / decrypt with GID key).

### Matrix implications

- **Full pipeline support (gaster → pongoOS → kernel):** CPIDs 0x8960, 0x7001,
  0x7000, 0x8003, 0x8000, 0x8001, 0x8010, 0x8011, 0x8015, 0x8012 — A7 through
  A11. **pomme's declared target (iPhone 7, T8010, CPID 0x8010) is in this set**
  (`gaster.c:712-713`).
- **Recognized but outside the command-exec gate:** 0x8947, 0x8950, 0x8955,
  0x7002, 0x8002, 0x8004 (A5/A6-era and A9-family variants). The SRTG table
  knows them and the armv7 payload fallback exists, but they are not in the
  `gaster.c:1525` exec list — treat as out of scope for pomme until proven
  otherwise on hardware (which pomme has not done; builds-not-boots).
- **Not supported at all:** A12 and newer (T8020+). No CPID ≥ 0x8020 appears
  anywhere in the pinned source — consistent with the pipeline-wide rule: no
  public bootROM exploit exists for A12+, so these devices are permanently
  out of scope.

## Feeding the compatibility matrix

Machine-readable summary for `docs/` consumers:

- supported_cpids: 0x8960, 0x7000, 0x7001, 0x7002*, 0x8000, 0x8003, 0x8001,
  0x8002*, 0x8004*, 0x8010, 0x8011, 0x8012, 0x8015
  (`*` = SRTG-recognized only, not in exec gate)
- srtg_recognized_only_cpids (armv7 payload fallback, outside exec gate):
  0x8947, 0x8950, 0x8955
- pomme_target_cpid: 0x8010 (iPhone 7, T8010)
- pomme_verified_on_hardware: none (builds-not-boots)
