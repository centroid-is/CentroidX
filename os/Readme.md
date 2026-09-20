# os/ — CentroidX station images

The Debian that runs under the containers, and the USB key that installs it.
Built with [debos](https://github.com/go-debos/debos).

Builds two artifacts:

| artifact | what it is |
|---|---|
| `out/centroidx-<sha>.img.gz` + `.bmap` | a fully configured Debian trixie station; flash onto an SSD |
| `out/usb-installer.img.gz` + `.bmap` | a USB key that boots, asks the per-station questions on the panel, and writes that image onto the station's SSD |

Nothing is configured on the target machine. By the time a station boots, it is
already configured — which is why nothing here runs ansible.

`os/ansible-playbook.yml` is kept only as the record of how the
already-deployed stations were built, so a field machine can be compared
against it. Nothing runs it, and nothing should: it carries the
unattended-upgrades pattern that never matched (below) and a `curl | bash`
ZeroTier install.

## Get the USB

The same key installs any station, so there is nothing customer-specific to
build — it asks at install time. Published on every release, and rebuilt from
the tip of `main` on every merge:

```bash
# the current release
gh release download --repo centroid-is/CentroidX --pattern 'usb-installer.img.*'
# or the tip of main
gh release download main-latest --repo centroid-is/CentroidX --pattern 'usb-installer.img.*'

# A preloaded installer arrives in parts -- see below -- and has to be joined.
# Guarded, not run unconditionally: the redirect truncates its target BEFORE
# cat runs, so an unguarded join empties a whole-file installer when there are
# no parts beside it.
[ -e usb-installer.img.gz.part00 ] && cat usb-installer.img.gz.part* > usb-installer.img.gz

sudo bmaptool copy --bmap usb-installer.img.bmap usb-installer.img.gz /dev/sdX
```

Both are also on the releases page for anyone without `gh`. Checksums are in
that release's `SHA256SUMS.txt`, and they are of the files as published — so
verify the parts, then join them.

**Why the parts.** `PRELOAD=true`, which every release build uses, bakes the
~1.9GB of container images into the key so a station commissions with no
uplink. That puts the compressed installer at ~2.7GB, and GitHub refuses any
single release asset of 2 GiB or more. So the publish step splits anything over
that limit into `usb-installer.img.gz.part00`, `.part01`, ... and `cat` in glob
order puts it back byte-for-byte. An installer under the limit — a
non-preloaded one is ~1.0GB — is published whole and there is nothing to join.

Only the installer is published, not the station image inside it — the key
already carries it. For flashing an SSD directly, build below or take one from a
`station-v*` release.

## Build

Only needed to change the image itself; installing a station needs nothing from
this section.

```bash
make generated          # stage ../docker-compose.yml + the provenance stamp
make image              # the station image          (needs Linux + KVM)
make usb                # the installer USB          (needs Linux + KVM)
make qemu               # boot the USB against a blank 32G disk, end to end
make dry-run            # validate all three recipes (works on macOS)
```

```bash
make image GPU=amd      # AMD station instead of Intel
make image PRELOAD=true # bake the container images in, for an offline install
```

### Which images a station runs

The compose file at the repo root names `:latest` for every CentroidX image,
which is right for a developer running the stack on a laptop and wrong for a
station: **`centroid-hmi:latest` is a debug Flutter build.**
`.github/workflows/centroid-hmi.yml` says so directly — `latest` is built
`--debug`, and `latest-release` exists precisely because "`latest-release` is
what stations pull". Every station installed before this change ran a debug
engine.

`make generated` therefore retags the copy it bakes, driven by `CHANNEL`:

| `CHANNEL` | centroid-hmi | centroid-backend | hmi-profiler | who passes it |
|---|---|---|---|---|
| `prerelease` (default) | `latest-release` | `latest` | `latest` | main-prerelease.yml |
| `stable` | `stable` | `stable` | `stable` | tag.yml |

`weston`, `novnc` and `docker-update` are built in other repos and publish only
`:latest`, so they are deliberately left alone — a blanket
`s/:latest/:stable/` would bake a reference to a tag that does not exist, and
the station would fail to pull on a first boot that may have no network. The
retag is per image for that reason, and CI asserts both the rewrite and the
absence of `centroid-hmi:latest` in the baked file.

The embedder extracted from `centroid-hmi:latest` for the *setup app* (the
`build` job) is a separate artifact for a separate binary and is intentionally
unchanged.

### Offline installs

Every **released** stick is built with `PRELOAD=true` (it is the `workflow_call`
default in `station-image.yml`, which is what `main-prerelease.yml` and
`tag.yml` take). The ~1.9GB of container images the compose file names are
pulled in CI, saved as zstd tarballs inside the station image, and loaded by
`centroidx-firstboot` on first boot, which then deletes them. A plant with no
uplink can be commissioned; nothing is downloaded at install time.

The cost is on the stick. `USBSIZE` is derived from `PRELOAD` in the Makefile —
4GB without, 8GB with — and an 8GB image does **not** fit a nominal 8GB USB
key, so **a preloaded installer is a 16GB-stick product**. Both images are
sparse and written with `bmaptool`, so the declared size costs nothing: only
the ~4.3GB actually present is copied.

PR builds stay `PRELOAD=false`. They are checking the recipe, not shipping a
stick, and the pull would double the job. `make preload` also drops each image
from the local daemon once it has been saved, because holding it twice does not
fit beside debos's scratch on a runner; pass `PRELOAD_KEEP=true` when iterating
locally to avoid re-pulling.

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

Plug the key in, boot it. A touch UI comes up on the panel — with an on-screen
keyboard, because a station has no keyboard attached — and walks through four
screens: the disk, the station settings, remote access, and a confirmation.
Disks never include the USB it booted from.

| answer | used for |
|---|---|
| station name | browser tab, hostname, TLS cert CN |
| `centroid` password | the host login |
| `root` password | the host login |
| VNC password | the remote screen |
| database password | timescaledb |
| keyboard layout | which of Icelandic, English and Polish the panel, VNC and the on-screen keyboard start in (`KEYBOARD_DEFAULT`); the other two stay one Alt+Shift or globe key away |
| VPN endpoint, keys, addresses | WireGuard over wg-obfuscator; skippable. The endpoint is prefilled with `wireguard-obf.centroid.is:13256` — the *obfuscator's* address, which is the only one that leaves the station: `wg0.conf`'s Endpoint is always `127.0.0.1`, and the WireGuard server itself (`wireguard-1.centroid.is`) is reached from the far side of the obfuscator |

Then it writes the image, drops the answers in `/etc/centroid/station.conf`, and
reboots.

Every screen shows the addresses the installer currently holds, in the header
band beside the wordmark. The USB takes a DHCP lease on any wired interface
(`systemd-networkd`, `overlays/installer/etc/systemd/network/10-dhcp.network`)
and does nothing else with it — the station's own image runs NetworkManager and
has a settings page. It is there because a panel on DHCP is otherwise a machine
whose address only the plant's router knows.

If the install fails after the image has been written, the target is wiped on
the way out. A disk carrying the image but no `station.conf` is the worst
outcome available: it boots, `centroidx-firstboot` finds no answers, mints
secrets nobody knows, and starts pulling containers — a station that looks
installed and is not. Better to stop at the firmware and run the installer
again.

The WireGuard keypair is generated **on the station being installed**, so no
private key ever travels on a USB stick; the public half is shown at the end to
register on the server. Dropping a ready-made `wg0.conf` and
`wg-obfuscator.conf` next to the payload still works, for a station whose key
already exists — but answers win: they are written after the payload copy, so
filling in the VPN screen overwrites a file placed that way.

To install without touching the screen, put a `station.env` on the USB's FAT
partition at `centroidx/station.env` — the same `KEY=value` file the UI writes.
Every value is validated the same way either way: the station name must be a
DNS label, the VPN block is all-or-nothing, and `KEYBOARD_DEFAULT` is optional
and one of `is`, `en`, `pl` (default `is`).

Passwords are restricted by a deny list rather than an allow list: printable
ASCII, no spaces, and none of ``" ' ` $ \ ; & | < > ( )``. Those are the
characters that turn a quoting slip into executed code or a truncated value
somewhere on the path from `station.conf` through `.env` and compose
interpolation to a shell inside a container. Everything else — `#` included,
which the original allow list refused for no reason that survived inspection —
is allowed. `password_ok` in `centroidx-install` and `validatePassword` in
`os/app/lib/answers.dart` implement the same rule and are tested against the
same cases.

If the graphical installer cannot start — no GPU, a compositor that will not
take the DRM device — the unit hands over to a text installer on tty1 that asks
the same questions.

### Watching an install from somewhere else

The installer mirrors the panel over VNC, so a support engineer can see and
drive the same screen the operator is looking at. The header band shows what to
connect to and the credential for it:

```
https://<address>   <user> / <password>
```

- **Browser**: `https://<address>/vnc.html`. https is not cosmetic — noVNC's
  RA2ne handshake needs `window.crypto.subtle`, which browsers withhold on an
  insecure origin, so http loads a page that then cannot authenticate. The
  certificate is self-signed and minted per boot; the browser warns once.
- **Native client**: port 5900, TigerVNC ≥ 1.12 or anything else that speaks
  RSA-AES.
- **One viewer at a time.** `weston-vnc(7)`: "The VNC backend is not multi-seat
  aware, so if a second client connects to the backend, the first client will be
  disconnected." The person at the panel is unaffected; a second remote is not.

How it works, and why not the obvious way:

- `--backend=drm,vnc` with `[output] mirror-of=<connector>`. weston 14 takes a
  comma-separated backend list where the first is primary and provides the
  renderer, and `mirror-of` makes the remote output overlap the native one.
  Debian does **not** build `screen-share.so` (verified with `dpkg -L`);
  `mirror-of` is its upstream replacement and is what the station's weston 16
  already uses.
- `mirror-of` needs the literal DRM connector name, which differs per panel, so
  `centroidx-gui-launch` reads the first `connected` entry under
  `/sys/class/drm` and templates the real `weston.ini` into `/run`.
- **One compositor, one setup app.** A second weston running a second copy of
  the app was rejected outright: two instances means two processes each entitled
  to wipe a disk, from two divergent sets of answers.
- **The credential.** weston's VNC backend authenticates through PAM as the user
  running weston — root here — with no way to turn authentication off, and
  `installer-setup.sh` locks root. So `centroidx-remote-access` sets a code for
  exactly one boot, seeded from `REMOTE_PASSWORD` in the ESP's `station.env`
  when nobody is at the panel to read one. There is no sshd on the stick and the
  host keys are stripped, so the code reaches only the VNC session and a local
  VT — and anyone at a local VT can already erase every disk through the
  installer's own UI, unauthenticated, by design.
- No TLS on the VNC leg, deliberately: noVNC cannot speak VeNCrypt, so weston
  runs in its password-only mode and negotiates RA2ne, which is encrypted and is
  what noVNC does speak. The browser leg gets its own TLS from websockify. This
  is the same trade the station's compose file documents.

`boot-test.py` forwards the guest's 5900 and asserts the 12-byte `RFB 003.008`
greeting. A screenshot cannot tell you whether the second head came up — the
panel looks identical either way — so that one TCP read is the CI guard.

### Keyboards on the stick

The keyboard pieces are the station's own, not copies: the on-screen keyboard
is the binary from the `centroid-is/dockers` weston image and the Flutter
embedder is the one from the `centroid-hmi` image, so every keyboard patch that
lands for the station (the Gboard-style layouts and globe key in the keyboard,
the dead-keys, numlock and navigation patches in the embedder) is what the
installer runs the next time it is built. Two things differ from a station and
are deliberate:

- The compositor is trixie's stock weston 14, not the patched weston 16 image.
  The dockers patches to weston itself fix the VNC seat's keymap, and the
  installer has no VNC backend, so there is nothing for them to fix here.
- There is no weston wrapper resolving `KEYBOARD_*` from `.env`, because there
  is no `.env` yet. `overlays/installer/etc/xdg/weston/weston.ini` writes the
  three layouts out for a physical keyboard, and `centroidx-gui.service` hands
  `KEYBOARD_LAYOUTS=is,en,pl` to weston for the on-screen one.

The layout the operator picks does not change the installer's own keyboard —
it is the station's answer, written to `station.conf` and from there to
`KEYBOARD_DEFAULT` in the station's `.env` at first boot.

### Testing the installer without a disk

`make test` runs `test/installer-test.sh`, which sources the installer script
for its functions and checks the `station.env` parser, the validators, the
seed-file rules and the files written to the target — into a temporary
directory, never a device. Any bash will do; the WireGuard cases skip when `wg`
is not installed. CI runs it in the `validate` job on every pull request.

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

## Where the stack lives

`/home/centroid/docker-compose.yml`, which is what `docker-update` bind-mounts by
absolute path (`docker-compose.yml:304`), and therefore where every relative
volume in that file resolves: `./timescale_data`, `./local-share`,
`./seatd-socket`, `./tfc_config` and the cert directories.

Worth checking against your stations before reimaging one: `tools/hmi_profiler.py`
documents running the stack from a project directory one level below `$HOME`,
which disagrees with the absolute path `docker-update` bind-mounts. If a station
really runs from a subdirectory, its `docker-update` bind mount cannot be
resolving, and a reimaged station will not find that station's existing
`timescale_data`.

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
