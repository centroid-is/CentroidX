#!/bin/sh
# Entrypoint of the `-profile` backend image (docker/backend/Dockerfile,
# stage `profile`). Starts the backend under the JIT VM with whatever VM
# options the environment asks for, then gets out of the way.
#
# The options come from numbered environment entries, the shape the HMI uses
# for its engine switches (FLUTTER_ENGINE_SWITCHES / FLUTTER_ENGINE_SWITCH_n,
# see the flutter service in docker-compose.yml), so that whoever has
# profiled the panel already knows how to read this:
#
#   DART_VM_SWITCHES: 2
#   DART_VM_SWITCH_1: enable-vm-service=8181         # fixed port; the bind stays 127.0.0.1
#   DART_VM_SWITCH_2: disable-service-auth-codes     # no per-boot secret in the ws path
#
# Each value is handed to `dart run` with `--` in front, so the vocabulary is
# `dart help -v run`'s "Debugging options". There is no profiler switch in
# that list — the standalone VM's sampling profiler is a runtime flag, and
# the profiler turns it on itself over the service (`setFlag profiler true`,
# which is what DevTools does). The launcher form that would take
# `--profiler` on the command line, `dart --profiler bin/main.dart`, was
# measured to skip the native-asset build hooks, and without those there is
# no open62541.
#
# `--enable-vm-service=<port>` binds 127.0.0.1 unless told otherwise. Nothing
# here tells it otherwise, and the compose file publishes no port: the
# profiler reaches it by sharing this container's network namespace. Anyone
# who can open that socket can read this process's memory and evaluate code
# in it, on the process that drives the machines.
#
# Unset, or 0, means plain `dart run bin/main.dart` — a JIT backend with no
# service. Miscount, and this refuses to start rather than run with fewer
# switches than were asked for: a backend that came up without its service
# would look exactly like one that is fine, until somebody tried to attach.
set -eu

count="${DART_VM_SWITCHES:-0}"
case "$count" in
  ''|*[!0-9]*)
    echo "profile-entrypoint: DART_VM_SWITCHES must be a count, got '$count'" >&2
    exit 64
    ;;
esac

set --
i=1
while [ "$i" -le "$count" ]; do
  eval "value=\${DART_VM_SWITCH_$i:-}"
  if [ -z "$value" ]; then
    echo "profile-entrypoint: DART_VM_SWITCHES=$count but DART_VM_SWITCH_$i is unset" >&2
    exit 64
  fi
  set -- "$@" "--$value"
  i=$((i + 1))
done

cd /app/packages/tfc_dart

# exec, twice over: this shell execs the `dart` launcher, and on Linux the
# launcher execvp()s the VM (runtime/bin/dartdev.cc -> Process::Exec), so
# the VM ends up as PID 1 and `docker stop`'s SIGTERM lands on main.dart's
# own handler, the same as it does in the AOT image.
#
# DART_BIN exists for testing the assembly above without a VM (`DART_BIN=echo`).
exec "${DART_BIN:-dart}" run "$@" bin/main.dart
