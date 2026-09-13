#!/usr/bin/env bash
#
# Enumerate every path from Dart code in this repository to a persistent store.
#
# Why this exists: `docs/access-control-spec.md` §6 lists the write paths that
# bypass `StateMan.write` and `PreferencesApi.set*` — the two interfaces the
# Phase 3 guards wrap. That list was written as three. A fourth of exactly the
# same shape (the history view's Drift deletes) had been sitting in the tree the
# whole time and was found only because somebody read an unrelated comment and
# checked one claim. §6 now says outright: assume there is a fifth. This script
# is what stops the next person having to take that on trust.
#
# It is a REPORT, not a gate. It exits 0 whether it finds one site or a hundred,
# and it is *expected* to find legitimate ones — the guards themselves,
# `DriftAuditSink` (append-only by design), the preference providers, the store
# implementations in `packages/tfc_dart/lib/core/`. Finding a site is not a
# defect; a site with no verdict is. `docs/access-control-write-path-sweep.md`
# is where each hit gets its verdict. Plan 03-11 turns a subset of section 4
# into a CI gate; plan 03-12 re-runs this script and asserts every hit still has
# a row in that document.
#
# Two design rules, both bought with real mistakes:
#
#   * SEARCH FOR THE THING, NOT FOR ITS SPELLING. The two history-view deletes
#     go through different accessors — `adb.deleteHistoryView(...)` and
#     `dbWrap.db.deleteHistoryViewPeriod(...)` — so a grep keyed on the receiver
#     name finds one and misses the other. Section 1 therefore searches the
#     *method names* declared on `AppDatabase`, and section 3 searches the
#     *type* `AppDatabase` and the `.db` accessor, not `adb` or `dbWrap`.
#
#   * USE THE SAME ROOTS EVERYWHERE. Section 9 covers `lib` and `packages/*/lib`
#     exactly like sections 1-8. Hand-naming a couple of files there is how
#     `packages/tfc_mcp_server/lib/src/tools/read_toggles.dart:38` escaped the
#     first pass.
#
# Two output conventions, so nothing is hidden without saying so:
#
#   * Lines whose first non-space character starts a comment (`//`, `/*`, `*`)
#     are dropped. A comment is not a call. This is why
#     `centroid-hmi/lib/main.dart:449`, which quotes `adb.deleteHistoryView`
#     inside a note, does not appear as a site.
#   * Hits in generated files (`*.g.dart`, `*.freezed.dart`, `*.gen.dart`) are
#     collapsed to one `[generated] <file> (N occurrences ...)` line per file
#     rather than listed. Generated code is regenerated from a source file that
#     IS searched here, and drift's `database_drift.g.dart` alone carries 179
#     mentions of `AppDatabase`. The count is still printed, so a generated file
#     that suddenly acquires hits in an unexpected section is visible.
#
# Both conventions are limits on the search, and both are restated in section 6
# of the sweep document. Nothing in this script proves a site is unreachable
# from a widget; it finds the sites, and a human writes the reasoning.
#
# Usage:
#   scripts/sweep-write-paths.sh
#
# Exit codes:
#   0  the report was produced (always, when it could run)
#   2  the search roots could not be located

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$repo_root"

# The same roots for every section. `test`, `build` and `.dart_tool` are
# excluded: a test that writes a store is a test, and build output is not
# source. `scripts/` is deliberately not a root, so this file cannot match
# itself.
ROOTS=()
for candidate in lib centroid-hmi/lib demo packages/*/lib; do
  [ -d "$candidate" ] && ROOTS+=("$candidate")
done
if [ "${#ROOTS[@]}" -eq 0 ]; then
  printf 'sweep-write-paths: no search roots found under %s\n' "$repo_root" >&2
  exit 2
fi

GREP_OPTS=(-rnE --include=*.dart --exclude-dir=test --exclude-dir=build --exclude-dir=.dart_tool)

# A comment is not a call.
NOT_A_COMMENT='^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'
GENERATED='\.(g|freezed|gen)\.dart:'

search() {
  grep "${GREP_OPTS[@]}" -- "$1" "${ROOTS[@]}" 2>/dev/null | grep -vE "$NOT_A_COMMENT" || true
}

# Print the hits on stdin, then the collapsed generated-file summary, then a
# count line. `(none)` when a section found nothing: an empty section must be
# visibly empty, not absent.
report() {
  local hits generated plain plain_count gen_files gen_total
  hits="$(cat)"

  plain="$(printf '%s\n' "$hits" | grep -vE "$GENERATED" || true)"
  generated="$(printf '%s\n' "$hits" | grep -E "$GENERATED" || true)"

  if [ -n "$plain" ]; then
    printf '%s\n' "$plain"
    plain_count="$(printf '%s\n' "$plain" | wc -l | tr -d ' ')"
  else
    plain_count=0
  fi

  gen_total=0
  if [ -n "$generated" ]; then
    gen_files="$(printf '%s\n' "$generated" | sed 's/:[0-9]*:.*//' | sort -u)"
    while IFS= read -r gf; do
      [ -n "$gf" ] || continue
      local n
      n="$(printf '%s\n' "$generated" | grep -cF "$gf:" || true)"
      printf '  [generated] %s (%s occurrences, not listed)\n' "$gf" "$n"
      gen_total=$((gen_total + n))
    done <<<"$gen_files"
  fi

  if [ "$plain_count" -eq 0 ] && [ "$gen_total" -eq 0 ]; then
    printf '(none)\n'
  fi
  if [ "$gen_total" -gt 0 ]; then
    printf -- '-- %s hits (plus %s collapsed occurrences in generated files)\n' \
      "$plain_count" "$gen_total"
  else
    printf -- '-- %s hits\n' "$plain_count"
  fi
}

