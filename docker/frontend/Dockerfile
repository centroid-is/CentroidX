# =============================================================================
# Stage: rebuild the Wayland embedder with the keyboard patches
#
# The bundle ships a prebuilt libflutter_elinux_wayland.so that is wrong for
# this station in three ways, so rebuild it from the exact source tag matching
# the bundled engine and swap it into the bundle below:
#
#   force-numlock  its xkb state is driven solely by the compositor's
#                  wl_keyboard.modifiers events, and weston's VNC seat never
#                  latches NumLock, so keypad keys resolve to navigation
#                  keysyms and produce no characters — a dead numpad over the
#                  VNC mirror.
#   kp-enter       the keypad's Enter is a separate evdev code that inserted a
#                  bare CR instead of firing the input action.
#   nav-keys       Home/End were dropped in the text-input keysym switch, and
#                  Up/Down arrived but had no handler.
# =============================================================================
FROM debian:trixie-slim AS embedder-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang build-essential cmake pkg-config git ca-certificates \
    libgles2-mesa-dev libegl1-mesa-dev libxkbcommon-dev libwayland-dev \
    libdrm-dev libgbm-dev libinput-dev libudev-dev libsystemd-dev \
    wayland-protocols libx11-dev \
    && rm -rf /var/lib/apt/lists/*

# The embedder repo tags releases by Flutter engine hash. This must match the
# engine of the Flutter version flutter-elinux builds with (bin/internal/
# engine.version — Flutter 3.47.0 since #350). Update alongside any
# flutter-elinux version bump; a mismatch fails loudly at link time, not
# silently.
ARG EMBEDDER_REF=5f77625673
RUN git clone https://github.com/flutter-elinux/flutter-embedded-linux.git /embedder \
    && git -C /embedder checkout ${EMBEDDER_REF}

# nav-keys.patch is cut against the tree with the other two already applied,
# so keep this order.
COPY force-numlock.patch kp-enter.patch nav-keys.patch /tmp/embedder-patches/
RUN git -C /embedder apply --stat --apply /tmp/embedder-patches/force-numlock.patch \
      /tmp/embedder-patches/kp-enter.patch \
      /tmp/embedder-patches/nav-keys.patch

# The embedder links against the engine at build/libflutter_engine.so
# (hardcoded in its cmake). Use the one from the app bundle so the .so is
# built against exactly the engine it will run with.
ARG APP_BUNDLE
COPY ${APP_BUNDLE}/lib/libflutter_engine.so /embedder/build/

# Release regardless of the bundle's build mode: the wrapper ABI is identical,
# only optimization and embedder-internal assertions differ.
RUN cmake -S /embedder -B /embedder/build \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_ELINUX_SO=ON -DBACKEND_TYPE=WAYLAND \
    && cmake --build /embedder/build -j"$(nproc)" \
    && ls -la /embedder/build/libflutter_elinux_wayland.so

# =============================================================================
# Stage: runtime
# =============================================================================
FROM debian:trixie-slim

# Install only the required libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    libgcc-s1 \
    libc6 \
    libfontconfig1 \
    libpthread-stubs0-dev \
    libxkbcommon0 \
    libwayland-client0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libegl1 \
    libfreetype6 \
    libexpat1 \
    libffi8 \
    libgl1 \
    zlib1g \
    libpng16-16 \
    libglib2.0-0 \
    libsecret-1-0 \
    sqlite3 \
    libmpv2 \
    libnss3 \
    libnspr4 \
    libasound2t64 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libatspi2.0-0t64 \
    libcups2t64 \
    libxcomposite1 \
    libxdamage1 \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# libmpv2 is what plays the RTSP camera asset. package:media_kit loads it by
# name at runtime (media_kit_libs_linux bundles nothing on Linux — it expects
# the distro's), so without it every camera tile fails MediaKit.
# ensureInitialized and the app logs "one or more required dependencies could
# not be located". It brings the ffmpeg libraries with it, which is most of
# this image's size; the video output that consumes its frames is
# packages/media_kit_video_elinux.

# libnss3 through libxdamage1 are CEF's runtime dependencies, needed by the
# Web page asset's browser (packages/webview_cef). CEF itself is not installed
# here — it is downloaded at build time by the plugin's CMake and lands in the
# app bundle alongside the binary — but it will not start without these.
# libfontconfig1 is also required and is already above.
#
# They are not optional: libcef.so names every one of them in its DT_NEEDED,
# and the webview plugin and the app binary inherit that. Missing any one, the
# dynamic loader refuses to start the app at all — "error while loading shared
# libraries: libatk-1.0.so.0" in a restart loop, and no HMI on the station.
# The ldd check at the end of this stage fails the build instead.

# Hacks for amplify secure storage
RUN ln -s /usr/lib/x86_64-linux-gnu/libgio-2.0.so.0 /usr/lib/x86_64-linux-gnu/libgio-2.0.so
RUN ln -s /usr/lib/x86_64-linux-gnu/libglib-2.0.so.0 /usr/lib/x86_64-linux-gnu/libglib-2.0.so
RUN ln -s /usr/lib/x86_64-linux-gnu/libsecret-1.so.0 /usr/lib/x86_64-linux-gnu/libsecret-1.so

# package:sqlite3 dlopens the unversioned name. The `sqlite3` package above
# brings libsqlite3-0, which ships only libsqlite3.so.0 — the unversioned
# symlink lives in libsqlite3-dev, which no runtime image installs. The local
# configuration store is opened before runApp, so without this the app does not
# start at all. Belt and braces: packages/tfc_dart/lib/core/sqlite_loader.dart
# falls back to the versioned soname from Dart, which covers a station still
# running an older image; this line covers an image built without that fallback.
RUN ln -s /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /usr/lib/x86_64-linux-gnu/libsqlite3.so

RUN useradd -m centroid

# Copy in your Flutter libraries and executable
# These will be supplied at build time
ARG APP_DIR=/flutter-app
WORKDIR $APP_DIR

# You can use build args to specify the location of your app and libs
# Example: docker build --build-arg APP_BIN=flutter_elinux_wayland --build-arg FLUTTER_ENGINE=./bundle ...
ARG APP_BIN
ENV BINARY=${APP_BIN}
ARG APP_BUNDLE
ENV BUNDLE=${APP_BUNDLE}

COPY ${APP_BUNDLE} $APP_DIR/

# Swap in the keypad-patched Wayland embedder built above (see the
# embedder-builder stage and the patches it applies).
COPY --from=embedder-builder /embedder/build/libflutter_elinux_wayland.so $APP_DIR/lib/

# Download libpdfium.so (flutter-elinux skips the CMake FFI plugin pipeline)
ARG PDFIUM_RELEASE=chromium%2F7520
RUN curl -sL "https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_RELEASE}/pdfium-linux-x64.tgz" \
      -o /tmp/pdfium.tgz \
    && mkdir -p /tmp/pdfium \
    && tar -xzf /tmp/pdfium.tgz -C /tmp/pdfium lib/libpdfium.so \
    && cp /tmp/pdfium/lib/libpdfium.so $APP_DIR/lib/ \
    && rm -rf /tmp/pdfium /tmp/pdfium.tgz

RUN chown -R centroid:centroid $APP_DIR \
    && chmod +x $APP_DIR/${BINARY}

# Fail the build, not the station: every library the binary or the bundle
# names must resolve in this image. A bundled plugin that pulls in a new
# system library otherwise ships an image that cannot start.
RUN missing=$(for f in ./${BINARY} lib/*.so; do \
        LD_LIBRARY_PATH=./lib ldd "$f" | grep 'not found' | sed "s|^[[:space:]]*|$f: |"; \
    done); \
    if [ -n "$missing" ]; then \
        echo "Unresolved shared libraries; install the packages that provide them:"; \
        echo "$missing"; \
        exit 1; \
    fi

# CEF also needs lib/locales/*.pak beside libcef.so, which no ldd can see.
# Without one, Chromium CHECK-fails in the browser and in every zygote as soon
# as the first Web page tile opens, and the HMI dies with it: SIGTRAP in
# libcef.so, and the only log line is "locale_file_path.empty() for locale".
# The plugin's CMake is what ships them; see packages/webview_cef/elinux.
RUN if [ -f lib/libcef.so ] && [ ! -f lib/locales/en-US.pak ]; then \
        echo "lib/libcef.so is bundled but lib/locales/en-US.pak is not: CEF would crash on first use"; \
        exit 1; \
    fi

USER centroid

CMD ["/bin/sh", "-c", "LD_LIBRARY_PATH=./lib ./${BINARY} --bundle=. --fullscreen --onscreen-keyboard"]
