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

**Reimaging is also a Debian major-version upgrade.** The deployed stations are
bookworm; this image is trixie. Everything that is not in a container moves with
it — kernel, glibc, mesa, weston — and the compositor and GPU stack the HMI
renders through are exactly the host-side parts. That is a bigger change than the
`.env` contract and deserves one station as a pilot before the fleet.

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
`RENDER_GID` lost its default too. A station without a `.env` refuses to start —
loudly, naming the variable — rather than run with a password anyone can read in
a public repo. On a station installed from here, first boot writes the file.

On an existing station, `.env.example` is not there to copy: it ships at
`/etc/centroid/env.example` on imaged machines and only in the repo otherwise.
Write the file directly, and fill in the values you are keeping:

```bash
cd /home/centroid
{ echo "NOVNC_STATION_NAME=$(hostname)"
  echo "DOCKER_UPDATE_CERT_CN=$(hostname)"
  echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)"
  echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)"
  echo "DB_PASSWORD=<the database password this station is ALREADY using>"
  echo "VNC_PASSWORD=<pick one>"
  echo "FLUTTER_KEYRING_PASSWORD=TODOSetThisStrongPassword"
  echo "DOCKER_UPDATE_BASIC_AUTH_USER=centroid"
  echo "DOCKER_UPDATE_BASIC_AUTH_PASS=<pick one>"
} > .env
chmod 600 .env && chown centroid:centroid .env
```

Two of those need care, and in opposite directions.

`DB_PASSWORD` must be the password the station is **already** using. timescaledb
only reads `POSTGRES_PASSWORD` when it initialises an empty data directory, so
setting a new one here does not change the database — it just stops the backend
and the HMI being able to reach it. Rotate deliberately:

```bash
docker compose exec timescaledb \
  psql -U centroid -d hmi -c "ALTER ROLE centroid PASSWORD 'new'"
```

`FLUTTER_KEYRING_PASSWORD` must be the **old literal**,
`TODOSetThisStrongPassword`, on any station that has already run. The HMI's
keyring file is encrypted with it; a fresh value orphans the stored database
config, the dbus login and every secure preference. Rotate it only together with
deleting `local-share/keyrings/flutter.keyring` and re-entering what was in it.

**Rotation is not optional, though.** All three literals are in this repo's git
history, which is public and permanent, so "keep using the old value" is a
migration step and not an end state — and the database it protects is published
on `5432:5432`, which ufw does not cover (see below). Plan the `ALTER ROLE` and
the keyring reset; this section only keeps a station running in the meantime.

## Keys and pins

`overlays/base/etc/apt/keyrings/docker.asc` is committed rather than downloaded,
so an upstream edit cannot change what a build installs. `make verify-keys`
checks it against the hash recorded in `scripts/apt-sources.sh`.

`wg-obfuscator` is not packaged anywhere, so the recipe fetches upstream's
statically linked release binary and pins it by sha256 the same way. The pinned
v1.6 is a step up from the `ab65bea` dev build found on the deployed station —
the nearest tagged release at or after it.

debos itself and shellcheck are pinned by image digest in the Makefile. The
recipes depend on newer debos fields (`parttype`, `partlabel`), so the version is
load-bearing.

Still unpinned, and worth knowing before claiming two builds of one commit are
identical: the suite is a moving target, Docker's archive is its `stable`
channel, there is no snapshot.debian.org date, and `image-info` carries a build
timestamp. "Every station is byte-identical" holds across stations flashed from
the same `out/` file, which is the property that matters for a fleet, but it is
narrower than reproducible builds.

## Remote access

WireGuard, not ZeroTier — the latter was dropped over its licence and an image
that reinstalled it would walk the fleet backwards. `wireguard` and
`wireguard-tools` come from Debian; `wg-obfuscator` is vendored as above.

Neither `wg-quick@wg0` nor `wg-obfuscator` is enabled in the image, because both
need a per-station config and an enabled unit without one is a failed unit on
every boot. Put the two files beside the payload on the USB and the installer
places them at 0600:

```
os/out/payload/wg0.conf              -> /etc/wireguard/wg0.conf
os/out/payload/wg-obfuscator.conf    -> /etc/wg-obfuscator.conf
```

First boot enables whichever it finds and says so on the console when there is no
`wg0.conf`, because that is a station with no remote access. A sample obfuscator
config is left at `/usr/share/doc/wg-obfuscator/wg-obfuscator.conf.example`.