# Show the command a reader would run to reproduce the section.
cmd() {
  # The patterns below contain no single quotes, so quoting them this way is
  # exact: the printed line is runnable as written.
  printf "\$ grep -rnE --include='*.dart' '%s' %s\n" "$1" "${ROOTS[*]}"
}

# Section 9's `set*` calls are frequently split across lines, and the key
# expression — the whole reason that section prints call lines rather than
# file:line — lands on the continuation. Fold up to two continuation lines onto
# the hit so the key stays readable in one line of output.
with_continuation() {
  local hit file rest lineno content trimmed out nxt n extra
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"
    out="$hit"
    trimmed="$(printf '%s' "$content" | sed 's/[[:space:]]*$//')"
    n="$lineno"
    extra=0
    while [ "$extra" -lt 2 ]; do
      case "$trimmed" in
        *'(' | *',') ;;
        *) break ;;
      esac
      n=$((n + 1))
      nxt="$(sed -n "${n}p" "$file" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$nxt" ] || break
      out="$out ~> $nxt"
      trimmed="$nxt"
      extra=$((extra + 1))
    done
    printf '%s\n' "$out"
  done
}

printf '# Write-path sweep\n'
printf '#\n'
printf '# Generated by scripts/sweep-write-paths.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '# Roots: %s\n' "${ROOTS[*]}"
printf '# Verdicts live in docs/access-control-write-path-sweep.md.\n'
printf '# This is a report, not a gate. Finding a site is not a defect;\n'
printf '# a site with no verdict is.\n'
printf '\n'

# ---------------------------------------------------------------------------
S1='\b(createHistoryView|updateHistoryView|deleteHistoryView|addHistoryViewPeriod|deleteHistoryViewPeriod|createTable|updateRetentionPolicy)[[:space:]]*\('
printf '## 1. Named Drift write helpers on AppDatabase\n'
printf '#\n'
printf '# The seven public write methods declared on `AppDatabase`\n'
printf '# (packages/tfc_dart/lib/core/database_drift.dart:698, 742, 785, 845,\n'
printf '# 855, 898, 1116), searched BY NAME so an unusual receiver spelling\n'
printf '# cannot hide one. Declarations appear alongside call sites on purpose:\n'
printf '# the reader should see what is being searched for.\n'
printf '# `createTable` is also the name of drift`s Migrator method, so schema\n'
printf '# migration calls land here too; they are a different method of the same\n'
printf '# name and the document says so rather than the grep guessing.\n'
cmd "$S1"
search "$S1" | report
printf '\n'

# ---------------------------------------------------------------------------
S2='(\binto\(|\.delete\(|\.update\(|\bcustomStatement\(|\bcustomUpdate\(|\bcustomInsert\(|\.batch\(|\.go\(\)|\binsertOnConflictUpdate\(|\bwriteReturning\(|\bdeleteAll\(|\breplace\()'
printf '## 2. Raw Drift statement API\n'
printf '#\n'
printf '# The statement builders a caller reaches for when it skips the named\n'
printf '# helpers entirely — this is the shape of spec §6 bypass 1\n'
printf '# (`ServerConfigDb.publish()`/`.remove()`). Deliberately broad: it also\n'
printf '# catches `.update(` / `.delete(` on things that are not databases at\n'
printf '# all (NetworkManager connections, maps), which the document sorts out.\n'
cmd "$S2"
search "$S2" | report
printf '\n'

# ---------------------------------------------------------------------------
S3='(\bAppDatabase\b|[A-Za-z0-9_]+(\!|\?)?\.db\b)'
printf '## 3. AppDatabase handles and the `.db` accessor\n'
printf '#\n'
printf '# Every mention of the TYPE, and every `.db` accessor, rather than the\n'
printf '# accessor spellings `adb` and `dbWrap.db` that spec §6 quotes. Those two\n'
printf '# are why this section exists: they are two names for the same handle in\n'
printf '# one file, and a grep for either finds only half the deletes. A new\n'
printf '# accessor name shows up here the first time it appears.\n'
cmd "$S3"
search "$S3" | report
printf '\n'

