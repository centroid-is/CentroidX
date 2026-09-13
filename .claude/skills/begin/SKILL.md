---
name: begin
description: Start development work on CentroidX (tfc-hmi) — create an isolated git worktree with working native-asset cache, and orient in the project structure and conventions before touching code.
---

# CentroidX Begin

Sets up a safe, isolated place to work on the CentroidX monorepo and loads the
project conventions. Run this at the start of any task that edits the repo.

## Usage

```
/begin [branch-name]
```

If no branch name is given, derive a short kebab-case one from the task.

## Phase 1: Worktree (NEVER skip)

The shared checkout is used by multiple agents in parallel. **Never switch
branches, commit, or leave stray files in the main checkout** — all work
happens in a worktree.

```bash
REPO=$(git rev-parse --show-toplevel)
cd "$REPO" && git fetch origin main
git worktree add ../tfc-hmi-worktrees/<branch> -b <branch> origin/main
```

## Phase 2: Lockfiles + native-asset cache

`pubspec.lock` is gitignored, so a fresh worktree resolves newer package
versions than the environment expects. The open62541 native-assets hook
downloads binaries from GitHub and gets rate-limited (HTTP 429). Both are
fixed by copying from the main checkout:

```bash
WT=../tfc-hmi-worktrees/<branch>
cp "$REPO/pubspec.lock" "$WT/"
cp "$REPO/packages/tfc_dart/pubspec.lock" "$WT/packages/tfc_dart/"
mkdir -p "$WT/.dart_tool/hooks_runner"
cp -c -R "$REPO/.dart_tool/hooks_runner/shared" "$WT/.dart_tool/hooks_runner/"
find "$WT/.dart_tool/hooks_runner/shared" -type d -name build -path "*src*" -prune -exec rm -rf {} +
# The line above misses open62541's own downloaded sources, which are a level
# deeper. Leave them and the first `flutter test` dies with "patch does not
# apply" — the hook re-patches a tree it already patched.
rm -rf "$WT/.dart_tool/hooks_runner/shared/open62541/build/dl/src" \
       "$WT/.dart_tool/hooks_runner/shared/open62541/build/tls/src"
cd "$WT" && flutter pub get
./scripts/check-flutter-version.sh
```

**macOS only:** `cp -c` is the APFS clonefile flag — it copies the cache at no
disk cost, which matters because the dev Mac runs near-full. On Linux drop the
`-c` (plain `cp -R`) and expect the space to actually be used.

If the version check fails, the worktree is set up but the toolchain is not.
The pinned SDK is at `~/flutter-sdks/$(cat .flutter-version)`; put it first on
`PATH` and re-run `flutter pub get`. Do not regenerate goldens, and do not
trust a green local run of a UI change, until it passes.

If running `dart test` inside `packages/tfc_mcp_server` or
`packages/tfc_dart`, repeat the `hooks_runner/shared` copy into those
packages' `.dart_tool/` too.

## Phase 3: Orientation

What this repo is: **CentroidX**, an industrial HMI (Flutter) monitoring and
controlling automation via OPC UA and MQTT. Layout:

- `lib/page_creator/assets/` — the HMI mimic assets (conveyors, gates,
  sensors, IO modules…). Each asset = a `*Config` class
  (`@JsonSerializable`, generated `*.g.dart`) with `build()` for the runtime
  widget and `configure()` for the page-editor form.
- `lib/widgets/panes/` — the `SidePane` system (`side_pane.dart`,
  `pane_chrome.dart` with `PaneStatus`/`PaneStatusChip`). Runtime taps on
  assets open non-modal side panes, not dialogs.
- `lib/providers/state_man.dart` — Riverpod `stateManProvider` →
  `StateMan` (packages/tfc_dart) for OPC UA subscribe/write by string key.
- `packages/tfc_dart` — core Dart package, own tests (`dart test`).
- `centroid-hmi/` — the app shell (`cd centroid-hmi && flutter run -d macos`).
- `test/` — mirrors `lib/`. Goldens live in `test/**/goldens/`.

Conventions that reviews get bounced on:

- **Codegen**: after changing any `@JsonSerializable` config, run
  `dart run build_runner build --delete-conflicting-outputs` (tfc_dart
  first, then root).
- **Widget tests** mock OPC UA with a local `_FakeStateMan implements
  StateMan` (see `test/page_creator/assets/start_stop_button_widget_test.dart`)
  and override `stateManProvider`.
- **Goldens are rendered on Linux, in a container** — `scripts/goldens.sh`,
  built from `docker/goldens/`. Every visual change gets a golden test, and the
  PNG must be inspected by eye before calling the work done:

  ```sh
  scripts/goldens.sh test/widgets/my_thing_test.dart          # verify
  scripts/goldens.sh --update test/widgets/my_thing_test.dart # re-baseline
  ```

  Do not run `flutter test --update-goldens` natively on the Mac: macOS
  rasterises glyphs through CoreText, which belongs to the OS, so the PNGs will
  not match what CI compares. Pass the specific file — `--update` rewrites
  every golden the run produces, not just the failing ones (`/finish` Phase 2).
  Platform gating comes from `test/helpers/golden_platform.dart`: `goldenSkip`
  for `group`/`test`, `goldenSkipFlag` for `testWidgets`, which types `skip` as
  `bool?` and cannot take a reason string. Tolerance lives in
  `test/helpers/golden_tolerance.dart`.

  First container run takes a few minutes to build the image, then it is
  cached. It runs on your machine's native architecture — amd64 and arm64 were
  measured producing byte-identical goldens, so no emulation is involved.
- **Colors**: muted equipment-state colors via the theme
  (`HmiStateColors` / `PaneStatus`), never raw `Colors.*`; only fault red
  may be saturated. Forced/override state is **orange** by repo convention.
- **Panes show values, not wiring**: live figures, no raw OPC UA key names;
  charts behind a tap.
- **C++ work is test-driven**: tests first, logic split from Win32/Flutter.

## Phase 4: Report

State the worktree path, branch, and that `pub get` succeeded. Then start
the actual task **in the worktree**.

When the work is done, use `/finish` to validate, make goldens, and ship a PR.
