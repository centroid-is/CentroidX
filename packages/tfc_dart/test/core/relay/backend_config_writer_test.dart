/// The gateway's writer of the plant's shared configuration.
///
/// Everything here runs against two in-memory SQLite databases: one standing
/// in for the plant's Postgres, one for the writer's own ephemeral mirror. No
/// Docker, no Flutter, no socket.
///
/// The properties worth stating before the cases, because each of them is a
/// way this writer could quietly destroy a plant's configuration:
///
///  * **The empty mirror must never delete.** `writeItems` replaces within
///    kinds, and this store's snapshot is permanently empty. A save derived
///    from it would remove every shared preference in the plant.
///  * **One save is one action.** The decorator mints the action id and the
///    change rows have to carry it, or the audit trail shows a verdict with
///    nothing beneath it.
///  * **The station is the panel's, not the gateway's.** One process writes
///    for every panel; the column exists to tell them apart.
///  * **Concurrent calls must not swap action ids.** The writer awaits a read
///    of Postgres before it writes, and json_rpc_2 dispatches into that gap.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/relay/backend_config_writer.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

const String kGateway = 'gateway-host';
const String kPanel = 'svn-nes-ot-cl02';

late AppDatabase plant;
late Database plantHandle;
late BackendConfigWriter writer;

/// A signed-in engineer, as the relay identity would hand one over.
final AccessSession _engineer = AccessSession(
  user: const AuthenticatedUser(
    username: 'jon',
    roleName: 'Engineer',
    displayName: 'Jón',
  ),
  groups: const {AccessGroup.operate, AccessGroup.configure},
  expiresAt: DateTime.utc(2030),
);

/// Puts a shared preference row into the plant, as a station would have.
Future<void> seedPreference(String id, String type, Object value) =>
    plant.into(plant.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: ConfigKind.preference.wireName,
          id: id,
          scope: ConfigScope.shared.wireName,
          payload: ConfigItem.of(
            kind: ConfigKind.preference,
            id: id,
            value: preferencePayload(type, value),
          ).payload,
          rev: const Value(1),
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedBy: 'migration',
        ));

Future<Map<String, String>> preferenceRows() async {
  final rows = await (plant.select(plant.configItemTable)
        ..where((t) => t.kind.equals(ConfigKind.preference.wireName)))
      .get();
  return {for (final row in rows) row.id: row.payload};
}