# ---------------------------------------------------------------------------
S4='(SharedPreferencesAsync|SqlitePreferences|ConfigStore)[[:space:]]*\('
printf '## 4. A device-local store — constructed, not injected\n'
printf '#\n'
printf '# The constructor spec §6 names in its CI check: nothing outside\n'
printf '# `lib/providers/` may construct one. Every hit outside that directory is\n'
printf '# a store a widget owns privately, which no decorator can wrap.\n'
printf '#\n'
printf '# TWO constructors, because the store changed under the rule. Milestone\n'
printf '# v1.2 replaced `shared_preferences` with `SqlitePreferences`, so a\n'
printf '# section that watched only the old name would report an empty, healthy\n'
printf '# looking column while every device-local store in the app was built\n'
printf '# somewhere it could not see. The rule is about ownership, not about\n'
printf '# which package holds the bytes.\n'
printf '#\n'
printf '# THREE now. Milestone v1.2 phase 2 added `ConfigStore` — the SHARED\n'
printf '# configuration store, one row per key mapping — which is the same\n'
printf '# ownership rule over a store whose writes land on every station rather\n'
printf '# than on this one. The pattern also matches `GuardedConfigStore(`,\n'
printf '# deliberately: hand-wiring the guard outside `lib/providers/` means\n'
printf '# hand-picking the session, policy and audit sink it checks against.\n'
printf '# The enforced subset of this section is\n'
printf '# `scripts/check-preferences-construction.sh`, and it carries the same\n'
printf '# four patterns — a section here the gate does not enforce is how the\n'
printf '# two drift apart.\n'
cmd "$S4"
search "$S4" | report
printf '\n'

# ---------------------------------------------------------------------------
S5='SharedPreferences\.getInstance[[:space:]]*\('
printf '## 5. Legacy synchronous shared preferences\n'
printf '#\n'
printf '# The pre-`Async` API. Spec §6 does not mention it and the CI check it\n'
printf '# asks for would never catch it.\n'
printf '#\n'
printf '# EMPTY SINCE MILESTONE v1.2 PLAN 01-06, which moved the last six calls\n'
printf '# (`providers/theme.dart` and `pages/dbus_login.dart`) onto the\n'
printf '# device-local store. The section stays because `shared_preferences` is\n'
printf '# still a readable dependency for one release, so a regression to this\n'
printf '# API is still possible; it leaves with the package in Phase 4.\n'
cmd "$S5"
search "$S5" | report
printf '\n'

# ---------------------------------------------------------------------------
S6='(\bSecureStorage\b|\bMySecureStorage\b|\.write\(key:)'
printf '## 6. Secure storage\n'
printf '#\n'
printf '# Where `state_man_config`, the database config and the D-Bus password\n'
printf '# actually live. Neither guard covers this store; it is reached through\n'
printf '# `SecureStorage.getInstance()`, a process-wide singleton.\n'
cmd "$S6"
search "$S6" | report
printf '\n'

# ---------------------------------------------------------------------------
S7='(\bwriteAsString|\bwriteAsBytes|\.openWrite\()'
printf '## 7. File writes\n'
printf '#\n'
printf '# Config export and anything else that persists outside a database.\n'
cmd "$S7"
search "$S7" | report
printf '\n'

# ---------------------------------------------------------------------------
S8='(\bcallSet[A-Z][A-Za-z0-9_]*\(|\bHostname1\b|\baddAndActivateConnection\(|\bactivateConnection\(|\bdeactivateConnection\(|\baddConnection\(|\bNetworkManagerClient\b)'
printf '## 8. D-Bus — network and hostname\n'
printf '#\n'
printf '# Spec §6 bypass 3. The D-Bus call itself stays as it is; Phase 2 gated\n'
printf '# `/advanced/ip-settings` at the route. This section exists so that\n'
printf '# bypass is visibly accounted for rather than assumed.\n'
cmd "$S8"
search "$S8" | report
printf '\n'

