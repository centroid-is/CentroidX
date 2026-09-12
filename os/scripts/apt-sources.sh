#!/bin/bash
# Writes the Debian security/updates suites and the Docker archive source. A script rather than a file in the
# overlay because both lines name the suite, and the suite is a recipe variable.
#   usage: apt-sources.sh <suite>
set -euo pipefail
suite="${1:?suite required}"

install -d -m 0755 /etc/apt/sources.list.d

# debos's debootstrap action writes exactly ONE line -- the base suite -- so a
# freshly bootstrapped rootfs has no security index at all. Without this the
# corrected unattended-upgrades pattern in overlays/base matches nothing, which
# is the very defect this repo set out to fix, and the image would be a
# regression against the hand-built stations (they do have a security line).
# Verified by debootstrapping trixie/minbase and reading sources.list.
#
# http, like Debian's own shipped debian.sources: apt's integrity comes from the
# signed Release file, so TLS buys nothing here and http removes any dependency
# on a CA bundle being present at the moment the first index is fetched.
cat > /etc/apt/sources.list.d/debian-security.list <<EOF
deb http://deb.debian.org/debian-security ${suite}-security main non-free-firmware
EOF

# Point releases and the tzdata/ca-certificates stream land here, not in the
# base suite. Debian ships this commented out of unattended-upgrades by default,
# so the index exists and nothing installs from it unattended unless asked.
cat > /etc/apt/sources.list.d/debian-updates.list <<EOF
deb http://deb.debian.org/debian ${suite}-updates main non-free-firmware
EOF

# Keys are committed in overlays/base/etc/apt/keyrings/ and land before this
# runs. Recorded sha256 (verified 2026-09-12, see `make verify-keys`):
#   docker.asc    1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${suite} stable
EOF

chmod 0644 /etc/apt/keyrings/docker.asc
