#!/usr/bin/env bash
#
# Runs the golden tests on Linux, from any host, so that the PNGs a developer
# produces are the PNGs CI compares against.
#
#   scripts/goldens.sh                          # verify every golden
#   scripts/goldens.sh test/painter             # verify one directory
#   scripts/goldens.sh --update test/painter/auger_conveyor_test.dart
#   scripts/goldens.sh --shell                  # poke around inside the image
#
# Goldens are rendered on Linux because that is the only platform where the
# text rasteriser is pinned by .flutter-version rather than by the host OS --
# see the long comment in docker/goldens/Dockerfile.
#
# The image is pinned to linux/amd64, the architecture CI runs, and that pin is
# load-bearing. Most of the suite does render identically on arm64 -- but not
# all of it: 18 goldens across four files differ between the two, by 0.03% to
# 2.96%. Every one of those files rotates something (`pi`, and `sin` in the
# image tests), and sin/cos differ in the last ULP between arm64 and x86_64
# libm, which moves geometry a fraction of a pixel and changes the
# antialiasing. So on an arm64 host this runs under emulation.
#
# Emulation is not what costs time here -- compiling is, and it is cached.
# Timed on an M-series Mac, one golden file against a cold volume:
#
#   flutter pub get ....................... 21s
#   first test run (builds native assets) . 175s   <- open62541 compiling mbedTLS
#   second test run ....................... 5s
#
# The 175s is paid once per (Flutter version, architecture) and then never
# again, which is why the volumes below are keyed by both.
#
# On an x86_64 Linux machine you can equally well run `flutter test` directly
# and skip this script; it exists so a Mac or a Windows box can reach the same
# renderer.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

FLUTTER_VERSION="$(tr -d '[:space:]' < .flutter-version)"
IMAGE="centroidx-goldens:${FLUTTER_VERSION}"

UPDATE=0
SHELL_MODE=0
REBUILD=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --update|--update-goldens) UPDATE=1 ;;
    --shell)                   SHELL_MODE=1 ;;
    --rebuild)                 REBUILD=1 ;;
    -h|--help)
      sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
      exit 0 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running." >&2
  echo "       On macOS/Windows start Docker Desktop; on Linux start the daemon" >&2
  echo "       -- or, since you are already on Linux, just run 'flutter test' directly." >&2
  exit 1
fi

# Check the architecture, not just that a tag exists. An arm64 image under this
# tag -- from an earlier build, or from a checkout that predated the amd64 pin
# -- makes `docker run --platform linux/amd64` go looking for a variant that is
# not there and fail with "pull access denied", which reads like an auth
# problem rather than a stale local image.
HAVE_ARCH="$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || true)"
if [ "$REBUILD" = 1 ] || [ "$HAVE_ARCH" != "amd64" ]; then
  [ -n "$HAVE_ARCH" ] && [ "$HAVE_ARCH" != "amd64" ] && \
    echo "==> local $IMAGE is $HAVE_ARCH, rebuilding for amd64"
  echo "==> building $IMAGE (first run takes a few minutes; cached after that)"
  docker build \
    --platform linux/amd64 \
    --build-arg "FLUTTER_VERSION=${FLUTTER_VERSION}" \
    -t "$IMAGE" \
    "$REPO/docker/goldens"
fi

# Named volumes shadow the paths the Linux toolchain writes to, so the
# container never stamps Linux build output over the host checkout's. Without
# this, the next native `flutter test` on a Mac fails with a kernel-binary or
# native-asset error that looks like corruption -- .dart_tool would be holding
# another platform's artifacts. They are keyed by Flutter version so a version
# bump starts clean instead of reusing a stale cache.
# Keyed by Flutter version AND architecture. The architecture is not
# decoration: these volumes hold compiled native assets, and a volume populated
# by an arm64 run makes the next amd64 run rebuild mbedTLS from scratch -- a
# measured 175 seconds that looks like the container simply being slow, because
# nothing in the output says a C library is being compiled.
V="centroidx-goldens-${FLUTTER_VERSION//[^a-zA-Z0-9_.-]/_}-amd64"

# Stale failure images from a previous run are worse than useless: the
# comparator writes expected/actual/diff PNGs into `failures/` next to each
# failing test, they are gitignored so `git status` stays quiet about them, and
# a later run that fixes the golden leaves the old images sitting there looking
# current. They also break test/tools/centroidx_env_naming_test.dart, which
# walks the filesystem rather than git and counts ~1,400 of them as source the
# binary filter has swallowed.
find "$REPO/test" -type d -name failures -exec rm -rf {} + 2>/dev/null || true

# `flutter test` needs a pub get first, because .dart_tool is a fresh volume
# rather than the host's. The host pubspec.lock IS shared (it is bind-mounted
# and is platform-independent), which is what keeps the container resolving the
# same package versions the developer resolved.
INNER="set -e
flutter pub get >/dev/null
exec flutter test"
[ "$UPDATE" = 1 ] && INNER="$INNER --update-goldens"
for a in "${ARGS[@]:-}"; do [ -n "$a" ] && INNER="$INNER $(printf '%q' "$a")"; done

if [ "$SHELL_MODE" = 1 ]; then
  INNER="flutter pub get >/dev/null 2>&1 || true; exec bash"
  TTY=(-it)
else
  TTY=()
  [ -t 1 ] && TTY=(-t)
fi

if [ "$UPDATE" = 1 ] && [ ${#ARGS[@]} -eq 0 ]; then
  # --update-goldens rewrites every golden the run produces, not just failing
  # ones, so a blanket update re-baselines images nobody touched and buries the
  # real change in the diff.
  echo "warning: --update with no path re-baselines ALL goldens." >&2
  echo "         Pass the test file or directory you actually changed." >&2
fi

ACTION="flutter test"
[ "$UPDATE" = 1 ] && ACTION="$ACTION --update-goldens"
HOST_ARCH="$(docker version --format '{{.Server.Arch}}')"
if [ "$HOST_ARCH" != "amd64" ]; then
  echo "==> host is $HOST_ARCH; running linux/amd64 under emulation to match CI"
fi
echo "==> $IMAGE (linux/amd64) : ${ACTION}${ARGS[*]:+ ${ARGS[*]}}"

# Only the checkout is mounted. In a git worktree, .git is a file pointing
# outside it, so git commands do not work inside the container -- nothing in a
# test run needs them, but that is why this is not a general-purpose shell.
docker run --rm "${TTY[@]}" \
  --platform linux/amd64 \
  -v "$REPO:/work" \
  -v "${V}-dart-tool:/work/.dart_tool" \
  -v "${V}-build:/work/build" \
  -v "${V}-pub-cache:/pub-cache" \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
  -w /work \
  "$IMAGE" \
  bash -lc "$INNER"

# Docker Desktop maps ownership back to the invoking user, but a native Linux
# daemon does not: without this the regenerated PNGs come back owned by root.
if [ "$(uname -s)" = "Linux" ] && [ "$UPDATE" = 1 ]; then
  find "$REPO/test" -path '*/goldens/*' -newermt '-10 minutes' \
    -exec chown "$(id -u):$(id -g)" {} + 2>/dev/null || true
fi
