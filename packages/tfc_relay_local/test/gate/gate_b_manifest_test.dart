/// Properties of *resilience gate B as a whole*, which no gate case can
/// assert about itself.
///
/// **Copied from `packages/tfc_relay_client/test/gate/gate_manifest_test.dart`
/// (gate A's manifest), deliberately, not imported.** The sweep's functions
/// are private and un-importable across packages, and extracting them into
/// `tfc_stateman_contract/lib/testing/` would refactor a just-frozen,
/// load-bearing artifact to serve a second consumer — which is a change to
/// Phase 7's evidence made in Phase 9. This is 07-01's own precedent, which
/// re-implemented `platform_skip_audit_test.dart`'s skip rules rather than
/// importing them and wrote down why. Where a mechanism below has a reason,
/// the reason is restated rather than pointed at, so this file survives the
/// original moving.
///
/// **No row without a case, no case without a row.** `f_row_registry.dart`
/// beside this file names seven catalogue rows (F22-F28) and this phase
/// claims each one is either judged by a case in this directory or owed by a
/// named plan. That claim is a property of the directory, so it is asserted
/// here in both directions: a row nobody exercises is a hostile plant
/// condition nobody is testing, sitting in the repository looking like
/// coverage, and a case naming a row the registry does not declare is a case
/// that will never be reached from the list an auditor reads.
///
/// **How cases are discovered, and why the choice matters.** By reading the
/// `test(...)` names out of each file's source and matching them against a
/// grammar — not by matching a filename, and not by looking for the row id
/// anywhere in the file. Prose about a row is what a file has instead of a
/// test for it.
///
/// **This is gate B's manifest, not an extension of gate A's.** Gate A's
/// `_declaredRows = 27`, its empty-outstanding assertion and its strangers
/// arm are Phase 7's closing condition; the two gates reconcile here by one
/// **text read** of gate A's registry, direction B→A only. Gate A is never
/// imported, never edited, and never learns this package exists — it must
/// stay buildable and testable alone.
///
/// **The directory is read as text, never imported.** The sweep reads case
/// files with `readAsStringSync` and imports nothing from them: importing
/// couples the sweep to the names most likely to change, and then a rename
/// breaks the audit rather than being audited by it.
///
/// **A sweep that stops looking reports full coverage of nothing.** So
/// [_cases] takes its directory as an argument, one case points it at an
/// empty temp directory and asserts zero, another points it at a temp
/// directory holding a single fabricated case and asserts it finds exactly
/// that one, and the "the matchers match" group holds every pattern in this
/// file against a sample of the thing it is looking for. That last group is
/// what stops this file being a decoration during the waves when this
/// `test/gate/` is still filling up: on the day it lands, every content arm
/// below has nothing to judge, and an arm with nothing to judge is
/// indistinguishable from a broken one.
///
/// **The counts live here, not in the registry.** [_declaredRows] and
/// [_declaredDeviations] are written down in this file on purpose. A sweep
/// that derives both sides of its comparison from the same source asserts
/// nothing — a row deleted from `gateRows` takes its outstanding entry and
/// its deviations with it and every in-file count still agrees with itself.
/// These two numbers are the only place the deletion is visible.
///
/// **The lane budget.** The gate lane is slower than every other lane in this
/// package by design. The budget exists so that "slower by design" cannot
/// drift into "nobody runs it". Measuring it means running the lane, which
/// costs the lane's whole runtime again, so it is opt-in behind
/// [_laneBudgetEnvVar] — on by name on one CI job, skipped by name everywhere
/// else, never silently.
@TestOn('vm')
@Tags(['gate', 'meta'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'f_row_registry.dart';

/// Where gate B's cases live, relative to the package root — which is the
/// working directory `dart test` runs from.
const _gateDir = 'test/gate';

/// How many rows this registry is claimed to hold, and how many clauses the
/// phase's green is claimed not to cover.
///
/// Written down here rather than read from `f_row_registry.dart`, because a
/// sweep that derives both sides of its comparison from the same source
/// asserts nothing. A row deleted from `gateRows` deletes its own outstanding
/// entry and its own deviations in the same edit, and every in-file count
/// still agrees with itself. These two numbers are the only place the
/// deletion is visible.
///
/// [_declaredDeviations] is a floor rather than an equality: 09-PLAN-INDEX
/// expects the registry to close at eight (nine if the historian fallback is
/// taken), with 09-05 and 09-09 appending their own and moving this number in
/// the same commit. Seven is what 09-01 seeds, and a *shrinking* registry is
/// the failure worth catching — a deviation deleted without saying what now
/// asserts the clause is the gate quietly widening its own promise.
const _declaredRows = 7;
const _declaredDeviations = 8;

/// Gate A's registry, reached by relative path from this package's root and
/// read as **text** — the same crossing `no_retry_test.dart:182-293` makes
/// into `../tfc_relay_server/lib`. Never imported: no `package:` URI reaches
/// another package's `test/` directory, and an import would couple Phase 7's
/// closed evidence to this package's build.
const _gateARegistry = '../tfc_relay_client/test/gate/f_row_registry.dart';

/// How many rows gate A's registry declares. Written down HERE, in a second
/// file in a second package, so the reconciliation compares two independent
/// records: gate A's `_declaredRows = 27` is Phase 7's tripwire, this is
/// Phase 9's. If either moves, the catalogue changed size and that is a
/// finding, not a constant to adjust.
const _gateARows = 27;

/// The whole gate-B lane's declared wall-clock budget.
///
/// Eight minutes, matching gate A's, deliberately slack against a loaded
/// shared runner: the number this bound is watching for is not the estimated
/// ~270 s, it is the day somebody adds a row that waits sixty seconds.
/// **Report it, never raise it.**
const _laneBudget = Duration(minutes: 8);

/// Set this to any non-empty value to actually run and time the lane.
///
/// `GATE_B_LANE_BUDGET`, not `GATE_LANE_BUDGET`: the two lanes are measured
/// separately, in different packages, so a future cost jump is attributable
/// to a phase rather than to "the gates".
const _laneBudgetEnvVar = 'GATE_B_LANE_BUDGET';

/// Shortest acceptable skip reason, in characters.
///
/// Forty characters forces at least a clause about the capability and a
/// clause about the consequence; `'not supported on windows'` is twenty-four
/// and sends the next engineer to read the source to find out what they lost.
const _skipReasonFloor = 40;

/// Shortest acceptable reason for a deviation or a supporting-case exemption.
///
/// Higher than [_skipReasonFloor], because a skip says "this platform cannot
/// run this" and a deviation says "this gate does not promise this". The
/// second needs the measurement or the ruling that made it: a descope with a
/// number is a finding, one without is an excuse.
const _deviationReasonFloor = 60;

/// Where a deviation may send a clause — this manifest's own copy of the
/// registry's [followUpDestinations], written down twice for the same reason
/// the row count is: a destination pruned from the registry deletes itself
/// from both sides of a one-source comparison, and this literal is the only
/// place the pruning shows.
///
/// `'Phase 10'` and `'Phase 11'` have zero users among the seven seeded
/// deviations and stay anyway (the registry's doc says why: cheaper to carry
/// the destination now than to reopen this closed set when a later wave or
/// Phase 11's soak defers a clause there). Do not prune them here either.
const _followUpDestinations = <String>{
  'Phase 10',
  'Phase 11',
  'post-milestone',
  'app-side (AlarmMan)',
  'none — accepted',
};

/// The three texts a deviation may quote its clause from. A closed set: a
/// `source` outside it names no text, so the clause it carries is checkable
/// against nothing.
const _deviationSources = <String>{'expectation', 'injection', 'prose'};

/// Getters whose value is derived from a wall clock, and must therefore never
/// be read at an instant.
///
/// The F5 lesson made general, inherited from gate A unchanged: an assertion
/// on one of these at a single moment measures the scheduler, not the
/// property, and fails one run in three on a loaded runner. Read these inside
/// an `until()` or `within()` window, or do not read them. The list is gate
/// A's verbatim — `isSubscriptionStale` and `staleSubscriptions` earned their
/// places in 07-11/07-12 when both became live wall-clock computations — and
/// gate B's rows read the same client surfaces through the same fixture
/// family, so every name still applies here.
const _wallClockSurfaces = <String>[
  'viewIsStale',
  'isReady',
  'linkState',
  'staleSubscriptions',
  'isSubscriptionStale',
  'forwarding',
];

/// The calls that turn an instant into a window.
const _windowCalls = <String>['until(', 'within(', 'arrived('];

/// The one way a line may read a wall-clock surface at an instant and stay:
/// a consistency check against an event that already completed, argued in
/// writing on the line.
///
/// **The rule above does not bend; this is an exemption, and the difference
/// is the whole design.** The failure mode this constant exists to prevent is
/// a reader meeting a false positive, deciding the rule is wrong, and
/// **loosening the rule** — widening [_windowCalls], deleting a surface, or
/// dropping the arm — which silently re-permits the flake everywhere. An
/// exemption keeps the rule strict and makes each departure individually
/// visible, argued, and greppable at review time.
///
/// Spelling: a trailing `// window-exempt: <reason>` on the offending line.
/// The reason must name **the completed event that established the state
/// being asserted** — not "this is fine", not "flaky otherwise". A marker
/// whose reason is missing or shorter than [_exemptionReasonFloor] characters
/// fails the sweep exactly as an unmarked instant read does, because an
/// exemption nobody had to justify is a comment that switches off a test.
final _windowExemption = RegExp(r'//\s*window-exempt:\s*(\S.*)$');

/// How long an exemption's reason must be to count as one.
const _exemptionReasonFloor = 40;

/// Files in the gate directory that are not gate cases, and why.
///
/// One entry, and it has to be here: this file names the row grammar, the
/// wall-clock surfaces and the skip spellings as *data* in order to search
/// for them, and it builds sample sources containing `test('F22: …')` to
/// prove its own matchers bite. A sweep that did not exempt it would report
/// itself as the worst offender in the directory, and whoever read that as
/// the false positive it is would loosen the rule rather than the exemption.
///
/// `f_row_registry.dart` needs no entry: it is not a `_test.dart` file, so
/// discovery never reaches it. It is still swept for instant reads, along
/// with every other `.dart` file here.
const _notAGateCase = <String, String>{
  'gate_b_manifest_test.dart':
      'declares the grammar, the wall-clock surfaces and the skip spellings '
          'it searches for, and fabricates sample case sources to prove its '
          'own matchers match; it injects no fault and judges no row',
};

/// Cases in this gate directory that deliberately gate **no** catalogue row,
/// and the written argument for each.
///
/// **Empty on day one, and that is the rule, not an accident.** An entry
/// lands in the same commit as the case it exempts, never before it: the
/// presence arm below requires every exempted name to be a case actually in
/// the directory, so a pre-seeded entry would be red until its case arrived,
/// and an arm knowingly left red is the one thing this file exists to
/// prevent. Three entries are expected over the phase — the fixture probe
/// (09-02), the panel-isolate capability probe (09-05) and the stall
/// capability probe (09-07) — each with a reason of at least
/// [_deviationReasonFloor] characters saying why numbering it would report
/// the catalogue as covering something it does not.
///
/// Two arms hold the map honest. One requires each exempted name to be a
/// case that is actually in the directory — an exemption for a case that was
/// renamed or deleted is a hole held open for nothing. The other requires
/// each exempted name to gate no row *under the grammar*, so the day somebody
/// renumbers a probe into a row this file says so, instead of the row count
/// quietly going up by an arm.
const _supportingCases = <String, String>{
  'the gate-B pipe probe (supporting case, gates no row)':
      'the fixture\'s non-vacuity probe (09-02 task 1): it proves the pipe '
          'every row stands on is not a mirage — two panels reach ready, a '
          'value set on a link arrives at both with its real payload and '
          'quality, the plant driver\'s sweep count advances, and the socket '
          'count settles back to the case\'s own baseline after an ordered '
          'teardown. It injects no fault and asserts no catalogue clause, so '
          'numbering it would report the catalogue as covering a scenario it '
          'does not — the exact inflation the row grammar exists to prevent',
  'the panel-isolate probe (supporting case, gates no row)':
      'the panel-isolate harness\'s capability probe (09-05 task 1): it '
          'measures on THIS platform that a paused panel isolate stops '
          'sending its reports and that a killed one stops immediately — the '
          'two capabilities every F26 arm leans on, re-measured here rather '
          'than trusted from F16\'s number (07-RESEARCH §A.4). It injects no '
          'catalogue fault and asserts no F26 clause, so numbering it would '
          'report the catalogue as covering a scenario it does not',
  'the stall capability probe (supporting case, gates no row)':
      'the stall harness\'s capability probe (09-07 task 1): it measures on '
          'THIS platform that pausing an isolate which OWNS A LISTENING SOCKET '
          'stops it serving that socket — assumption A3 — by proving the plant '
          'freezes, a command to the gateway times out while paused, and a '
          'connected panel sees no new value across the pause, then recovers on '
          'resume. Re-measured here rather than trusted from F16\'s '
          'client-isolate number (07-RESEARCH §A.4). It injects no catalogue '
          'fault and asserts no F22 clause, so numbering it would report the '
          'catalogue as covering a scenario it does not',
};

void main() {
  final directory = Directory(_gateDir);
  final files = _gateFiles(directory);
  final cases = _cases(directory);
  final byRow = _byRow(cases);

  group('the sweep is looking where it thinks it is', () {
    test('the gate directory is on disk beside this file', () {
      expect(directory.existsSync(), isTrue,
          reason: 'there is no $_gateDir under ${Directory.current.path}, so '
              'every arm below is judging an empty list. `dart test` runs '
              'from the package root and this path is relative to it — check '
              'the directory the run was invoked from before believing any '
              'other result here');
      expect(File('$_gateDir/f_row_registry.dart').existsSync(), isTrue,
          reason: 'the row registry is not beside this sweep. The counts '
              'below come from an import, so they would still be right; what '
              'would be wrong is the assumption that the directory being read '
              'is the directory the registry describes');
    });

    test('the real directory holds sources for the sweep to read', () {
      final sources = _allGateSources(directory);
      expect(sources, isNotEmpty,
          reason: 'the non-exempt source list for $_gateDir is empty, so '
              'every content arm in this file is sweeping nothing. On day one '
              'the registry alone should appear here; the two temp-directory '
              'arms below prove discovery reacts to what it is handed, and '
              'this arm proves it was handed something real. (Cases cannot be '
              'the subject of this arm yet — the directory legitimately holds '
              'zero cases until 09-02 lands the first row.)');
    });

    test('every file exempted from discovery still exists', () {
      final missing = [
        for (final name in _notAGateCase.keys)
          if (!File('$_gateDir/$name').existsSync()) name,
      ];
      expect(missing, isEmpty,
          reason: 'these files are exempted from case discovery and are not '
              'on disk. An exemption for a file that no longer exists is a '
              'hole held open for nothing — and the next file to take one of '
              'these names inherits the exemption without anybody deciding to '
              'give it one');
    });

    test('discovery reports zero for an empty directory', () async {
      final empty = await Directory.systemTemp.createTemp('gate-b-manifest-');
      addTearDown(() => empty.delete(recursive: true));

      expect(_cases(empty), isEmpty,
          reason: 'discovery pointed at a directory with no test files in it '
              'still returned cases, so it is not reading the directory it '
              'was handed. Every count above would then be describing '
              'something other than $_gateDir');
    });

    test('discovery finds the one case in a directory that has one', () async {
      final one = await Directory.systemTemp.createTemp('gate-b-manifest-');
      addTearDown(() => one.delete(recursive: true));
      File('${one.path}/foo_test.dart').writeAsStringSync('''
void main() {
  test('F22: a fabricated case', () {});
}
''');

      final found = _cases(one);
      expect(found, hasLength(1),
          reason: 'discovery found ${found.length} cases in a directory '
              'holding exactly one, so the zero it reports for the empty '
              'directory above proves nothing: a matcher that matches nothing '
              'reports zero everywhere. This is the positive half of that '
              'control arm, and it is the half that has teeth while '
              '$_gateDir is still filling up');
      expect(found.single.rows, ['F22'],
          reason: 'the fabricated case is named `F22:` and discovery read its '
              'row as ${found.single.rows}. The name is parsed by the same '
              'grammar every real case is judged by');
      expect(found.single.file, 'foo_test.dart',
          reason: 'discovery attributed the case to ${found.single.file} '
              'rather than to the file it read it out of, so the '
              '"which file must quote the anchor" arm below is pointing at '
              'the wrong file');
    });

    test('every plan id in the outstanding list is well-formed', () {
      final malformed = [
        for (final entry in gateOutstanding.entries)
          if (!RegExp(r'^09-\d\d$').hasMatch(entry.value.owner))
            '${entry.key} -> ${entry.value.owner}',
      ];
      expect(malformed, isEmpty,
          reason: 'these outstanding entries name an owner that is not a '
              'Phase 9 plan id: $malformed. The owner is the whole value of '
              'the entry — an outstanding row with no plan behind it is a row '
              'nobody has agreed to write, recorded as though somebody had');
    });
  });

  group('the counts are written down twice', () {
    test('the catalogue is still the size this phase claims', () {
      expect(gateRows, hasLength(_declaredRows),
          reason: 'gateRows holds ${gateRows.length} rows and this phase '
              'claims $_declaredRows. Every other arm in this file derives '
              'both of its sides from gateRows, so a row deleted there is '
              'invisible to all of them: it takes its outstanding entry and '
              'its deviations with it and every count still agrees with '
              'itself. This number is the only place the deletion shows');
    });

    test('no row id is declared twice', () {
      final seen = <String>{};
      final duplicated = [
        for (final row in gateRows)
          if (!seen.add(row.id)) row.id,
      ];
      expect(duplicated, isEmpty,
          reason: 'these row ids appear more than once in gateRows: '
              '$duplicated. The outstanding map is keyed by id, so a '
              'duplicate row silently shares one owner and one clause with '
              'its twin');
    });

    test('the deviations registry has not shrunk below its seed', () {
      expect(gateDeviations.length, greaterThanOrEqualTo(_declaredDeviations),
          reason: 'gateDeviations holds ${gateDeviations.length} entries and '
              '09-01 seeded $_declaredDeviations. Later plans append; none '
              'may delete an entry without saying what now asserts the '
              'clause, because a deviation that disappears is a promise the '
              'gate quietly widened');
    });
  });

  group('no row without a case, no case without a row', () {
    test('every row has a case or a named plan that owes it', () {
      final unaccounted = [
        for (final row in gateRows)
          if (byRow[row.id] == null &&
              gateOutstanding[row.id]?.kind != OutstandingKind.missing)
            row.id,
      ];
      expect(unaccounted, isEmpty,
          reason: 'these catalogue rows have no case in $_gateDir and no '
              'missing entry in gateOutstanding: $unaccounted. A row in '
              'neither list is not deferred, it is forgotten — the phase '
              'reports its remaining work by running this sweep, and a row '
              'nobody claims does not appear in that report');
    });

    test('no row is both covered and still owed', () {
      final both = [
        for (final row in gateRows)
          if (byRow[row.id] != null &&
              gateOutstanding[row.id]?.kind == OutstandingKind.missing)
            '${row.id} (owed to ${gateOutstanding[row.id]!.owner}, covered by '
                '${byRow[row.id]!.map((c) => c.name).join(', ')})',
      ];
      expect(both, isEmpty,
          reason: 'these rows have a case and are still listed as missing: '
              '$both. Every plan deletes its own entries in the commit that '
              'lands its rows; an entry left behind makes the outstanding '
              'count overstate the remaining work, which is how 09-09\'s '
              '"the map is empty" closing condition will fail for a reason '
              'that is not about the gate at all');
    });

    test('a partial entry names a row that has a case', () {
      final mislabelled = [
        for (final entry in gateOutstanding.entries)
          if (entry.value.kind == OutstandingKind.partial &&
              byRow[entry.key] == null)
            entry.key,
      ];
      expect(mislabelled, isEmpty,
          reason: 'these rows are listed as partially covered and have no '
              'case at all: $mislabelled. A partial entry for a row with no '
              'case is a missing entry wearing the wrong label, and it reads '
              'on the progress line as work that is nearly done');
    });

    test('every supporting case is in the directory, and gates no row', () {
      final present = _caseNames(directory);

      final vanished = [
        for (final name in _supportingCases.keys)
          if (!present.contains(name)) name,
      ];
      expect(vanished, isEmpty,
          reason: 'these names are exempted from the row mapping as '
              'supporting cases and no case in $_gateDir carries them: '
              '$vanished. An exemption for a case that was renamed or deleted '
              'is a hole held open for nothing, and the next case to take the '
              'name inherits an argument nobody made about it');

      final claiming = [
        for (final name in _supportingCases.keys)
          if (_rowsIn(name).isNotEmpty) '$name -> ${_rowsIn(name)}',
      ];
      expect(claiming, isEmpty,
          reason: 'these supporting cases name a catalogue row under the '
              'grammar: $claiming. A case cannot be both exempt from the row '
              'mapping and a gate for a row — whichever of the two the reader '
              'believes, the other one is wrong, and the count printed below '
              'is computed from the grammar rather than from this map');
    });

    test('every supporting-case exemption is justified in writing', () {
      final thin = [
        for (final entry in _supportingCases.entries)
          if (entry.value.length < _deviationReasonFloor)
            '${entry.key} (${entry.value.length} chars)',
      ];
      expect(thin, isEmpty,
          reason: 'these supporting-case reasons are shorter than '
              '$_deviationReasonFloor characters: $thin. The entry is the '
              'only record that a case in the gate directory gates nothing on '
              'purpose; a reason that short says it is exempt without saying '
              'why numbering it would be wrong, which is the argument the '
              'next reader needs before they renumber it');
    });

    test('every case names a row the catalogue declares', () {
      final declared = {for (final row in gateRows) row.id};
      final strangers = [
        for (final one in cases)
          for (final row in one.rows)
            if (!declared.contains(row)) '${one.file}: ${one.name} -> $row',
      ];
      expect(strangers, isEmpty,
          reason: 'these cases name rows this registry does not declare: '
              '$strangers. This is the mirror of gate A\'s strangers arm, and '
              'it points the other way: an F1 here belongs in gate A, in '
              'packages/tfc_relay_client/test/gate, and a typo here is a row '
              'that reads as covered while its real name reads as missing — '
              'the reverse direction exists because those two failures look '
              'identical from the forward direction');
    });
  });

  group('arm letters are unique and gapless', () {
    test('a row with several cases lettered them a, b, c', () {
      final wrong = <String>[];
      for (final entry in byRow.entries) {
        final letters = [
          for (final one in entry.value) one.armOf(entry.key),
        ]..sort((a, b) => (a ?? '').compareTo(b ?? ''));

        if (letters.length == 1) {
          if (letters.single != null) {
            wrong.add('${entry.key}: one case, lettered '
                '${entry.key}${letters.single}');
          }
          continue;
        }
        final expected = [
          for (var i = 0; i < letters.length; i++)
            String.fromCharCode('a'.codeUnitAt(0) + i),
        ];
        if (!_sameList(letters, expected)) {
          wrong.add('${entry.key}: $letters, expected $expected');
        }
      }
      expect(wrong, isEmpty,
          reason: 'these rows letter their arms with a gap, a repeat, or a '
              'letter on a row that has only one case: $wrong. F22a beside '
              'F22c is not a naming quibble — it is the shape a deleted arm '
              'leaves behind, and the forward sweep cannot see it because the '
              'row still has a case');
    });
  });

  group('every case quotes its catalogue line', () {
    test('the file holding a row\'s case carries the row\'s quote anchor', () {
      final byName = {for (final file in files) file.name: file};
      final unquoted = <String>[];
      for (final row in gateRows) {
        final holders = byRow[row.id];
        if (holders == null) continue;
        for (final holder in {for (final one in holders) one.file}) {
          final source = byName[holder]?.source ?? '';
          if (!source.contains(row.quoteAnchor)) {
            unquoted.add('$holder is missing ${row.id}\'s anchor '
                '"${row.quoteAnchor}"');
          }
        }
      }
      expect(unquoted, isEmpty,
          reason: 'these files hold a row\'s case and do not contain the '
              'row\'s anchor: $unquoted. The anchor is a fragment of the '
              'catalogue text copied character-for-character, so a file that '
              'does not contain it has paraphrased the row it claims to gate '
              '— and a paraphrase is where a scenario quietly becomes a '
              'weaker scenario that still passes');
    });
  });

  group('the deviations name real clauses', () {
    test('every deviation quotes a row the catalogue declares', () {
      final declared = {for (final row in gateRows) row.id};
      final strangers = [
        for (final deviation in gateDeviations)
          if (!declared.contains(deviation.row)) deviation.row,
      ];
      expect(strangers, isEmpty,
          reason: 'these deviations name rows gateRows does not declare: '
              '$strangers. A deviation against a row that does not exist '
              'excuses nothing and is read by the verification document as '
              'though it excused something');
    });

    test('every deviation clause is verbatim from the text its source names',
        () {
      final rows = {for (final row in gateRows) row.id: row};
      final paraphrased = <String>[];
      for (final deviation in gateDeviations) {
        final row = rows[deviation.row];
        if (row == null) continue; // the strangers arm above owns that fault
        final text = switch (deviation.source) {
          'expectation' => row.expectation,
          'injection' => row.injection,
          'prose' => catalogueProse[deviation.row],
          _ => null,
        };
        if (text == null || !text.contains(deviation.clause)) {
          paraphrased.add(
              '${deviation.row} (source: ${deviation.source}): '
              '"${deviation.clause}"');
        }
      }
      expect(paraphrased, isEmpty,
          reason: 'these deviation clauses are not substrings of the text '
              'their source names: $paraphrased. Each entry says which of the '
              'row\'s three texts it quotes — expectation, injection or prose '
              '— and the clause must be found in exactly that text. A '
              'deviation that paraphrases the clause it descopes is a '
              'deviation nobody can check against the catalogue: the reader '
              'cannot tell whether the thing being given up is the whole row '
              'or a corner of it');
    });

    test('the registry is printed, in full, on every run', () {
      // The print is the point. RES-02's checkbox evidence is this block
      // plus the manifest plus a green lane, and the verification document
      // quotes the block — a registry read only by an assertion is a
      // registry nobody reads. It goes to the run report whether or not
      // anything below fails.
      print('');
      print('gate B deviations — what the green does NOT cover '
          '(${gateDeviations.length} entries)');
      print('row · source · clause · reason · follow-up');
      for (final deviation in gateDeviations) {
        print('${deviation.row} · ${deviation.source} · '
            '"${deviation.clause}" · ${deviation.reason} · '
            '-> ${deviation.followUp}');
      }
      print('');

      expect(gateDeviations, isNotEmpty,
          reason: 'the deviations registry is empty, so this run reports '
              'that the gate covers every clause of all ${gateRows.length} '
              'catalogue rows. That has not been true since before the phase '
              'started — three of F27\'s clauses and one of F23\'s were out '
              'of scope before the first case was written (09-CONTEXT '
              'rulings 1 and 4). An empty registry is not a clean gate, it '
              'is a gate that stopped saying what it gave up');

      final thin = [
        for (final deviation in gateDeviations)
          if (deviation.reason.length < _deviationReasonFloor)
            '${deviation.row}: "${deviation.clause}" '
                '(${deviation.reason.length} chars)',
      ];
      expect(thin, isEmpty,
          reason: 'these deviation reasons are shorter than '
              '$_deviationReasonFloor characters: $thin. A reason that short '
              'names the clause and not the measurement or the ruling behind '
              'it, which is the difference between a finding and an excuse');
    });

    test('every deviation names a real source and a real destination', () {
      // The row-exists half of the plan's rule is asserted by "every
      // deviation quotes a row the catalogue declares" above; asserting it
      // twice would fail two cases for one fault and send the reader to the
      // wrong one first. What only this case asserts: the source names one
      // of the three texts, a prose source has prose to quote, and the
      // follow-up is somewhere the phase can grep for at the milestone.
      final unsourced = [
        for (final deviation in gateDeviations)
          if (!_deviationSources.contains(deviation.source))
            '${deviation.row}: "${deviation.source}"',
      ];
      expect(unsourced, isEmpty,
          reason: 'these deviations name a source outside '
              '${_deviationSources.toList()}: $unsourced. The source says '
              'which text the clause was quoted from, and a source that '
              'names no text is a clause checkable against nothing — the '
              'verbatim arm above will have judged it against null and the '
              'reader deserves the direct accusation too');

      final proseless = [
        for (final deviation in gateDeviations)
          if (deviation.source == 'prose' &&
              !catalogueProse.containsKey(deviation.row))
            deviation.row,
      ];
      expect(proseless, isEmpty,
          reason: 'these prose-sourced deviations name rows with no '
              'catalogueProse entry: $proseless. A prose clause with no '
              'prose behind it quotes a text this repository does not hold, '
              'which is the exact gap the prose map was added to close — '
              'the Expect column compresses requirements the prose states '
              'in full, and a deviation against the compressed form would '
              'silently drop the clause the user asked to have recorded');

      expect(followUpDestinations, _followUpDestinations,
          reason: 'the registry\'s followUpDestinations set and this '
              'manifest\'s copy disagree. The two are written down twice on '
              'purpose, like the row count: Phase 10 and Phase 11 have zero '
              'users among the seeded seven DELIBERATELY, and pruning them '
              'from one file is the edit this comparison exists to catch');

      final adrift = [
        for (final deviation in gateDeviations)
          if (!_followUpDestinations.contains(deviation.followUp))
            '${deviation.row}: "${deviation.followUp}"',
      ];
      expect(adrift, isEmpty,
          reason: 'these deviations name a follow-up outside the closed set '
              '${_followUpDestinations.toList()}: $adrift. "later" and '
              '"TODO" are not destinations — nobody can grep for them at the '
              'milestone, and the entry stops being a handover to a named '
              'owner and becomes a note to self. If a clause genuinely goes '
              'nowhere, "none — accepted" says so out loud');
    });
  });

  group('the phase measures itself by running its own sweep', () {
    test('every row is either covered or owed, and the count is printed', () {
      final covered = [
        for (final row in gateRows)
          if (byRow[row.id] != null) row.id,
      ];
      final missing = [
        for (final entry in gateOutstanding.entries)
          if (entry.value.kind == OutstandingKind.missing) entry.key,
      ];
      final partial = [
        for (final entry in gateOutstanding.entries)
          if (entry.value.kind == OutstandingKind.partial) entry.key,
      ];

      // The phase measures itself by running its own sweep, so the progress
      // line carries both registries: this one's coverage, and the
      // reconciled total. The gate-A half is the same text read the
      // reconciliation group guards; here it only feeds the print, and a
      // missing registry fails loudly there rather than quietly here.
      final gateA = File(_gateARegistry);
      final gateARows = gateA.existsSync()
          ? _rowIdsDeclaredIn(gateA.readAsStringSync()).length
          : 0;
      print('gate B: ${covered.length} of $_declaredRows rows have a case, '
          '${gateOutstanding.length} outstanding (${partial.length} partial); '
          '${gateARows + covered.length + missing.length} of '
          '${_gateARows + _declaredRows} across two registries');

      expect(covered.length + missing.length, _declaredRows,
          reason: '${covered.length} rows have a case and ${missing.length} '
              'are listed as missing, which is '
              '${covered.length + missing.length} of $_declaredRows. The two '
              'must account for the whole catalogue or the outstanding list '
              'is not a gap, it is a number somebody stopped maintaining. The '
              'per-row arms above say which rows fell out');
    });

    test('the outstanding list is empty, because the phase is over', () {
      // The phase's own closing condition, asserted rather than remembered —
      // gate A's arm, one phase later, for the same reason it exists there.
      //
      // Every plan in Phase 9 deleted its own entries in the commit that
      // landed its rows, and 09-09 deleted the last one (F22's historian
      // clause, closed by F22e). This arm is what makes that a property
      // instead of a habit: a list that tracked the phase's progress must
      // not survive the phase as a list of things nobody is going to do. It
      // is deliberately separate from the arms above — those ask whether
      // the two lists *agree*, and two empty lists and two full ones agree
      // equally well.
      final left = [
        for (final entry in gateOutstanding.entries)
          '${entry.key} (${entry.value.kind.name}, owed to '
              '${entry.value.owner})',
      ];
      expect(left, isEmpty,
          reason: 'the phase is closing with these rows still outstanding: '
              '$left. An entry here after the phase closes is one of exactly '
              'two things, and they are fixed differently. Either it is a '
              'clause that never landed — in which case the phase did not do '
              'what it said, and the owner named in the entry is where to '
              'start. Or it is a clause the phase decided not to assert, '
              'wearing the wrong label: an outstanding entry says "somebody '
              'is going to write this", and nobody is. That belongs in '
              'gateDeviations, with the clause quoted verbatim from the '
              'catalogue and the measurement or ruling that settled it — '
              'which is the list RES-02\'s evidence quotes and this file '
              'prints on every run. Moving it there is not bookkeeping: an '
              'outstanding row is invisible after the phase ends and a '
              'deviation is read every time somebody asks what the green '
              'covers');
    });
  });

  group('the two gates reconcile, B to A, by one text read', () {
    test('gate A\'s registry is on disk where this file says it is, and '
        'declares exactly $_gateARows rows', () {
      final registry = File(_gateARegistry);
      // The anti-vacuity guard, and it fails by PATH, not by count: a text
      // read of a file that is not there must never decay into "found zero
      // rows", because zero rows against a bad path and zero rows against an
      // emptied registry are different faults with different fixes.
      expect(registry.existsSync(), isTrue,
          reason: 'no file at $_gateARegistry (resolved against '
              '${Directory.current.path}). The B→A reconciliation is a '
              'relative-path text read from this package\'s root — the same '
              'crossing no_retry_test.dart makes into ../tfc_relay_server/lib '
              '— so a moved or renamed gate-A registry lands here first. Fix '
              'the path or find where Phase 7\'s registry went; do not let '
              'this arm report a row count of nothing');

      final ids = _rowIdsDeclaredIn(registry.readAsStringSync());
      expect(ids, hasLength(_gateARows),
          reason: 'gate A\'s registry declares ${ids.length} row ids and this '
              'file wrote down $_gateARows. Gate A\'s own _declaredRows = 27 '
              'is Phase 7\'s tripwire and this constant is Phase 9\'s — two '
              'records in two packages, and if they disagree the catalogue '
              'changed size, which is a finding to take to the orchestrator, '
              'never a constant to adjust. Gate A is read as text and never '
              'edited: growing it would retroactively un-close a finished '
              'phase');
      expect(ids.toSet(), hasLength(ids.length),
          reason: 'gate A\'s registry declares a duplicate row id, so the '
              'count above is double-crediting a row and the 34 below is '
              'built on it');

      // 27 of the 34 have their case in gate A — its own manifest holds that
      // (closed at 27 of 27 with 0 outstanding, Phase 7's closing condition)
      // and it is not re-proved from here. The 7 declared in this package are
      // each covered or owed by a named plan, held by the forward arm above.
      // This line is the reconciliation artifact 09-09's ledger quotes.
      print('gate: ${ids.length + _declaredRows} of '
          '${_gateARows + _declaredRows} rows have a case across two '
          'registries');
    });
  });

  group('no case skips silently', () {
    test('no gate case carries an unconditional skip', () {
      final offenders = <String>[];
      for (final file in files) {
        for (final skip in _skips(file.code)) {
          if (_isUnconditional(skip.expression)) {
            offenders.add('${file.name}: `${skip.expression}`');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these gate cases skip unconditionally: $offenders. A row '
              'green by a case that never runs is the "capability switched '
              'off" failure one level up: the manifest counts the row as '
              'covered, the run report shows a skip, and the hostile plant '
              'condition is as unjudged as it would have been with no case at '
              'all. No row goes green by a case that skips');
    });

    test('every conditional skip says what stopped being judged', () {
      final thin = <String>[];
      for (final file in files) {
        for (final skip in _skips(file.code)) {
          if (_isUnconditional(skip.expression)) continue;
          if (skip.literals.isEmpty) {
            if (!_tracesToAProbe(skip.expression, file.code)) {
              thin.add('${file.name}: `${skip.expression}` (no reason, and no '
                  'probe it could have come from)');
            }
            continue;
          }
          for (final reason in skip.literals) {
            if (reason.length < _skipReasonFloor) {
              thin.add('${file.name}: "$reason" (${reason.length} chars)');
            }
          }
        }
      }
      expect(thin, isEmpty,
          reason: 'these skip reasons are shorter than $_skipReasonFloor '
              'characters or are computed from something that is not a '
              'probe: $thin. On the Windows column of the matrix a skipped '
              'row and a passing row are the same green tick, and the reason '
              'is the only thing that tells them apart');
    });
  });

  group('no instant read of a wall-clock boolean', () {
    test('every staleness read happens inside a window', () {
      final instants = <String>[
        for (final source in _allGateSources(directory))
          ..._instantReadsIn(source),
      ];
      expect(instants, isEmpty,
          reason: 'these lines read a wall-clock-derived value at an instant '
              'inside an expect(): $instants. The property is "it becomes '
              'stale", which is a window; asserting it at a point measures '
              'the scheduler and fails one run in three on a loaded runner. '
              'Wrap the read in until() or within(), and platform-scale the '
              'deadline. If the read is a consistency check against an event '
              'that has already completed, say so on the line with '
              '`// window-exempt: <reason naming the completed event>` — and '
              'read _windowExemption\'s doc first, because widening the rule '
              'instead is the failure it describes');
    });

    test('every exemption is justified in writing', () {
      final unjustified = <String>[];
      for (final source in _allGateSources(directory)) {
        final lines = source.code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final reason = _exemptionOn(lines[i]);
          if (reason == null) continue;
          if (reason.length < _exemptionReasonFloor) {
            unjustified.add('${source.name}:${i + 1} — "$reason" '
                '(${reason.length} chars)');
          }
        }
      }
      expect(unjustified, isEmpty,
          reason: 'these window-exempt markers carry a reason shorter than '
              '$_exemptionReasonFloor characters: $unjustified. The marker '
              'suppresses the one arm standing between this directory and the '
              'instant-read flake, so the reason is the entire safeguard: it '
              'has to name the completed event that established the state '
              'being asserted, which is a sentence nobody can write by '
              'accident about a read that is really racing a timer');
    });
  });

  group('every gate file carries the tag', () {
    test('each case file is selected by --tags gate', () {
      final untagged = [
        for (final file in files)
          if (!_carriesTheGateTag(file.source)) file.name,
      ];
      expect(untagged, isEmpty,
          reason: 'these files under $_gateDir carry no @Tags naming gate: '
              '$untagged. The CI lane and the budget arm both select by tag, '
              'so an untagged file is a row that is in the manifest, on disk, '
              'and not in the lane — green locally on a full run and never '
              'executed by the job that owns the number');
    });
  });

  group('the matchers match', () {
    // Every content arm above passes today by having almost nothing to judge:
    // 09-01 lands this sweep before a single row does. A pattern with a typo
    // in it reports green forever under exactly those conditions, which is
    // the failure this file exists to catch, one level up. These cases hold
    // each matcher against a sample of the thing it is looking for, and
    // against a sample of the thing it must not mistake for it.
    test('the row grammar reads the names the phase will write', () {
      expect(_rowsIn('F22: a stalled gateway announces itself'), ['F22']);
      expect(_rowsIn('F24/F28: one fixture proves two rows'), ['F24', 'F28'],
          reason: 'a case that gates two rows at once names both, and the '
              'forward sweep has to credit both or one of them reads as '
              'missing while its assertion is right there');
      expect(_rowsIn('F26c: a backgrounded panel'), ['F26']);
      expect(_rowsIn('F25a: one subscription flagged stale'), ['F25']);
      expect(_rowsIn('F1: a stray gate-A name still parses'), ['F1'],
          reason: 'the grammar is deliberately looser than this registry — '
              'F1 parses — so that a case naming a row nobody here declares '
              'is reported by the reverse sweep as the stranger it is and '
              'pointed back at gate A, rather than vanishing from discovery '
              'and reading as no case at all');
    });

    test('the row grammar refuses a row merely mentioned', () {
      expect(_rowsIn('F22 is fine now'), isEmpty,
          reason: 'a test name that mentions a row without gating it is being '
              'counted as coverage, which is the whole reason discovery '
              'matches a grammar rather than a substring');
      expect(_rowsIn('the F24 path is not this'), isEmpty,
          reason: 'the grammar is anchored at the start of the name; a row id '
              'in the middle of a sentence is prose');
      expect(_rowsIn('F25:no space after the colon'), isEmpty,
          reason: 'the grammar requires a colon and a space, which is what '
              'keeps a Dart type annotation or a map literal in a name from '
              'reading as a row');
    });

    test('arm letters are read off the name they are attached to', () {
      expect(_armIn('F26a: x', 'F26'), 'a');
      expect(_armIn('F26: x', 'F26'), isNull);
      expect(_armIn('F24/F28b: x', 'F28'), 'b',
          reason: 'in a two-row name each row carries its own arm letter, so '
              'reading the letter off the wrong token would letter F24 with '
              'F28\'s arm and report a gap in both rows');
    });

    test('an instant read is recognised and a windowed one is not', () {
      const instant = 'expect(api.viewIsStale, isTrue);';
      const windowed = 'await until(() => api.viewIsStale, reason: ...);';
      expect(
          instant.contains('expect(') &&
              !_windowCalls.any(instant.contains) &&
              _wallClockSurfaces.any(instant.contains),
          isTrue,
          reason: 'the instant-read sweep does not recognise an instant read '
              'written out longhand, so it has been passing on every file by '
              'matching nothing');
      expect(
          windowed.contains('expect(') && !_windowCalls.any(windowed.contains),
          isFalse,
          reason: 'a read already inside an until() window is being reported '
              'as an instant, which is the false positive that gets a sweep '
              'switched off rather than obeyed');
    });

    test('the two shapes that used to walk past the instant-read sweep do not',
        () {
      // Gate A's 07-REVIEW WR-04 and IN-06, re-proved here because this is a
      // copy and a copy with a typo reports green forever. The line-scoped
      // sweep this implementation replaced passed on all four of these; the
      // first three are evasions and the fourth is the false positive that
      // must not come with fixing them.
      const multiLine = '''
void main() {
  test('F22: a thing', () {
    expect(
        fixture.client.viewIsStale,
        isFalse,
        reason: 'the house style for anything carrying a reason');
  });
}
''';
      // The line reported is the one the `expect(` starts on, not the one the
      // surface is on: the message is then the same one the line-scoped sweep
      // printed, and the reader's next step is unchanged.
      expect(_instantReadsOf(multiLine), ['x.dart:3 — viewIsStale'],
          reason: 'a multi-line expect() is the house style for every '
              'assertion in this directory that carries a reason, and the '
              'sweep saw neither the line with the expect( on it nor the line '
              'with the surface on it');

      const bound = '''
void main() {
  test('F22: a thing', () {
    final parked = fixture.client.staleSubscriptions;
    expect(parked, isEmpty);
  });
}
''';
      expect(_instantReadsOf(bound),
          ['x.dart:4 — staleSubscriptions (via `parked`)'],
          reason: 'reading the surface into a local one line above the expect '
              'made the read invisible. A read is a read wherever the result '
              'is parked');

      const prose = '''
void main() {
  test('F22: a thing', () {
    expect(fixture.client.viewIsStale, isTrue, reason: 'the until() above');
  });
}
''';
      expect(_instantReadsOf(prose), ['x.dart:3 — viewIsStale'],
          reason: 'the word until( inside a reason string switched the arm '
              'off for that line, silently, with no exemption marker and '
              'nothing to grep for');

      const recorder = '''
void main() {
  test('F22: a thing', () async {
    final watching = fixture.client.linkStates.listen(states.add);
    final trusted = fixture.client.isReady;
    samples.add(trusted);
    final counted = samples.where((s) => s).toList();
    expect(states, isEmpty);
    expect(counted, isNotEmpty);
    expect(sample.trusted, isTrue);
  });
}
''';
      expect(_instantReadsOf(recorder), isEmpty,
          reason: 'the sweep reported a transition recorder as an instant '
              'read. `linkStates` contains `linkState`, `counted` was rebound '
              'from something that is not a surface, and `sample.trusted` is '
              'somebody else\'s field — and a sweep that cries wolf on the '
              'three commonest correct spellings is a sweep the next reader '
              'switches off rather than obeys, which is the failure '
              '_windowExemption\'s doc is about');
    });

    test('an exemption is read only when it carries a real reason', () {
      const justified = 'expect(c.isReady, isTrue); // window-exempt: the '
          'resynced value arrived one line above, so this asserts consistency '
          'with a completed event';
      expect(_exemptionOn(justified), isNotNull,
          reason: 'a properly spelled marker is not being recognised, so '
              'every argued exemption is being counted as an instant read and '
              'the next reader meets the false positive this mechanism exists '
              'to retire');
      expect(_exemptionOn(justified)!.length,
          greaterThanOrEqualTo(_exemptionReasonFloor));

      expect(_exemptionOn('expect(c.isReady, isTrue);'), isNull,
          reason: 'a line with no marker is being read as exempt, which would '
              'switch the arm off for the whole directory at once');
      expect(_exemptionOn('expect(c.isReady, isTrue); // window-exempt:'),
          isNull,
          reason: 'an empty marker is being accepted. `// window-exempt:` '
              'with nothing after it is the cheapest thing to type and the '
              'exact shape that turns an argued exemption into a mute button');

      const short = 'expect(c.isReady, isTrue); // window-exempt: fine';
      expect(_exemptionOn(short), isNotNull);
      expect(_exemptionOn(short)!.length, lessThan(_exemptionReasonFloor),
          reason: 'the reason floor is not biting: "fine" is being measured '
              'as a justification, and the sweep arm above would let it '
              'through');
    });

    test('an unconditional skip is recognised and a probed one is not', () {
      expect(_isUnconditional('true'), isTrue);
      expect(_isUnconditional("'parked while the flake is investigated'"),
          isTrue,
          reason: 'a bare string handed to skip: is an unconditional skip '
              'wearing a reason. It is the most common spelling of the thing '
              'this arm forbids and the easiest one to miss');
      expect(_isUnconditional('probe.available ? null : probe.reason'), isFalse,
          reason: 'a runtime-decided skip is being read as unconditional, '
              'which would forbid the one shape a capability probe asks for');
    });

    test('a skip expression is read whole, across lines', () {
      const sample = '''
  }, skip: probe.available
      ? null
      : 'the probe declined and this is the reason it gave');
''';
      final skips = _skips(sample);
      expect(skips, hasLength(1),
          reason: 'the scanner found ${skips.length} skips in a sample with '
              'exactly one');
      expect(skips.single.literals.single,
          'the probe declined and this is the reason it gave',
          reason: 'the reason three lines below the `skip:` was not read, so '
              'a multi-line skip is judged on its condition alone — the house '
              'style puts the reason there and a line-bounded capture would '
              'accuse every file that follows it');
    });

    test('a skip written inside a string is not a skip', () {
      expect(_skips("expect(x, isTrue, reason: 'it becomes a Skip() later');"),
          isEmpty,
          reason: 'prose about skipping is being counted as a skip, which is '
              'how the files that document this rule best become the ones the '
              'audit accuses');
    });

    test('the tag matcher reads the tag off the header it will meet', () {
      expect(_carriesTheGateTag("@Tags(['gate'])"), isTrue);
      expect(_carriesTheGateTag("@Tags(['gate', 'opcua'])"), isTrue);
      expect(_carriesTheGateTag("@Tags(['opcua'])"), isFalse,
          reason: 'a file tagged for another lane is being read as tagged for '
              'this one, so the arm would pass for a row the gate lane never '
              'runs');
      expect(_carriesTheGateTag('/// the gate lane runs this'), isFalse,
          reason: 'the word "gate" in prose is being read as a tag');
    });

    test('the gate-A row counter reads ids off the shape that file uses', () {
      const sample = '''
/// id: 'F99' in a doc comment is prose, not a declaration.
const rows = [
  GateRow(
    id: 'F1',
    scenario: 'x',
  ),
  GateRow(
    id: 'G6',
    scenario: 'y',
  ),
];
''';
      expect(_rowIdsDeclaredIn(sample), ['F1', 'G6'],
          reason: 'the reconciliation\'s text read did not find the two ids '
              'declared in a sample shaped exactly like gate A\'s registry, '
              'or it counted the one in the comment — either way the 27 it '
              'reports for the real file is not a count of declarations, and '
              'the 34 built on it reconciles nothing');
    });

    test('comments are stripped before the source is scanned', () {
      const sample = '''
// skip: true
/// expect(api.viewIsStale, isTrue);
final x = 1;
''';
      final stripped = _stripCommentLines(sample);
      expect(stripped, isNot(contains('skip:')));
      expect(stripped, isNot(contains('viewIsStale')));
      expect(stripped, contains('final x = 1;'),
          reason: 'the comment stripper is eating code, which would hide real '
              'offenders from every source arm in this file');
    });
  });

  group('the sweep itself', () {
    test('the whole gate-B lane runs inside its declared budget', () async {
      final lane = Stopwatch()..start();
      final run = await Process.run(
        Platform.resolvedExecutable,
        // `db` is excluded alongside `meta`, and for a different reason:
        // this budget measures the lane the relay CI step runs, and that
        // step is `--exclude-tags db` on a job that has no database and
        // must not grow one (test.yml's own words). F22e runs — and is
        // separately floor-checked — on the tfc-dart-test job's db leg;
        // letting it into this child would time a Compose bring-up into
        // the budget and hand the relay job a database dependency by the
        // back door.
        ['test', _gateDir, '--exclude-tags', 'meta', '--exclude-tags', 'db'],
        workingDirectory: Directory.current.path,
        // Cleared in the child, because the child inherits this process's
        // environment and would otherwise see the variable that turned this
        // arm on and run it again. The only other thing stopping that is the
        // `meta` tag being excluded above — so dropping or renaming that tag
        // would turn one CI job into an unbounded recursion of `dart test`
        // processes rather than into a failing assertion. Two guards, and
        // neither of them alone.
        environment: {_laneBudgetEnvVar: ''},
      );
      lane.stop();

      print('the gate-B lane ran in ${lane.elapsed.inSeconds} s '
          '(budget ${_laneBudget.inSeconds} s, ${byRow.length} rows with a '
          'case)');
      if (byRow.isEmpty) {
        // 09-01 lands this arm before a single row does, and `dart test
        // test/gate --exclude-tags meta` against a directory holding only
        // this manifest selects nothing — package:test exits 79 for "no
        // tests ran", never 0. Asserting 0 here would make the arm red for
        // the whole of wave 1 and the first thing the next executor did
        // would be to loosen it. So the empty lane is a named state with its
        // own exit code, and the branch closes itself: 09-02 lands the first
        // rows and the strict arm below takes over for good.
        expect(run.exitCode, 79,
            reason: 'no row in $_gateDir has a case yet, so the lane selects '
                'nothing and package:test should report exit 79 ("no tests '
                'ran"). It reported ${run.exitCode} instead, which means the '
                'lane is not empty after all and this branch is excusing a '
                'real failure:\n${run.stdout}\n${run.stderr}');
      } else {
        expect(run.exitCode, 0,
            reason: 'the gate-B lane is not green, so the time below is the '
                'cost of a failing suite:\n${run.stdout}\n${run.stderr}');
      }
      expect(lane.elapsed, lessThan(_laneBudget),
          reason: 'the gate-B lane took ${lane.elapsed.inSeconds} s against a '
              '${_laneBudget.inSeconds} s budget. The lane is slower than '
              'every other lane in this package by design, and this bound is '
              'what keeps "slower by design" from becoming "nobody runs it". '
              'Report the number, do not raise the budget');
    },
        timeout: const Timeout(Duration(minutes: 12)),
        skip: Platform.environment[_laneBudgetEnvVar]?.isNotEmpty ?? false
            ? null
            : 'the lane budget is measured by running the lane, which costs '
                'the lane\'s full runtime a second time on top of the run '
                'that is already in progress. Set $_laneBudgetEnvVar=1 to '
                'measure it; CI sets it on the one job that owns the number. '
                'What stops being judged while it is unset: whether the whole '
                'gate-B lane still fits in ${_laneBudget.inSeconds} s, and '
                'whether it is green when run on its own rather than inside a '
                'full suite');
  });
}

// ---------------------------------------------------------------------------
// Discovery.
// ---------------------------------------------------------------------------

/// One `test('…')` in the gate directory whose name gates at least one row.
final class GateCase {
  const GateCase(this.file, this.name, this._tokens);

  /// The file it was read out of.
  final String file;

  /// The whole test name, as written.
  final String name;

  /// The `(row, arm)` pairs parsed off the front of [name].
  final List<({String row, String? arm})> _tokens;

  /// Every row this case gates.
  List<String> get rows => [for (final token in _tokens) token.row];

  /// The arm letter this case carries for [row], or null if it carries none.
  String? armOf(String row) =>
      _tokens.firstWhere((token) => token.row == row).arm;
}

/// One `.dart` file in the gate directory, with its source and its code.
typedef _Source = ({String name, String source, String code});

/// The grammar a gate case name has to satisfy: one or more `row` or
/// `row+arm` tokens separated by `/`, then a colon and a space.
///
/// The row half is deliberately looser than this registry — `F1` and `G1`
/// parse — so that a case naming a row nobody here declared is reported by
/// the reverse sweep as the stranger it is and pointed back at gate A,
/// rather than vanishing from discovery and reading as no case at all. The
/// same choice, made for the same reason, as gate A parsing `F22`.
final _rowGrammar = RegExp(r'^([FG]\d{1,2}[a-z]?(?:/[FG]\d{1,2}[a-z]?)*): ');

/// One token of that grammar, split into its row and its arm letter.
final _rowToken = RegExp(r'^([FG]\d{1,2})([a-z])?$');

/// A `test('…')` or `test("…")` call, with the first literal of its name.
final _testCall = RegExp(
    '''\\btest\\(\\s*(?:'((?:[^'\\\\]|\\\\.)*)'|"((?:[^"\\\\]|\\\\.)*)")''');

/// Every gate case in [directory].
///
/// Takes the directory as an argument so the empty-directory and
/// one-fabricated-case arms above can falsify it. A discovery function that
/// hard-codes its own input cannot be shown to be looking anywhere — which is
/// the reason this sweep can be trusted during the waves when this
/// `test/gate/` is nearly empty.
List<GateCase> _cases(Directory directory) => [
      for (final file in _gateFiles(directory))
        for (final match in _testCall.allMatches(file.code))
          ..._caseOf(file.name, match.group(1) ?? match.group(2) ?? ''),
    ];

/// Every `test('…')` name in [directory], row-naming or not.
///
/// Wider than [_cases], which drops anything the grammar does not recognise —
/// and the supporting-case arms need exactly what it drops. Reads the same
/// comment-stripped source, so a name that only appears in prose is not a
/// case here either.
Set<String> _caseNames(Directory directory) => {
      for (final file in _gateFiles(directory))
        for (final match in _testCall.allMatches(file.code))
          match.group(1) ?? match.group(2) ?? '',
    };

/// [name] as a gate case, or nothing if it names no row.
List<GateCase> _caseOf(String file, String name) {
  final tokens = _tokensIn(name);
  return tokens.isEmpty ? const [] : [GateCase(file, name, tokens)];
}

/// The row ids a gate registry's source text declares, in declaration order.
///
/// The reconciliation's one crossing into gate A. Matches the `id: 'F1',`
/// field of a `GateRow(` instantiation after comment lines are stripped, so
/// an id mentioned in a doc comment is prose, not a declaration. Held honest
/// by its own matcher arm above, because a text read with a typo in its
/// pattern reports zero against the real file and zero is exactly what the
/// existsSync guard cannot catch.
List<String> _rowIdsDeclaredIn(String source) => [
      for (final match in RegExp(r"id: '([FG]\d{1,2})'")
          .allMatches(_stripCommentLines(source)))
        match.group(1)!,
    ];

/// [_instantReadsIn] against a fabricated source, for the falsification arms.
///
/// The same treatment `_cases` gets from the empty-directory and
/// one-fabricated-case arms, and for the same reason: a sweep held only
/// against the tree it is supposed to police reports green when its patterns
/// have a typo in them.
List<String> _instantReadsOf(String sample) => _instantReadsIn((
      name: 'x.dart',
      source: sample,
      code: _stripCommentLines(sample),
    ));

/// Every instant read of a wall-clock surface in [source], as `file:line —
/// surface`.
///
/// **Statement-scoped, not line-scoped** — the post-07-review implementation,
/// copied whole, because the earlier line-scoped draft passed two ordinary
/// spellings:
///
///  * **a multi-line `expect(`**, which is the house style for anything
///    carrying a `reason:`. The `expect(` and the surface land on different
///    lines and neither line matches on its own.
///  * **bound to a local first.** `final live = panel.client.staleSubscriptions;`
///    reads the surface on one line and the `expect(live, …)` below it names
///    nothing a line scan knew about. A read is a read wherever the result is
///    parked, so a binding carries the surface's name forward to every
///    `expect(` after it in the same file — and a rebinding of the same name
///    from something that is *not* a surface takes the name back.
///
/// Both tests run against the call with **string literals blanked**, so prose
/// in a `reason:` can neither switch the arm off by containing `until(` nor
/// trip it by quoting a surface's name.
///
/// The surfaces are matched on word boundaries, which is not decoration:
/// `linkStates.listen(states.add)` contains `linkState`, and a substring
/// match would tag every transition recorder in the directory as an instant
/// read of the state it is deliberately collecting over a window.
List<String> _instantReadsIn(_Source source) {
  final found = <String>[];
  // Local name -> the surface it was bound from, in source order.
  final tagged = <String, String>{};

  for (final statement in _statementsIn(source.code)) {
    final code = _withoutLiterals(statement.text);

    if (statement.isExpect) {
      if (_windowCalls.any(code.contains)) continue;
      if (statement.lines.any((line) => _exemptionOn(line) != null)) continue;
      for (final surface in _wallClockSurfaces) {
        if (_namesSurface(code, surface)) {
          found.add('${source.name}:${statement.line} — $surface');
        }
      }
      for (final entry in tagged.entries) {
        if (_namesLocal(code, entry.key)) {
          found.add('${source.name}:${statement.line} — ${entry.value} '
              '(via `${entry.key}`)');
        }
      }
      continue;
    }

    // A binding. The surface it was read from travels with the name.
    final surface = _windowCalls.any(code.contains)
        ? null
        : _wallClockSurfaces
            .where((surface) => _namesSurface(code, surface))
            .firstOrNull;
    if (surface == null) {
      tagged.remove(statement.name);
    } else {
      tagged[statement.name!] = surface;
    }
  }
  return found;
}

/// Whether [code] reads [surface] as a member — `client.viewIsStale` counts,
/// `linkStates` does not.
bool _namesSurface(String code, String surface) =>
    RegExp('(?<![\\w\$])$surface(?![\\w\$])').hasMatch(code);

/// Whether [code] names the bare local [name].
///
/// Stricter than [_namesSurface] by one character: a local is an identifier
/// on its own, so `sample.trusted` is a field on somebody else's record and
/// not the local this sweep tagged.
bool _namesLocal(String code, String name) =>
    RegExp('(?<![\\w\$.])$name(?![\\w\$])').hasMatch(code);

/// [text] with the contents of every string literal blanked, spaces for
/// characters so offsets and line breaks survive.
String _withoutLiterals(String text) {
  final out = StringBuffer();
  var quote = '';
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quote.isNotEmpty) {
      if (char == r'\' && i + 1 < text.length) {
        out.write(text[i + 1] == '\n' ? '\n  ' : '  ');
        i++;
        continue;
      }
      if (char == quote) {
        quote = '';
        out.write(char);
        continue;
      }
      out.write(char == '\n' ? '\n' : ' ');
      continue;
    }
    if (char == "'" || char == '"') quote = char;
    out.write(char);
  }
  return out.toString();
}

/// One statement the instant-read sweep judges: an `expect(` call captured
/// whole, or a `final`/`var` binding.
typedef _Statement = ({
  bool isExpect,
  String? name,
  int line,
  List<String> lines,
  String text,
});

/// Every `expect(` call and every local binding in [code], in source order.
///
/// The bracket walk steps over string literals, so a `reason:` containing a
/// bracket or an apostrophe cannot end a call early.
List<_Statement> _statementsIn(String code) {
  final lineStarts = <int>[0];
  for (var i = 0; i < code.length; i++) {
    if (code[i] == '\n') lineStarts.add(i + 1);
  }
  int lineAt(int index) {
    var low = 0;
    var high = lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (lineStarts[mid] <= index) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  List<String> linesOf(int from, int to) =>
      code.substring(lineStarts[lineAt(from) - 1], to).split('\n');

  final found = <_Statement>[];
  var quote = '';
  for (var i = 0; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }

    if (code.startsWith('expect(', i) &&
        (i == 0 || !RegExp(r'[\w$.]').hasMatch(code[i - 1]))) {
      final end = _callEnd(code, i + 6);
      found.add((
        isExpect: true,
        name: null,
        line: lineAt(i),
        lines: linesOf(i, end),
        text: code.substring(i, end),
      ));
      i = end - 1;
      continue;
    }

    if (_bindingHead.matchAsPrefix(code, i) case final head?) {
      // Ends at the first `;` outside a bracket or a literal, so a binding
      // whose initialiser is a multi-line call is one statement.
      final end = _statementEnd(code, head.end);
      found.add((
        isExpect: false,
        name: head.group(1),
        line: lineAt(i),
        lines: linesOf(i, end),
        text: code.substring(i, end),
      ));
      i = head.end - 1;
      continue;
    }
  }
  return found;
}

/// `final name =` or `var name =`, at a statement boundary.
final _bindingHead = RegExp(r'(?<![\w$])(?:final|var)\s+(\w+)\s*=(?!=)');

/// The index just past the `)` that closes a call whose `(` is at [open].
int _callEnd(String code, int open) {
  var depth = 0;
  var quote = '';
  for (var i = open; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return code.length;
}

/// The index of the `;` that ends the statement beginning at [from].
int _statementEnd(String code, int from) {
  var depth = 0;
  var quote = '';
  for (var i = from; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      if (depth == 0) return i;
      depth--;
    } else if (char == ';' && depth == 0) {
      return i;
    }
  }
  return code.length;
}

/// The reason on [line]'s window exemption, or null if it carries none.
///
/// Returns the reason rather than a bool so the caller can judge it: a
/// marker and a justified marker are different things, and only the second
/// one is allowed to suppress an arm.
String? _exemptionOn(String line) =>
    _windowExemption.firstMatch(line)?.group(1)?.trim();

/// The `(row, arm)` pairs at the front of [name].
List<({String row, String? arm})> _tokensIn(String name) {
  final prefix = _rowGrammar.firstMatch(name);
  if (prefix == null) return const [];
  return [
    for (final token in prefix.group(1)!.split('/'))
      if (_rowToken.firstMatch(token) case final parsed?)
        (row: parsed.group(1)!, arm: parsed.group(2)),
  ];
}

/// Every row [name] gates. Used by the matcher arms.
List<String> _rowsIn(String name) => [
      for (final token in _tokensIn(name)) token.row,
    ];

/// The arm letter [name] carries for [row]. Used by the matcher arms.
String? _armIn(String name, String row) =>
    _tokensIn(name).firstWhere((token) => token.row == row).arm;

/// Every gate case in [cases], grouped by the row it gates.
Map<String, List<GateCase>> _byRow(List<GateCase> cases) {
  final grouped = <String, List<GateCase>>{};
  for (final one in cases) {
    for (final row in one.rows) {
      (grouped[row] ??= <GateCase>[]).add(one);
    }
  }
  return grouped;
}

/// Every non-exempt `_test.dart` file in [directory], read.
List<_Source> _gateFiles(Directory directory) => [
      for (final source in _allGateSources(directory))
        if (source.name.endsWith('_test.dart'))
          if (!_notAGateCase.containsKey(source.name)) source,
    ];

/// Every non-exempt `.dart` file in [directory], read.
///
/// Wider than [_gateFiles] because the instant-read sweep is a rule about
/// the directory, not about its cases: a helper that reads `viewIsStale` at
/// an instant hands the flake to every case that calls it.
List<_Source> _allGateSources(Directory directory) {
  if (!directory.existsSync()) return const [];
  return [
    for (final entity
        in directory.listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (entity is File && entity.path.endsWith('.dart'))
        if (!_notAGateCase.containsKey(entity.uri.pathSegments.last))
          (
            name: entity.uri.pathSegments.last,
            source: entity.readAsStringSync(),
            code: _stripCommentLines(entity.readAsStringSync()),
          ),
  ];
}

/// [source] with whole-line `//` and `///` comments blanked out.
///
/// Blanked rather than removed, so a reported line number still matches the
/// file. Trailing comments after code stay, because stripping those safely
/// means parsing string literals and none of the patterns here are written
/// that way.
String _stripCommentLines(String source) => [
      for (final line in source.split('\n'))
        if (line.trimLeft().startsWith('//')) '' else line,
    ].join('\n');

/// Whether [source] declares the `gate` tag in its library header.
bool _carriesTheGateTag(String source) {
  final tags = RegExp(r'@Tags\(\[([^\]]*)\]\)').firstMatch(source);
  if (tags == null) return false;
  return RegExp(r"""['"]gate['"]""").hasMatch(tags.group(1)!);
}

// ---------------------------------------------------------------------------
// The skip rules, re-implemented for this directory.
//
// `platform_skip_audit_test.dart` enforces these over tfc_stateman_contract's
// own test tree and will never see this package; gate A's manifest enforces
// them over tfc_relay_client's gate directory and will never see this one.
// The scanner is ported rather than imported for the same reason both of
// those give: it lives in a test tree that is not on this package's import
// path. The rules are the same three — no unconditional skip, a
// forty-character reason floor, and a computed skip has to trace to a probe.
// ---------------------------------------------------------------------------

/// One skip site: the expression handed to `skip:`/`Skip(`, and the string
/// literals inside it.
typedef _Skip = ({String expression, List<String> literals});

/// Every skip site in [code], with its expression extracted exactly.
///
/// Exactly, rather than to the end of the line, because the house style puts
/// a multi-line ternary after `skip:` and a line-bounded capture reads only
/// the condition. The scan tracks bracket depth and steps over string
/// literals, so a `Skip(` written *inside* a failure message is not a site.
List<_Skip> _skips(String code) {
  final found = <_Skip>[];
  var quote = '';
  for (var i = 0; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (!code.startsWith('skip:', i) && !code.startsWith('Skip(', i)) continue;
    // Both spellings put the colon or bracket that opens the argument at
    // i + 4.
    final expression = _argumentAt(code, i + 4);
    found.add(
        (expression: expression.trim(), literals: _literalsIn(expression)));
  }
  return found;
}

/// The argument text beginning at [from] (which indexes `:` or `(`), up to
/// the comma or closing bracket that ends it at depth zero.
String _argumentAt(String code, int from) {
  var depth = 0;
  var quote = '';
  for (var i = from + 1; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      if (depth == 0) return code.substring(from + 1, i);
      depth--;
    } else if (char == ',' && depth == 0) {
      return code.substring(from + 1, i);
    }
  }
  return code.substring(from + 1);
}

/// Every single-quoted literal in [expression], with adjacent segments
/// joined the way Dart joins them — so a two-line reason is judged as one
/// sentence rather than as two short ones.
List<String> _literalsIn(String expression) {
  final segments = RegExp(r"'((?:[^'\\]|\\.)*)'")
      .allMatches(expression)
      .map((m) => m.group(1)!);
  return segments.isEmpty ? const [] : [segments.join()];
}

/// Whether [expression] skips no matter what the platform says.
///
/// `skip: true` is the obvious spelling. `skip: 'the reason'` is the common
/// one and the one worth catching: a bare string reads like a justification
/// and behaves like `true`.
bool _isUnconditional(String expression) {
  final trimmed = expression.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed == 'true') return true;
  final withoutLiterals = trimmed
      .replaceAll(RegExp(r"'((?:[^'\\]|\\.)*)'"), '')
      .replaceAll(RegExp(r'"((?:[^"\\]|\\.)*)"'), '')
      .trim();
  return withoutLiterals.isEmpty;
}

/// Whether a skip's text comes from a probe rather than from the call site.
final _probeReason = RegExp(r'[sS]kipReason|\.reason\b|\breason\b');

/// Whether [expression] carries a probe's reason, following one level of
/// local indirection.
///
/// `skip: needsIsolates` says nothing on its own; `final needsIsolates =
/// probe.available ? null : probe.reason;` says everything. Refusing to
/// follow the identifier would fail the file that does this correctly and
/// pass the one that writes its excuse inline, which is backwards.
bool _tracesToAProbe(String expression, String code) {
  if (_probeReason.hasMatch(expression)) return true;
  for (final identifier in RegExp(r'\b[a-z]\w*\b').allMatches(expression)) {
    final name = identifier.group(0)!;
    final declaration =
        RegExp('(?:final|const|var)\\s+$name\\s*=([^;]*);', dotAll: true)
            .firstMatch(code);
    if (declaration != null && _probeReason.hasMatch(declaration.group(1)!)) {
      return true;
    }
  }
  return false;
}

/// Whether two lists of nullable strings hold the same values in order.
bool _sameList(List<String?> a, List<String?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
