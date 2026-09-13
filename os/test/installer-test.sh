#!/bin/bash
# Exercises the parts of centroidx-install that can run without a disk: the
# station.env parser, the validators, the seed-file rules, and the files the
# installer leaves on the target. Runs on any bash -- CI's validate job, a Mac,
# Git Bash on Windows. `wg` is optional: the WireGuard cases are skipped when it
# is missing, and say so.
#
#   usage: os/test/installer-test.sh      (or `make test` in os/)
#
# The variables assigned below are read by the sourced installer's functions,
# which shellcheck cannot see through the `.` -- hence SC2034 off for the file.
# shellcheck disable=SC2034
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
installer="$here/../overlays/installer/usr/local/bin/centroidx-install"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# `source` hands the caller's positional parameters to the script, and the
# script parses them as its own options.
set --
# SC1091 is "not specified as input"; SC1090 is "can't follow non-constant
# source" and is what you get instead once SC1091 is silenced, because the
# path is a variable. Both are the same fact: shellcheck is not reading the
# installer. That is also why SC2034 is off for the file.
# shellcheck disable=SC1090,SC1091
. "$installer"
PAYLOAD="$tmp/payload"
RUNTIME_DIR="$tmp/run"
mkdir -p "$PAYLOAD"

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
skipt(){ skip=$((skip + 1)); printf '  skip  %s\n' "$1"; }
expect_true()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_false() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
expect_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ------------------------------------------------------------------- read_kv
echo "read_kv"
kv="$tmp/kv"
# The $ in has$dollar is test data: read_kv must not expand it.
# shellcheck disable=SC2016
printf 'A=b c\nB=has$dollar\nKEY=abc==\nEMPTY=\n# C=comment\nD=first=second\n' > "$kv"
expect_eq "keeps a space"               "$(read_kv "$kv" A)"     'b c'
# shellcheck disable=SC2016
expect_eq "keeps a dollar literally"    "$(read_kv "$kv" B)"     'has$dollar'
expect_eq "keeps base64 padding"        "$(read_kv "$kv" KEY)"   'abc=='
expect_eq "empty value is empty"        "$(read_kv "$kv" EMPTY)" ''
expect_eq "absent key is empty"         "$(read_kv "$kv" NOPE)"  ''
expect_eq "commented key is not a key"  "$(read_kv "$kv" C)"     ''
expect_eq "splits on the first = only"  "$(read_kv "$kv" D)"     'first=second'
expect_eq "missing file is empty"       "$(read_kv "$tmp/none" A)" ''
expect_true "missing file is not an error" read_kv "$tmp/none" A

# ------------------------------------------------------------ station name
echo "valid_station_name"
for n in line1 a st-01 UPPER99; do expect_true "accepts $n" valid_station_name "$n"; done
for n in -bad bad- 'has space' 'has#hash' a.b '' 'under_score'; do
  expect_false "rejects '$n'" valid_station_name "$n"
done
expect_false "rejects 64 characters" valid_station_name "$(printf 'a%.0s' $(seq 64))"
expect_true  "accepts 63 characters" valid_station_name "$(printf 'a%.0s' $(seq 63))"

# --------------------------------------------------------------- passwords
# The rule is a deny list, and the deny list is short on purpose: it is the set
# of characters that turn a quoting slip at one of the four layers these values
# pass through into executed code or a truncated value. Everything else
# printable is allowed, because refusing a character an operator wants costs
# them a password and buys nothing. os/app/lib/answers.dart must agree
# character for character.
echo "password_ok"
for p in 'Plain12345' 'a-pass:with@odd%chars' 'dots.and_unders~/+' \
         'hash#pass1' '#leading12' 'trailing1#' 'bang!pass1' 'comma,pass' \
         'equals=pass' 'question?p1' 'star*pass12' 'caret^pass1' \
         'brack[et]s1' 'brace{s}pass'; do
  expect_true "accepts '$p'" password_ok "$p"
done
# '#' in particular: it was refused by the allow list this replaced, for no
# reason that survives inspection. compose's dotenv only opens a comment on
# ' #', and a space is refused below.
# The $ in has$dollar is test data, like the one in the read_kv block above.
# shellcheck disable=SC2016
for p in 'has space1' "$(printf 'tab\tstop1')" 'has$dollar' 'back`tick' \
         "quote'pass" 'double"quo' 'back\slash' 'semi;colon' 'amper&sand' \
         'pipe|char1' 'gt>pass123' 'lt<pass123' 'paren(then)' '' \
         "$(printf 'newline\npass')" 'þorlákur12'; do
  expect_false "rejects '$p'" password_ok "$p"
done

# ---------------------------------------------------------- keyboard layout
echo "valid_keyboard_layout"
for l in is en pl; do expect_true "accepts $l" valid_keyboard_layout "$l"; done
for l in de IS '' 'is ' us; do expect_false "rejects '$l'" valid_keyboard_layout "$l"; done

