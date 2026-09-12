# CentroidX station images.
#
#   make image     -> out/centroidx-<ref>.img.gz + .bmap   (flash onto an SSD)
#   make usb       -> out/usb-installer.img.gz + .bmap      (write onto a USB key)
#   make qemu      -> boot the USB key against a blank disk, end to end
#   make dry-run   -> validate all three recipes without building
#
# debos needs KVM, so `image`/`usb` only run on Linux. `dry-run` works anywhere.

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

# The compose file lives one directory up, in this same repo, at this same
# commit. That is the whole reason the installer moved in here: there is no ref
# to pin, no copy to go stale, and the provenance stamp below covers the compose
# file, the Dockerfiles and the app together.
COMPOSE_SRC    ?= ../docker-compose.yml

SUITE          ?= trixie
GPU            ?= intel
IMAGESIZE      ?= 8GB
USBSIZE        ?= 8GB
PRELOAD        ?= false

OUT            := out
GEN            := overlays/generated
PAYLOAD        := $(OUT)/payload
STAMP          := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit)
IMAGE          := centroidx-$(STAMP).img

DEBOS_IMAGE    ?= godebos/debos:latest
# CI has no TTY; a local run wants one for debos's progress output.
DOCKER_TTY     ?= $(shell [ -t 0 ] && echo -it)
DEBOS          = docker run --rm $(DOCKER_TTY) \
                   --device /dev/kvm \
                   --group-add "$$(stat -c '%g' /dev/kvm)" \
                   --user $$(id -u) \
                   --workdir /recipes \
                   --mount "type=bind,source=$(CURDIR),destination=/recipes" \
                   --security-opt label=disable \
                   $(DEBOS_IMAGE)
# --dry-run needs no virtualisation, so it needs no /dev/kvm either.
DEBOS_DRY      = docker run --rm \
                   --user $$(id -u) \
                   --workdir /recipes \
                   --mount "type=bind,source=$(CURDIR),destination=/recipes" \
                   --security-opt label=disable \
                   $(DEBOS_IMAGE)

.PHONY: help
help:
	@sed -n '2,9p' Makefile | sed 's/^# \?//'
	@echo
	@echo "Variables: COMPOSE_SRC=$(COMPOSE_SRC) SUITE=$(SUITE) GPU=$(GPU)"
	@echo "           IMAGESIZE=$(IMAGESIZE) USBSIZE=$(USBSIZE) PRELOAD=$(PRELOAD)"

