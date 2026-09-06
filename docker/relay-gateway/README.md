# `relay_gateway` is a test harness. It is not a deployable.

This directory used to hold a Dockerfile, a compose fragment and an example
config that built and ran `relay_gateway` at a plant. Phase 13 deleted all
four. Nothing in this repository builds `relay_gateway` into an image, and
nothing runs it at the plant.

The deletion is deliberate rather than a comment: a commented-out compose block
is a thing somebody uncomments at 2 a.m.

## The plant runs one process

`centroidx-backend` — `packages/tfc_dart/bin/main.dart` — is the plant's single
deployable. From Phase 13 onward it serves the relay WebSocket itself, from an
adapter over its own acquisition pipe. Its relay configuration lives in the
backend's own `stateman.json` world (`CENTROID_STATEMAN_FILE_PATH`), not in a
`gateway.json`, and it is **off by default**: a backend with no relay section
boots with the WebSocket off and says so in one log line.

## Why one and not two

The eight M2200 weighers accept exactly one TCP client each, so two processes
owning the plant is not a deployment choice — whichever process loses the race
loses the weighers.

## Where the harness is still used

- `packages/tfc_relay_local/test/` — the gateway composition is the reference
  the relay tests exercise end to end.
- `dart run tfc_relay_local:relay_gateway --help` — the usage text.

Started without `--harness` (or `CENTROIDX_RELAY_HARNESS=1`), the binary writes
a notice to stderr saying it is not the plant's deployable. It still runs; a
harness that has to be special-cased is a harness people stop using.

## What goes red if a build path comes back

`packages/tfc_relay_local/test/harness_only_test.dart` scans this directory
tree and fails if any file here names `relay_gateway` in a build or run
directive. This README is the one exemption, by name.