# ----------------------------------------------------------- root_partition
# This is the one that got away. The installer resolved the target's root
# partition from `lsblk -pno NAME,PARTLABEL`, whose NAME column carries the
# tree-drawing glyphs when --list is not given -- so it mounted "└─/dev/sda2",
# which is not a device, and the install failed on a real panel AFTER the image
# had been written. Nothing in CI installs onto a disk, so the table is fed in
# as recorded text instead; that is the whole reason the awk is its own
# function.
echo "root_partition"
expect_eq "picks the labelled partition out of a --list table" \
  "$(printf '/dev/sda\n/dev/sda1 esp\n/dev/sda2 root\n' | root_partition)" \
  '/dev/sda2'
expect_eq "strips the tree glyphs a table without --list carries" \
  "$(printf '/dev/sda\n├─/dev/sda1 esp\n└─/dev/sda2 root\n' | root_partition)" \
  '/dev/sda2'
expect_eq "is not fooled by partition order" \
  "$(printf '/dev/nvme0n1\n├─/dev/nvme0n1p1 root\n└─/dev/nvme0n1p2 esp\n' | root_partition)" \
  '/dev/nvme0n1p1'
expect_eq "empty when nothing is labelled root" \
  "$(printf '/dev/sda\n└─/dev/sda1 esp\n' | root_partition)" ''
expect_eq "empty when the disk has no partitions at all" \
  "$(printf '/dev/sda\n' | root_partition)" ''

# ---------------------------------------------------------------- seed file
# questions() in seed mode dies on a bad file. Run it in a subshell so the
# exit does not take the test with it, and echo the answers it settled on.
echo "seed file"
seed_result() {   # seed_result FILE -> "rc|KEYBOARD_DEFAULT|UNATTENDED" ; stderr in $tmp/err
  local out rc
  out="$(SEED="$1"; questions 2>"$tmp/err" >/dev/null && printf '%s|%s' "$KEYBOARD_DEFAULT" "$UNATTENDED")"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}
base='STATION_NAME=line1
CENTROID_PASSWORD=aaaaaaaa
ROOT_PASSWORD=bbbbbbbb
VNC_PASSWORD=cccccccc
DB_PASSWORD=dddddddd'
printf '%s\n' "$base" > "$tmp/s1"
expect_eq "complete seed is accepted, keyboard defaults to is" "$(seed_result "$tmp/s1")" '0|is|1'

printf '%s\nKEYBOARD_DEFAULT=pl\n' "$base" > "$tmp/s2"
expect_eq "KEYBOARD_DEFAULT is carried" "$(seed_result "$tmp/s2")" '0|pl|1'

printf '%s\nKEYBOARD_DEFAULT=de\n' "$base" > "$tmp/s3"
expect_eq "unknown layout is refused" "$(seed_result "$tmp/s3" | cut -d'|' -f1)" '1'
expect_true "and named" grep -q KEYBOARD_DEFAULT "$tmp/err"

printf '%s\n' "$base" | grep -v DB_PASSWORD > "$tmp/s4"
expect_eq "missing password is refused" "$(seed_result "$tmp/s4" | cut -d'|' -f1)" '1'
expect_true "and named" grep -q 'missing: DB_PASSWORD' "$tmp/err"

printf '%s\n' "$base" | sed 's/^VNC_PASSWORD=.*/VNC_PASSWORD=has space1/' > "$tmp/s5"
expect_eq "password outside the charset is refused" "$(seed_result "$tmp/s5" | cut -d'|' -f1)" '1'

printf '%s\n' "$base" | sed 's/^STATION_NAME=.*/STATION_NAME=bad name/' > "$tmp/s6"
expect_eq "station name that is not a DNS label is refused" "$(seed_result "$tmp/s6" | cut -d'|' -f1)" '1'

printf '%s\nVPN_ENDPOINT=vpn.example.is:13255\n' "$base" > "$tmp/s7"
expect_eq "half a VPN block is refused" "$(seed_result "$tmp/s7" | cut -d'|' -f1)" '1'
expect_true "and the missing keys are named" grep -q 'VPN_SERVER_PUBKEY VPN_ADDRESS VPN_ALLOWED_IPS' "$tmp/err"

vpn='VPN_ENDPOINT=vpn.example.is:13255
VPN_SERVER_PUBKEY=serverpubkey=
VPN_ADDRESS=192.0.2.42/24
VPN_ALLOWED_IPS=192.0.2.0/24'
printf '%s\n%s\n' "$base" "$vpn" > "$tmp/s8"
expect_eq "a full VPN block without an obfuscation key is accepted" "$(seed_result "$tmp/s8" | cut -d'|' -f1)" '0'
printf '%s\n%s\nVPN_OBFUSCATOR_KEY=obf\n' "$base" "$vpn" > "$tmp/s9"
expect_eq "a full VPN block with one is accepted" "$(seed_result "$tmp/s9" | cut -d'|' -f1)" '0'