Future<List<ConfigChangeRow>> changes() =>
    (plant.select(plant.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// The wire family for one identity, over the writer under test.
relay.PreferencesApi identityPreferences({
  bool withoutWriter = false,
  AccessSession? session,
}) =>
    RelayIdentityPreferences(
      reads: _NoReads(),
      writer: withoutWriter ? null : writer,
      session: () => session ?? _engineer,
      station: kPanel,
    );

/// A read half that refuses everything: these cases are about writes, and a
/// read reaching the source would be a case testing the wrong thing.
final class _NoReads implements relay.PreferencesApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('reads are not under test here');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    plant = AppDatabase.inMemoryForTest();
    plantHandle = Database(plant);
    writer = BackendConfigWriter.create(
      remote: plantHandle,
      station: kGateway,
    )!;
  });

  tearDown(() async {
    await writer.close();
    await plant.close();
  });

  group('a write replaces one row and leaves the rest of the plant alone', () {
    test('two untouched preferences survive a write of a third', () async {
      await seedPreference('alarm_man_config', kPrefStringType, '{"a":1}');
      await seedPreference('startup_url', kPrefStringType, '/lines');

      await writer.setPreference(
        'report_config', kPrefStringType, '{"r":2}',
        who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).keys,
          unorderedEquals(['alarm_man_config', 'startup_url', 'report_config']),
          reason: 'the mirror this writer holds is empty; a replace set '
              'derived from it would have deleted the other two');
    });

    test('bookkeeping rows are carried through a write, not diffed away',
        () async {
      await seedPreference('_migration.preferences', kPrefStringType, 'done');

      await writer.setPreference('startup_url', kPrefStringType, '/lines',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).containsKey('_migration.preferences'),
          isTrue,
          reason: 'a station that read a migrated plant as unmigrated would '
              'migrate it a second time');
    });

    test('the value that lands is the payload the app would have written',
        () async {
      await writer.setPreference('retries', kPrefIntType, 7,
          who: 'jon', roleName: 'Engineer', station: kPanel);

      final stored = (await preferenceRows())['retries']!;
      expect(decodePreferencePayload(stored), 7,
          reason: 'the tag that separates 7 from "7" has to survive');
    });

    test('writing the same value again writes no change row', () async {
      await writer.setPreference('startup_url', kPrefStringType, '/lines',
          who: 'jon', roleName: 'Engineer', station: kPanel);
      await writer.setPreference('startup_url', kPrefStringType, '/lines',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect(await changes(), hasLength(1));
    });
  });

  group('attribution is the verified identity, per call', () {
    test('the change row carries the panel, not the gateway', () async {
      await writer.setPreference('startup_url', kPrefStringType, '/lines',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      final row = (await changes()).single;
      expect(row.station, kPanel);
      expect(row.who, 'jon');
      expect(row.roleName, 'Engineer');
    });

    test('two panels writing through one gateway are told apart', () async {
      await writer.setPreference('a', kPrefStringType, '1',
          who: 'jon', roleName: 'Engineer', station: 'panel-a');
      await writer.setPreference('b', kPrefStringType, '2',
          who: 'gudrun', roleName: 'Shift Leader', station: 'panel-b');

      expect(
          {for (final row in await changes()) row.who: row.station},
          {'jon': 'panel-a', 'gudrun': 'panel-b'});
    });
  });

  group('the action id is the decorator\'s', () {
    test('a scoped write lands its change rows under that id', () async {
      await runUnderWriteAction('action-from-the-gate', () async {
        await writer.setPreference('startup_url', kPrefStringType, '/lines',
            who: 'jon', roleName: 'Engineer', station: kPanel);
      });

      expect((await changes()).single.actionId, 'action-from-the-gate');
    });

    test('unscoped, the writer mints its own rather than writing none',
        () async {
      await writer.setPreference('startup_url', kPrefStringType, '/lines',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await changes()).single.actionId, isNotEmpty);
    });

    /// The race the design rejected a mutable field over. The writer awaits a
    /// read of the plant before it writes, and json_rpc_2 dispatches the next
    /// frame into that gap — so a field holding "the next action id" would
    /// have request B's id land on request A's rows.
    test('two writes interleaved keep their own ids', () async {
      final first = runUnderWriteAction('action-A', () async {
        await writer.setPreference('a', kPrefStringType, '1',
            who: 'jon', roleName: 'Engineer', station: kPanel);
      });
      final second = runUnderWriteAction('action-B', () async {
        await writer.setPreference('b', kPrefStringType, '2',
            who: 'jon', roleName: 'Engineer', station: kPanel);
      });
      await Future.wait([first, second]);

      final byKey = {
        for (final row in await changes()) row.entityId: row.actionId,
      };
      expect(byKey, {'a': 'action-A', 'b': 'action-B'});
    });
  });

  group('what a relayed caller may not delete', () {
    test('the key mappings row is refused by name, for everyone', () async {
      await seedPreference('key_mappings', kPrefStringType, '{"nodes":{}}');

      await expectLater(
        writer.removePreference('key_mappings',
            who: 'jon', roleName: 'Engineer', station: kPanel),
        throwsA(isA<UnsupportedError>().having((e) => e.message.toString(),
            'message', contains('refused at the gateway'))),
      );
      expect((await preferenceRows()).containsKey('key_mappings'), isTrue);
      expect(await changes(), isEmpty, reason: 'refused before anything moved');
    });

    test('a clear naming it removes the others and keeps it', () async {
      await seedPreference('key_mappings', kPrefStringType, '{"nodes":{}}');
      await seedPreference('startup_url', kPrefStringType, '/lines');

      await writer.clearPreferences({'key_mappings', 'startup_url'},
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).keys, ['key_mappings'],
          reason: 'a settings page emptying its own section must not fail '
              'over a key it never meant to include, and must not take the '
              "plant's routing with it either");
    });

    test('a clear never takes a bookkeeping row', () async {
      await seedPreference('_migration.preferences', kPrefStringType, 'done');
      await seedPreference('startup_url', kPrefStringType, '/lines');

      await writer.clearPreferences({'_migration.preferences', 'startup_url'},
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).keys, ['_migration.preferences']);
    });

    test('removing a bookkeeping row writes nothing at all', () async {
      await seedPreference('_migration.preferences', kPrefStringType, 'done');

      await writer.removePreference('_migration.preferences',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).keys, ['_migration.preferences']);
      expect(await changes(), isEmpty);
    });

    test('removing a row that is not there is not an error and not a write',
        () async {
      await seedPreference('startup_url', kPrefStringType, '/lines');

      await writer.removePreference('never_stored',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect(await changes(), isEmpty);
    });

    test('an ordinary remove takes the row and leaves its siblings', () async {
      await seedPreference('startup_url', kPrefStringType, '/lines');
      await seedPreference('alarm_man_config', kPrefStringType, '{}');

      await writer.removePreference('startup_url',
          who: 'jon', roleName: 'Engineer', station: kPanel);

      expect((await preferenceRows()).keys, ['alarm_man_config']);
      expect((await changes()).single.op, 'delete');
    });
  });

  /// The gateway must degrade to "configuration writes refused", never to
  /// "backend down". An image without libsqlite3 throws from the mirror's
  /// construction, and under `restart: unless-stopped` a throw at startup is
  /// a crash loop with the plant's acquisition off — while the macOS bench
  /// passes, because macOS ships the library.
  group('a mirror it cannot build is refused writes, not a dead gateway', () {
    test('create answers null and does not throw', () {
      expect(
        BackendConfigWriter.create(
          remote: plantHandle,
          station: kGateway,
          mirrorFactory: () =>
              throw ArgumentError('Failed to load dynamic library'),
        ),
        isNull,
      );
    });

    test('the null writer is what the identity family refuses through', () {
      final degraded = BackendConfigWriter.create(
        remote: plantHandle,
        station: kGateway,
        mirrorFactory: () =>
            throw ArgumentError('Failed to load dynamic library'),
      );
      expect(
        RelayIdentityPreferences(
          reads: _NoReads(),
          writer: degraded,
          session: () => _engineer,
          station: kPanel,
        ).setString('startup_url', '/lines'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('the identity family on the wire', () {
    test('a setString reaches the plant attributed to the session', () async {
      await identityPreferences().setString('startup_url', '/lines');

      final row = (await changes()).single;
      expect(row.who, 'jon');
      expect(row.roleName, 'Engineer');
      expect(row.station, kPanel);
    });

    test('an anonymous session writes as anonymous, never as nobody',
        () async {
      await identityPreferences(
              session: AccessSession.anonymous(const {AccessGroup.configure}))
          .setString('startup_url', '/lines');

      expect((await changes()).single.who, 'anonymous');
    });

    test('underAction reaches the change rows through the wire family',
        () async {
      final family = identityPreferences() as relay.ActionScopedWrites;
      await family.underAction('graded-action',
          () => identityPreferences().setString('startup_url', '/lines'));

      expect((await changes()).single.actionId, 'graded-action');
    });

    test('an unrestricted clear is refused by name', () async {
      await expectLater(
        identityPreferences().clear(),
        throwsA(isA<UnsupportedError>()
            .having((e) => e.message.toString(), 'message',
                contains('no allowList'))),
      );
    });

    test('with no writer, every mutator refuses and names the cause',
        () async {
      final none = identityPreferences(withoutWriter: true);
      for (final call in <(String, Future<void> Function())>[
        ('setString', () => none.setString('k', 'v')),
        ('setBool', () => none.setBool('k', true)),
        ('setInt', () => none.setInt('k', 1)),
        ('setDouble', () => none.setDouble('k', 1.5)),
        ('setStringList', () => none.setStringList('k', const ['v'])),
        ('remove', () => none.remove('k')),
        ('clear', () => none.clear(allowList: const {'k'})),
      ]) {
        await expectLater(call.$2(),
            throwsA(isA<UnsupportedError>().having(
                (e) => e.message.toString(), 'message',
                allOf(contains('preferences.${call.$1}'),
                    contains('libsqlite3')))),
            reason: '${call.$1} must say why, not fail silently');
      }
    });
  });
}
