/// The seventh contract leg: the same fifty-one checks over a **real
/// TimescaleDB**.
///
/// ## What this leg is for, in one sentence
///
/// `test/core/relay/backend_contract_test.dart` runs the whole suite against
/// `BackendStateMan` with `supportsDataServices: false`, because a backend
/// composed without a `Database` has no historian, no saved views and no
/// preference store. This file is the same subject with the database put back,
/// so the **eight** data-services checks stop being skipped and start being
/// judged — in process, against Postgres, with no wire anywhere. Its
/// accounting therefore asserts the FULL roster and an EMPTY gap set, which is
/// criterion 1's "empty gap list" stated as a number in the one leg entitled
/// to claim it.
///
/// ## Why the offline leg stays
///
/// The rule decides it: **`dart test --exclude-tags db` must not need a
/// database.** The offline leg is that lane's contract coverage and keeps
/// `supportsDataServices: false`, which is not a gap being tolerated but a
/// true statement about a backend with no `Database` — the default deployment,
/// and the one `BackendStateMan.timeseries` refuses by name rather than
/// answering with an empty chart. This file is additive.
///
/// ## The port is hardcoded at 15432, and a parallel worktree collides
///
/// `test/integration/docker_compose.dart:42` fixes the proxy port. Two
/// worktrees running any `db` leg at once fight over it, and the loser fails
/// with connection errors that look exactly like a real defect in the code
/// under test. Run this leg alone. `TIMESCALEDB_EXTERNAL=1` points the same
/// fixture at a natively provisioned server instead of Docker Compose.
///
/// ## Table hygiene, and what cannot be prefixed
///
/// Every timeseries table this file touches carries the `gw_` prefix and a
/// per-run random suffix, and `tearDownAll` drops what it created — 8b's rule,
/// and the reason several suites can point at one server. An unprefixed
/// `st101_cn01_mot01_setpoint` is a name the plant's own HMI could plausibly
/// be collecting into right now.
///
/// `flutter_preferences` and the history-view tables **cannot** be prefixed:
/// they are drift's own schema, and the contract's preference keys and view
/// names are literal strings inside the kit. Those rows are deleted by name in
/// `setUp` AND `tearDownAll` instead.
///
/// ## Seeding goes through the shared table derivation
///
/// 13-04 named it: `collectTableName(entry)` in `collector.dart`, five call
/// sites and no sixth spelling. This leg's physical table names are *derived*
/// by that function from the same `CollectEntry` the resolver reads, so a seed
/// and a query cannot disagree. A leg that hand-spelled the table on one side
/// would prove the reader can read rows of a shape no collector ever produces
/// — which is exactly the year-of-flat-charts defect the finding is about.
@TestOn('vm')
@Tags(['db', 'contract'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:math';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart' show CollectEntry, collectTableName;
import 'package:tfc_dart/core/database.dart' hide TimeseriesData;
import 'package:tfc_dart/core/preferences.dart' show Preferences;
import 'package:tfc_dart/core/relay/backend_data_services.dart';
import 'package:tfc_dart/core/relay/key_mapping_series_resolver.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart' show KeyMappings, KeyMappingEntry;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/harnessed_backend_state_man.dart';
import 'docker_compose.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart';

late pg.Connection admin;
late Database writer;

/// Whether `setUpAll` got as far as a live connection.
///
/// The teardown reaches for [admin] and [writer], and a `setUpAll` that died
/// on a missing Docker daemon leaves both uninitialised. Without this guard
/// the run report carries a `LateInitializationError` from `tearDownAll`
/// *underneath* the real cause, and the second error is the one a reader sees
/// first — so the daemon gets diagnosed as a bug in this file.
bool fixtureUp = false;

/// The per-run suffix every physical table name carries.
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

/// The kit's two series names, as they arrive on the `tableName` parameter.
///
/// Read off `data_services_contract.dart:52` and `:56` rather than guessed:
/// the first is seeded by three cases, the second is *deliberately never
/// seeded* and exists so a multi-series query has to answer for a silent
/// series instead of dropping it.
const String recordedSeries = 'st101_cn01_mot01_setpoint';
const String unrecordedSeries = 'st201_cn04_mot01_setpoint';

/// The collection plan this leg pretends the backend was started with.
///
/// One mapped key per wire series, each with a `collect:` block whose `name`
/// is the prefixed physical table. Nothing here spells a table: the name goes
/// in as configuration and comes out through [collectTableName], which is the
/// single derivation `KeyMappingSeriesResolver` also reads.
///
/// Deliberately a *separate* mapping from `contractKeyMappings()`. The value
/// side's `keys` is what `checkKeysListsWhatTheSourceCanServe` judges, and
/// adding two lower-case series names to it would put two tags in the picker
/// that no plant key names.
KeyMappings seriesMappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final series in <String>[recordedSeries, unrecordedSeries])
        series: KeyMappingEntry(
          collect: CollectEntry(key: series, name: 'gw_${series}_$suffix'),
        ),
    });

