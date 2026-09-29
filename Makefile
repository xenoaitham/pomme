# pomme — Linux for checkm8-era iPhones (A7–A11)
# Pipeline: gaster → pongoOS → kernel → images
# See docs/pipeline-conventions.md for the stage contract.

.DEFAULT_GOAL := help
LOGDIR := evidence/builds
STAMP := $(shell date +%Y%m%d_%H%M%S)

.PHONY: help gaster pongoos kernel images all verify docs-sync clean logs

help:
	@echo "pomme build pipeline (builds-not-boots; no device required)"
	@echo "  make gaster   - checkm8 exploit tool (Linux host binary)"
	@echo "  make pongoos  - pongoOS bootloader (arm64 Mach-O payload)"
	@echo "  make kernel   - Linux arm64 Image + DTBs + modules (iPhone 7)"
	@echo "  make images   - initramfs + Alpine rootfs image"
	@echo "  make all      - everything above, in order"
	@echo "  make verify   - check artifacts against artifacts/manifest.json"
	@echo "  make clean    - remove build outputs (keeps evidence/)"

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

all: gaster pongoos kernel images
	@bash scripts/manifest.sh
	@python3 scripts/update_doc_hashes.py

docs-sync:
	@bash scripts/manifest.sh
	@python3 scripts/update_doc_hashes.py

verify:
	@bash scripts/verify.sh

clean:
	@rm -rf artifacts/gaster/* artifacts/pongoos/* artifacts/kernel/* artifacts/images/*
