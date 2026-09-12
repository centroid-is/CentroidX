#!/bin/bash
# Last thing to run in the chroot. Everything that must differ between two
# machines built from the same image is removed here, so that forgetting to
# reset it later is impossible rather than merely unlikely.
set -euo pipefail

# openssh-server's postinst generated these during apt. Shipping them would let
# any station impersonate any other.
rm -f /etc/ssh/ssh_host_*

# An EMPTY (not absent) machine-id is the documented signal for systemd to
# generate one on next boot, and it is also what makes that boot a
# ConditionFirstBoot=yes boot.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

rm -f /etc/centroid/station.conf
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/debconf/*-old
rm -f /var/log/*.log /var/log/dpkg.log /var/log/alternatives.log
truncate -s0 /var/log/lastlog 2>/dev/null || true
