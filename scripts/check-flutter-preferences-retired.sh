#!/usr/bin/env bash
#
# Fail the build when production code reads or writes `flutter_preferences`.
#
# SC-2's code side. Milestone v1.2 moved every shared setting onto `config_item`
# rows (plans 04-05 and 04-11) and 04-12 retired the code that used the old
# table. This gate is what keeps it retired: the table itself survives on a
# plant until somebody runs `bin/drop_flutter_preferences.dart` from the
# runbook, and for as long as it is still there a reintroduced read would work
# perfectly in testing and fail on the day of the drop.
#
# THE ROOTS INCLUDE `packages/*/bin`, AND THAT IS NOT INCIDENTAL. Written as a
# `lib/`-only check, this script passed clean on 2026-09-08 while TWO
# production binaries still read the table — `packages/tfc_dart/bin/main.dart`
# (the acquisition backend's alarm configuration) and
# `packages/tfc_mcp_server/bin/tfc_mcp_server.dart` (the MCP tool toggles,
# which default to ENABLED when the read finds nothing, so the drop would have
# silently opened every tool). A gate whose search path misses the binaries is
# vacuous in the way that matters, and it looks green while being so.
#
# Usage:
#   scripts/check-flutter-preferences-retired.sh [--quiet|--self-test]
#
# Exit codes:
#   0  no production reference outside the allow list
#   1  at least one found — the offending file and line are printed
#   2  the check could not be run (no search roots), or --self-test failed

set -uo pipefail

mode="check"
case "${1:-}" in
  --quiet) mode="quiet" ;;
  --self-test) mode="self-test" ;;
  "") ;;
  -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'check-flutter-preferences-retired: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$repo_root" || exit 2

# Source roots only. `scripts/` is deliberately NOT a root, so this file cannot
# match its own patterns; tests are excluded because a test that seeds the
# legacy table to prove the migration reads it is doing its job, and generated
# drift output is not source anybody wrote.
ROOTS=()
for candidate in lib centroid-hmi/lib packages/*/lib packages/*/bin; do
  [ -d "$candidate" ] && ROOTS+=("$candidate")
done
if [ "${#ROOTS[@]}" -eq 0 ]; then
  printf 'check-flutter-preferences-retired: no search roots under %s\n' "$repo_root" >&2
  exit 2
fi

GREP_OPTS=(-rnE --include=*.dart --exclude=*.g.dart
           --exclude-dir=test --exclude-dir=build --exclude-dir=.dart_tool)

# Both spellings: the raw SQL name and the drift accessor the generated code
# exposes. A check for one of them only would miss half the ways in.
PATTERN='flutter_preferences|flutterPreferences|FlutterPreferences'

# A line whose first non-space character opens a comment is prose, not a
# reference. Same convention as `scripts/check-preferences-construction.sh`,
# deliberately: two different ideas of what counts as a hit would make the two
# gates disagree for no reason.
NOT_A_COMMENT='^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'

# --- allow list ------------------------------------------------------------
# One entry per line, `<path>|<reason>`. An unexplained allow list is how an
# invariant becomes decoration, so every entry carries its reason inline.
#
# Three kinds of survivor, and no fourth kind should ever be added:
#   1. the schema declaration, which must exist while any plant still has the
#      table — the drop tool has to be able to name it, and a database that
#      has not been dropped yet must still open;
#   2. the migrations that read it, which is their whole purpose;
#   3. the drop tool itself.
ALLOW_LIST=(
  'packages/tfc_dart/lib/core/database_drift.dart|the drift table declaration. It must outlive the code that used it: a plant keeps the table until somebody runs the drop tool, and a build whose schema no longer knows about it cannot open that database or drop it. It leaves when the last plant has been dropped, not before'
  'packages/tfc_dart/lib/core/config/preference_migration.dart|04-11: the one-shot copy of the remaining families out of the table into config_item rows. Reading it is what it is for'
  'packages/tfc_dart/lib/core/config/blob_migration.dart|Phases 2 and 3: the key-mappings and pages blob migrations, same reason'
  'packages/tfc_dart/bin/drop_flutter_preferences.dart|the drop tool. It names the table because it removes it'
  'lib/providers/config_store.dart|a LOG MESSAGE, not a read: the line an operator greps for after the drop, which says the table is gone. No SQL, no accessor'
)

allowed() {
  local file="$1" entry
  for entry in "${ALLOW_LIST[@]}"; do
    [ "${entry%%|*}" = "$file" ] && return 0
  done
  return 1
}

# Collect hits, dropping comment lines and allow-listed files.
hits_in() {
  local roots=("$@") line file
  grep "${GREP_OPTS[@]}" -- "$PATTERN" "${roots[@]}" 2>/dev/null \
    | grep -vE "$NOT_A_COMMENT" \
    | while IFS= read -r line; do
        file="${line%%:*}"
        allowed "$file" || printf '%s\n' "$line"
      done
}

