# CentroidX

Industrial HMI (Human-Machine Interface) for monitoring and controlling automation systems via OPC-UA and MQTT.

## Install

Download the **CentroidX Version Manager** for your platform — it handles installation, updates, and rollback:

| Platform | Download |
|----------|----------|
| :apple: **macOS** (Apple Silicon) | [`centroidx-manager_darwin_arm64.dmg`](https://github.com/centroid-is/tfc-hmi/releases/latest/download/centroidx-manager_darwin_arm64.dmg) |
| :window: **Windows** (x64) | [`centroidx-manager_windows_amd64.exe`](https://github.com/centroid-is/tfc-hmi/releases/latest/download/centroidx-manager_windows_amd64.exe) |
| :penguin: **Linux** (x64) | [`centroidx-manager_linux_amd64`](https://github.com/centroid-is/tfc-hmi/releases/latest/download/centroidx-manager_linux_amd64) |

Run the manager and it will download and install the latest CentroidX release.

> The macOS manager is Developer ID signed and notarized — no Gatekeeper
> warning. The Windows manager is not code-signed, so SmartScreen shows a
> "Windows protected your PC" prompt on first run: choose **More info → Run
> anyway**. CentroidX itself ships as an MSIX signed by a self-signed sideload
> certificate, published alongside it as `centroidx-sideload.cer`. Windows will
> refuse to install the MSIX until that certificate is trusted:
>
> ```powershell
> Import-Certificate -FilePath centroidx-sideload.cer `
>   -CertStoreLocation Cert:\LocalMachine\TrustedPeople
> ```
>
> Run once per machine, elevated.

### Latest `main` build

Unpackaged builds straight from the tip of `main`, rebuilt on every merge. No installer and no version manager — download, unpack, run.

| Platform | Download | Notes |
|----------|----------|-------|
| :apple: **macOS** (Apple Silicon) | [`centroidx_darwin_arm64.dmg`](https://github.com/centroid-is/tfc-hmi/releases/download/main-latest/centroidx_darwin_arm64.dmg) | Developer ID signed; Gatekeeper may warn if the build was not notarized |
| :window: **Windows** (x64) | [`centroidx_windows_x64.zip`](https://github.com/centroid-is/tfc-hmi/releases/download/main-latest/centroidx_windows_x64.zip) | Portable `centroidx.exe` + libs, no MSIX |
| :penguin: **Linux** (x64) | [`centroidx_linux_x64.tar.gz`](https://github.com/centroid-is/tfc-hmi/releases/download/main-latest/centroidx_linux_x64.tar.gz) | Needs GTK 3 and libsecret installed |

Checksums: [`SHA256SUMS.txt`](https://github.com/centroid-is/tfc-hmi/releases/download/main-latest/SHA256SUMS.txt) · All assets: [`main-latest` prerelease](https://github.com/centroid-is/tfc-hmi/releases/tag/main-latest)

> These are development builds with no release testing, replaced on every merge to `main`. They do not auto-update — use the version manager above for production.

## Development

### Prerequisites

- Flutter SDK — the version in [`.flutter-version`](.flutter-version)
- Dart SDK
- For NixOS: install the `mkhl.direnv` VSCode extension and run `direnv allow`

### Flutter version

`.flutter-version` is the single source for the Flutter version: every CI
workflow reads it through `.github/actions/setup-flutter`, so nothing hardcodes
a version any more.

**Match it locally, and check that you have:**

```sh
scripts/check-flutter-version.sh
```

It compares the `flutter` on your PATH against `.flutter-version` and exits
non-zero if they differ. Run it before starting work — it costs a second and it
is the only thing that catches either of the two failure modes below, both of
which look green on your machine and red on `main`.

**1. Goldens.** The widget tests compare rendered PNGs byte for byte
(`test/**/goldens/`), and different Flutter versions rasterise the same drawing
slightly differently — antialiasing along an edge shifts by a pixel or two. So
goldens are rendered on one pinned toolchain, on one reference platform.

**The reference platform is Linux, and goldens are rendered in a container:**

```sh
scripts/goldens.sh                       # verify every golden
scripts/goldens.sh test/painter          # verify one directory
scripts/goldens.sh --update test/painter/auger_conveyor_test.dart
```

On Linux you can equally well run `flutter test` directly — the script only
exists so a Mac or a Windows box can reach the same renderer. It builds
`docker/goldens/` on first use (a few minutes, cached after), reading the
Flutter version from `.flutter-version` so the image cannot drift from CI.

Why Linux rather than macOS, where these used to be authored: our goldens load
RobotoMono from repo bytes, so the font data is already pinned and the host's
installed fonts are never consulted. What is left is the glyph rasteriser. On
macOS, Skia rasterises glyphs through CoreText — part of the operating system
— so a golden authored on macOS 15 could fail on CI's macOS 26 under an
identical Flutter 3.44.9, with nothing changed and no way to regenerate out of
it. The only lever was the tolerance, and it kept widening. On Linux, Skia
rasterises through the FreeType compiled into the engine binary, which ships
inside the SDK: pin `.flutter-version` and the whole text raster stack is
pinned with it.

The container runs on your machine's **native** architecture. linux/amd64 and
linux/arm64 were measured producing byte-identical goldens, so an Apple Silicon
Mac reproduces CI's amd64 output without paying for emulation.

Pass the specific test file or directory you changed. `--update-goldens`
rewrites every golden the run produces, not just the failing ones, so a blanket
update re-baselines images nobody touched and buries the real change.

When a golden fails on CI, the comparator writes the expected/actual/diff PNGs
to a `failures/` directory next to the test; the `flutter-test` job uploads them
as a `golden-failures-<os>` artifact on the run.

**2. Framework assertions that only exist in the pinned version.** Flutter adds
debug-mode assertions between releases. One of them — `ListTile` inside a
`Container` with a `decoration`, "ink splashes may be invisible" — reddened
`main` from a PR whose author had just run the whole suite locally and watched
3181 tests pass. The assertion is not in the older Flutter's source at all, so
no amount of local testing could have found it. This is not something more
tests fix; only the right toolchain does.

#### Getting onto the pinned version

Nothing here touches a global Flutter install — on a machine shared with other
projects that is not a decision to make casually, and no script in this repo
makes it for you.

- **A second SDK, on PATH only for this repo.** Clone the pinned tag somewhere
  outside the repo and put its `bin` first on PATH in the shell you work in:

  ```sh
  git clone --depth 1 -b "$(cat .flutter-version)" \
    https://github.com/flutter/flutter.git ~/flutter-sdks/"$(cat .flutter-version)"
  export PATH="$HOME/flutter-sdks/$(cat .flutter-version)/bin:$PATH"
  ```

  Costs a few GB per version and leaves everything else alone. Every `flutter`
  invocation in this repo's tooling then resolves to the right one with no
  changes.

- **Moving the global install** is fine if this is the only Flutter project on
  the machine, and only then.

- **[`fvm`](https://fvm.app)** manages per-project SDKs, but wants invocations
  prefixed (`fvm flutter test`) and an IDE pointed at `.fvm/flutter_sdk`. It is
  not used here; the scripts, skills, and workflows all call bare `flutter`.

### Code generation

```sh
flutter pub run build_runner build
```

### Run

```sh
cd centroid-hmi
flutter run -d macos
```

### Profiling

`ghcr.io/centroid-is/centroid-hmi:latest-profile` is a Flutter **profile**
build — AOT-compiled like release, so its timings are the ones an operator
feels, but with the Dart VM Service left in. It is an extra tag alongside
`latest` and `latest-release`, which are unchanged; point a station's compose
at it when you want to profile that station. `tools/hmi_profiler.py`
turns that into a markdown report: frame build/raster percentiles, the call
tree behind them, timeline blocks and the largest classes on the heap — led by
a "Where to look" summary.

For the one-off stall rather than the average, `slow` finds blocks that ran far
longer than the median for their own name and dumps the stack that was on the
CPU during each.

It also reads the layers the VM cannot see: per-thread CPU (is the raster
thread pegged while the UI thread idles?), RSS against the Dart heap (the
engine, Skia, pdfium and open62541 allocate outside it), every container
against its memory limit, and the database's live queries and scan counts.

```sh
# a running station (port 8181 is on the compose network, not published)
docker compose run --rm profiler report --seconds 30
docker compose run --rm profiler slow --seconds 20 --repeat   # hunt for hiccups
docker compose run --rm profiler system --seconds 10          # containers, threads, database

# a local profile run — paste the ws:// URI `flutter run` printed
flutter run --profile -d macos
python3 tools/hmi_profiler.py report --url ws://127.0.0.1:PORT/AUTHCODE=/ws
```

See [`docker/profiler/README.md`](docker/profiler/README.md) for the engine
switches this needs, how to read the output, and why the port is not exposed.
