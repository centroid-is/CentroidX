/// The phase gate: the write-path sweep as a property, and the operator's day
/// still working.
///
/// **POSIX only, deliberately.** This file shells out to `bash` to run
/// `scripts/sweep-write-paths.sh`, and to `grep` for two of its structural
/// checks. Neither exists on a stock Windows runner, so `setUpAll` dies before
/// a single assertion is reached — a red job that says nothing about the code.
/// The sweep's *conclusions* are platform-independent and are re-checked on
/// macOS and ubuntu on every run, so skipping the third platform costs no
/// coverage. Rewriting the sweep in Dart to gain a third identical answer is
/// not worth the second implementation of it.
///
/// Two things live here, and they are the two halves of the phase's claim.
///
/// **The sweep, re-run and reconciled.** `scripts/sweep-write-paths.sh` is run
/// for real, its hits parsed, and compared against
/// `docs/access-control-write-path-sweep.md` in **both** directions: a hit with
/// no row fails, and a row with no hit fails. Plan 03-03 enumerated the write
/// paths before anything was closed; seven plans have moved the tree since,
/// and without this the document is a snapshot that silently rots. It found
/// one real omission on its first run — `lib/core/network_manager_ops.dart`,
/// in the tree since 2026-08-27 and given no row by the 2026-08-29 sweep. See
/// the document's §4.1 F.
///
/// **Matched by file, never by line.** Every line number in the document's
/// §2.1 changed between the two runs and not one of the calls did: plan 03-10
/// moved five writes from `adb.deleteHistoryView(...)` to
/// `store.deleteHistoryView(...)` and everything below shifted. A check that
/// fails on reformatting gets deleted rather than fixed, so the reconciliation
/// key is the **file path**, and the call shape is checked separately for
/// script section 1 — the section whose grep is by method name and where the
/// fourth bypass hid.
///
/// **Not for CI.** It shells out to bash and reads a markdown document. It
/// belongs in the local suite the phase gate runs, which `flutter test test/`
/// picks up. Do not wire it into `.github/workflows/test.yml`: it would be the
/// slowest job there, and the first thing deleted the week it goes red for a
/// reason nobody has time to read. `scripts/check-preferences-construction.sh`
/// is the part of this that *is* a CI gate, and plan 03-11 owns it.
///
/// The behavioural half complements `test/providers/guard_wiring_test.dart`
/// (plan 03-06) rather than repeating it: that file proves the providers are
/// wrapped; this one proves an anonymous panel can still run the line through
/// them, and that the unmapped-surface branch of `AccessPolicy` sits on the
/// production write path rather than only in `access_policy_test.dart`.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import '../helpers/test_helpers.dart'
    show createTestConfigStore, useInMemoryDeviceLocalPreferences;

// ---------------------------------------------------------------------------
// The sweep, parsed
// ---------------------------------------------------------------------------

const String _kScript = 'scripts/sweep-write-paths.sh';
const String _kDoc = 'docs/access-control-write-path-sweep.md';

/// One hit from the script: a file, a line, and the source text.
class _Hit {
  const _Hit(this.file, this.line, this.text, this.section);

  final String file;
  final int line;
  final String text;

  /// The script section it came from, so a failure can name which grep found
  /// it rather than leaving the reader to guess.
  final String section;

  @override
  String toString() => '[§$section] $file:$line';
}

/// The roots the script searches, as a path alternation.
const String _kRoots =
    r'(?:lib|centroid-hmi/lib|demo|packages/[^/]+/lib)/[^\s:]+\.dart';

final RegExp _hitPattern = RegExp('^($_kRoots):([0-9]+):');
final RegExp _sectionPattern = RegExp(r'^## ([0-9]+)\.');
final RegExp _generatedPattern = RegExp(r'^\s*\[generated\] (\S+\.dart) \(');