# --- self-test -------------------------------------------------------------
# Proves the gate can fail. `check-preferences-construction.sh` once printed
# "clean" while enforcing nothing, because the constructor it watched had
# moved; the lesson is that a gate nobody has watched fail is a gate nobody
# knows works.
if [ "$mode" = "self-test" ]; then
  # TWO plants, and the second one is the point. A `lib/`-only proof re-proves
  # the root this gate always had; what the widened search path added is
  # `packages/*/bin`, and on 2026-09-08 that is where the two real violations
  # were. So the self-test plants in a binary root as well, and requires BOTH
  # to be detected — a search path that quietly lost its `bin` entry fails
  # here rather than going green over a backend that still reads the table.
  bin_root=""
  for root in "${ROOTS[@]}"; do
    case "$root" in */bin) bin_root="$root"; break ;; esac
  done
  if [ -z "$bin_root" ]; then
    printf 'check-flutter-preferences-retired: SELF-TEST FAILED — no ' >&2
    printf 'packages/*/bin root is being searched. The gate cannot see the ' >&2
    printf 'binaries, which is where the last two readers lived.\n' >&2
    exit 2
  fi

  planted_lib="lib/.check_flutter_preferences_retired_selftest.dart"
  planted_bin="$bin_root/.check_flutter_preferences_retired_selftest.dart"
  cleanup() { rm -f "$planted_lib" "$planted_bin"; }
  trap cleanup EXIT
  # Not a comment, and not in the allow list: the two ways a real violation
  # could hide from this gate.
  printf 'final x = db.select(db.flutterPreferences);\n' > "$planted_lib"
  printf 'final y = db.select(db.flutterPreferences);\n' > "$planted_bin"

  all_hits="$(hits_in "${ROOTS[@]}")"
  lib_hits="$(printf '%s\n' "$all_hits" | grep -F "$planted_lib" || true)"
  bin_hits="$(printf '%s\n' "$all_hits" | grep -F "$planted_bin" || true)"
  cleanup
  trap - EXIT
  after_hits="$(hits_in "${ROOTS[@]}" \
    | grep -F -e "$planted_lib" -e "$planted_bin" || true)"

  if [ -z "$lib_hits" ]; then
    printf 'check-flutter-preferences-retired: SELF-TEST FAILED — a planted ' >&2
    printf 'violation in %s was not detected. The gate is vacuous.\n' "$planted_lib" >&2
    exit 2
  fi
  if [ -z "$bin_hits" ]; then
    printf 'check-flutter-preferences-retired: SELF-TEST FAILED — a planted ' >&2
    printf 'violation in %s was not detected. The binary roots are not ' >&2
    printf 'searched, which is the failure this gate was widened to catch.\n' \
      "$planted_bin" >&2
    exit 2
  fi
  # The planted lines must also STOP being reported once removed. Without this
  # half, a self-test would pass against a gate that reported the same hit
  # whatever the tree contained. It asserts the planted paths specifically, and
  # NOT that the whole tree is clean: a real violation elsewhere is what the
  # ordinary run is for, and folding the two together would make this arm fail
  # for a reason that has nothing to do with whether the gate works.
  if [ -n "$after_hits" ]; then
    printf 'check-flutter-preferences-retired: SELF-TEST FAILED — %s is still ' >&2
    printf 'reported after removal.\n' "$after_hits" >&2
    exit 2
  fi
  printf 'check-flutter-preferences-retired: self-test passed — planted '
  printf 'violations in a lib root and a bin root were both detected, and '
  printf 'stopped being reported once removed:\n'
  printf '%s\n%s\n' "$lib_hits" "$bin_hits"
  exit 0
fi

hits="$(hits_in "${ROOTS[@]}")"

if [ -z "$hits" ]; then
  [ "$mode" = "quiet" ] || printf 'check-flutter-preferences-retired: clean — only the schema declaration, the migrations and the drop tool name the table.\n'
  exit 0
fi

{
  printf '\n  ERROR: production code still reaches flutter_preferences.\n\n'
  printf '%s\n' "$hits" | sed 's/^/    /'
  cat <<'EOF'

  The shared settings are `config_item` rows since milestone v1.2 (plans 04-05
  and 04-11). A read here works today, because the table is still on the plant
  as rollback insurance — and stops working the moment somebody runs
  packages/tfc_dart/bin/drop_flutter_preferences.dart from the cutover runbook.
  That is the worst kind of failure: green in every test, broken on the night.

  The fix:

    * a shared setting — read it through `preferencesProvider`
      (SharedRowPreferences), which serves the same keys from rows;
    * a per-station setting — `localPreferencesProvider`;
    * a migration or the drop tool — add an allow-list entry at the top of
      this script WITH ITS REASON.

  If the reference is only a log message, say so in the allow list. Do not
  widen the pattern or the exclusions to make a real read disappear.
EOF
} >&2

exit 1
