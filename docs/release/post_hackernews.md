Show HN: Pomme - reproducible Linux boot-chain builds for checkm8-era iPhones

*Draft for Hacker News. The line above is the exact post title (77 chars); everything below is the author's first comment. Do not post automatically.*

---

checkm8 (axi0mX, 2019) is a bootROM bug in Apple's A5–A11 SoCs. The bug lives in mask ROM, so no software update removes it; arbitrary code can run in DFU before any OS loads. That opening is what the ecosystem stands on: pongoOS, the checkra1n team's bootloader, loads into pwned DFU and hands off to an arm64 Linux kernel. Project Sandcastle ran Linux on an iPhone 7 in 2020; postmarketOS maintains a testing-tier apple-idevice port today. Every one of those chains reached for the same closed piece at the bottom: the checkra1n binary.

pomme replaces that piece with gaster (open source, Apache-2.0) and treats everything above it as a reproducibility problem rather than a tutorial. Every upstream sits at a pinned commit, every build log is committed, and every artifact lands in a sha256 manifest `make verify` recomputes end to end. Clean-room rebuilds are compared for bit-identity: the 92 device trees match, the kernel Image differs only by an epoch-fixed timestamp, the initramfs is byte-reproducible, the ext4 rootfs is not (mke2fs randomizes its UUID — pinned by hash instead). The host is Linux-only; even pongoOS, normally an Xcode build, is produced with checksum-pinned ld64/cctools-strip.

In the repo's own phrase: builds, not boots. All four stages — gaster, pongoOS, Linux 7.0.12 with 92 DTBs, Alpine initramfs and rootfs — build green with that evidence attached; nothing has ever booted, because no device was ever attached to this project. The first hardware session, on an iPhone 7, is sequenced in RESUME.md, and the compatibility matrix marks every device UNTESTED ON HARDWARE.

Two things stated plainly. A12 and newer are permanently out of scope — no public checkm8-equivalent bootROM exploit exists, and no roadmap pretends otherwise. The images serve an unauthenticated root shell on every channel they reach (port 23 on the USB network, serial console, passwordless getty) — a bench bring-up posture, a reason to keep such a device off any network.

If you enjoy reviewing provenance chains: the pin records, the manifest, the determinism claims in artifacts/*/provenance.json, and the rules in docs/pipeline-conventions.md were built to be checked — eyes on them are the ask. Credits: palera1n (gaster, pongoOS fork), Corellium's Project Sandcastle (loader protocol), postmarketOS's apple-idevice port (chain, kernel lineage), HoolockLinux (kernel, m1n1 forks), axi0mX (checkm8). pomme's glue is MIT; upstreams keep their licenses. Repo and v0.1.0 release, artifacts attached: https://github.com/xenoaitham/pomme