/// Wire name → the physical table the backend's own collector would write.
///
/// **Through `collectTableName`, never through a string literal.** This is
/// 13-04's finding applied: `KeyMappingSeriesResolver` derives the table it
/// resolves to by calling that function on the same `CollectEntry`, so if the
/// derivation ever changes, the seed and the query move together.
final Map<String, String> physicalTables = <String, String>{
  for (final entry in seriesMappings().nodes.entries)
    entry.key: collectTableName(entry.value.collect!),
};

/// The preference keys the kit's three preference cases write.
///
/// Named here so `setUp` can put the shared table back the way it found it.
/// They are the kit's literals (`data_services_contract.dart`) and cannot be
/// namespaced from this side.
const List<String> contractPreferenceKeys = <String>[
  'svn.ui.darkMode',
  'svn.chart.maxPoints',
  'svn.weigher.tolerance',
  'svn.site.name',
  'svn.page.recent',
  'svn.never.set',
];

/// The view names the kit's two history-view cases create.
const List<String> contractViewNames = <String>['Frystir — vakt 1', 'Vaktir'];

const RetentionPolicy keepEverything =
    RetentionPolicy(dropAfter: Duration.zero);

/// A secure store that refuses, so this process never reaches a keychain.
///
/// `Preferences.create` asks `SecureStorage.getInstance()` unconditionally and
/// outside its own try (`preferences.dart:219`), and the default instance on
/// macOS is `AwsSecureStorage` — which prompts for the login keychain on every
/// fresh binary. A test run must not do that, and nothing reachable from the
/// pipe may ask for secret material anyway (SEC-01).
///
/// Declared here rather than imported: `tfc_relay_local` has one, and that
/// edge would be the dependency cycle `package_edge_test.dart` pins shut.
final class RefusingSecureStorage implements MySecureStorage {
  const RefusingSecureStorage();

