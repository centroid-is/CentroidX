#!/bin/bash
# Runs in the chroot AFTER filesystem-deploy, when the ESP is mounted and
# /etc/fstab has real UUIDs.
set -euo pipefail

# --removable writes /EFI/BOOT/BOOTX64.EFI, the path UEFI firmware tries when it
# has no NVRAM entry for this disk -- which is always true of an image cloned
# onto a machine the builder never saw. --no-nvram because there are no EFI
# variables to write to inside a build VM.
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=CentroidX \
  --removable \
  --no-nvram \
  --recheck
update-grub
