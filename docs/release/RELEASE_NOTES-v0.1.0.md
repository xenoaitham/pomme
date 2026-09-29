pomme v0.1.0 — an open-source Linux boot chain for checkm8-era iPhones (A7–A11)

First public release. pomme is a documented, evidence-backed build pipeline
that produces a complete open-source Linux boot chain for checkm8-era
iPhones and iPads, targeting the iPhone 7 (Apple T8010) first. Everything
builds on a plain Linux x86-64 host — no macOS, no Xcode, no Apple SDK,
pongoOS included.

**Read the honesty box first**

- **Builds, not boots.** Nothing in this repository has ever been booted on
  hardware — the project has no device. "Green" means the build pipeline and
  its evidence are clean, never that a phone ran them. The first hardware
  session is pre-sequenced in RESUME.md; the operator guide is
  docs/bring-up.md.
- **A12 and newer are permanently unsupported.** No public checkm8-equivalent
  bootROM exploit exists for them. Not a TODO.
- **The boot tools are untested on hardware.**
- **The images serve an unauthenticated root shell by design** (port 23 on
  the USB gadget network, ttyGS0 serial, passwordless getty) — a bench
  bring-up posture. Do not put a device running them on a network.

**What ships (all sha256-pinned in artifacts/manifest.json; `make verify`
recomputes every hash)**

- **gaster** — the checkm8 exploit tool as a Linux host binary
  (palera1n/gaster@20958256, Apache-2.0)
- **pongoOS** — Pongo.bin + Pongo.macho + checkra1n kernel patchfinder,
  built natively on Linux with checksum-pinned ld64/cctools-strip
  (palera1n/pongoOS@e98323f8)
- **Linux 7.0.12** (HoolockLinux/linux@dfa4d420, tag hoolock-7.0.12 — the
  same source postmarketOS's apple-idevice port ships): 16K-page Image +
  Image.initramfs (initramfs embedded via CONFIG_INITRAMFS_SOURCE), 92
  Apple DTBs, modules
- **4K-page flavor for A7/A8/A8X** (iPhone 5s/6/6+, iPad Air 1/2, mini
  2/3/4, iPod touch 6): Image + Image.initramfs with its own initramfs and
  rootfs module closure (pmaports linux-postmarketos-apple-4k config
  lineage, sha512-matched against the APKBUILD)
- **m1n1** — the idevice chainloader (pongoOS `bootm` payload), built with
  RELEASE=1 CHAINLOADING=1, byte-identical across three consecutive full
  rebuilds (HoolockLinux/m1n1@bd117d71, MIT)
- **Alpine 3.24.2 userspace** — netboot-first initramfs (byte-reproducible)
  + 256 MB ext4 rootfs, per flavor
- **scripts/pomme** — a guided host tool: device-state detection, DFU-entry
  coaching, full chain, host-network setup. Build-verified without a device;
  UNTESTED ON HARDWARE.

**Evidence discipline** — every artifact traces to a pinned upstream commit
or a committed build log, or both; determinism records in
artifacts/*/provenance.json (DTBs bit-identical across clean-room rebuilds;
initramfs byte-reproducible; rootfs honestly not — mke2fs randomizes its
UUID, pinned by hash instead); hosted CI rebuilds all seven stages on every
push, and the manifest/doc-hash/log-hash gates re-verify the evidence chain.

**Credits** — axi0mX (checkm8/ipwndfu), palera1n (gaster, pongoOS fork),
Corellium's Project Sandcastle (loader protocol), postmarketOS apple-idevice
(chain, kernel lineage, m1n1 packaging), HoolockLinux (kernel + m1n1 forks).
pomme's glue is MIT; upstreams keep their own licenses. Not affiliated with
Apple Inc.

Assets: SHA256SUMS covers every file; the DTB sets ship as dtbs-16k.tar.gz /
dtbs-4k.tar.gz. Verify after download: `sha256sum -c SHA256SUMS`.
