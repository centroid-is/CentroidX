/// The fifth contract leg: the same fifty checks, over a **real TimescaleDB**.
///
/// ## What this leg is for, in one sentence
///
/// `contract_test.dart` runs the whole suite against `LocalStateMan` with
/// `supportsDataServices: false`, because a gateway composed without a
/// database has no historian, no saved views and no preference store. This
/// file is the same subject with the database put back, so the seven
/// data-services checks stop being skipped and start being judged — in
/// process, against Postgres, with no wire anywhere.
///
/// ## A FLAG, not a LIST — and the difference matters
///
/// Two different mechanisms retire the two kinds of gap this phase closes, and
/// confusing them sends a reader looking for something that never existed.
///
///  * The **socket legs** empty a *list*. `channel_full_contract_test.dart`,
///    `socket_contract_test.dart` and `ws_contract_test.dart` each carried an
///    `expectUnreachable` set naming thirteen checks, and each of those
///    sentences asserted that the method answered JSON-RPC `-32601`. 10-02
///    through 10-05 removed them a batch at a time as the handlers landed.
///  * **This leg** raises a *boolean*. It never had a list and could not have
///    had one: `expectUnreachable` passes a case only by failing with exactly
///    `-32601`, and an in-process implementation has no wire, no envelope and
///    no error code to produce with. 08-11 wrote `supportsDataServices: false`
///    with that reason at the call site; this file is the result.
///
/// So there is no gap list here to find retired, and looking for one is Trap 4.
/// The flag is the whole record.
///
/// ## Why the database-free leg stays
///
/// The plan's rule decides it: **`dart test --exclude-tags db` must not need a
/// database.** `contract_test.dart` is that lane's contract coverage and keeps
/// `supportsDataServices: false`, which is not a gap being tolerated but a true
/// statement about a gateway with no `collection:` block — the ordinary
/// deployment, and the one `LocalStateMan.timeseries` refuses by name. This
/// file is additive: the same fifty checks over the same class, with the three
/// services composed in. Replacing the pure leg with this one would have put a
/// TimescaleDB behind every offline run of the package.
///
/// ## The fakes are not deleted
///
/// `fake_data_services.dart:11-18` says what has to survive their replacement
/// is the contract, not the code, and the fakes stay for two live reasons:
/// they are `parity_test.dart:107`'s reference leg, and they are the sabotage
/// baseline — an arm that breaks the database implementation has to be able to
/// show the same check still passing against something.
///
/// ## Sharing a database with 8b, and with the other Phase 10 db legs
///
/// Every timeseries table this file touches carries the `gw_` prefix and a
/// per-run random suffix, and `tearDownAll` drops what it created — the same
/// rule `timeseries_read_test.dart` and 8b's `side_by_side_test.dart` follow,
/// and the reason the two phases can point at one server.
///
/// `flutter_preferences` and the four history-view tables cannot be prefixed:
/// they are drift's own schema and the contract's preference keys are literal
/// strings inside the kit. Those rows are deleted by name in `setUp` and
/// `tearDownAll` instead. See the SUMMARY's note on the residual cross-suite
/// hazard in `TIMESCALEDB_EXTERNAL` mode, where every db suite shares one
/// server rather than getting its own container.
@TestOn('vm')
@Tags(['db', 'contract'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:math';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
// `TimeseriesData` is spelled in both packages — the seam's own doc comment
// (`timescale_reader.dart`) says the two are the same shape and that the
// protocol's is the wire one. Hidden here rather than prefixed so the seeding
// helper's signature matches the kit's lever exactly.
import 'package:tfc_dart/core/database.dart' hide TimeseriesData;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_local/src/data/history_view_store.dart';
import 'package:tfc_relay_local/src/data/preference_store.dart';
import 'package:tfc_relay_local/src/data/timescale_reader.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/harnessed_local_state_man.dart';
import 'support/timescale_fixture.dart';

late TimescaleFixture fx;
late pg.Connection admin;
late Database writer;

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

/// Wire name → the physical table the gateway would have collected into.
///
/// **The prefix is the isolation** (T-10-46). `gw_` is 8b's convention for
/// "the gateway wrote this", and the suffix keeps two runs of this file off
/// each other's rows. An unprefixed `st101_cn01_mot01_setpoint` is a name the
/// plant's own HMI could plausibly be collecting into right now, which is
/// exactly the collision `side_by_side_test.dart` exists to prevent.
final Map<String, String> physicalTables = <String, String>{
  recordedSeries: 'gw_${recordedSeries}_$suffix',
  unrecordedSeries: 'gw_${unrecordedSeries}_$suffix',
};

/// The preference keys the kit's two preference cases write.
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

DatabaseConfig dbConfig() => DatabaseConfig(
      postgres: pg.Endpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      sslMode: pg.SslMode.disable,
      connectTimeout: const Duration(seconds: 5),
      queryTimeout: const Duration(seconds: 5),
      applicationName: 'relay-contract-db',
    );

/// The resolver the reader is given: the collection plan, expressed directly.
///
/// The same shape `timeseries_read_test.dart` uses, and for the same reason —
/// what a wire name means is the collection config's answer in production, and
/// a leg that invented a second mapping would be judging its own fixture.
final class ContractResolver implements SeriesResolver {
  const ContractResolver();

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    final table = physicalTables[address.series];
    if (table == null) return null;
    return ResolvedSeries(
        table: table, member: address.member, plantKey: address.series);
  }

  @override
  String? keyForTable(String table) => physicalTables.entries
      .where((entry) => entry.value == table)
      .map((entry) => entry.key)
      .firstOrNull;

  @override
  String? keyForNode(String nodeId) => null;
}

/// Puts rows in front of the reader the way the recorder would.
///
/// **Through the same `Database` the reader reads.** Not a second insert path:
/// a leg that wrote its rows by a route nothing else uses would prove the
/// reader can read rows of a shape no collector ever produces. `Database.
/// insertTimeseriesData` + `flush` is literally what `TimescaleSink` does per
/// entry, so the rows here have the columns and the types 8b-03 measured.
Future<void> record(String wireName, List<TimeseriesData> points) async {
  final table = physicalTables[wireName];
  if (table == null) {
    fail('the contract seeded "$wireName", which this leg has no physical '
        'table for. Add it to physicalTables — a seed that goes nowhere is a '
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
/// Measured in `tearDownAll` and asserted in a case, rather than measured in
/// the case: the assertion is about the state the run *left behind*, and the
/// only connection that can see it is closed by the same teardown that drops
/// the tables. A `null` here is a probe that did not happen, which the case
/// reports as a failure rather than as an empty list — an isolation check that
/// silently measures nothing is worse than none.
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

void main() {
  var ran = 0;
  final before = contractCasesRegistered;

  group('the whole contract, over LocalStateMan and a real TimescaleDB', () {
    setUpAll(() async {
      // SEC-01: this process must never reach a keychain. `Preferences.create`
      // asks `SecureStorage.getInstance()` unconditionally and outside its own
      // try (`preferences.dart:219-220`), so the refusing backend goes in
      // before the first store is built — the same line
      // `preferences_read_test.dart` opens with, and for the same reason.
      SecureStorage.setInstance(const NoSecretStorage());
      fx = await TimescaleFixture.start();
      admin = await fx.connect();
      writer = Database(await AppDatabase.create(dbConfig()));
      await writer.open();
      // Both tables exist before any case runs, and the unrecorded one stays
      // empty for the whole file. A table that is not there is
      // `SeriesTableMissing` (10-10), which is the right answer to a
      // misconfigured series and the wrong answer to a series that simply has
      // nothing in the window — and telling those two apart is the whole of
      // `checkTimeseriesMultipleReturnsAnEntryPerTable`.
      for (final table in physicalTables.values) {
        await createEmpty(table, 0);
      }
    });

    tearDownAll(() async {
      // Before anything is dropped: the question is what this run created,
      // and a cleanup that ran first would answer it for us.
      await probeForUnprefixedTables();
      await admin.execute(
          pg.Sql.named('DELETE FROM flutter_preferences WHERE key = ANY(@k)'),
          parameters: {'k': contractPreferenceKeys});
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
      await fx.stop();
    });

    // Every case starts against an empty series and an untouched preference
    // table. Three cases seed the same logical series and two write the same
    // preference keys; without this, case N would be reading case N-1's rows
    // and reporting it as the reader returning too many.
    setUp(() async {
      ran++;
      await admin
          .execute('TRUNCATE TABLE "${physicalTables[recordedSeries]}"');
      await admin.execute(
          pg.Sql.named('DELETE FROM flutter_preferences WHERE key = ANY(@k)'),
          parameters: {'k': contractPreferenceKeys});
    });

    runStateManContract(
      makeDatabaseBackedLocalStateMan,
      supportsWrites: true,
      readOnlyKey: contractReadOnlyKey,
      supportsBrowse: true,
      browseFixture: gatewayBrowseFixture,
      // -----------------------------------------------------------------
      // TRUE, and the result belongs at the call site where the reason was.
      //
      // 08-11 wrote `false` here with a reason: no historian, no saved views
      // and no preference store existed behind this package, and
      // `LocalStateMan`'s three getters threw an `UnimplementedError` naming
      // 10-01 as the plan that owed them. All three landed — the reader in
      // 10-07, the view store in 10-08, the preference store and its change
      // feed in 10-09 — and `freeze_test.dart`'s
      // `declaredUnimplementedMembers` is 0 because of it.
      //
      // What turning it buys is the phase's strongest claim: the seven
      // data-services checks pass against a real TimescaleDB in process, and
      // the same seven pass over a real socket in `ws_contract_test.dart`,
      // and `parity_test.dart` says the two agree element for element.
      supportsDataServices: true,
      supportsHoldToRun: true,
      // Nothing is unreachable: an in-process peer cannot produce -32601, and
      // there is nothing left for it to be unreachable about.
      expectUnreachable: const <String>{},
    );
  });

  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    /// What the flags entitle this leg to — computed by the kit, never
    /// written down as a number.
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
              'would be least visible: the seven it would take with it are '
              'the seven the whole phase was for');
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
      print('leg 5 (LocalStateMan over TimescaleDB): $registered of '
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
              'Phase 10 and 8b share one server in TIMESCALEDB_EXTERNAL mode '
              'and the plant shares one with its own HMI: an unprefixed '
              '"st101_cn01_mot01_setpoint" is a name the application could '
              'already be collecting into, and writing it is the doubling '
              'defect side_by_side_test.dart:252-256 exists to catch, '
              'arrived at from the other side');
    });
  });
}

