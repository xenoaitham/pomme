# kernel stage — supported devices (apple/*.dtb coverage)

Device coverage of the DTBs built by `tooling/kernel/build.sh` from
`arch/arm64/boot/dts/apple/` (HoolockLinux/linux @ `hoolock-7.0.12`,
`arch/arm64/boot/dts/apple/Makefile`: 92 `dtb-$(CONFIG_ARCH_APPLE)` entries,
all 92 installed into `artifacts/kernel/dtbs/` — verified by the committed
build log `evidence/builds/kernel_7.0.12-hoolock_20260929.log`). Model strings
are quoted from the `.dts` sources (`model = "..."`), not from hardware.

**These are DTS-level claims, not boot claims.** pomme is builds-not-boots
(`docs/pipeline-conventions.md`): a dtb existing here means the build produced
it, nothing more. pmOS's own tested list (wiki, `docs/bars.md` bar 3) is the
only hardware-verified floor.

**Page-size gate (decides which SoCs this exact kernel can serve):** this is
the **16K-page** flavor — correct for A9/A9X/A10/A10X/A11/T2; A7/A8/A8X
devices need the 4K flavor, which pomme does not build (yet). Citation:
pmOS wiki "Apple Generic iDevice" (https://wiki.nura.eco/wiki/Apple_Generic_iDevice_(apple-idevice),
retrieved 2026-09-29) + pmaports
`config-postmarketos-apple-16k.aarch64:462` (`CONFIG_ARM64_16K_PAGES=y`).
The 16K property of the shipped Image is independently visible to `file(1)`:
"Linux kernel ARM64 boot executable Image, little-endian, 16K pages".

## In scope: checkm8-era (A7–A11) and T2

### T8010 / A10 Fusion — PRIMARY TARGET (16K ✓)

| dtb | device |
|---|---|
| `t8010-d10.dtb` | **Apple iPhone 7 (Qualcomm modem)** — iPhone9,1 (A1660/A1778/A1779/A1780) |
| `t8010-d101.dtb` | **Apple iPhone 7 (Intel modem)** — iPhone9,3 |
| `t8010-d11.dtb` | Apple iPhone 7 Plus (Qualcomm) — iPhone9,2 |
| `t8010-d111.dtb` | Apple iPhone 7 Plus (Intel) — iPhone9,4 |
| `t8010-j71b.dtb` | Apple iPad 6 (Wi-Fi) |
| `t8010-j72b.dtb` | Apple iPad 6 (Cellular) |
| `t8010-j171.dtb` | Apple iPad 7 (Wi-Fi) |
| `t8010-j172.dtb` | Apple iPad 7 (Cellular) |
| `t8010-n112.dtb` | Apple iPod touch 7 |

### T8015 / A11 (16K ✓)

| dtb | device |
|---|---|
| `t8015-d20.dtb` | Apple iPhone 8 (Global) |
| `t8015-d201.dtb` | Apple iPhone 8 (GSM) |
| `t8015-d21.dtb` | Apple iPhone 8 Plus (Global) |
| `t8015-d211.dtb` | Apple iPhone 8 Plus (GSM) |
| `t8015-d22.dtb` | Apple iPhone X (Global) |
| `t8015-d221.dtb` | Apple iPhone X (GSM) |

A11 caveat (from palera1n, `docs/bars.md` bar 2): passcode must be disabled in
the jailbroken state; pmOS reports internal storage works on A11 only.

### T8011 / A10X (16K ✓)

| dtb | device |
|---|---|
| `t8011-j120.dtb` | Apple iPad Pro 2 (12.9-inch) (Wi-Fi) |
| `t8011-j121.dtb` | Apple iPad Pro 2 (12.9-inch) (Cellular) |
| `t8011-j207.dtb` | Apple iPad Pro 2 (10.5-inch) (Wi-Fi) |
| `t8011-j208.dtb` | Apple iPad Pro 2 (10.5-inch) (Cellular) |
| `t8011-j105a.dtb` | Apple TV 4K (1st Generation) |

### S8000/S8003 / A9 and S8001 / A9X (16K ✓)