/// The seven method names script section 1 greps for. Kept here so the
/// call-level check below is about the *call*, not about a line number.
const Set<String> _kSection1Methods = {
  'createHistoryView',
  'updateHistoryView',
  'deleteHistoryView',
  'addHistoryViewPeriod',
  'deleteHistoryViewPeriod',
  'createTable',
  'updateRetentionPolicy',
};

/// Runs the script once for the whole file. It greps eight roots; running it
/// per test would multiply that by the number of tests for no extra coverage.
({List<_Hit> hits, Set<String> generated, String raw}) _runSweep() {
  final result = Process.runSync('bash', [_kScript]);
  expect(result.exitCode, 0,
      reason: 'the sweep script must run; stderr was:\n${result.stderr}');

  final raw = result.stdout as String;
  final hits = <_Hit>[];
  final generated = <String>{};
  var section = '?';

  for (final line in raw.split('\n')) {
    final sectionMatch = _sectionPattern.firstMatch(line);
    if (sectionMatch != null) {
      section = sectionMatch.group(1)!;
      continue;
    }
    final generatedMatch = _generatedPattern.firstMatch(line);
    if (generatedMatch != null) {
      generated.add(generatedMatch.group(1)!);
      continue;
    }
    final hitMatch = _hitPattern.firstMatch(line);
    if (hitMatch != null) {
      hits.add(_Hit(
        hitMatch.group(1)!,
        int.parse(hitMatch.group(2)!),
        line.substring(hitMatch.end),
        section,
      ));
    }
  }
  return (hits: hits, generated: generated, raw: raw);
}

/// Every `.dart` path in the **first column** of a table row in the document.
///
/// The first column only, deliberately. A path in the "Reached from" column is
/// narrative — `lib/providers/tech_doc.dart` is named there as the place a
/// site is *wired*, not as a site — and counting those would make the reverse
/// direction pass on prose. The first column is where the document commits to
/// a verdict for a file.
Set<String> _claimedFiles(String doc) {
  final pathPattern = RegExp('(?:lib|centroid-hmi/lib|demo|packages/[^/]+/lib)'
      r'/[^\s`,:|]+\.dart');
  final claimed = <String>{};
  for (final line in doc.split('\n')) {
    if (!line.startsWith('|')) continue;
    final cells = line.split('|');
    if (cells.length < 3) continue;
    final first = cells[1].trim();
    if (first.startsWith('---') || first == 'Verdict') continue;
    claimed.addAll(pathPattern.allMatches(first).map((m) => m.group(0)!));
  }
  return claimed;
}

/// The body of one `###` subsection of the document, by its heading prefix.
String _section(String doc, String headingPrefix) {
  final lines = doc.split('\n');
  final start = lines.indexWhere((l) => l.startsWith('### $headingPrefix'));
  expect(start, isNot(-1), reason: 'the document has no "### $headingPrefix"');
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith('### ') || lines[i].startsWith('## ')) {
      end = i;
      break;
    }
  }
  return lines.sublist(start, end).join('\n');
}

// ---------------------------------------------------------------------------
// Doubles for the behavioural half
// ---------------------------------------------------------------------------

/// A `StateMan` that records what reached it and opens no connection.
class _FakeStateMan implements StateMan {
  final List<(String, DynamicValue)> writes = [];
  final Map<String, DynamicValue> values = {};

  @override
  Future<void> close() async {}

  @override
  String resolveKey(String key) => key;

  @override
  Future<DynamicValue> read(String key) async =>
      values[key] ?? DynamicValue(value: null);

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key, value));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The smallest `Preferences` a guard can be built over.
///
/// `Fake` rather than a hand-written implementation: the guard touches
/// `getString` on the permitted path and nothing at all on the refused one, so
/// any other member being reached is a change in the guard that should fail
/// this file loudly rather than be quietly answered.
class _MemoryPreferences extends Fake implements Preferences {
  final Map<String, String> store = {};
  final List<String> writes = [];

  @override
  Future<String?> getString(String key, {bool secret = false}) async =>
      store[key];

