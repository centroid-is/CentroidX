#!/bin/bash
# Turns a plain Debian rootfs into a single-purpose installer: it boots, runs
# one script on tty1, and nothing else.
set -euo pipefail

echo "centroidx-installer" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcentroidx-installer\n' > /etc/hosts

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