# ---------------------------------------------------------------- generated/
# Everything here is fetched or derived, never committed. The station's compose
# file is pulled from CentroidX at a pinned ref rather than copied into this
# repo, because a second copy of that file is a copy that goes stale -- which is
# exactly what happened to the one that used to sit in this directory.
.PHONY: generated
generated:
	@mkdir -p $(GEN)/home/centroid $(GEN)/etc/centroid $(GEN)/var/lib/centroid/preload
	@test -r "$(COMPOSE_SRC)" || { echo "no compose file at $(COMPOSE_SRC)"; exit 1; }
	@cp "$(COMPOSE_SRC)" $(GEN)/home/centroid/docker-compose.yml
	@test -r ../.env.example && cp ../.env.example $(GEN)/etc/centroid/env.example || true
	@{ echo "CentroidX station image"; \
	   echo "built:      $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	   echo "centroidx:  $$(git describe --always --dirty --tags 2>/dev/null || echo unknown)"; \
	   echo "commit:     $$(git rev-parse HEAD 2>/dev/null || echo unknown)"; \
	   echo "suite:      $(SUITE)"; \
	   echo "gpu:        $(GPU)"; \
	   echo "preloaded:  $(PRELOAD)"; \
	 } > $(GEN)/etc/centroid/image-info
	@cat $(GEN)/etc/centroid/image-info | sed 's/^/  /'

# Pull every image the compose names and stage it as a tarball inside the rootfs.
# centroidx-firstboot loads and deletes them. Costs the compressed size twice on
# disk until first boot, and buys an install that needs no network at all.
.PHONY: preload
preload: generated
	@command -v docker >/dev/null || { echo "docker required for preload"; exit 1; }
	@set -euo pipefail; \
	imgs=$$(grep -oE '^\s+image:\s*\S+' $(GEN)/home/centroid/docker-compose.yml | awk '{print $$2}' | sort -u); \
	for i in $$imgs; do \
	  echo "pulling $$i"; \
	  docker pull --platform linux/amd64 "$$i"; \
	  out=$(GEN)/var/lib/centroid/preload/$$(echo "$$i" | tr '/:' '__').tar; \
	  docker save "$$i" -o "$$out"; \
	  zstd -q -f --rm "$$out"; \
	done; \
	du -sh $(GEN)/var/lib/centroid/preload

# -------------------------------------------------------------------- builds
.PHONY: require-kvm
require-kvm:
	@test -w /dev/kvm || { \
	  echo "debos needs /dev/kvm to build an image (image-partition does not work"; \
	  echo "without a fakemachine). Build on Linux or in CI. 'make dry-run' and"; \
	  echo "'make print-recipe' work here."; exit 1; }

.PHONY: image
image: require-kvm generated
	@mkdir -p $(OUT)
	$(DEBOS) -v --fakemachine-backend=kvm --scratchsize=16GB \
	  --artifactdir=/recipes/$(OUT) \
	  -t image:$(IMAGE) -t imagesize:$(IMAGESIZE) \
	  -t suite:$(SUITE) -t gpu:$(GPU) \
	  image.yaml
	@# Name it <image>.img.bmap so it sits beside <image>.img.gz and the
	@# installer can find it by stripping .gz. bmaptool must run on the raw
	@# image, before compression.
	bmaptool create -o $(OUT)/$(IMAGE).bmap $(OUT)/$(IMAGE)
	gzip -f -9 $(OUT)/$(IMAGE)
	@ls -lh $(OUT)/

.PHONY: usb
usb: require-kvm generated
	@test -n "$$(ls $(OUT)/centroidx-*.img.gz 2>/dev/null)" || { echo "run 'make image' first"; exit 1; }
	rm -rf $(PAYLOAD) && mkdir -p $(PAYLOAD)
	@# centroidx-* explicitly, never *.img.gz: out/ also holds usb-installer.img.gz
	@# after a previous run, and globbing it in would nest one image inside the next.
	cp $(OUT)/centroidx-*.img.gz $(OUT)/centroidx-*.img.bmap $(PAYLOAD)/
	cp $(GEN)/etc/centroid/image-info $(PAYLOAD)/image-info
	@# Drop a station.env here to make the USB install without asking anything.
	@test -f station.env && cp station.env $(PAYLOAD)/ || true
	$(DEBOS) -v --fakemachine-backend=kvm --scratchsize=24GB \
	  --artifactdir=/recipes/$(OUT) \
	  -t usbimage:usb-installer.img -t usbsize:$(USBSIZE) -t suite:$(SUITE) \
	  installer.yaml
	@# Same treatment as the station image. Most of an 8GB USB image is holes --
	@# bmaptool skips them, so writing the stick copies what is actually there.
	bmaptool create -o $(OUT)/usb-installer.img.bmap $(OUT)/usb-installer.img
	gzip -f -9 $(OUT)/usb-installer.img
	@ls -lh $(OUT)/

# ------------------------------------------------------------------ validate
.PHONY: dry-run
dry-run: generated
	$(DEBOS_DRY) --dry-run -t image:$(IMAGE) -t suite:$(SUITE) -t gpu:$(GPU) rootfs.yaml
	$(DEBOS_DRY) --dry-run -t image:$(IMAGE) -t suite:$(SUITE) -t gpu:$(GPU) image.yaml
	mkdir -p $(PAYLOAD) && touch $(PAYLOAD)/.keep
	$(DEBOS_DRY) --dry-run -t suite:$(SUITE) installer.yaml

.PHONY: print-recipe
print-recipe: generated
	$(DEBOS_DRY) --print-recipe --dry-run -t suite:$(SUITE) -t gpu:$(GPU) image.yaml

.PHONY: verify-keys
verify-keys:
	@echo "1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570  overlays/base/etc/apt/keyrings/docker.asc" | shasum -a 256 -c -
	@echo "bc3e1dc91a891aab76d730c3683b3b93515fe52cda4f83980c8694fa782fba3c  overlays/base/etc/apt/keyrings/zerotier.asc" | shasum -a 256 -c -

# ----------------------------------------------------------------- test boot
# The tfc-nix test loop: boot the installer against a blank NVMe under OVMF and
# watch it install. Needs KVM; the QEMU invocation is lifted from
# tfc-nix/flake.nix, which already had exactly the right device set.
OVMF ?= /usr/share/OVMF/OVMF_CODE.fd
OVMF_VARS ?= /usr/share/OVMF/OVMF_VARS.fd
.PHONY: qemu
qemu:
	@test -f $(OUT)/usb-installer.img.gz || { echo "run 'make usb' first"; exit 1; }
	@# QEMU wants a raw disk, and `make usb` leaves a compressed one.
	@test -f $(OUT)/usb-installer.img || gunzip -k $(OUT)/usb-installer.img.gz
	@test -f $(OUT)/test-disk.qcow2 || qemu-img create -f qcow2 $(OUT)/test-disk.qcow2 32G
	@test -f $(OUT)/OVMF_VARS.fd || cp $(OVMF_VARS) $(OUT)/OVMF_VARS.fd
	qemu-system-x86_64 \
	  -enable-kvm -cpu host -smp 2 -m 2G -machine q35 \
	  -drive if=pflash,format=raw,unit=0,readonly=on,file=$(OVMF) \
	  -drive if=pflash,format=raw,unit=1,file=$(OUT)/OVMF_VARS.fd \
	  -device nvme,serial=deadbeef,drive=nvm \
	  -drive file=$(OUT)/test-disk.qcow2,format=qcow2,if=none,id=nvm,cache=unsafe \
	  -device usb-ehci,id=ehci \
	  -device usb-storage,bus=ehci.0,drive=usbdisk \
	  -drive file=$(OUT)/usb-installer.img,format=raw,if=none,id=usbdisk \
	  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
	  -nographic

.PHONY: qemu-reset
qemu-reset:
	rm -f $(OUT)/test-disk.qcow2 $(OUT)/OVMF_VARS.fd

.PHONY: clean
clean:
	rm -rf $(GEN) $(PAYLOAD) $(OUT)/*.img $(OUT)/*.img.gz $(OUT)/*.bmap
