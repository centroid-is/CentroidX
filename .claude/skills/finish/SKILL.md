---
name: finish
description: Finish development work on CentroidX (tfc-hmi) — validate, golden every UI change and inspect the PNGs, open a PR with the goldens embedded in the description, then watch CI until it is green, investigating anything that hangs past its known-good duration.
---

# CentroidX Finish

Ships the work sitting in the current CentroidX worktree: validation → goldens
→ PR with images → green CI. Run from inside the worktree branch created by
`/begin`.

## Usage

```
/finish
```

## Global watchdog rule

**Nothing in this pipeline is allowed to silently take longer than its
known-good duration.** Know the baselines before calling anything hung:

| Step | Known-good |
|---|---|
| CI `flutter-test (macos-latest)` — the only job that compares goldens | **18–20 min** |
| CI `flutter-test (ubuntu-latest)` | ~9 min |
| Any local suite | < 10 min |

For every long-running step (local test run, `gh pr checks --watch`,
background task):

- Give local Bash commands an explicit timeout via the Bash tool's `timeout`
  parameter (10 min is generous for any local suite here). On this macOS/fish
  setup do NOT use the `timeout` *shell* command — it does not exist there, and
  prefixing a background watch with it silently kills the watch.
- When watching CI, compare against `main` rather than against a remembered
  number before declaring a job stuck:

  ```bash
  gh run list --workflow="Flutter Tests" --branch main --limit 3 --json databaseId --jq '.[].databaseId' \
    | while read -r r; do
        gh run view "$r" --json jobs \
          --jq '.jobs[]|select(.name|test("flutter-test \\(macos"))|"\(.conclusion) \(.startedAt) \(.completedAt)"'
      done
  ```

  If it is past that and you still suspect a hang: `gh run view <run-id>` — is
  it queued (runner starvation → wait or `gh run rerun`), or running? A live
  step name means it is working, not wedged:
  `gh api repos/centroid-is/CentroidX/actions/jobs/<id> --jq '.steps[]|select(.status!="completed")|.name'`.
  Job logs 404 while a run is in progress — that is not a dead job either.
- Never declare "still waiting" twice in a row for the same step without
  having looked at *why*.

## Phase 1: Validate locally

Cheap first, broad after:

```bash
./scripts/check-flutter-version.sh
flutter analyze <changed files and their tests>
flutter test <test files covering the touched areas>
```

The version check comes first because everything after it is only as
trustworthy as the SDK that ran it. If it fails, stop and say so — see Phase 2.

If the change is broad (shared widgets, providers, tfc_dart), run the full
suite: `flutter test test/` and `cd packages/tfc_dart && dart test
--exclude-tags=integration`. If codegen inputs changed, re-run build_runner
before analyzing. Report failures with file:line; fix before continuing.

## Phase 2: Goldens for every UI change

Every visual change needs a golden test, and every golden PNG must be
**inspected by eye** (Read the PNG file) before shipping — checking that it
merely "passes" is not review.

- Follow the repo patterns: macOS skip guard
  (`skip: !Platform.isMacOS ...`), goldens in the test dir's `goldens/`.
  `dart_test.yaml` skips the `golden` tag only on Linux/Windows via `on_os:`,
  so macOS runs them either way — `--run-skipped` is obsolete here, and its
  absence is never why a suite ran nothing.
- **Text in the golden?** Load a real font or every glyph renders as a solid
  box — copy `loadRealFont()` from
  `test/page_creator/assets/third_party_golden_test.dart` (RobotoMono from
  `lib/fonts/`, registered as 'Roboto').
- **Never generate a golden on a Flutter that is not the pinned one.** Run
  `./scripts/check-flutter-version.sh` first; if it fails, stop and say so
  rather than shipping an image CI will not reproduce. The pinned SDK lives at
  `~/flutter-sdks/$(cat .flutter-version)` — put it first on `PATH`:
  `export PATH="$HOME/flutter-sdks/$(cat .flutter-version)/bin:$PATH"`, then
  re-run `flutter pub get`. It is per-shell and does not persist.

  The 0.01% tolerance in `test/helpers/golden_tolerance.dart` absorbs drift
  nobody caused. It does **not** make an off-version golden safe: one can land
  just inside it and pass, leaving the next person an image already most of the
  way to failing. This has cost real time twice — a stale golden reddened
  `main` and blocked six PRs, and a full local suite went green on an assertion
  that does not exist in the older SDK.
- **Full-app-surface golden?** A large surface has more room to drift than the
  0.01% default allows for even on the right SDK. Call
  `useTolerantGoldenComparator(tolerance: 0.002)` in that test file's `main()`
  and say why in a comment.
- **Derive the failing set before regenerating.**
  `flutter test --update-goldens <file>` rewrites **every** golden that file
  produces, including passing ones — on a shared-widget change that silently
  re-baselines dozens of images on this machine's raster. Run the suite plain
  first and collect the failures (`flutter test test/ --reporter=json`,
  `testDone` events where `result != "success"`), then regenerate and check the
  changed-PNG count equals the failing-test count. If it is higher,
  `git checkout --` the surplus.
- Generate: `flutter test --update-goldens <golden test file>`
- Verify it passes WITHOUT `--update-goldens` afterwards.
- Read each new/changed PNG and confirm it shows what the change claims.
  While looking, also check repo conventions: muted state colors, forced =
  orange, panes show values not key names.

## Phase 3: Commit and push

Conventional-commit style matching the log (`feat(scope): lower-case
summary`), body explaining why not what, footer:

```
Co-Authored-By: Claude <the model's co-author line>
```

```bash
git push -u origin <branch>
```

## Phase 4: PR with goldens in the description

```bash
gh pr create --title "<same as commit summary>" --body "..."
```

Body structure:

```markdown
## Summary
<what changed and why, honest about behavioural assumptions>

## Golden
<one line saying what the image shows>
![<name>](https://github.com/centroid-is/CentroidX/raw/<commit-sha>/<path-to-golden>.png)

## Testing
<new tests, suites run, counts>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Embed **every** golden that illustrates the change, using a **commit-SHA URL,
never a branch URL**. GitHub proxies images through camo and caches them by
URL: after a force-push the branch URL is byte-identical, so the reader keeps
seeing the OLD image — this shipped stale panes to reviewers on PR #382. SHA
URLs also survive branch deletion on merge. Re-pin on every force-push, and
verify before claiming the images are right:

```bash
curl -sL -H "Authorization: token $(gh auth token)" "<url>" | md5 -q   # == md5 -q <local png>
```

## Phase 5: Watch CI until green

```bash
gh pr checks <number> --watch --interval 60
```

Run it in the background and apply the watchdog rule above. On any failure:

1. Pull the log: `gh run view --job <job-id> --log-failed`, or if the run is
   still in progress
   `gh api repos/centroid-is/CentroidX/actions/jobs/<job-id>/logs`.
2. Diagnose honestly — is it this change? Known repo failure modes:
   - **Golden pixel drift on `flutter-test (macos-latest)`**: CI pins a
     different Flutter than local; small drift on a big golden. Fix with
     per-file tolerance (Phase 2), not by regenerating blindly.
   - Goldens only compare on macOS — a green ubuntu/windows run says nothing
     about them.
3. Fix in the worktree, re-run the affected tests locally, push, and watch
   again.

Do not stop until every check is green (or a failure is proven pre-existing
on `main` — then say so explicitly in the PR and to the user).

## Phase 6: Report

Final message: PR URL, check status, what the goldens show, and anything the
reviewer must know (assumptions, skipped areas, pre-existing failures).