# ---------------------------------------------------------------------------
S9A='\.(setString|setBool|setInt|setDouble|setStringList)[[:space:]]*\('
S9B='[A-Za-z0-9_]*([Pp]ref|[Pp]refs|[Pp]references)[A-Za-z0-9_]*(\!|\?)?\.(remove|clear)[[:space:]]*\('
S9C='[A-Za-z0-9_]+(\!|\?)?\.(remove|clear)[[:space:]]*\('
printf '## 9. Writes through the injected preferences interface\n'
printf '#\n'
printf '# The shape a construction search and a Drift search both produce NO hit\n'
printf '# for, and the majority of config writes in this repo. These are not\n'
printf '# bypasses — they are the surface plan 03-01 classifies. Section 5 of the\n'
printf '# sweep document reconciles every key expression below against\n'
printf '# `kPrefAccessRules`, because a key with no rule falls through to the\n'
printf '# `administer` default and breaks in normal operation.\n'
printf '# Roots are the same as sections 1-8: `lib` AND `packages/*/lib`.\n'
printf '# The call line is printed, not just file:line, because the keys are\n'
printf '# constants (`storageKey`) and interpolations (`\x27${keyPrefix}$id\x27`)\n'
printf '# and a file:line alone says nothing about which key is at risk.\n'
printf '# Calls split across lines are folded with ` ~> ` so the key stays visible.\n'
printf '\n'
printf '### 9a. setString / setBool / setInt / setDouble / setStringList\n'
printf '#\n'
printf '# Unfiltered. These five names are not carried by any non-preference\n'
printf '# receiver in this tree, so no receiver filter is applied and none is\n'
printf '# needed.\n'
cmd "$S9A"
search "$S9A" | with_continuation | report
printf '\n'
printf '### 9b. remove / clear on a preference-shaped receiver\n'
printf '#\n'
printf '# `remove` and `clear` ARE carried by every collection in the language, so\n'
printf '# these two are matched on receivers spelled `pref`/`prefs`/`preferences`.\n'
printf '# That is a filter on spelling, which is the failure mode this whole\n'
printf '# script is built against — so 9c prints the census of everything the\n'
printf '# filter dropped rather than discarding it silently.\n'
cmd "$S9B"
search "$S9B" | report
printf '\n'
printf '### 9c. remove / clear — census of the receivers 9b dropped\n'
printf '#\n'
printf '# Not sites, and not individually inspected: the distinct receiver\n'
printf '# spellings and their counts, so a reader can scan for anything that\n'
printf '# could be a preferences handle under another name (a `PreferencesApi`\n'
printf '# held in a field called `_store` would hide from 9b and show up here).\n'
cmd "$S9C"
census="$(search "$S9C" \
  | grep -vE "$S9B" \
  | grep -oE "$S9C" \
  | sed -E 's/[!?]*\.(remove|clear).*//' \
  | sort | uniq -c | sort -rn || true)"
if [ -n "$census" ]; then
  printf '%s\n' "$census" | sed 's/^/  /'
  printf -- '-- %s distinct receivers, %s calls\n' \
    "$(printf '%s\n' "$census" | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$census" | awk '{s+=$1} END {print s+0}')"
else
  printf '(none)\n'
  printf -- '-- 0 distinct receivers, 0 calls\n'
fi
printf '\n'

# ---------------------------------------------------------------------------
S10='(\.(saveKeyMappings|writeKeyMappings|seedDefaultIfEmpty)[[:space:]]*\(|\.save\([^)]*kind:)'
printf '## 10. Writes through the shared configuration store\n'
printf '#\n'
printf '# New in milestone v1.2 phase 2. The plant wiring left\n'
printf '# `flutter_preferences.key_mappings` for one `config_item` row per key,\n'
printf '# and with it left every pattern above: a `saveKeyMappings` call is not a\n'
printf '# `setString`, carries no key literal, and touches no Drift API at the\n'
printf '# call site. Without this section the sweep would have watched\n'
printf '# `key_repository.dart` and `page_creator/assets/common.dart` go quiet\n'
printf '# and reported it as progress, while the most consequential writes in\n'
printf '# the app carried on through a path it could not see. That is the\n'
printf '# failure this whole script is built against, arriving by migration\n'
printf '# rather than by deletion.\n'
printf '#\n'
printf '# The pattern names the store methods rather than matching a bare\n'
printf '# `save(` — which is the filter-on-spelling this script otherwise\n'
printf '# refuses, and it is a deliberate exception: `canvas.save()` appears in\n'
printf '# every painter in `lib/painter/`, so a broad pattern would bury the\n'
printf '# handful of real hits under several hundred graphics calls and the\n'
printf '# section would be read past. The kind-generic `save(..., kind:)` is\n'
printf '# matched where the call fits on one line; where it does not, the\n'
printf '# delegation through `saveKeyMappings` is what shows up, which is the\n'
printf '# same file. WHEN PHASE 3 ADDS PAGE AND ASSET WRITES, add their\n'
printf '# spellings here — a call site this pattern does not name is a\n'
printf '# configuration write with no verdict.\n'
printf '#\n'
printf '# Section 4 covers construction of the store; this covers writes through\n'
printf '# it.\n'
cmd "$S10"
search "$S10" | report
printf '\n'

exit 0