  static Never _refuse(String op) => throw StateError(
      'this backend does not handle secret material: $op was asked of the '
      'refusing secure store. Keys are mounted files, not preference rows');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

/// Puts rows in front of the reader the way the collector would.
///
/// **Through the same `Database` the reader reads.** Not a second insert path:
/// a leg that wrote its rows by a route nothing else uses would prove the
/// reader can read rows of a shape no collector ever produces.
/// `Database.insertTimeseriesData` + `flush` is what `Collector` does per
/// entry.
Future<void> record(String wireName, List<TimeseriesData> points) async {
  final table = physicalTables[wireName];
  if (table == null) {
    fail('the contract seeded "$wireName", which this leg has no physical '
        'table for. Add it to seriesMappings() — a seed that goes nowhere is a '
        'case that measures an empty table and says the reader lost the rows');
  }
  for (final point in points) {
    await writer.insertTimeseriesData(table, point.time, point.value);
  }
  await writer.flush();
}

/// Creates [table] as a typed, empty hypertable.
///
/// Typed by an insert and then emptied, rather than by a hand-written CREATE:
/// the column type a collector produces is the one the reader has to cope
/// with, and spelling `BIGINT` here would let the two drift apart silently.
Future<void> createEmpty(String table, Object typeWitness) async {
  await writer.registerRetentionPolicy(table, keepEverything);
  await writer.insertTimeseriesData(table, DateTime.utc(2000), typeWitness);
  await writer.flush();
  await admin.execute('TRUNCATE TABLE "$table"');
}

/// Every unprefixed table this leg's own series names would collide with, as
/// they stood at the end of the run — or null if the probe never got to run.
///
/// Measured in `tearDownAll` and asserted in a case: the assertion is about
/// the state the run *left behind*, and the only connection that can see it is
/// closed by the same teardown that drops the tables. A `null` is a probe that
/// did not happen, which the case reports as a failure rather than as an empty
/// list — an isolation check that silently measures nothing is worse than
/// none.
List<String>? unprefixedTablesLeftBehind;

Future<void> probeForUnprefixedTables() async {
  final found = <String>[];
  for (final wireName in physicalTables.keys) {
    final rows = await admin.execute(
      pg.Sql.named('SELECT count(*) FROM information_schema.tables '
          'WHERE table_name = @t'),
      parameters: {'t': wireName},
    );
    if ((rows.first.first! as int) > 0) found.add(wireName);
  }
  unprefixedTablesLeftBehind = found;
}

/// Removes the views the kit's two history-view cases create.
///
/// By name, never by `DELETE FROM history_view`: the table is drift's own and
/// is shared with every other suite pointed at this server, and at the plant
/// with the application's own HMI.
Future<void> deleteContractViews() async {
  await admin.execute(
    pg.Sql.named('DELETE FROM history_view WHERE name = ANY(@n)'),
    parameters: {'n': contractViewNames},
  );
}

Future<void> deleteContractPreferences() async {
  await admin.execute(
      pg.Sql.named('DELETE FROM flutter_preferences WHERE key = ANY(@k)'),
      parameters: {'k': contractPreferenceKeys});
}

/// The three data services, over the one `Database` this file owns.
///
/// **One connection, fresh services per case.** `BackendStateMan.dispose` does
/// not close the sub-interfaces — they are borrowed from a composition root
/// that outlives the adapter — so a `Database` per case would be fifty-one
/// connection storms in a suite whose subject is neither.
late Preferences preferences;

StateManApi makeDatabaseBackedBackendStateMan() =>
    buildHarnessedBackendStateMan(
      timeseries: BackendTimeseries.overDatabase(
        database: writer,
        resolver: KeyMappingSeriesResolver(keyMappings: seriesMappings()),
        limits: TimeseriesLimits(),
      ),
      historyViews: BackendHistoryViews.overDatabase(database: writer.db),
      preferences: BackendPreferences.overPreferences(preferences),
      recorder: record,
    );

void main() {
  useRunnerBudgets();

  var ran = 0;
  final before = contractCasesRegistered;

  group('the whole contract, over BackendStateMan and a real TimescaleDB', () {
    setUpAll(() async {
      SecureStorage.setInstance(const RefusingSecureStorage());
      await startDockerCompose();
      await waitForDatabaseReady();
      admin = await getTestConnection();
      writer = await connectToDatabase();
      preferences = await Preferences.create(db: writer);
      // Both tables exist before any case runs, and the unrecorded one stays
      // empty for the whole file. A table that is not there is a missing-series
      // refusal, which is the right answer to a misconfigured series and the
      // wrong answer to a series that simply has nothing in the window — and
      // telling those two apart is the whole of
      // `checkTimeseriesMultipleReturnsAnEntryPerTable`.
      for (final table in physicalTables.values) {
        await createEmpty(table, 0);
      }
      fixtureUp = true;
    });

    tearDownAll(() async {
      // Nothing came up, so there is nothing to take down and nothing to
      // measure. `unprefixedTablesLeftBehind` stays null on purpose: the
      // isolation case then fails saying the probe never ran, which is true,
      // rather than passing on an empty list it never measured.
      if (!fixtureUp) return;
      // Before anything is dropped: the question is what this run created, and
      // a cleanup that ran first would answer it for us.
      await probeForUnprefixedTables();
      await deleteContractPreferences();
      await deleteContractViews();
      try {
        await writer.close();
      } catch (_) {
        // A writer a case already closed is not a failure here.
      }
      for (final table in physicalTables.values) {
        await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
      }
      await admin.close();
      await stopDockerCompose();
    });

    // Every case starts against an empty series and an untouched preference
    // table. Three cases seed the same logical series and three write the same
    // preference keys; without this, case N would be reading case N-1's rows
    // and reporting it as the reader returning too many.
    setUp(() async {
      ran++;
      await admin.execute('TRUNCATE TABLE "${physicalTables[recordedSeries]}"');
      await deleteContractPreferences();
      await deleteContractViews();
    });

    runStateManContract(
      makeDatabaseBackedBackendStateMan,
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      browseFixture: defaultBrowseFixture,
      // -----------------------------------------------------------------
      // TRUE, and the result belongs at the call site where the reason was.
      //
      // The offline leg writes `false` with a reason: it composes no
      // `Database`, so 13-05's three classes have nothing behind them. Here
      // they have a real one, and what turning it buys is this phase's
      // strongest claim — the eight data-services checks judged against a real
      // TimescaleDB, with nothing left over.
      supportsDataServices: true,
      supportsHoldToRun: true,
      upstreamWriteAttempts: (api, cmd) =>
          (api as HarnessedBackendStateMan).writes.upstreamAttempts(cmd),
      stallWrites: (api) => (api as HarnessedBackendStateMan).plant.stall(),
      dropLinkWithWritesInFlight: (api) =>
          (api as HarnessedBackendStateMan).killUpstreamWorker(),
      // Nothing is unreachable: an in-process peer cannot produce -32601, and
      // with the database composed there is nothing left for it to be
      // unreachable about either.
      expectUnreachable: const <String>{},
    );
  });

  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    /// What the flags entitle this leg to — computed by the kit, never written
    /// down as a number.
    final entitled = contractCases(
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      supportsDataServices: true,
      supportsHoldToRun: true,
    );

    test('every check the flags entitle this leg to ran against a database',
        () {
      expect(registered, entitled.length,
          reason: 'the umbrella registered $registered of ${entitled.length} '
              'checks. A smaller number means a capability was switched off '
              'rather than met, and this is the leg where switching one off '
              'would be least visible: the eight it would take with it are the '
              'eight this file exists for');
    });

    test('every registered check actually started', () {
      expect(ran, entitled.length,
          reason: '$ran of $registered registered cases actually ran. The '
              'difference is a case registered and then skipped, which the '
              'registration count cannot see');
    });

    test('this leg is short of exactly the access family, named', () {
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());

      // The access family (17-05, 51 -> 78 on the kit roster) is the one
      // NAMED gap: this leg has a plant and a database behind it, but no
      // access surface yet, and the gap is pinned as a set rather than a
      // count so a 28th unjudged check still reddens this arm.
      // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
      expect(gap, accessChecks.keys.toSet(),
          reason: 'the flags leave part of the roster unjudged that is not '
              'the access family ($gap). Outside that named set this leg '
              'exists to have no gap: it is the one with both a plant and a '
              'database behind it');
      expect(registered + gap.length, allContractChecks.length,
          reason: 'registered plus the named access gap must reconcile to '
              'the whole roster; if it does not, a check exists that is '
              'neither run nor accounted for');
      // ignore: avoid_print
      print('leg 7 (BackendStateMan over TimescaleDB): $registered of '
          '${allContractChecks.length} checks registered and $ran ran; '
          'supportsDataServices is true; the ${gap.length} access cases are '
          'off behind supportsAccessControl: false until 17-06/17-08 opt '
          'this leg in (17-14 empties the gap)');
    });

    test('nothing this leg recorded went into an unprefixed table', () {
      final unprefixed = unprefixedTablesLeftBehind;
      expect(unprefixed, isNotNull,
          reason: 'the isolation probe never ran, so this case is measuring '
              'nothing. It runs in the contract group\'s tearDownAll, before '
              'the drops; if that teardown died early, fix that first');
      expect(unprefixed, isEmpty,
          reason: 'this leg created $unprefixed, which carries no gw_ prefix. '
              'Suites share one server in TIMESCALEDB_EXTERNAL mode and the '
              'plant shares one with its own HMI: an unprefixed '
              '"st101_cn01_mot01_setpoint" is a name the application could '
              'already be collecting into');
    });
  });
}
