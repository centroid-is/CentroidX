#!/usr/bin/env bash
#
# Fail the build when anything outside `lib/providers/` constructs a
# device-local preferences store.
#
# Why this exists: `docs/access-control-spec.md` §6 asks for exactly this
# check, and gives the reason — "this is the invariant that will rot silently
# — every future feature that news up its own preferences reopens the hole and
# the type system will not object." A store constructed in a widget is not
# wrapped by `GuardedPreferences`, so its writes pass no check and leave no
# audit row, and nothing about the code looks wrong.
#
# The fix for a hit is one line:
#
#   * where a `ref` is available (any `ConsumerWidget` / `ConsumerState`), read
#     `localPreferencesProvider` — it is overridable in a test, the factory is
#     not;
#   * where there is none (a static method, a plain function, anything before
#     `runApp`), call `createDeviceLocalPreferences()` from
#     `lib/providers/preferences.dart`.
#
# THREE patterns, not one. Spec §6 names only `SharedPreferencesAsync()`. The
# legacy synchronous `SharedPreferences.getInstance()` reaches the same
# per-device store and a check written to §6's wording would never see it, so
# it is covered here as well.
#
# The third is `SqlitePreferences()`, the store that replaced both of them in
# milestone v1.2. It is not an addition for completeness — it is what keeps
# this check from enforcing nothing. `shared_preferences` construction is gone
# from `lib/` as of plan 01-06, so a two-pattern version of this script now
# matches nothing and prints "clean" forever, however many stores a future
# widget news up. An invariant that is satisfied by the disappearance of the
# thing it watched is precisely "the invariant that will rot silently" this
# file opens by quoting, so the check follows the store.
#
# The two `shared_preferences` patterns STAY. The dependency is still readable
# for one release (rollback insurance), so a regression to the old constructor
# is still possible and still caught; they leave with the package in Phase 4.
#
# The FOURTH is `ConfigStore()` — the shared configuration store, which
# milestone v1.2 phase 2 made the one write path for the plant's wiring. It is
# here for the same reason as the other three and for one more: a store
# constructed in a widget is not wrapped by `GuardedConfigStore`, so its writes
# pass no `configure` check, leave no `audit_entry`, and — unlike a preference
# write — produce `config_change` rows that claim an author the trail has no
# row for. The pattern deliberately also matches `GuardedConfigStore(`, because
# constructing the guard outside `lib/providers/` means building a second
# store's worth of session, policy and audit wiring by hand, which is the same
# hole one layer up.
#
# The one construction site is `lib/providers/config_store.dart`. Everything
# else reads `configStoreProvider`.
#
# This check is the ENFORCED SUBSET of `scripts/sweep-write-paths.sh`, whose
# sections 4 and 5 are these two patterns. That script is a report over nine
# kinds of write path and always exits 0; this one is a gate over two of them.
# Do not grow this file into a second sweep — add a section there instead, and
# `docs/access-control-write-path-sweep.md` is where every hit gets a verdict.
#
# NO LOCKFILE, DELIBERATELY. `/pubspec.lock` is gitignored (`.gitignore:26`),
# so any check keyed on a resolved dependency would find nothing in a fresh CI
# checkout and pass vacuously. This check reads source files only. Do not add
# a dependency-based variant.
#
# Usage:
#   scripts/check-preferences-construction.sh [--quiet]
#
# Exit codes:
#   0  no construction outside `lib/providers/`
#   1  at least one found — the offending file and line are printed
#   2  the check could not be run (no search roots)

set -uo pipefail

quiet=0
case "${1:-}" in
  --quiet) quiet=1 ;;
  "") ;;
  -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'check-preferences-construction: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$repo_root" || exit 2

# Source roots only. `scripts/` is deliberately NOT a root, so this file cannot
# match its own patterns; `test/`, `build/` and `.dart_tool/` are excluded in
# the grep options below rather than left to chance — a test that stands up an
# in-memory store is a test, and build output is not source.
ROOTS=()
for candidate in lib centroid-hmi/lib; do
  [ -d "$candidate" ] && ROOTS+=("$candidate")
done
if [ "${#ROOTS[@]}" -eq 0 ]; then
  printf 'check-preferences-construction: no search roots under %s\n' "$repo_root" >&2
  exit 2
fi

GREP_OPTS=(-rnE --include=*.dart --exclude-dir=test --exclude-dir=build --exclude-dir=.dart_tool)

# The one directory that may construct a store. `lib/providers/preferences.dart`
# holds `createDeviceLocalPreferences()` and both preference providers.
ALLOWED_DIR='^lib/providers/'

# A line whose first non-space character opens a comment is prose, not a
# construction. Same convention as `scripts/sweep-write-paths.sh`, on purpose:
# plan 03-12 reconciles this gate against that report, and two different ideas
# of what counts as a hit would make the two disagree for no reason.
NOT_A_COMMENT='^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'