/// One `LocalStateMan` with a plant on one side and a database on the other.
///
/// The links, the keymapping, the browse space and the read-only weigher are
/// `contract_test.dart`'s exactly — shared through
/// `buildHarnessedLocalStateMan` rather than copied, so the two legs cannot
/// drift into judging different subjects.
///
/// **Fresh stores per case, one shared connection.** `LocalStateMan.dispose`
/// closes the preference store (it holds a channel subscription on the shared
/// notification socket), so a store shared across cases would be closed by the
/// first teardown and unusable by the second case. The `Database` underneath
/// is deliberately *not* per case: fifty pools against one server is fifty
/// connection storms in a suite whose subject is neither.
StateManApi makeDatabaseBackedLocalStateMan() => buildHarnessedLocalStateMan(
      timeseries: TimescaleReader(
        database: () => writer,
        resolver: const ContractResolver(),
      ),
      historyViews: HistoryViewStore(database: () => writer),
      preferences: PreferenceStore(database: () => writer),
      recorder: record,
    );

/// Removes the views the kit's two history-view cases create.
///
/// By name, never by `DELETE FROM history_view`: the table is drift's own and
/// is shared with `history_view_read_test.dart`, with 8b, and at the plant
/// with the application's own HMI.
Future<void> deleteContractViews() async {
  await admin.execute(
    pg.Sql.named('DELETE FROM history_view WHERE name = ANY(@n)'),
    parameters: {'n': contractViewNames},
  );
}