  @override
  Future<void> setString(String key, String value,
      {bool saveToDb = true, bool secret = false}) async {
    writes.add(key);
    store[key] = value;
  }
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _MemorySecrets implements MySecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}

const String _kStation = 'test-panel';

/// A surface string `AccessPolicy` does not know. Not 'tag', not 'pref', not
/// 'route' — the case `groupForWireSurface` answers `administer` for.
const String _kUnmappedSurface = 'conveyor-recipe-blob';

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// A container with the real `preferencesProvider` and `stateManProvider`,
/// their inner construction faked, and nothing pointed at a real database or
/// a real PLC. The `guard_wiring_test.dart` idiom from plan 03-06, copied
/// rather than imported — importing another test file executes its top-level
/// state.
({
  ProviderContainer container,
  _RecordingSink sink,
  _FakeStateMan inner,
}) _wiring() {
  final sink = _RecordingSink();
  final inner = _FakeStateMan();

  final container = ProviderContainer(
    overrides: [
      // No Postgres: `Preferences` falls back to its in-memory cache and the
      // local SharedPreferences, which is what a station with no database is.
      databaseProvider.overrideWith((ref) async => null),
      accessRepositoryProvider
          .overrideWith((ref) async => null as AccessRepository?),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      stateManFactoryProvider.overrideWithValue(
        ({
          required StateManConfig config,
          required KeyMappings keyMappings,
          List<DeviceClient> deviceClients = const [],
        }) async =>
            inner,
      ),
      // `collectorProvider` watches `stateManProvider`, so leaving it real
      // would have this test reaching for a database it does not have.
      collectorProvider.overrideWith((ref) async => null),
      // Since 04-05 `preferencesProvider` is backed by the configuration
      // store, so a container without a reachable one is a station with no
      // Postgres — every preference write below would be refused as offline
      // before it was ever checked, and this file is about what the *policy*
      // permits. `sessionOf` rather than `session` because production passes
      // `() => sessionInForce(ref)`.
      configStoreProvider.overrideWith((ref) => createTestConfigStore(
            station: _kStation,
            sessionOf: () => sessionInForce(ref),
            audit: sink,
            onDenied: (denial) => reportAccessDenial(ref, denial),
          )),
    ],
  );
  addTearDown(container.dispose);

  return (container: container, sink: sink, inner: inner);
}

// ---------------------------------------------------------------------------

