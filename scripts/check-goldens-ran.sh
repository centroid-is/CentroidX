#!/usr/bin/env bash
#
# Asserts that golden tests were skipped on exactly the platforms they should
# have been, and ran on the one they should have run on.
#
# The failure mode this exists for is silent. Goldens are gated by
# `test/helpers/golden_platform.dart`, which is one line deciding the reference
# platform for 62 test files. Invert it, point it at a platform no CI job uses,
# or let a merge drop the import, and every golden in the repository stops
# being compared -- on every runner, with every job still green. That is the
# same defect that left packages/jbtm's 227 tests unrun for five months, and
# centroid-hmi's 15 navigation tests unrun since they were written.
#
# So: on the reference platform, no test may carry the golden skip reason. On
# the others, a healthy number must. Checking both directions is what makes
# this more than a tautology -- a guard that only asserted "none skipped here"
# would pass just as happily if the tests had stopped existing.
set -euo pipefail

REPORT="${1:-test-report.json}"
[ -f "$REPORT" ] || { echo "::error::$REPORT not found — the test step never produced a report"; exit 1; }

python3 - "$REPORT" <<'PY'
import json, os, sys

report = sys.argv[1]
skipped, ran = 0, 0
stale = []
with open(report, encoding='utf-8') as fh:
    for line in fh:
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get('type') != 'testStart':
            continue
        t = ev.get('test', {})
        name = t.get('name', '')
        if name.startswith('loading '):
            continue
        ran += 1
        reason = (t.get('metadata') or {}).get('skipReason') or ''
        if 'rendered on Linux' in reason:
            skipped += 1
        # A file that predates the shared guard, or one written from an older
        # file as a template, carries its own reason string instead. Counting
        # only the shared one made those invisible here: they skipped on Linux
        # and this script still printed "ok", which is precisely the silent
        # defect it exists to catch. Two report golden files sat in that state
        # after the reference platform moved (#507 then #447), so this is a
        # fixed bug, not a hypothetical.
        elif 'only run on' in reason and 'olden' in reason:
            stale.append(name)

# `runner.os` is not set outside GitHub Actions; fall back to the platform so
# the script is runnable by hand.
os_name = os.environ.get('RUNNER_OS') or (
    'Linux' if sys.platform.startswith('linux')
    else 'macOS' if sys.platform == 'darwin' else 'Windows')

print(f"{os_name}: {ran} tests reported, {skipped} skipped as golden")

# 62 files carry the guard, most with several goldens each; on a non-reference
# platform the skip count is in the hundreds. The floor is deliberately far
# below that -- it catches the guard collapsing, not the suite growing.
FLOOR = 60

if stale:
    sys.exit(f"::error::{len(stale)} golden test(s) carry a hand-written skip "
             f"reason instead of goldenSkip from "
             f"test/helpers/golden_platform.dart, so they follow their own "
             f"idea of the reference platform and this check cannot see them: "
             f"{stale[:5]}")

if os_name == 'Linux':
    if skipped:
        sys.exit(f"::error::{skipped} golden tests were SKIPPED on Linux, the "
                 f"platform that is supposed to render them. "
                 f"Check goldenSkip in test/helpers/golden_platform.dart.")
    print("ok: goldens were compared on the reference platform")
else:
    if skipped < FLOOR:
        sys.exit(f"::error::only {skipped} golden tests were skipped on "
                 f"{os_name}, expected >={FLOOR}. Either the guard in "
                 f"test/helpers/golden_platform.dart stopped applying, or the "
                 f"golden tests have stopped existing — both mean the goldens "
                 f"are no longer being checked anywhere.")
    print(f"ok: {skipped} goldens correctly deferred to the Linux runner")
PY
