#!/bin/bash
# Runs in the target chroot, after apt: fails the build when the GPU firmware the
# image is meant to carry is not on disk.
#
#   usage: check-gpu-firmware.sh <gpu>...      gpu: intel | amd
#
# Why a build step and not a boot check: a station without its GPU firmware does
# not fail. The display still comes up (KMS works without it), Mesa quietly falls
# back to llvmpipe, and weston plus the HMI render on the CPU -- measured at a
# load of 6 on a 12-core panel, against ~23% on the same hardware with the
# firmware. Nothing on screen says so. The first trixie image shipped that way:
# Debian moved the i915 blobs out of firmware-misc-nonfree into
# firmware-intel-graphics, and the recipe still named only the former.
#
# FIRMWARE_DIR exists for test/gpu-firmware-test.sh.
set -euo pipefail

FIRMWARE_DIR="${FIRMWARE_DIR:-/lib/firmware}"

# The kernel loads a blob uncompressed or as .zst/.xz, whichever the package
# shipped, so any of the three counts.
have_blob() {
  local f="$FIRMWARE_DIR/$1"
  [ -s "$f" ] || [ -s "$f.zst" ] || [ -s "$f.xz" ]
}

missing=0
need() {
  if have_blob "$1"; then
    printf '  ok       %s\n' "$1"
  else
    printf '  MISSING  %s (%s)\n' "$1" "$2" >&2
    missing=1
  fi
}

need_dir() {
  if [ -n "$(ls -A "$FIRMWARE_DIR/$1" 2>/dev/null)" ]; then
    printf '  ok       %s/\n' "$1"
  else
    printf '  MISSING  %s/ is empty or absent (%s)\n' "$1" "$2" >&2
    missing=1
  fi
}

[ "$#" -gt 0 ] || { echo "usage: $0 <intel|amd>..." >&2; exit 2; }

for gpu in "$@"; do
  printf '== %s GPU firmware in %s\n' "$gpu" "$FIRMWARE_DIR"
  case "$gpu" in
    intel)
      # Alder Lake-P, the panel the Intel image is built for. Without the GuC
      # the i915 driver cannot hand Mesa a working render context; without the
      # DMC the display's power states are gone too.
      need i915/adlp_guc_70.bin firmware-intel-graphics
      need i915/adlp_dmc.bin    firmware-intel-graphics
      ;;
    amd)
      need_dir amdgpu firmware-amd-graphics
      ;;
    *)
      echo "unknown gpu '$gpu' (want intel or amd)" >&2
      exit 2
      ;;
  esac
done

if [ "$missing" -ne 0 ]; then
  echo "GPU firmware missing: this image would render on the CPU. See the package named above." >&2
  exit 1
fi
