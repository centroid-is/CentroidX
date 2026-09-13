# Renders CentroidX's golden images on Linux, so that a Mac, a Windows box and
# CI all produce the same PNGs.
#
# Why Linux is the reference platform, and not macOS where the goldens used to
# be authored:
#
#   Our golden tests load RobotoMono from repo bytes (test/helpers/golden_fonts.dart),
#   so the font data is already pinned and the host's installed fonts are never
#   consulted. The only remaining variable is the glyph rasteriser -- and that
#   is where the two platforms differ in kind. On macOS, Skia rasterises glyphs
#   through CoreText, which is part of the operating system: it changes when
#   macOS changes, and no amount of pinning Flutter holds it still. That is why
#   a golden authored on macOS 15 could fail on CI's macOS 26 with an identical
#   Flutter 3.44.9, and why regenerating never fixed it -- the two machines
#   cannot produce each other's raster. On Linux, Skia rasterises through the
#   FreeType compiled into the engine binary, which ships inside the SDK. Pin
#   the Flutter version and the entire text raster stack is pinned with it.
#
# Measured on 2026-09-12 with a three-golden probe (dense small text, an
# antialiased line drawing, a Material surface):
#
#   two fresh containers, same arch ....... byte-identical
#   macOS vs Linux, pure drawing .......... byte-identical (0 px)
#   macOS vs Linux, sparse text ........... 0.104% of pixels
#   macOS vs Linux, dense small text ...... 1.482% of pixels
#
# That probe also showed linux/amd64 and linux/arm64 agreeing byte for byte,
# and on the real suite that turned out to be TOO STRONG A CONCLUSION. Running
# the whole suite on amd64 against arm64-generated goldens fails 18 of them,
# across four files, by 0.03% to 2.96%. Every one of those files rotates
# something -- `pi`, and `sin` in the image tests -- and sin/cos differ in the
# last ULP between arm64 and x86_64 libm. A fraction of a pixel of geometry
# moves, and the antialiasing along the edge changes with it. The probe drew
# arcs and beziers from literal constants, which happen to agree; rotation does
# not.
#
# So scripts/goldens.sh pins --platform linux/amd64, the architecture CI runs,
# and an arm64 host renders under emulation. The native-asset build is cached
# in a volume, which is what keeps that practical.
#
# The base image is pinned by digest rather than by tag. The rasteriser lives
# in the engine, not in the distro, so this is belt-and-braces rather than
# load-bearing -- but an unpinned `ubuntu:24.04` can change under us between
# two builds of the "same" image, and an image that silently changes is exactly
# what this file exists to prevent.
FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

# Passed by scripts/goldens.sh, which reads it from .flutter-version so that
# this image and CI cannot drift apart. There is deliberately no default: a
# build that forgets it should fail loudly, not silently produce a different
# Flutter.
ARG FLUTTER_VERSION
RUN test -n "$FLUTTER_VERSION" || { echo "FLUTTER_VERSION build-arg is required (it comes from .flutter-version)"; exit 1; }

ENV DEBIAN_FRONTEND=noninteractive

# Split into two apt layers on purpose. Everything the Flutter install itself
# needs goes first; the libraries the *tests* need go after the SDK is cached,
# so discovering one more missing library does not re-clone Flutter and redo
# precache. That discovery happens more than once -- GitHub's ubuntu runners
# ship a broad set of libraries preinstalled, so CI never had to name them, and
# a bare ubuntu image finds them one failure at a time.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$FLUTTER_VERSION" \
      https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

# `flutter test` renders on the headless flutter_tester -- no GPU, no display,
# no desktop toolchain -- so only the Linux host artifacts are worth caching.
# --universal drags in the iOS and Android artifacts and roughly triples both
# the build time and the image.
RUN git config --global --add safe.directory /opt/flutter \
 && git config --global --add safe.directory '*' \
 && flutter --version \
 && flutter precache --no-ios --no-android --no-web --no-macos --no-windows --linux

# build-essential, cmake,
# ninja-build, pkg-config -- open62541's build hook compiles mbedTLS from
#                            source through native_toolchain_cmake. Without a C
#                            toolchain the hook dies in cmakePath before a
#                            single test loads.
# libglib2.0-dev          -- what .github/workflows/test.yml installs on its
#                            ubuntu runners for the root package's build hooks.
# libsecret-1-0           -- flutter_secure_storage dlopens libsecret-1.so at
#                            runtime. Missing, it does not fail at link time or
#                            at startup: tests throw "Cannot open libsecret-1"
#                            mid-run, which reads like a code fault rather than
#                            an image gap.
# libsqlite3-dev          -- drift opens the *unversioned* 'libsqlite3.so',
#                            which only the -dev package provides;
#                            libsqlite3-0 ships libsqlite3.so.0 and is not
#                            enough. Without it ~600 non-golden tests fail with
#                            "Failed to load dynamic library 'libsqlite3.so'".
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config \
      libglib2.0-dev libglu1-mesa libsecret-1-0 libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

# The Linux toolchain writes into .dart_tool/, build/ and the pub cache, and
# those must never land in the bind-mounted host checkout: a macOS developer's
# .dart_tool holds macOS native assets, and letting the container stamp Linux
# ones over them breaks their next native `flutter test`. scripts/goldens.sh
# mounts a named volume over each of these paths.
ENV PUB_CACHE=/pub-cache

WORKDIR /work
