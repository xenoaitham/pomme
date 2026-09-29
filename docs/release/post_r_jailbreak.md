Title: pomme v0.1.0 — an open-source Linux boot chain for checkm8-era devices (A7–A11), built entirely on Linux, with receipts
Target: Reddit r/jailbreak
Flair: Discussion (suggested)
Status: DRAFT — never posted; paste manually only

---

Hey all. Sharing pomme: a documented build pipeline that produces a complete open-source Linux boot chain for checkm8-era iPhones and iPads (A7–A11). The chain is gaster (an open checkm8 exploit tool) → pongoOS → Linux 7.0.12 with 92 device trees → Alpine userspace. Primary target: iPhone 7 (T8010). Everything builds on a plain Linux x86-64 host — no macOS, no Xcode, no Apple SDK, pongoOS included.

**The honesty box**

- **Builds, not boots.** Nothing here has ever run on hardware — there is no device yet. "Green" means the pipeline and its evidence are clean, never that a phone ran any of it.
- **A12 and newer (iPhone XS/XR and later) are permanently unsupported.** No public checkm8-equivalent bootROM exploit exists for them. That is a hardware fact, full stop.
- **The boot scripts are untested on hardware.** `scripts/boot-iphone7.sh` exists and is sequenced into a first-session checklist; that is the entire claim.
- **The images serve an unauthenticated root shell by design** — port 23 on the USB gadget network, the ttyGS0 serial console, a passwordless root getty. That's a bench bring-up posture for a phone plugged into your own host. **Do not put a device running these images on a network.**
- **Both page-size flavors ship with evidence.** The 16K build serves A9–A11 (iPhone 7 primary); the 4K build — kernel plus its own initramfs/rootfs module closure — serves A7/A8/A8X (iPhone 5s/6/6+, iPad Air 1/2, mini 2/3/4, iPod touch 6). The 4K devices' chainloader (m1n1, chainloaded by pongoOS `bootm`, matching pmOS packaging) is built too. None of it has touched hardware.

**What v0.1.0 contains** (artifacts attached to the release; every sha256 in `artifacts/manifest.json`, `make verify` recomputes the lot):

- `gaster` — Linux host binary, 46 KB, `6802003b…` — palera1n/gaster@20958256 (Apache-2.0)
- `Pongo.bin` — 233 KB, `22eec6e4…` — pongoOS from palera1n/pongoOS@e98323f8, built on Linux with checksum-pinned `ld64`/`cctools-strip`
- Linux 7.0.12, HoolockLinux/linux@dfa4d420 (tag `hoolock-7.0.12`; the same source pmOS's apple-idevice port ships): a bare 16K-page `Image` (19.3 MB, `57ef480e…`), an `Image.initramfs` (20 MB, `473660c0…`) with the initramfs embedded, **92 DTBs** covering A7–A11-era boards, and `modules.tar.gz` (6.0 MB, `fb480afd…`)
- Alpine 3.24.2 userspace: `initramfs.cpio.gz` (708 KB, `39f349e9…`, byte-reproducible) and a 256 MB ext4 `rootfs.img` (`66a2e301…`)
- The 4K flavor for A7/A8/A8X: a 4K-page `Image` + `Image.initramfs` (HoolockLinux/linux@dfa4d420, pmaports `linux-postmarketos-apple-4k` config lineage), with its own initramfs + rootfs module closure, plus `m1n1` (`4014f9f7…`, HoolockLinux/m1n1@bd117d71, `RELEASE=1 CHAINLOADING=1`, byte-identical across three full rebuilds) — the pongoOS-`bootm` chainloader those devices use on pmOS

Every artifact traces to a pinned upstream commit or a committed build log; the DTBs came out bit-identical across clean-room rebuilds; the cross toolchain is a sha256-pinned Bootlin gcc 15.3.0.

**What's next:** the first hardware session on an iPhone 7 — pre-sequenced in `RESUME.md` with a triage tree, `docs/bring-up.md` as the operator guide. Both predate any boot attempt, so the first console capture is evidence, not a story. An A7–A11 device plus a Linux host is the combination this project needs.

To be explicit about scope: pomme doesn't patch iOS and isn't a jailbreak tool — the destination is Linux, loaded over checkm8 in DFU.

Credits, since nothing here is from scratch: axi0mX (checkm8, ipwndfu), palera1n (gaster and the pongoOS fork), Corellium's Project Sandcastle (the `fdt`/`bootl` loader protocol, kernel cross-reference), postmarketOS's apple-idevice port (the chain pomme mirrors), HoolockLinux (kernel and m1n1 forks). pomme is MIT; the upstreams keep their own licenses.

Repo and the v0.1.0 release with all artifacts: https://github.com/xenoaitham/pomme
