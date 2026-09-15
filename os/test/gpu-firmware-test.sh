#!/bin/bash
# The GPU firmware guard, and the recipe lines it guards.
#
# Two halves. The guard (scripts/check-gpu-firmware.sh) only runs inside an
# image build, which pull requests do not do -- so the recipes are also read
# here, and a recipe that stops installing the firmware fails on the PR rather
# than on the first panel that boots it.
#
#   usage: os/test/gpu-firmware-test.sh      (or `make test` in os/)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
os="$here/.."
guard="$os/scripts/check-gpu-firmware.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
expect_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

run_guard() { local dir="$1"; shift; FIRMWARE_DIR="$dir" bash "$guard" "$@"; }

# --------------------------------------------------------------------- guard
echo "check-gpu-firmware.sh"
fw="$tmp/fw"
mkdir -p "$fw/i915" "$fw/amdgpu"
expect_false "intel: empty firmware dir fails"   run_guard "$fw" intel
echo guc > "$fw/i915/adlp_guc_70.bin"
expect_false "intel: GuC without DMC fails"      run_guard "$fw" intel
echo dmc > "$fw/i915/adlp_dmc.bin"
expect_true  "intel: GuC and DMC pass"           run_guard "$fw" intel
: > "$fw/i915/adlp_guc_70.bin"
expect_false "intel: an empty blob does not count" run_guard "$fw" intel
rm "$fw/i915/adlp_guc_70.bin"
echo guc > "$fw/i915/adlp_guc_70.bin.zst"
expect_true  "intel: a .zst blob counts"         run_guard "$fw" intel
expect_false "amd: empty amdgpu dir fails"       run_guard "$fw" amd
expect_false "intel amd: one missing fails both" run_guard "$fw" intel amd
echo blob > "$fw/amdgpu/navi10_sos.bin"
expect_true  "amd: populated amdgpu dir passes"  run_guard "$fw" amd
expect_true  "intel amd: both present pass"      run_guard "$fw" intel amd
expect_false "no gpu argument is an error"       run_guard "$fw"
expect_false "an unknown gpu is an error"        run_guard "$fw" nvidia

# ------------------------------------------------------------------- recipes
# The lines of rootfs.yaml inside one gpu's template branch. index() rather than
# a regex: braces are literal in some awks and quantifiers in others.
gpu_branch() {
  # The $gpu below is the template's text, not a shell variable.
  # shellcheck disable=SC2016
  awk -v gpu="$1" '
    index($0, "{{ if eq $gpu ") == 1 || index($0, "{{ else if eq $gpu ") == 1 {
      inside = index($0, "\"" gpu "\"") > 0; next
    }
    index($0, "{{ end }}") == 1 { inside = 0; next }
    inside
  ' "$os/rootfs.yaml"
}
has_pkg()    { grep -qE "^[[:space:]]*- $1[[:space:]]*$"; }
branch_has() { gpu_branch "$1" | has_pkg "$2"; }
recipe_has() { has_pkg "$2" < "$os/$1"; }

echo "rootfs.yaml"
expect_true  "intel branch installs firmware-intel-graphics"  branch_has intel firmware-intel-graphics
expect_true  "amd branch installs firmware-amd-graphics"      branch_has amd   firmware-amd-graphics
expect_false "intel branch does not install the amd firmware" branch_has intel firmware-amd-graphics
# shellcheck disable=SC2016
expect_true  "runs the guard for the image's gpu" \
  grep -qF 'script: scripts/check-gpu-firmware.sh {{ $gpu }}' "$os/rootfs.yaml"

echo "installer.yaml"
expect_true "installs firmware-intel-graphics" recipe_has installer.yaml firmware-intel-graphics
expect_true "installs firmware-amd-graphics"   recipe_has installer.yaml firmware-amd-graphics
expect_true "runs the guard for both gpus" \
  grep -qF 'script: scripts/check-gpu-firmware.sh intel amd' "$os/installer.yaml"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
