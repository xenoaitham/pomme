# pomme — Linux for checkm8-era iPhones (A7–A11)
# Pipeline: gaster → pongoOS → kernel → images  (+ m1n1 and the 4K flavor)
# See docs/pipeline-conventions.md for the stage contract.

.DEFAULT_GOAL := help
LOGDIR := evidence/builds
STAMP := $(shell date +%Y%m%d_%H%M%S)

.PHONY: help gaster pongoos kernel images all verify docs-sync clean logs \
        m1n1 kernel-4k images-4k all-4k

help:
	@echo "pomme build pipeline (builds-not-boots; no device required)"
	@echo "  make gaster     - checkm8 exploit tool (Linux host binary)"
	@echo "  make pongoos    - pongoOS bootloader (arm64 Mach-O payload)"
	@echo "  make kernel     - Linux arm64 Image + DTBs + modules, 16K pages (iPhone 7, A9-A11)"
	@echo "  make images     - initramfs + Alpine rootfs image, 16K module closure"
	@echo "  make m1n1       - m1n1 idevice bootloader (pongoOS bootm payload; A7/A8 chain)"
	@echo "  make kernel-4k  - Linux arm64 Image + DTBs + modules, 4K pages (A7/A8/A8X)"
	@echo "  make images-4k  - initramfs + Alpine rootfs, 4K module closure"
	@echo "  make all        - 16K chain end to end (primary iPhone 7 target)"
	@echo "  make all-4k     - 4K chain end to end (kernel -> images -> kernel rebundle)"
	@echo "  make verify     - check artifacts against artifacts/manifest.json"
	@echo "  make clean      - remove build outputs (keeps evidence/)"

gaster:
	@mkdir -p $(LOGDIR) artifacts/gaster
	@bash tooling/gaster/build.sh 2>&1 | tee $(LOGDIR)/gaster_$(STAMP).log

pongoos:
	@mkdir -p $(LOGDIR) artifacts/pongoos
	@bash tooling/pongoos/build.sh 2>&1 | tee $(LOGDIR)/pongoos_$(STAMP).log

kernel:
	@mkdir -p $(LOGDIR) artifacts/kernel
	@bash tooling/kernel/build.sh 2>&1 | tee $(LOGDIR)/kernel_$(STAMP).log

images:
	@mkdir -p $(LOGDIR) artifacts/images
	@bash tooling/images/build.sh 2>&1 | tee $(LOGDIR)/images_$(STAMP).log

m1n1:
	@mkdir -p $(LOGDIR) artifacts/m1n1
	@bash tooling/m1n1/build.sh 2>&1 | tee $(LOGDIR)/m1n1_$(STAMP).log

kernel-4k:
	@mkdir -p $(LOGDIR) artifacts/kernel-4k
	@POMME_KERNEL_FLAVOR=4k bash tooling/kernel/build.sh 2>&1 | tee $(LOGDIR)/kernel-4k_$(STAMP).log

images-4k:
	@mkdir -p $(LOGDIR) artifacts/images-4k
	@POMME_KERNEL_FLAVOR=4k bash tooling/images/build.sh 2>&1 | tee $(LOGDIR)/images-4k_$(STAMP).log

# GNU make dedupes repeated prerequisites, so the final kernel-4k rebundle
# (which embeds the images-4k initramfs via CONFIG_INITRAMFS_SOURCE) is an
# explicit recipe step in both aggregate targets, not a repeated prerequisite.
# images-4k must run after kernel-4k (it integrates the 4K module closure);
# the trailing kernel-4k run is usually incremental and cheap.
all: gaster pongoos kernel images m1n1 kernel-4k images-4k
	@$(MAKE) kernel-4k
	@bash scripts/manifest.sh
	@python3 scripts/update_doc_hashes.py

all-4k: kernel-4k images-4k
	@$(MAKE) kernel-4k
	@bash scripts/manifest.sh
	@python3 scripts/update_doc_hashes.py

docs-sync:
	@bash scripts/manifest.sh
	@python3 scripts/update_doc_hashes.py

verify:
	@bash scripts/verify.sh

clean:
	@rm -rf artifacts/gaster/* artifacts/pongoos/* artifacts/kernel/* \
	        artifacts/images/* artifacts/m1n1/* artifacts/kernel-4k/* \
	        artifacts/images-4k/*
