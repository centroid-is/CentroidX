# os/ — CentroidX station images

The Debian that runs under the containers, and the USB key that installs it.
Built with [debos](https://github.com/go-debos/debos).

Builds two artifacts:

| artifact | what it is |
|---|---|
| `out/centroidx-<sha>.img.gz` + `.bmap` | a fully configured Debian trixie station; flash onto an SSD |
| `out/usb-installer.img.gz` + `.bmap` | a USB key that boots, asks five questions, and writes that image onto the station's SSD |

Nothing is configured on the target machine. By the time a station boots, it is
already configured — which is why `ansible-playbook.yml` is gone.

## Build

```bash
make generated          # stage ../docker-compose.yml + the provenance stamp
make image              # the station image          (needs Linux + KVM)
make usb                # the installer USB          (needs Linux + KVM)
make qemu               # boot the USB against a blank 32G disk, end to end
make dry-run            # validate all three recipes (works on macOS)
```

```bash
make image GPU=amd      # AMD station instead of Intel
make preload            # bake the container images in, for an offline install
```

`docker-compose.yml` is baked in from one directory up, at whatever commit the
image is built from — there is no ref to pin and no copy to go stale, which is
why this lives in the CentroidX repo rather than beside it. `image-info` inside
the image records that commit, so a station in the field traces back to the app,
the Dockerfiles and the compose file together.

`make image`/`make usb` need `/dev/kvm`: debos cannot do `image-partition`
without a fakemachine (debos's own CI excludes the partitioning tests from its
`--disable-fakemachine` matrix). Build on Linux or in CI; `dry-run` and
`print-recipe` work anywhere Docker does.

Write the USB with `bmaptool copy --bmap out/usb-installer.img.bmap out/usb-installer.img.gz /dev/sdX`
— most of the image is holes, so that copies what is actually there rather than
8 GB of zeroes. Without bmaptool: `gunzip -c out/usb-installer.img.gz | sudo dd of=/dev/sdX bs=4M`.
If the SSD is reachable on the bench, skip the USB entirely:
`bmaptool copy --bmap out/*.img.bmap out/*.img.gz /dev/sdX`.

## Installing

Plug the key in, boot it. It lists the disks — never the USB it booted from —
and asks for five things:

| answer | used for |
|---|---|
| station name | browser tab, hostname, TLS cert CN |
| `centroid` password | the host login |
| `root` password | the host login |
| VNC password | the remote screen |
| database password | timescaledb |

Then it writes the image, drops the answers in `/etc/centroid/station.conf`, and
reboots. Put a `station.env` beside the Makefile before `make usb` to bake the
answers in and install without prompting.

### First boot

`centroidx-firstboot.service` runs once and resolves everything an image cannot
know in advance:

- **grows** the root filesystem onto the real disk (`growpart` + `resize2fs`)
- **regenerates** the SSH host keys and machine-id, so no two stations share an
  identity
- **computes** `RENDER_GID` and `DOCKER_GID` from this host's
  `/dev/dri/renderD128` and `/var/run/docker.sock`, and writes them to
  `/home/centroid/.env`
- applies the passwords, then deletes the host logins from `station.conf`
- loads any preloaded container images, then `docker compose up -d`

The GID step is the point of the whole exercise. `docker-compose.yml:128`
records that every station provisioned by hand had `RENDER_GID=992`, matched no
group, and rendered in software: 150% → 25% CPU when it was fixed. Nobody types
those numbers any more.

Re-run it with `rm /var/lib/centroid/firstboot-done && reboot`.

## Layout

```
rootfs.yaml        the station system  (replaces ansible-playbook.yml)
image.yaml         rootfs + GPT/ESP + grub  -> bootable .img
installer.yaml     the USB key
overlays/base/     config files, verbatim, as they land on disk
overlays/installer/ the installer unit and script
overlays/generated/ fetched at build time, never committed
scripts/           the chroot steps that are not just a file
../.env.example    the per-station variable contract, beside the compose file
```

## Things worth knowing

**Security updates were not installing.** The playbook's unattended-upgrades
pattern was `o=Debian,n=trixie,l=Debian-Security`. On trixie, `apt-cache policy`
reports the security archive as
`o=Debian,a=stable-security,n=trixie-security,l=Debian-Security` — so `n=trixie`
(which carries `l=Debian`) never matches it. Verified on a stock trixie,
2026-09-12. `overlays/base/etc/apt/apt.conf.d/50unattended-upgrades` uses the
pattern Debian's own default ships.

**Two deliberate changes from the playbook.** Automatic reboot is now off — an
HMI on a production line should not disappear at 04:00. And `docker-ce` is
deliberately excluded from unattended upgrades, because its postinst restarts
the daemon and bounces every container including the HMI; check for pending ones
with `apt list --upgradable | grep -E 'docker-ce|containerd'`.

**ufw does not protect the containers.** Docker publishes ports straight into
the nat/DOCKER chain, which ufw's INPUT rules never see. Every `ports:` entry in
the compose file is reachable regardless of what ufw says. Restricting those
needs DOCKER-USER rules; not done.

**The installer USB's root filesystem is read-write.** Yanking the key during an
install can corrupt it. Mounting it read-only needs tmpfs overlays for
`/var/log`, `/etc/machine-id` and friends — worth doing, not done yet.

**No rollback.** A bad image means reflashing. A/B root partitions would fix it;
deliberately out of scope.

**Existing stations need a `.env` now.** `docker-compose.yml` used to hardcode
`FooBarHelloWorld`, `TODOSetThisStrongPassword` and `centroid:foo`; those are now
`${DB_PASSWORD:?}`, `${FLUTTER_KEYRING_PASSWORD:?}` and `${VNC_PASSWORD:?}`, and
`RENDER_GID` lost its wrong default too. A station without a `.env` will refuse
to start — loudly, naming the variable — rather than run with a password that was
published in a public repo. On a station installed from here, first boot writes
the file. On an existing one:

```bash
cd /home/centroid
cp .env.example .env            # then fill it in, and note:
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" >> .env
echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)" >> .env
```

`DB_PASSWORD` is the one to be careful with: timescaledb only reads
`POSTGRES_PASSWORD` when initialising an empty data directory, so an existing
station keeps its old database password until you `ALTER ROLE`. Put the existing
value in `.env` unless you are rotating it.

## Keys

`overlays/base/etc/apt/keyrings/` holds the Docker and ZeroTier archive keys,
committed rather than downloaded so a build cannot be changed by an upstream
edit. `make verify-keys` checks them against the hashes recorded in
`scripts/apt-sources.sh`. Refresh by re-downloading and updating both.

ZeroTier is matched by `site=` in the unattended-upgrades config because their
`Release` templates the codename into Origin and Label (`Origin: trixie trixie`)
and its `n=trixie` collides with Debian's own main archive.

---

## Superseded: the manual ansible procedure

Kept verbatim for reference. `ansible-playbook.yml` is still in the repo as the
record of what deployed stations were built from; nothing builds with it now.

```bash
# on the local machine
scp ansible-playbook.yml centroid@10.11.11.191:~/

# on the remote machine
su -
apt install ansible --no-install-recommends
ansible-playbook -i localhost -e 'root_password=foo' -e 'centroid_password=bar' ansible-playbook.yml
# might need to run twice to complete, some codename error
```

That last comment is the whole argument for this repo's current shape: the
playbook ran on the target, over the plant uplink, against whatever apt offered
that morning — so it was sometimes wrong twice before it was right once. The
image is built once, in CI, and tested before any station sees it.
