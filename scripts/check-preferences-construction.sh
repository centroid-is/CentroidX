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
# TWO patterns, not one. Spec §6 names only `SharedPreferencesAsync()`. The
# legacy synchronous `SharedPreferences.getInstance()` reaches the same
# per-device store and a check written to §6's wording would never see it, so
# it is covered here as well. It is in the tree today — see the allow list.
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
ALLOW_LIST=(
  # Spec §2 excludes this file from the milestone outright: the D-Bus login
  # form is not being changed in this phase. Sweep document §3.7. Two
  # `SharedPreferences.getInstance()` calls writing five bare keys.
  'lib/pages/dbus_login.dart|legacy|spec §2 excludes this file from the milestone (sweep §3.7)'

  # The one-shot import from `shared_preferences` into the relational config
  # store (milestone v1.2, phase 1). It READS the legacy store once, at boot,
  # and writes nothing through it — every write goes to `SqlitePreferences`.
  # There is no `ref` at that point in boot and the factory returns the new
  # store, which is the thing being imported *into*, so neither of the two
  # standard fixes applies. Time-limited by construction: the entry leaves with
  # the `shared_preferences` dependency after the compatibility release
  # (phase 4). Sweep §2.4.
  'lib/core/device_local_store.dart|async|read-only source for the one-shot import; nothing is written through it, and it leaves with the shared_preferences dependency after the compatibility release (Phase 4)'
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

if [ -z "$async_hits" ] && [ -z "$legacy_hits" ]; then
  [ "$quiet" = "1" ] || printf 'check-preferences-construction: clean — the only construction site is in lib/providers/.\n'
  exit 0
fi

{
  printf '\n  ERROR: a device-local preferences store is constructed outside lib/providers/.\n\n'
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
  cat <<'EOF'
  A store constructed here is not wrapped by GuardedPreferences: its writes
  pass no access check and leave no audit row, and nothing about the call
  site looks wrong. See docs/access-control-spec.md §6.

  The fix is one line:

    * a `ref` is in scope (ConsumerWidget, ConsumerState) —
        ref.read(localPreferencesProvider)
      This is the better fix: a test can override the provider.

    * no `ref` (a static method, a plain function, anything before runApp) —
        createDeviceLocalPreferences()      // lib/providers/preferences.dart

  If the site genuinely cannot use either, the allow list at the top of this
  script takes an entry — with its reason, and a row in
  docs/access-control-write-path-sweep.md.
EOF
} >&2

exit 1