# --- allow list ------------------------------------------------------------
# One entry per line, `<path>|<pattern-name>|<reason>`. An unexplained allow
# list is how an invariant becomes decoration, so every entry carries its
# reason inline and names the document that holds the decision.
#
# `lib/providers/theme.dart` is NOT here: it holds four legacy
# `getInstance()` calls, and it is inside `lib/providers/`, so the directory
# rule already covers it. That is a decision, not an oversight — see the sweep
# document §3.6: device-local UI state (`theme_mode`, `color_scheme`), left
# open deliberately.
#
# `lib/pages/dbus_login.dart` is no longer here. Its exemption was spent by
# milestone v1.2 plan 01-06: both of its `getInstance()` calls now read the
# device-local store — the factory in `loadSavedDbusCredentials`, which has no
# `ref`, and `localPreferencesProvider` in `_saveCredentials`, which does.
ALLOW_LIST=(
  # The one-shot import from `shared_preferences` into the relational config
  # store (milestone v1.2, phase 1). It READS the legacy store once, at boot,
  # and writes nothing through it — every write goes to `SqlitePreferences`.
  # There is no `ref` at that point in boot and the factory returns the new
  # store, which is the thing being imported *into*, so neither of the two
  # standard fixes applies. Time-limited by construction: the entry leaves with
  # the `shared_preferences` dependency after the compatibility release
  # (phase 4). Sweep §2.4.
  'lib/core/device_local_store.dart|async|read-only source for the one-shot import; nothing is written through it, and it leaves with the shared_preferences dependency after the compatibility release (Phase 4)'
  # The pre-`runApp` page load (milestone v1.2, phase 3 plan 04). SC-5 asks
  # for the station's layout to come off its local mirror before the first
  # frame, and there is no `ref` before `runApp` — `configStoreProvider` does
  # not exist until the `ProviderScope` is built, which is after the pages are
  # needed. So this is a SECOND handle beside the provider's, and the four
  # things that make it safe are all structural rather than promised: it has
  # no remote attached, so `writeItems` refuses every shared write before it
  # reaches a diff; it is handed to `PageManager` as `store:`, a field whose
  # only use is `itemsOf`; `config.sqlite` is WAL (Phase 1 SC-6), so two
  # handles on one file are fine; and the guard it is missing guards writes,
  # of which this handle performs none. Sweep §3.12.
  'centroid-hmi/lib/main.dart|config|read-only pre-runApp handle for PageManager.load; no remote attached, so it cannot write a shared row, and there is no ref before runApp'
)

allowed() {
  local file="$1" pattern="$2" entry
  for entry in "${ALLOW_LIST[@]}"; do
    [ "${entry%%|*}" = "$file" ] || continue
    local rest="${entry#*|}"
    [ "${rest%%|*}" = "$pattern" ] && return 0
  done
  return 1
}

# Collect hits for one pattern, dropping the allowed directory, comment lines
# and allow-listed files.
hits_for() {
  local regex="$1" pattern="$2" line file
  grep "${GREP_OPTS[@]}" -- "$regex" "${ROOTS[@]}" 2>/dev/null \
    | grep -vE "$ALLOWED_DIR" \
    | grep -vE "$NOT_A_COMMENT" \
    | while IFS= read -r line; do
        file="${line%%:*}"
        allowed "$file" "$pattern" || printf '%s\n' "$line"
      done
}

async_hits="$(hits_for 'SharedPreferencesAsync[[:space:]]*\(' async)"
legacy_hits="$(hits_for 'SharedPreferences\.getInstance[[:space:]]*\(' legacy)"
sqlite_hits="$(hits_for 'SqlitePreferences[[:space:]]*\(' sqlite)"
config_hits="$(hits_for 'ConfigStore[[:space:]]*\(' config)"

if [ -z "$async_hits" ] && [ -z "$legacy_hits" ] && [ -z "$sqlite_hits" ] \
   && [ -z "$config_hits" ]; then
  [ "$quiet" = "1" ] || printf 'check-preferences-construction: clean — the only construction site is in lib/providers/.\n'
  exit 0
fi

{
  printf '\n  ERROR: a configuration store is constructed outside lib/providers/.\n\n'
  if [ -n "$async_hits" ]; then
    printf '  SharedPreferencesAsync() — the constructor spec §6 names:\n\n'
    printf '%s\n' "$async_hits" | sed 's/^/    /'
    printf '\n'
  fi
  if [ -n "$legacy_hits" ]; then
    printf '  SharedPreferences.getInstance() — the legacy API, same store:\n\n'
    printf '%s\n' "$legacy_hits" | sed 's/^/    /'
    printf '\n'
  fi
  if [ -n "$sqlite_hits" ]; then
    printf '  SqlitePreferences() — the SQLite store; construct only behind createDeviceLocalPreferences():\n\n'
    printf '%s\n' "$sqlite_hits" | sed 's/^/    /'
    printf '\n'
  fi
  if [ -n "$config_hits" ]; then
    printf '  ConfigStore() / GuardedConfigStore() — the shared configuration store; read configStoreProvider instead:\n\n'
    printf '%s\n' "$config_hits" | sed 's/^/    /'
    printf '\n'
  fi
  cat <<'EOF'
  A store constructed here is not wrapped by its guard: its writes pass no
  access check and leave no audit row, and nothing about the call site looks
  wrong. See docs/access-control-spec.md §6.

  The fix is one line:

    * a `ref` is in scope (ConsumerWidget, ConsumerState) —
        ref.read(localPreferencesProvider)      // device-local preferences
        ref.read(configStoreProvider.future)    // shared configuration
      This is the better fix: a test can override the provider.

    * no `ref` (a static method, a plain function, anything before runApp) —
        createDeviceLocalPreferences()      // lib/providers/preferences.dart
      There is no factory equivalent for the configuration store, and there
      should not be: it has to be one object per process (its snapshot is what
      every mimic is drawn from), so it is provider-only by design.

  If the site genuinely cannot use either, the allow list at the top of this
  script takes an entry — with its reason, and a row in
  docs/access-control-write-path-sweep.md.
EOF
} >&2

exit 1
