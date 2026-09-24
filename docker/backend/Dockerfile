# Stage 1: Build tfc_dart (build hooks compile open62541 + mbedTLS automatically)
FROM dart:stable AS dart-builder

# Install build tools needed by open62541_dart build hook
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Mirror the packages/ layout so path deps resolve (tfc_dart → ../jbtm,
# ../tfc_access)
WORKDIR /app/packages/tfc_dart

# Copy all pubspecs so path dependencies resolve during pub get
COPY packages/tfc_dart/pubspec.yaml ./
COPY packages/jbtm/pubspec.yaml ../jbtm/
COPY packages/modbus_client_tcp/pubspec.yaml ../modbus_client_tcp/
COPY packages/modbus_client/pubspec.yaml ../modbus_client/
COPY packages/tfc_access/pubspec.yaml ../tfc_access/

# Get dependencies fresh
RUN dart pub get

# Copy source code
COPY packages/tfc_dart/ .
COPY packages/jbtm/ ../jbtm/
COPY packages/modbus_client_tcp/ ../modbus_client_tcp/
COPY packages/modbus_client/ ../modbus_client/
COPY packages/tfc_access/ ../tfc_access/

# Build executables (dart build cli triggers build hooks for native assets)
RUN dart build cli -t bin/main.dart -o build/main && \
    dart build cli -t bin/generate_certs.dart -o build/generate_certs


# Stage 2: Build jbtm proxy (depends on open62541 for DynamicValue)
FROM dart:stable AS jbtm-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY packages/jbtm/pubspec.yaml ./
RUN dart pub get
COPY packages/jbtm/ .

RUN dart build cli -t bin/m2400_proxy.dart -o build/m2400_proxy


# Stage 3: Profile variant — the same source, run by the JIT VM with the Dart
# VM Service left on. Published as `<sha>-profile` and `latest-profile`, the
# tags the HMI's profile build uses. It is NOT the default target: `docker
# build .` and the `latest` / `stable` / `pr-N` steps in the workflow still
# end at the runtime stage below, and this one is only reached with
# `--target profile`, only for main (see backend-build in centroid-hmi.yml).
#
# Why JIT, when the HMI's profile image is AOT. The Dart SDK ships one AOT
# runtime, `dartaotruntime`, and it is a product build with the service
# protocol compiled out — `dart build cli` and `dart compile exe` both embed
# that same binary. Measured on Dart 3.12.2 (the SDK inside the pinned
# Flutter; `dart:stable` was 3.13 when this was written and ships the same
# runtime): a compiled executable passes `--enable-vm-service` straight
# through to the script's argv, `DART_VM_OPTIONS=--enable-vm-service` answers
# "Unrecognized flags: enable_vm_service", and the marker the HMI's workflow
# greps for — the `getCpuSamples` RPC name — has 0 hits in dartaotruntime
# against 1 in dartvm. Flutter gets AOT plus service because its engine is
# built in a separate profile configuration; no such build of the standalone
# runtime is published, and building the SDK from source to get one is out of
# proportion for a diagnostic image. So this stage keeps what the builder has
# — SDK, sources, resolved packages, the open62541 the build hooks compiled —
# and starts the backend with `dart run`.
#
# What that costs, and whoever reads a memory report from this image has to
# know it before drawing a conclusion: the JIT heap is not the shipped heap.
# It holds unoptimised and optimised code, IC data and kernel for every
# function that has run, so its baseline is higher and it grows during
# warm-up for reasons that are not leaks, and the GC paces itself against
# that larger heap. What it shares with the AOT process is the program:
# every object the backend allocates, retains and forgets. A class whose
# instance count climbs hour over hour in `getAllocationProfile` climbs for
# the same reason under `latest`, and the RSS outside the Dart heap —
# open62541, the VM's own arenas — is the same code making the same calls.
# Compare the shape of growth, not absolute figures, and never a JIT timing
# against a production one. Startup is slower too: pub compiles a path
# package to kernel on every start, tens of seconds and a transient frontend
# compiler that has exited before main() runs.
FROM dart:stable AS profile

# The builder's toolchain again, not because a start needs it — the hooks are
# warmed below — but because a hook that decides to rebuild anyway must fail
# on its own error, not on a missing cmake.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash appuser

# A fresh stage and COPY --chown, rather than `FROM dart-builder` and a
# chown -R: Docker stores a chown as a full copy of every file it touches,
# which would have doubled a multi-GB image for nothing. Non-root for the
# same reason the runtime image is, and the user has to own the tree because
# `dart run` writes into .dart_tool on every start (the kernel snapshot, the
# hook runner's locks).
#
# The pub cache moves out of /root, which appuser cannot traverse. The dart
# image sets no PUB_CACHE, so the builder filled the default /root/.pub-cache.
COPY --from=dart-builder --chown=appuser:appuser /app /app
COPY --from=dart-builder --chown=appuser:appuser /root/.pub-cache /pub-cache
ENV PUB_CACHE=/pub-cache

# Same tools the runtime image carries, so `docker compose run --rm
# centroidx-backend generate_certs` works on this tag too.
COPY --from=dart-builder /app/packages/tfc_dart/build/generate_certs/bundle/bin/generate_certs /usr/local/bin/
COPY --from=jbtm-builder /app/build/m2400_proxy/bundle/bin/m2400_proxy /usr/local/bin/
COPY --chmod=0555 docker/backend/profile-entrypoint.sh /app/profile-entrypoint.sh

WORKDIR /app/packages/tfc_dart
USER appuser

# Re-point package_config.json at the moved cache, offline: the lock file
# already pins every version, and --offline is the proof that this stage
# fetches nothing the AOT build did not.
#
# Then warm the JIT-mode build hooks as the user that will run them. `dart
# build cli` ran the same hooks for the AOT bundle, but `dart run` keys its
# cache on its own configuration and would otherwise compile open62541 again
# on the first container start — minutes, in a container that is supposed
# to be up in seconds. Running any bin/ script runs every hook in the package
# graph; generate_certs --help is the one that then exits at once.
RUN dart pub get --offline \
    && dart run bin/generate_certs.dart --help > /dev/null

# A script rather than `dart run` inline: the switches come from the
# environment (DART_VM_SWITCHES, see profile-entrypoint.sh) the way the
# HMI's engine switches do. CMD, not ENTRYPOINT, like the runtime image, so
# `docker compose run centroidx-backend generate_certs` still replaces it.
CMD ["/app/profile-entrypoint.sh"]


# Stage 4: Runtime image — the default target, and the only one `latest`,
# `stable` and `pr-N` are built from.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled backend bundle (executable + bundled native libraries)
COPY --from=dart-builder /app/packages/tfc_dart/build/main/bundle/ /app/

# Copy generate_certs tool
COPY --from=dart-builder /app/packages/tfc_dart/build/generate_certs/bundle/bin/generate_certs /usr/local/bin/

# Copy M2400 proxy
COPY --from=jbtm-builder /app/build/m2400_proxy/bundle/bin/m2400_proxy /usr/local/bin/

# Create non-root user
RUN useradd -m -s /bin/bash appuser
USER appuser

CMD ["/app/bin/main"]
