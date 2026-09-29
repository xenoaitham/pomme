# pongoOS stage — SoC / device support

Scope of the built payload, cited from the pinned source tree
(upstream/pongoOS-palera1n @ `e98323f8a09abd80fc4cbcd74dee023b91a1ec22`).
Line numbers refer to that exact commit.

## Authoritative in-binary gate

`src/drivers/fuse/fuse.c` — `fuse_init()` switches on `socnum` and **panics on
any SoC not listed** (default case: `panic("Fuse: Unsupported SoC")`):

- `src/drivers/fuse/fuse.c:153-155` — `0x8960`, `0x7000`, `0x7001`
- `src/drivers/fuse/fuse.c:159-163` — `0x8000`, `0x8003`, `0x8001`, `0x8010`, `0x8011`
- `src/drivers/fuse/fuse.c:166-168` — `0x8012`
- `src/drivers/fuse/fuse.c:171-173` — `0x8015`
- `src/drivers/fuse/fuse.c:175-176` — `default: panic("Fuse: Unsupported SoC")`

`socnum` itself is set at boot from the device tree `device_type` name:
`src/kernel/entry.c:146-160` (`s5l8960x`→0x8960 at :146 … `t8015` at :153;
S8000 vs S8003 distinguished via the `/arm-io/sgx` compatible string at
:154-160).

## Platform drivers compiled in (probe by CPID)

Each registers via `REGISTER_DRIVER(..., DRIVER_FLAGS_PLATFORM)` and probes
`device->cpid` (probe bodies at `:28-33` in each file, registration at `:62`):

| CPID | SoC | Driver `.name` (source of truth) | File |
|------|-----|----------------------------------|------|
| 0x8960 | Apple A7 | "Apple A7 (S5L8960)" | `src/drivers/plat/s5l8960.c:30` |
| 0x7000 | Apple A8 | "Apple A8 (T7000)" | `src/drivers/plat/t7000.c:30` |
| 0x7001 | Apple A8X | "Apple A8X (T7001)" | `src/drivers/plat/t7001.c:30` |
| 0x8000 | Apple A9 (Samsung) | "Apple A9 (S8000, Samsung)" | `src/drivers/plat/s8000.c:30` |
| 0x8003 | Apple A9 (TSMC) | "Apple A9 (S8003, TSMC)" | `src/drivers/plat/s8003.c:30` |
| 0x8001 | Apple A9X | "Apple A9X (S8001)" | `src/drivers/plat/s8001.c:30` |
| 0x8010 | Apple A10 | "Apple A10 (T8010)" | `src/drivers/plat/t8010.c:30` |
| 0x8011 | Apple A10X | "Apple A10X (T8011)" | `src/drivers/plat/t8011.c:30` |
| 0x8015 | Apple A11 | "Apple A11 (T8015)" | `src/drivers/plat/t8015.c:30` |
| 0x8012 | Apple T2 | "Apple T2 (T8012)" | `src/drivers/plat/t8012.c:30` |

## What this means for pomme

- **In scope (A7–A11 iPhones):** iPhone 5s, 6/6 Plus, 6s/6s Plus/SE(1st),
  7/7 Plus, 8/8 Plus/X, and the iPad/iPod touch variants on those SoCs, are
  theoretically covered by the platform drivers compiled into this binary.
  The pomme kernel stage currently targets iPhone 7 (T8010) first.
- **Compiled-in but out of pomme scope:** Apple T2 (0x8012) is a Mac/iBridge
  chip, not an iPhone target; the driver is present because upstream builds
  it, but pomme does not claim T2 support.
- **A12 and newer:** permanently unsupported — no platform drivers exist in
  tree (`src/drivers/plat/` contains only the ten listed above), the fuse gate
  panics, and no public checkm8-equivalent bootROM exploit exists for A12+.
- **Device coverage is untested:** builds-not-boots. That platform drivers
  exist in the binary says nothing about whether a specific device actually
  boots it; that requires the gaster checkm8 stage and hardware.
