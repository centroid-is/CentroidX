#!/bin/bash
# Writes the Docker archive source. Runs AFTER ca-certificates is installed:
# download.docker.com is https-only, and a debootstrapped rootfs has no CA
# bundle until something puts one there.
#
# debootstrap installs ca-certificates only when its OWN mirror is https -- a
# side effect, not a guarantee. With an http mirror (which is what Debian's own
# sources use, and what this image uses) a minbase chroot has no CA bundle at
# all, apt cannot verify download.docker.com, the index is skipped with a
# warning, and the build fails later with "Package 'docker-ce' has no
# installation candidate". Measured both ways on trixie/minbase:
#   mirror=http  -> ca-certificates ABSENT
#   mirror=https -> ca-certificates 20250419
#   usage: apt-sources-docker.sh <suite>
set -euo pipefail
suite="${1:?suite required}"

[ -s /etc/ssl/certs/ca-certificates.crt ] \
  || { echo "no CA bundle: install ca-certificates before adding an https source" >&2; exit 1; }

install -d -m 0755 /etc/apt/sources.list.d

# Key committed in overlays/base/etc/apt/keyrings/. Recorded sha256 (verified
# 2026-09-12, see `make verify-keys`):
#   docker.asc  1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${suite} stable
EOF

chmod 0644 /etc/apt/keyrings/docker.asc
