Title: pomme v0.1.0: a from-source, pinned mirror of the apple-idevice chain — gaster instead of checkra1n at runtime, Linux host only, builds-not-boots
Target: Reddit r/postmarketOS
Status: DRAFT — never posted; paste manually only

---

Hi porting folks. pomme is a build pipeline that assembles the same chain your Apple Generic iDevice port boots — exploit → pongoOS → hoolock kernel → netboot userspace — with three deliberate differences: every stage builds from pinned upstream commits, the host is Linux-only end to end, and the one proprietary link in the runtime chain is replaced. Where the wiki says `PALERA1N_BYPASS_PASSCODE_CHECK=1 palera1n -p -f -k Pongo.bin` (borrowing the closed checkra1n binary), pomme builds gaster (Apache-2.0, palera1n/gaster@20958256) and drives checkm8 with it. Nothing proprietary remains in pomme's own artifacts.

Exactly which pmOS pieces pomme tracks, at which pins:

- **pmaports @ 34a4e3c3** (2026-09-28 tip) — the config lineage. pomme's 16K kernel config is your `device/testing/linux-postmarketos-apple-16k/config-postmarketos-apple-16k.aarch64`, committed into the repo with its sha256 and sha512-matched against the APKBUILD.
- **Kernel:** HoolockLinux/linux @ dfa4d420, tag `hoolock-7.0.12` — the same source as `linux-postmarketos-apple-16k`. One documented deviation: pomme builds with a sha256-pinned Bootlin gcc 15.3.0 instead of LLVM=1, which drops CONFIG_RUST and needs a single GCC fixup patch.
- **m1n1 packaging:** HoolockLinux/m1n1 @ bd117d71, following `m1n1-apple-idevice`.
- **Initramfs design:** netboot-first, mirroring `postmarketos-mkinitfs-hook-netboot` (`setup_usb_network`, nbd), on the wiki's own finding that only A11 devices have working internal storage.
- **pongoOS:** palera1n/pongoOS @ e98323f8, with the fork's `bootm` m1n1 hook as the handoff point.

v0.1.0 output: gaster, `Pongo.bin`, a Linux 7.0.12 Image (16K pages, iPhone 7/T8010 config), an `Image.initramfs` with the initramfs embedded via `CONFIG_INITRAMFS_SOURCE`, 92 DTBs, modules, and an Alpine 3.24.2 initramfs + 256 MB ext4 rootfs. The 4K A7/A8/A8X flavor matching `linux-postmarketos-apple-4k` is built too — 4K `Image` + `Image.initramfs` with its own initramfs/rootfs module closure — plus m1n1 itself (`RELEASE=1 CHAINLOADING=1` with your `m1n1-apple-idevice` knobs, byte-identical across three full rebuilds). Determinism evidence is committed: DTBs bit-identical across clean-room rebuilds (both flavors), the initramfs byte-reproducible (pinned mtimes, `gzip -n`), and the rootfs honestly not — mke2fs randomizes its UUID, so it's pinned by sha256 instead.

Honesty, in the house style: **builds-not-boots.** Nothing pomme ships has been booted on hardware, and there is no device in this project. Every row of the compatibility matrix carries UNTESTED ON HARDWARE, and the wiki's tested-device statuses stay pmOS's evidence, not pomme's. The images serve an unauthenticated root shell on every channel they reach (port 23 on the USB gadget network, ttyGS0, console) — a bench bring-up posture; keep them off networks. A12+ is permanently out of scope: no public checkm8-equivalent bootROM exploit exists.

pomme lives outside the distro (own pipeline, MIT glue, upstream licenses intact) and claims no APKBUILD integration. But the per-device matrix in `docs/compatibility-matrix.md` cites the wiki plus pinned code for every cell, and corrections from people who boot this hardware are what that file needs.

Credits: postmarketOS apple-idevice port (chain, kernel lineage, m1n1 packaging), palera1n (gaster, pongoOS fork), Project Sandcastle/Corellium (loader protocol, kernel cross-reference), axi0mX/ipwndfu (checkm8), HoolockLinux (kernel and m1n1 forks). Repo and the v0.1.0 release: https://github.com/xenoaitham/pomme
