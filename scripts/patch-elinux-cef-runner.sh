#!/usr/bin/env sh
# Teach the generated eLinux runner to start CEF's child processes.
#
# `centroid-hmi/elinux/` is not committed — CI regenerates it with
# `flutter-elinux create --platforms=elinux .` on every build — so the one
# change the Web page asset needs in `main()` cannot simply live in the tree.
# This script re-applies it after each create, and is idempotent so running it
# twice is harmless.
#
# Why the change is needed at all: CEF spawns no helper binaries of its own on
# Linux. It re-executes *this* binary with a --type= argument to be its render,
# GPU and utility children. initCEFProcesses returns >= 0 when this process is
# one of those children, and such a process must exit immediately — one that
# carried on would start a second HMI, open a second window and connect to the
# PLC a second time.
#
# Without it the asset finds no browser and shows its placeholder, which is
# also exactly what a build with no CEF at all looks like. See
# WebViewSurfaceAvailability in lib/page_creator/assets/web_view.dart.
set -eu

MAIN="${1:-centroid-hmi/elinux/runner/main.cc}"

if [ ! -f "$MAIN" ]; then
  echo "patch-elinux-cef-runner: $MAIN not found — run flutter-elinux create first" >&2
  exit 1
fi

if grep -q 'initCEFProcesses' "$MAIN"; then
  echo "patch-elinux-cef-runner: already patched, nothing to do"
  exit 0
fi

# Fail loudly rather than silently producing a runner without CEF: a build that
# looks green and ships a permanently-placeholdered asset is the worse outcome.
if ! grep -q '^int main(int argc, char\*\* argv) {' "$MAIN"; then
  echo "patch-elinux-cef-runner: could not find main() in $MAIN." >&2
  echo "The flutter-elinux runner template changed; update this script." >&2
  exit 1
fi

TMP="$(mktemp)"
awk '
  !inserted_include && /^#include/ {
    print "#include <webview_cef/webview_cef_plugin.h>"
    inserted_include = 1
  }
  { print }
  /^int main\(int argc, char\*\* argv\) \{$/ && !inserted_call {
    print "  // Added by scripts/patch-elinux-cef-runner.sh — see that file."
    print "  int cef_exit_code = initCEFProcesses(argc, argv);"
    print "  if (cef_exit_code >= 0) {"
    print "    return cef_exit_code;"
    print "  }"
    print ""
    inserted_call = 1
  }
  END {
    if (!inserted_call) exit 1
  }
' "$MAIN" > "$TMP"

mv "$TMP" "$MAIN"
echo "patch-elinux-cef-runner: patched $MAIN"
