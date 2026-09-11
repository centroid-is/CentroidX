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
- **Goldens**: every visual change gets a golden test, and the PNG must be
  inspected by eye before calling the work done. Generate with
  `flutter test --update-goldens <file>` — but read `/finish` Phase 2 first,
  because that flag rewrites every golden the file produces, not just the
  failing ones. Tolerance is handled by `test/helpers/golden_tolerance.dart`.
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
