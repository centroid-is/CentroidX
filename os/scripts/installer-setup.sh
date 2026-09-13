#!/bin/bash
# Turns a plain Debian rootfs into a single-purpose installer: it boots, runs
# one script on tty1, and nothing else.
set -euo pipefail

echo "centroidx-installer" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcentroidx-installer\n' > /etc/hosts

# Networking, so the installer can say what address it is on. networkd is part
# of the systemd package and ships disabled on Debian; the .network file comes
# from overlays/installer.
#
# NOT systemd-resolved: it has been its own binary package since Debian 12, so
# `systemctl enable` on it would fail the build here, and nothing on the stick
# resolves a name -- the installer writes a disk and reports an address. Add
# the package first if that ever stops being true.
systemctl enable systemd-networkd.service
chmod 0644 /etc/systemd/network/10-dhcp.network

# ------------------------------------------------------- remote view (VNC)
# weston mirrors the panel onto a VNC output (see weston.ini and
# centroidx-gui-launch); these two make it reachable and authenticable.
#
# The credential unit is what makes VNC usable at all: weston's VNC backend
# authenticates through PAM as the user running weston, with no way to turn
# authentication off, and that user is the root this script locks below. Per
# boot it sets a code and mints the certificate websockify serves.
chmod 0755 /usr/local/bin/centroidx-gui-launch /usr/local/bin/centroidx-remote-access
chmod 0644 /etc/systemd/system/centroidx-remote-access.service            /etc/systemd/system/centroidx-novnc.service
systemctl enable centroidx-remote-access.service
systemctl enable centroidx-novnc.service

# noVNC's web root without its nodejs dependency. The Debian package Depends on
# nodejs for a launcher we do not use -- websockify serves these files and the
# browser runs them -- so ~60MB is avoided by taking the directory out of the
# .deb directly. Fails loudly: a stick whose browser view 404s is worse than a
# build that stopped.
tmp="$(mktemp -d)"
( cd "$tmp" && apt-get download novnc )
dpkg-deb -x "$tmp"/novnc_*.deb "$tmp/x"
cp -r "$tmp/x/usr/share/novnc" /usr/share/novnc
rm -rf "$tmp"
test -f /usr/share/novnc/vnc.html

# The graphical installer when there is an app to run, the text one otherwise.
# centroidx-installer.service is deliberately NOT enabled when the GUI is: it is
# reached through centroidx-gui.service's OnFailure, so a compositor that will
# not start falls back instead of both fighting for tty1.
# -f, not -x: the bundle reaches the image through a GitHub artifact, which does
# not carry the executable bit. Testing -x here is how the first build shipped a
# text-only installer while reporting success.
setup_bin=""
for b in /opt/centroidx-setup/flutter_elinux_wayland /opt/centroidx-setup/centroidx_setup; do
  [ -f "$b" ] && { setup_bin="$b"; break; }
done
if [ -n "$setup_bin" ]; then
  chmod 0755 "$setup_bin"
  echo "setup app present ($setup_bin): enabling the graphical installer"
  systemctl enable seatd.service
  systemctl enable centroidx-gui.service
  chmod 0644 /etc/systemd/system/centroidx-gui.service
  chmod 0755 /usr/local/bin/centroidx-setup
  [ -e /usr/local/bin/centroidx-keyboard ] && chmod 0755 /usr/local/bin/centroidx-keyboard
  # Its lib/ sits beside the binary; the launcher sets LD_LIBRARY_PATH to it.
  [ -d /opt/centroidx-setup/lib ] && chmod -R a+rX /opt/centroidx-setup
else
  echo "no setup app bundle: enabling the text installer on tty1"
  systemctl enable centroidx-installer.service
fi
# The Makefile touches a .keep in each staged directory so debos always has a
# non-empty overlay source, even on a local build with no CI artifacts. They
# have done their job by now and would otherwise ship in the image.
rm -f /opt/centroidx-setup/.keep /usr/local/bin/.keep /opt/centroidx/.keep

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
