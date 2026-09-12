#!/bin/bash
# Writes the two third-party archive sources. A script rather than a file in the
# overlay because both lines name the suite, and the suite is a recipe variable.
#   usage: apt-sources.sh <suite>
set -euo pipefail
suite="${1:?suite required}"

install -d -m 0755 /etc/apt/sources.list.d

# Keys are committed in overlays/base/etc/apt/keyrings/ and land before this
# runs. Recorded sha256 (verified 2026-09-12, see `make verify-keys`):
#   docker.asc    1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
#   zerotier.asc  bc3e1dc91a891aab76d730c3683b3b93515fe52cda4f83980c8694fa782fba3c
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${suite} stable
EOF

cat > /etc/apt/sources.list.d/zerotier.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/zerotier.asc] https://download.zerotier.com/debian/${suite} ${suite} main
EOF

chmod 0644 /etc/apt/keyrings/docker.asc /etc/apt/keyrings/zerotier.asc
