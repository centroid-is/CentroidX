# Station polkit rules

Rules the HMI needs on the host it manages over D-Bus. They are **not**
installed by this repo — the app ships in a container that mounts only
`/var/run/dbus/system_bus_socket`, so it cannot write to the host's `/etc`.
They are provisioned by `ansible-playbook.yml` in
[centroid-is/debos-conf](https://github.com/centroid-is/debos-conf); the
files here are the reference copies.

| File | Grants | Needed by |
|---|---|---|
| `49-centroid-clock.rules` | `timedate1.set-time`, `set-timezone`, `set-local-rtc`, `set-ntp`, `timesync1.set-runtime-servers` | Date & Time on the About Linux page |

NetworkManager already has one — `50-networkmanager-container.rules`, from
the same playbook. That is why the IP settings page has always been able to
write and this one could not.

## Why `subject.user`, not `local && active`

Debian's own `org.freedesktop.NetworkManager.rules` grants
`settings.modify.system` to `local && active` members of `sudo` or `netdev`.
Copying that shape here would not work. The HMI runs in a container: its
process sits in `/system.slice/docker-<id>.scope` with no logind session, so
polkit sees it as neither local nor active. That is exactly why the
NetworkManager rule in the playbook tests `subject.user == "centroid"`
instead, and these rules match it.

## Installing

Normally: run the debos-conf playbook. To try one on a station by hand,

```sh
sudo install -m 0644 49-centroid-clock.rules /etc/polkit-1/rules.d/
```

polkit picks rules up without a restart.

## Checking

Check the **container's** process, not a shell — a login shell has a session
and the container does not, so a shell can answer differently from the thing
that actually makes the call:

```sh
pkcheck --action-id org.freedesktop.timedate1.set-ntp \
        --process $(docker inspect -f '{{.State.Pid}}' flutter)
echo $?
```

`0` means granted. `2`, with `Authorization requires authentication and -u
wasn't passed`, means the rule is not in effect — the state every station is
in before these are installed. For contrast,
`org.freedesktop.NetworkManager.settings.modify.system` should already
return `0`.

## Who the HMI lets near these actions

The rule below grants the container blanket rights, so polkit is not the thing
that decides whether the operator standing at the panel may move the clock —
the HMI is. Since the About Linux page's controls were gated, changing the
time, the timezone or the NTP servers, and rebooting or powering off the
station, all require the `administer` access group; the status half of the page
stays readable to anyone, because "is the clock right?" is an operator
question. The route itself is deliberately not gated. See
`lib/widgets/group_access_guard.dart` and the `/advanced/about-linux` note in
`centroid-hmi/lib/main.dart`'s route table.

A refusal writes an audit row and shows the denial prompt; it never reaches
D-Bus, so nothing in this document's polkit path is involved.

## Why a rule rather than a polkit agent

The obvious alternative is to run an authentication agent so the operator can
type an administrator password. That does not work here: the HMI is a
fullscreen kiosk with no desktop session, and the container has no agent. The
D-Bus calls pass `allow_interactive_authorization`, so an agent would be used
if one ever existed, but the rule is what makes the feature work today.

## What this does not cover

`SetRuntimeNTPServers` is the only NTP server setter systemd exposes on the
bus, and it is runtime-only — timesyncd forgets the list when it restarts.
Persistent servers live in `/etc/systemd/timesyncd.conf`, which the container
cannot write. The HMI works around this by storing the operator's list in
device-local preferences and re-applying it on start; see
`ntpServersPrefsKey` in `lib/core/system_clock.dart`. If you would rather the
host own the list, set `NTP=` in `timesyncd.conf` through provisioning — the
page shows those as "From /etc/systemd/timesyncd.conf on the host". The page
now says this too, in an info pill under the server list, so an engineer at the
panel is told where the persistent list lives rather than having to find this
file.

## Checking a station's clock from a workstation

`tool/probe_clock.dart` reads the same properties the page does, over an SSH
D-Bus bridge, and prints them parsed:

```sh
dart run tool/probe_clock.dart 10.50.10.11 centroid ~/.ssh/id_ed25519
```

Useful for confirming a station's time source during commissioning without
walking to the panel, and for checking that a parsing change still agrees
with `timedatectl show-timesync` on real hardware.