# --------------------------------------------------------- target config
# The files the installer leaves on the target, written into a directory
# instead of a mounted disk.
echo "write_target_config"
STATION_NAME=line1 ROOT_PASSWORD=bbbbbbbb CENTROID_PASSWORD=aaaaaaaa
VNC_PASSWORD=cccccccc DB_PASSWORD=dddddddd KEYBOARD_DEFAULT=pl
VPN_ENDPOINT='' VPN_OBFUSCATOR_KEY='' VPN_SERVER_PUBKEY='' VPN_ADDRESS='' VPN_ALLOWED_IPS=''
root="$tmp/root1"; mkdir -p "$root/etc"; printf '127.0.0.1\tlocalhost\n' > "$root/etc/hosts"
out="$(write_target_config "$root" 2>&1)"
conf="$root/etc/centroid/station.conf"
expect_true "station.conf written" test -f "$conf"
for k in STATION_NAME=line1 ROOT_PASSWORD=bbbbbbbb CENTROID_PASSWORD=aaaaaaaa VNC_PASSWORD=cccccccc DB_PASSWORD=dddddddd KEYBOARD_DEFAULT=pl; do
  expect_true "station.conf has $k" grep -qx "$k" "$conf"
done
expect_eq "every station.conf value is read back by read_kv" "$(read_kv "$conf" KEYBOARD_DEFAULT)" pl
if [ "$(uname -s)" = Linux ]; then
  expect_eq "station.conf is 0600" "$(stat -c %a "$conf")" 600
else
  skipt "station.conf mode (not Linux)"
fi
expect_eq "hostname" "$(cat "$root/etc/hostname")" line1
expect_true "hosts alias appended" grep -q "$(printf '^127.0.1.1\tline1$')" "$root/etc/hosts"
expect_true "localhost line kept" grep -q '^127.0.0.1' "$root/etc/hosts"

# The image now ships its own 127.0.1.1 placeholder (rootfs-setup.sh), so this
# has to replace rather than append: two entries for one address resolve in
# file order, i.e. to the placeholder, and the station would answer to the
# wrong name for the rest of its life.
rootp="$tmp/root1b"; mkdir -p "$rootp/etc"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcentroidx-unconfigured\n' > "$rootp/etc/hosts"
write_target_config "$rootp" >/dev/null 2>&1
expect_eq "exactly one 127.0.1.1 line" \
  "$(grep -c '^127\.0\.1\.1' "$rootp/etc/hosts")" 1
expect_true "and it is the station" \
  grep -q "$(printf '^127.0.1.1\tline1$')" "$rootp/etc/hosts"
expect_false "the placeholder is gone" \
  grep -q 'centroidx-unconfigured' "$rootp/etc/hosts"
expect_false "no wg0.conf without a VPN" test -e "$root/etc/wireguard/wg0.conf"
expect_true "says the station has no remote access" grep -q 'no VPN configured' <<<"$out"

if command -v wg >/dev/null 2>&1; then
  VPN_ENDPOINT=vpn.example.is:13255 VPN_OBFUSCATOR_KEY=obf VPN_SERVER_PUBKEY='serverpubkey='
  VPN_ADDRESS=192.0.2.42/24 VPN_ALLOWED_IPS=192.0.2.0/24
  root="$tmp/root2"; mkdir -p "$root/etc"; : > "$root/etc/hosts"
  out="$(write_target_config "$root" 2>&1)"
  wg0="$root/etc/wireguard/wg0.conf"
  expect_true  "wg0.conf written" test -f "$wg0"
  expect_true  "AllowedIPs is the answer, no fallback" grep -qx 'AllowedIPs = 192.0.2.0/24' "$wg0"
  expect_true  "Address is the answer" grep -qx 'Address = 192.0.2.42/24' "$wg0"
  expect_true  "endpoint goes through the obfuscator" grep -qx "Endpoint = 127.0.0.1:$OBF_PORT" "$wg0"
  expect_true  "obfuscator config written" grep -qx 'key = obf' "$root/etc/wg-obfuscator.conf"
  # Without this line the obfuscator defaults to AUTO, which on the client side
  # sends no masking at all -- the DPI evasion that is its only purpose is off.
  expect_true  "obfuscator masks its traffic" grep -qx 'masking = STUN' "$root/etc/wg-obfuscator.conf"
  expect_true  "public key left for the app" test -s "$RUNTIME_DIR/wg-pubkey"
  expect_eq    "and matches the private key" "$(sed -n 's/^PrivateKey = //p' "$wg0" | wg pubkey)" "$(cat "$RUNTIME_DIR/wg-pubkey")"
  expect_false "does not claim there is no remote access" grep -q 'no VPN configured' <<<"$out"
  if [ "$(uname -s)" = Linux ]; then
    expect_eq "wg0.conf is 0600" "$(stat -c %a "$wg0")" 600
  fi

  VPN_OBFUSCATOR_KEY=''
  root="$tmp/root3"; mkdir -p "$root/etc"; : > "$root/etc/hosts"
  write_target_config "$root" >/dev/null 2>&1
  expect_true  "without an obfuscation key the endpoint is direct" grep -qx 'Endpoint = vpn.example.is:13255' "$root/etc/wireguard/wg0.conf"
  expect_false "and no obfuscator config is written" test -e "$root/etc/wg-obfuscator.conf"
else
  skipt "WireGuard config generation (wg not installed)"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
