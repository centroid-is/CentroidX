#!/bin/bash
# Runs in the target chroot, after apt. This is the part of the old ansible
# playbook that is not just "drop a file in place" -- users, modes, unit enables.
# Everything that WAS just a file now lives in overlays/base/ instead.
set -euo pipefail

log() { printf '== %s\n' "$*"; }

# ------------------------------------------------------------------- locale/time
log "locale and timezone"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/Atlantic/Reykjavik /etc/localtime
echo "Atlantic/Reykjavik" > /etc/timezone
# The playbook waited in a retry loop for NTP to sync before it could apt-install
# anything. Nothing is installed at run time any more, so the loop is gone --
# timesyncd just corrects the clock whenever the station comes up.
systemctl enable systemd-timesyncd.service

# ------------------------------------------------------------------------ users
log "centroid user"
getent group docker >/dev/null || groupadd --system docker
# Password is deliberately left locked: centroidx-firstboot sets it from the
# answers the installer collected. A golden image must not ship a known login.
id -u centroid >/dev/null 2>&1 || useradd \
  --create-home --shell /usr/bin/fish --uid 1000 \
  --comment "CentroidX operator" centroid
usermod -aG sudo,docker,video,render,input,dialout centroid
passwd -l centroid
passwd -l root

# overlays/generated dropped docker-compose.yml into /home/centroid before the
# user existed, so it is root-owned. compose reads it as centroid.
chown -R centroid:centroid /home/centroid

# git cannot carry these, and sudo refuses to read a sudoers file that is group-
# or world-writable.
chmod 0440 /etc/sudoers.d/centroid
chown root:root /etc/sudoers.d/centroid
chmod 0644 /etc/polkit-1/rules.d/50-networkmanager.rules \
           /etc/polkit-1/rules.d/51-reboot-shutdown.rules
chmod 0755 /usr/local/bin/centroidx-firstboot

# --------------------------------------------------------------------- services
log "units"
systemctl enable NetworkManager.service
systemctl enable docker.service containerd.service
systemctl enable ssh.service
systemctl enable zerotier-one.service
systemctl enable centroidx-firstboot.service
systemctl enable unattended-upgrades.service
# ifupdown would otherwise race NetworkManager for the interface. The playbook
# disabled this too, after wiping /etc/network/interfaces (see overlays/base).
systemctl disable networking.service || true

# ------------------------------------------------------------------------- ufw
log "firewall"
# NOTE: ufw governs traffic to HOST services only. Docker inserts its published
# ports straight into the nat/DOCKER chain, which ufw's INPUT rules never see --
# so every `ports:` entry in docker-compose.yml is reachable whether or not it is
# listed here. Restricting those needs rules in the DOCKER-USER chain instead.
# Deliberately not done yet; the stations sit on a ZeroTier/plant network.
ufw --force reset >/dev/null 2>&1 || true
ufw allow 22/tcp    comment 'ssh'
ufw allow 5900/tcp  comment 'weston VNC (container; see note above)'
ufw default deny incoming
ufw default allow outgoing
# `ufw enable` wants to talk to netfilter, which does not exist in a build
# chroot. Flip the flag and let the unit apply the rules at boot.
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service

# -------------------------------------------------------------------- plymouth
log "boot splash"
# bgrt reuses the logo the UEFI firmware already put on screen, so the panel
# never flashes a Debian swirl at an operator.
plymouth-set-default-theme -R bgrt

log "grub config"
# /etc/default/grub came from the overlay; grub-install happens after
# filesystem-deploy, once there is a real ESP to install into.
update-grub || true

log "rootfs-setup done"