| dtb | device |
|---|---|
| `s8000-n71.dtb` | Apple iPhone 6s (Samsung fab) |
| `s8003-n71m.dtb` | Apple iPhone 6s (TSMC fab) |
| `s8000-n66.dtb` | Apple iPhone 6s Plus (Samsung) |
| `s8003-n66m.dtb` | Apple iPhone 6s Plus (TSMC) |
| `s8000-n69u.dtb` | Apple iPhone SE (Samsung) |
| `s8003-n69.dtb` | Apple iPhone SE (TSMC) |
| `s8000-j71s.dtb` / `s8003-j71t.dtb` | Apple iPad 5 (Wi-Fi) (Samsung / TSMC) |
| `s8000-j72s.dtb` / `s8003-j72t.dtb` | Apple iPad 5 (Cellular) (Samsung / TSMC) |
| `s8001-j98a.dtb` | Apple iPad Pro (12.9-inch) 1st gen (Wi-Fi) |
| `s8001-j99a.dtb` | Apple iPad Pro (12.9-inch) 1st gen (Cellular) |
| `s8001-j127.dtb` | Apple iPad Pro (9.7-inch) (Wi-Fi) |
| `s8001-j128.dtb` | Apple iPad Pro (9.7-inch) (Cellular) |

### T8012 / T2 (16K ✓ — Macs, not iDevices)

`t8012-j137.dtb` iMacPro1,1 · `t8012-j680.dtb`/`t8012-j780.dtb`
MacBookPro15,1/15,3 · `t8012-j132.dtb` MacBookPro15,2 · `t8012-j213.dtb`
MacBookPro15,4 · `t8012-j152f.dtb` MacBookPro16,1 · `t8012-j214k.dtb`
MacBookPro16,2 · `t8012-j215.dtb` MacBookPro16,4 · `t8012-j223.dtb`
MacBookPro16,3 · `t8012-j140k.dtb`/`t8012-j140a.dtb` MacBookAir8,1/8,2 ·
`t8012-j230k.dtb` MacBookAir9,1 · `t8012-j160.dtb` MacPro7,1 ·
`t8012-j174.dtb` Macmini8,1 · `t8012-j185.dtb`/`t8012-j185f.dtb` iMac20,1/20,2

### S5L8960 / A7, T7000 / A8, T7001 / A8X — **4K kernel required; NOT servable by this build**

Built and shipped in `artifacts/kernel/dtbs/`, but this 16K kernel will not
run on them (page-size gate above). They need the unbuilt 4K flavor:

| dtb | device |
|---|---|
| `s5l8960x-n51.dtb` | Apple iPhone 5s (GSM) |
| `s5l8960x-n53.dtb` | Apple iPhone 5s (LTE) |
| `s5l8960x-j71/j72/j73.dtb` | Apple iPad Air (Wi-Fi / Cellular / Cellular China) |
| `s5l8960x-j85/j86/j87.dtb` | Apple iPad mini 2 (Wi-Fi / Cellular / Cellular China) |
| `s5l8960x-j85m/j86m/j87m.dtb` | Apple iPad mini 3 (Wi-Fi / Cellular / Cellular China) |
| `t7000-n61.dtb` | Apple iPhone 6 |
| `t7000-n56.dtb` | Apple iPhone 6 Plus |
| `t7000-n102.dtb` | Apple iPod touch 6 |
| `t7000-j96.dtb` / `t7000-j97.dtb` | Apple iPad mini 4 (Wi-Fi / Cellular) |
| `t7000-j42d.dtb` | Apple TV HD |
| `t7001-j81.dtb` / `t7001-j82.dtb` | Apple iPad Air 2 (Wi-Fi / Cellular) |

## Out of scope but also built

The hoolock tree's apple DTS set includes Apple Silicon Macs (t8103 M1 ×5,
t6000/t6001/t6002 M1 Pro/Max/Ultra ×6, t6020/t6021/t6022 M2 ×8, t8112 M2 ×4 =
23 dtbs). They ride along in `artifacts/kernel/dtbs/` because the pmOS config
enables `CONFIG_ARCH_APPLE` for the whole family; pomme does not target them
and the checkm8 boot chain does not apply.

## Compatibility-matrix feeds

- Exact filename set: `artifacts/kernel/dtbs/` (92 files) + the sha256 block
  at the end of the committed build log.
- Feature status per device: pmOS wiki tested list + the iPhone 7/7+
  (apple-d10) page (URLs in `docs/bars.md` bar 3); touchscreen/WiFi/BT report
  working there, but that is pmOS-on-hardware, not pomme.
- SoC → page-size rule and per-device kernel flavor choice: citations at the
  top of this file.