void main() {
  late List<_Hit> hits;
  late Set<String> generated;
  late String raw;
  late String doc;

  setUpAll(() {
    final swept = _runSweep();
    hits = swept.hits;
    generated = swept.generated;
    raw = swept.raw;
    doc = File(_kDoc).readAsStringSync();
  });

  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    SecureStorage.setInstance(_MemorySecrets());
  });

  // -------------------------------------------------------------------------
  group('the sweep still runs, and finds things', () {
    test('the script produced hits — this file cannot pass vacuously', () {
      // A script that silently stopped matching would make every comparison
      // below trivially true, which is the one way this test could report
      // "green" while proving nothing at all.
      expect(hits, isNotEmpty);
      expect(hits.length, greaterThan(200),
          reason: 'the 2026-08-30 run found 393 hits across eight sections; a '
              'collapse to a handful means the greps stopped matching');
    });

    test('every one of the eight sections is represented', () {
      final sections = hits.map((h) => h.section).toSet();
      for (final n in ['1', '2', '3', '6', '7', '8', '9']) {
        expect(sections, contains(n),
            reason: 'script section $n produced no hits at all');
      }
      // Section 4 is the one that is *meant* to be nearly empty: plan 03-11
      // removed nine of its twelve constructions and CI refuses a tenth. It
      // still has the one sanctioned site, so it is asserted separately rather
      // than dropped from the list above.
      expect(sections, contains('4'));
      expect(raw, contains('lib/providers/preferences.dart'));

      // Section 5 is empty, and that is the finished state rather than a
      // collapsed grep: milestone v1.2 plan 01-06 moved the last six
      // `SharedPreferences.getInstance()` calls onto the device-local store.
      // It is asserted as empty rather than dropped, because the pattern stays
      // in the script while `shared_preferences` remains a readable dependency
      // — a regression to it must show up here.
      //
      // The store those six calls moved TO is what section 4 grew a second
      // constructor for in the same plan, so the sweep did not lose sight of
      // device-local construction when the package under it changed.
      expect(sections, isNot(contains('5')),
          reason: 'section 5 has hits again — something reintroduced '
              'SharedPreferences.getInstance(); it should be reaching '
              'localPreferencesProvider or createDeviceLocalPreferences()');
    });
  });

  group('the sweep and its document agree, in both directions', () {
    test('every file the script finds has a row in the document', () {
      final claimed = _claimedFiles(doc);
      final unrowed = hits
          .map((h) => h.file)
          .toSet()
          .where((f) => !claimed.contains(f))
          .toList()
        ..sort();

      expect(unrowed, isEmpty,
          reason: 'these files reach a store and $_kDoc gives them no '
              'verdict. Add a row — a guard beside an unenumerated hole is '
              'the decorative outcome spec §6 exists to prevent:\n'
              '${unrowed.join('\n')}');
    });

    test('every file the document claims is still found by the script', () {
      final found = hits.map((h) => h.file).toSet();
      final stale = _claimedFiles(doc)
          .where((f) => !found.contains(f) && !generated.contains(f))
          .toList()
        ..sort();

      expect(stale, isEmpty,
          reason: 'these files have a row in $_kDoc and the script no longer '
              'finds them. Either the call site was removed and the row is '
              'stale, or a grep stopped matching:\n${stale.join('\n')}');
    });

    test('the generated file the script collapses is still accounted for', () {
      // The one legitimate asymmetry, asserted rather than left as an
      // exception in the test above: `database_drift.g.dart` has a row and
      // never emits a `file:line` hit, because the script collapses generated
      // files to a counted line by design.
      expect(generated, contains('packages/tfc_dart/lib/core/database_drift.g.dart'));
      expect(_claimedFiles(doc),
          contains('packages/tfc_dart/lib/core/database_drift.g.dart'));
    });

    test('every section-1 call is a method the document names', () {
      // The call-level half. Section 1 greps by method name, which is how the
      // two history-view deletes were found through different receivers; so
      // this asserts the *call*, not the line. A new file calling
      // `deleteHistoryView` fails the file check above; a new *method* landing
      // in this section fails here.
      final section1 = hits.where((h) => h.section == '1');
      expect(section1, isNotEmpty);

      for (final hit in section1) {
        final called = _kSection1Methods.where(hit.text.contains).toList();
        expect(called, isNotEmpty,
            reason: '$hit matched section 1 with none of the seven method '
                'names in its text — the script\'s grep and this list have '
                'diverged');
        for (final method in called) {
          expect(doc, contains(method),
              reason: '$hit calls $method and $_kDoc never mentions it');
        }
      }
    });
  });

  // Named without a count on purpose. It read "two standing verdicts" until
  // plan 06-06 closed §3.3 and made it three; a group whose name has to be
  // re-edited every time the document moves is one that eventually is not.
  group("the document's standing verdicts", () {
    test('§3.1 is closed — no `left open` survives for the knowledge indexes',
        () {
      final body = _section(doc, '3.1');
      expect(body, isNot(contains('left open')),
          reason: 'plan 03-13 closed it at the controls and 03-14 at the '
              'route; a `left open` here contradicts both');

      // And the three rows that point at it agree. A closed finding whose
      // table rows still say `left open` is the defect 03-14 found and fixed.
      for (final index in [
        'drift_tech_doc_index.dart',
        'drift_plc_code_index.dart',
        'drift_drawing_index.dart',
      ]) {
        final row = doc
            .split('\n')
            .firstWhere((l) => l.startsWith('|') && l.contains(index));
        expect(row, contains('guarded by 03-13'));
        expect(row, isNot(contains('left open')));
      }
    });

    test('§3.1 still carries the evidence it was written about', () {
      // A closed finding stripped of its file-and-line list is one nobody can
      // re-check. These are the call sites the finding was raised on.
      final body = _section(doc, '3.1');
      for (final evidence in [
        'lib/tech_docs/tech_doc_upload_service.dart',
        'lib/tech_docs/tech_doc_library_section.dart',
        'lib/drawings/drawing_upload_service.dart',
        'page_editor_data',
      ]) {
        expect(body, contains(evidence),
            reason: '§3.1 no longer names $evidence');
      }
      expect(body, contains('03-13'));
      expect(body, contains('03-14'));
    });

    // Re-pointed by plan 04-09, not deleted. It used to assert that §3.2 was
    // *deferred* and that it did not say `Closed`; 04-09 built the six §7c
    // tools, the proposal-only posture and the `users` gate at the approval,
    // so that assertion had to invert. What did not change is the property
    // the original was defending — the section cannot quietly empty — and the
    // enumeration is still what defends it. Four `contains` became six.
    //
    // A green run of this test now reads as "the closure is recorded and its
    // evidence survives", where before it read "the deferral is recorded".
    // That distinction is the whole reason the name changed with the body: a
    // test whose name still said `deferred` while asserting a closure would
    // be the kind of stale green this file exists to prevent.
    test('§3.2 records the closure, still names Phase 4 and spec §7c, and '
        'still carries its evidence', () {
      final body = _section(doc, '3.2');
      expect(body, contains('Phase 4'),
          reason: 'MCP tool handlers run in-process and reach the same '
              'stores; a section that quietly emptied — whether it was '
              'deferred or closed — is the same defect as a sweep that '
              'never ran');
      expect(body, contains('§7c'));
      expect(body, contains('read_toggles.dart'));
      expect(body, contains('audit_log_service.dart'));

      // The closure itself, and the three things that make it checkable
      // rather than a claim: who applies an accepted proposal, under which
      // group, and how the row says where the change came from.
      expect(body, contains('Closed'),
          reason: '04-09 shipped the §7c tools; a §3.2 that still read as '
              'deferred would contradict the code');
      expect(body, contains('proposal'));
      expect(body, contains('`users`'));
      expect(body, contains("origin = 'mcp'"));

      // The `left open` verdict itself lives on the rows that point here —
      // §3.2's body is the reasoning, the table is where the vocabulary is
      // used. Both have to survive, so both are asserted.
      //
      // They still say `left open`, and that is not an oversight the closure
      // above forgot to tidy: 04-09 closed the **authorization** half. The
      // rows pointing here are `read_toggles.dart` (the copilot's own tool
      // config) and `audit_log_service.dart` (the copilot's own trail),
      // neither of which is authorization data and neither of which §7c
      // scoped. §3.2's body says so in those words, and this pair of
      // assertions is what stops the verdict widening from "the
      // authorization half" to "all of it" without anybody deciding to.
      final pointing = doc
          .split('\n')
          .where((l) => l.startsWith('|') && l.contains('see §3.2'))
          .toList();
      expect(pointing, hasLength(greaterThanOrEqualTo(3)),
          reason: 'the MCP rows that defer to §3.2 have gone');
      for (final row in pointing) {
        expect(row, contains('left open: reached over MCP'),
            reason: 'a row deferring to §3.2 stopped saying it is open: '
                '\n$row');
      }
      expect(body, contains('What stays open'),
          reason: 'the closed verdict has to name what it does NOT cover, or '
              'the rows above read as a contradiction rather than a scope');
    });

    // Added by plan 06-06, in the shape of the `§3.1 is closed` test above
    // rather than the `§3.2` one: §3.3 was a `left open` entry with its
    // closing condition written beside it — "Spec §7c and §9 put roles and
    // users behind `AccessGroup.users`, and Phase 6 builds the screens that
    // drive it. Closing it means gating those screens, not decorating this
    // class." Plan 06-03 built `AccessAdminStore` and met it.
    //
    // Document and table together, or neither: that is the rule 04-12 wrote
    // for §3.2 and it applies here for the same reason. A body saying
    // "closed" beside a row saying `left open` is worse than either alone,
    // because a reader believes whichever they happen to read.
    test('§3.3 is closed — no `left open` survives for the access repository',
        () {
      final body = _section(doc, '3.3');
      expect(body, isNot(contains('left open')),
          reason: 'plan 06-03 put every write to `app_role` and `app_user` '
              'behind `AccessAdminStore` and `kAccessAdminGroup`; a '
              '`left open` here contradicts it');

      // The closure, and the three things that make it checkable rather than
      // a claim: which object closed it, which constant it asks, and where
      // that object lives.
      expect(body, contains('06-03'));
      expect(body, contains('AccessAdminStore'));
      expect(body, contains('kAccessAdminGroup'));
      expect(body, contains('lib/core/access_admin_store.dart'));

      // The scope of the closure, named as explicitly as §3.2 names its own.
      // §3.3 closed the *path*, not the class: the repository is still
      // constructible and still callable by anything holding an
      // `AppDatabase`, and `first_user.dart` calls it on purpose. A section
      // that dropped those sentences would have widened from "the screens are
      // gated" to "the class refuses", which it does not.
      expect(body, contains('does not claim'),
          reason: 'the closed verdict has to name what it does NOT cover, or '
              'a later reader will take the gate for a property of the class');
      expect(body, contains('first_user.dart'));
      expect(body, contains('not decorat'),
          reason: 'the entry said in advance that closing it meant gating the '
              'screens rather than decorating this class; the closure has to '
              'say which of the two it did');

      // And the row that points here agrees. Unlike §3.2 — which closed the
      // authorization half and left its rows open on purpose — §3.3 closed
      // the whole of its entry, so no row deferring to it may still say
      // `left open`.
      final pointing = doc
          .split('\n')
          .where((l) => l.startsWith('|') && l.contains('see §3.3'))
          .toList();
      expect(pointing, hasLength(greaterThanOrEqualTo(1)),
          reason: 'the access-repository row that defers to §3.3 has gone');
      for (final row in pointing) {
        expect(row, contains('guarded by 06-03'),
            reason: 'a row deferring to §3.3 does not carry the closed '
                'verdict, in the vocabulary §2 fixes:\n$row');
        expect(row, isNot(contains('left open')),
            reason: 'a row deferring to §3.3 still says it is open:\n$row');
      }
    });

    test('no file under `lib/pages/` constructs an `AccessRepository`', () {
      // The honest form of §3.3's closure. `AccessRepository` refuses nobody:
      // it takes an `AppDatabase` and writes. The gate lives in
      // `AccessAdminStore`, which means it is a property of the path the UI
      // takes and not of the class — so the checkable statement is that the
      // page layer never builds one for itself and therefore cannot route
      // around the store.
      //
      // `first_user.dart` is not a counter-example and is not an oversight:
      // it *calls* a repository it got from `accessRepositoryProvider`, for
      // the first-user window, which exists precisely for the state where
      // nobody can hold `users` yet. It constructs nothing, so it does not
      // match this grep, and §3.3 names it in as many words.
      final built =
          Process.runSync('grep', ['-rn', 'AccessRepository(', 'lib/pages']);
      expect((built.stdout as String).trim(), isEmpty,
          reason: 'a page builds its own AccessRepository and can then write '
              '`app_role` or `app_user` with no `users` check and no audit '
              'row. That is the bypass §3.3 was closed to prevent, and the '
              'closure is about the path rather than the class, so this is '
              'where it fails.');

      // Not vacuous: the same tool over the same directory, with a pattern
      // that must match. If `lib/pages` moved or the grep found nothing to
      // search, this fails rather than passing on an empty walk.
      final mentioned =
          Process.runSync('grep', ['-rl', 'AccessRepository', 'lib/pages']);
      expect((mentioned.stdout as String).trim(), isNotEmpty,
          reason: 'no file under lib/pages mentions AccessRepository at all — '
              'the search above found nothing to search');
    });

    test('the four `is! DriftPlcCodeIndex` type tests are gone from lib/', () {
      // Plan 03-13 moved them to `PlcCodeIndexExtras`. A revert reddens the
      // four provider tests there — and this, so the phase gate catches it too.
      final result = Process.runSync(
          'grep', ['-rn', 'is! DriftPlcCodeIndex', 'lib']);
      expect((result.stdout as String).trim(), isEmpty,
          reason: 'a concrete-type test against DriftPlcCodeIndex is back; '
              'the wrapped provider hands out a GuardedPlcCodeIndex and the '
              'call-graph panels go silently blank');
    });
  });

  // -------------------------------------------------------------------------
  group('the unmapped surface, on the production write path', () {
    test('GuardedStateMan built with a surface the policy does not know '
        'refuses on administer, and never reaches its inner', () async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();
      final guard = GuardedStateMan(
        inner: inner,
        policy: const AccessPolicy(),
        session: _anonymous,
        audit: sink,
        station: _kStation,
        surface: _kUnmappedSurface,
      );

      await expectLater(
        guard.write('ST101.CN01', DynamicValue(value: true)),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.administer)),
      );

      expect(inner.writes, isEmpty,
          reason: 'a refused write must not reach the PLC');
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.surface, _kUnmappedSurface,
          reason: 'the row records the surface that was checked, unmapped or '
              'not — a row that renamed it would hide the misconfiguration');
    });

    test('GuardedPreferences built with a surface the policy does not know '
        'refuses on administer, and never reaches its inner', () async {
      final inner = _MemoryPreferences();
      final sink = _RecordingSink();
      final guard = GuardedPreferences(
        inner: inner,
        policy: const AccessPolicy(),
        session: _anonymous,
        audit: sink,
        station: _kStation,
        surface: _kUnmappedSurface,
      );

      await expectLater(
        guard.setString('theme_mode', 'dark'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.administer)),
      );

      expect(inner.writes, isEmpty);
      expect(inner.store, isEmpty);
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.surface, _kUnmappedSurface);
    });

    test('`theme_mode` is `operate` on the pref surface — so the refusal above '
        'is the surface, not the key', () async {
      // Without this the two tests above would pass just as well against a
      // key nobody may write, and would say nothing about the unmapped branch.
      const policy = AccessPolicy();
      expect(policy.groupForWireSurface('pref', 'theme_mode'),
          AccessGroup.operate);
      expect(policy.groupForWireSurface(_kUnmappedSurface, 'theme_mode'),
          AccessGroup.administer);
    });
  });

  group('the surface a guard checks is the surface it records', () {
    test('GuardedStateMan: the default surface round-trips', () async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();
      // The default, not a literal: this is the value production uses.
      final guard = GuardedStateMan(
        inner: inner,
        policy: const AccessPolicy(),
        session: _anonymous,
        audit: sink,
        station: _kStation,
      );

      await guard.write('ST101.CN01.p_cmd_JogFwd', DynamicValue(value: true));

      expect(sink.rows, hasLength(1));
      final recorded = sink.rows.single.surface;

      // Compared, not asserted against 'tag'. The property is that the string
      // handed to the policy and the string in the row's surface column are
      // the same one — a literal on both sides would still pass if the guard
      // grew a second surface field.
      const policy = AccessPolicy();
      expect(
        policy.groupForWireSurface(recorded, 'ST101.CN01.p_cmd_JogFwd'),
        policy.groupForTag('ST101.CN01.p_cmd_JogFwd'),
        reason: 'the recorded surface must resolve through the same branch '
            'the check took',
      );
      expect(recorded, AccessSurface.tag.wireName);
    });

    test('GuardedPreferences: the default surface round-trips', () async {
      final inner = _MemoryPreferences();
      final sink = _RecordingSink();
      final guard = GuardedPreferences(
        inner: inner,
        policy: const AccessPolicy(),
        session: _anonymous,
        audit: sink,
        station: _kStation,
      );

      await guard.setString('theme_mode', 'dark');

      expect(sink.rows, hasLength(1));
      final recorded = sink.rows.single.surface;

      const policy = AccessPolicy();
      expect(
        policy.groupForWireSurface(recorded, 'theme_mode'),
        policy.groupForPref('theme_mode'),
        reason: 'the recorded surface must resolve through the same branch '
            'the check took',
      );
      expect(recorded, AccessSurface.pref.wireName);
      expect(sink.rows.single.groupRequired, AccessGroup.operate.name);
    });
  });

  // -------------------------------------------------------------------------
  group("the operator's day, through the wired providers", () {
    test('an anonymous session writes a tag and it reaches the PLC, with one '
        'audit row', () async {
      // The regression that matters most in this phase, and it is asserted at
      // `stateManProvider` rather than at `GuardedStateMan`: the decorator
      // failing open proves nothing if the provider hands out something else.
      final w = _wiring();
      final stateMan = await w.container.read(stateManProvider.future);

      await stateMan.write('ST101.CN01.p_cmd_JogFwd', DynamicValue(value: true));

      expect(w.inner.writes, hasLength(1),
          reason: 'tags fail open until Phase 4 binds access templates; an '
              'anonymous panel must still jog, start, stop and acknowledge');
      expect(w.inner.writes.single.$1, 'ST101.CN01.p_cmd_JogFwd');

      final rows =
          w.sink.rows.where((r) => r.itemKey == 'ST101.CN01.p_cmd_JogFwd');
      expect(rows, hasLength(1),
          reason: 'one hand-made write is one row — not zero, and not one per '
              'member of a struct that did not change');
      expect(rows.single.allowed, isTrue);
      expect(rows.single.station, _kStation);
      expect(rows.single.surface, AccessSurface.tag.wireName);
      expect(rows.single.who, isNotEmpty,
          reason: 'an anonymous write still names who — the trail must not '
              'have a blank subject');
    });

    test('an anonymous session may write `theme_mode` through the wired '
        'provider', () async {
      // The permitted half of plan 03-01's inventory. A panel that cannot
      // change its own appearance is the sign the policy table is too strict.
      final w = _wiring();
      final prefs = await w.container.read(preferencesProvider.future);

      await prefs.setString('theme_mode', 'dark');

      final rows = w.sink.rows.where((r) => r.itemKey == 'theme_mode');
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isTrue);
      expect(rows.single.groupRequired, AccessGroup.operate.name);
    });

    test('an anonymous session may not write `page_editor_data` through the '
        'wired provider', () async {
      // The refused half. `page_editor_data` is `configure`, and it is the
      // key the page editor saves — so this and the route gate must agree.
      final w = _wiring();
      final prefs = await w.container.read(preferencesProvider.future);

      await expectLater(
        prefs.setString('page_editor_data', '{}'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      final rows = w.sink.rows.where(
          (r) => r.itemKey == 'page_editor_data' && r.origin != 'system');
      expect(rows, hasLength(1),
          reason: 'a denial that leaves no row is the repudiation the trail '
              'exists to prevent');
      expect(rows.single.allowed, isFalse);
      expect(rows.single.groupRequired, AccessGroup.configure.name);
    });

    test('an anonymous session may not write a `page.` key either — the '
        'prefix half of the same rule', () async {
      final w = _wiring();
      final prefs = await w.container.read(preferencesProvider.future);

      await expectLater(
        prefs.setString('page.overview.layout', '{}'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );
    });
  });
}
