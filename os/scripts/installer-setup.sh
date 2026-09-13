#!/bin/bash
# Turns a plain Debian rootfs into a single-purpose installer: it boots, runs
# one script on tty1, and nothing else.
set -euo pipefail

echo "centroidx-installer" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcentroidx-installer\n' > /etc/hosts

systemctl enable centroidx-installer.service
# getty would otherwise race the installer for tty1 and eat its prompts.
systemctl mask getty@tty1.service
# Nothing to log into; the installer is the only interface.
passwd -l root

chmod 0755 /usr/local/bin/centroidx-install /usr/local/bin/centroidx-install-failsafe
chmod 0644 /etc/systemd/system/centroidx-installer.service

# A blank machine-id would make the USB itself claim a fresh identity each boot,
# which is fine and actually preferable for a stick used on many machines.
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
