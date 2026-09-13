/// The shared preference store, as rows: the `{type, value}` codec both
/// stores share, and the [PreferencesApi] over `kind='preference'` rows at
/// [ConfigScope.shared] that replaces `Preferences`' `flutter_preferences`
/// arm.
///
/// Everything here runs against two in-memory SQLite databases — the station's
/// local mirror and a stand-in for the shared Postgres — so what is proved is
/// the real SQL, the real audit row and the real change row, not a mock's idea
/// of any of them.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';

const String kStation = 'svn-nes-ot-cl02';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

const AccessPolicy kPolicy = AccessPolicy();

/// `alarm_man_config` is a `configure` key and `collector_config` an
/// `administer` one (`kPrefAccessRules`), which is what makes the per-key
/// group observable rather than asserted.
AccessSession configureSession() => const AccessSession(
      user: AuthenticatedUser(username: 'sigga', roleName: 'Shift Leader'),
      groups: {AccessGroup.operate, AccessGroup.configure},
    );

AccessSession administerSession() => const AccessSession(
      user: AuthenticatedUser(username: 'jon', roleName: 'Engineer'),
      groups: {
        AccessGroup.operate,
        AccessGroup.configure,
        AccessGroup.setpoints,
        AccessGroup.administer,
      },
    );

/// A Shift Leader: recipes and nothing else above `operate`. The `.recipes`
/// suffix rule is the only one that resolves to `setpoints`, so this session
/// is what tells that group apart from `configure` and `administer`.
AccessSession setpointsSession() => const AccessSession(
      user: AuthenticatedUser(username: 'sigga', roleName: 'Shift Leader'),
      groups: {AccessGroup.operate, AccessGroup.setpoints},
    );

AccessSession anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

class RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A secure storage that keeps secrets in a map. Secrets never reach a row,
/// and the tests below that touch one are proving exactly that.
class FakeSecureStorage implements MySecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;
late GuardedConfigStore guard;
late RecordingSink sink;
late List<AccessDenied> denials;
late AccessSession session;
late FakeSecureStorage secrets;
late SharedRowPreferences prefs;

/// The shared preference rows on the remote, which is where a shared write
/// has to land for it to have happened at all.
Future<List<ConfigItemRow>> remotePreferenceRows() =>
    (remote.select(remote.configItemTable)
          ..where((t) =>
              t.kind.equals(ConfigKind.preference.wireName) &
              t.scope.equals(ConfigScope.shared.wireName))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<List<ConfigChangeRow>> remoteChanges() =>
    (remote.select(remote.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// Seeds [values] straight into the remote and reconciles, so a test starts
/// from a store that holds them exactly as a sweep would have left it.
Future<void> seedShared(Map<String, (String, Object)> values) async {
  for (final entry in values.entries) {
    final (type, value) = entry.value;
    await remote.into(remote.configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: entry.key,
            scope: ConfigScope.shared.wireName,
            payload: ConfigItem.of(
              kind: ConfigKind.preference,
              id: entry.key,
              value: preferencePayload(type, value),
            ).payload,
            rev: const Value(1),
            updatedAt: DateTime.now(),
            updatedBy: 'seed',
          ),
        );
  }
  await store.reconcile();
}

void main() {
  // Two AppDatabase instances is the design here: the local mirror and the
  // remote are two files with two executors, which is the shape a station
  // runs in.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = ConfigStore(
      local: local,
      stationScope: kStationScope,
      station: kStation,
    );
    await store.open();
    store.attachRemoteDatabase(remote, startSync: false);
    sink = RecordingSink();
    denials = [];
    session = administerSession();
    secrets = FakeSecureStorage();
    guard = GuardedConfigStore(
      inner: store,
      policy: kPolicy,
      session: () => session,
      audit: sink,
      station: kStation,
      onDenied: denials.add,
    );
    prefs = SharedRowPreferences(store: guard, secureStorage: secrets);
  });

  tearDown(() async {
    await prefs.close();
    await store.close();
    await local.close();
    await remote.close();
  });

  // -------------------------------------------------------------------
  // Task 1: the codec, extracted once and shared.
  // -------------------------------------------------------------------

  group('the {type, value} codec', () {
    test('round-trips all five PreferencesApi types', () {
      final cases = <(String, Object)>[
        (kPrefBoolType, true),
        (kPrefIntType, 7),
        (kPrefDoubleType, 7.5),
        (kPrefStringType, '7'),
        (kPrefStringListType, const ['a', 'b']),
      ];
      for (final (type, value) in cases) {
        final item = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'k',
          value: preferencePayload(type, value),
        );
        expect(decodePreferencePayload(item.payload), value,
            reason: 'the $type round trip');
      }
    });

    test('the written tag is what tells 7 from "7", and int from double', () {
      final asInt = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'k',
        value: preferencePayload(kPrefIntType, 1),
      ).payload;
      final asDouble = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'k',
        value: preferencePayload(kPrefDoubleType, 1.0),
      ).payload;
      final asString = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'k',
        value: preferencePayload(kPrefStringType, '1'),
      ).payload;

      // `samePayload` compares with DeepCollectionEquality, for which
      // 1 == 1.0. The tag is what makes the two payloads unequal, and
      // therefore what makes the write happen.
      expect(samePayload(asInt, asDouble), isFalse);
      expect(samePayload(asInt, asString), isFalse);
      expect(decodePreferencePayload(asInt), isA<int>());
      expect(decodePreferencePayload(asDouble), isA<double>());
    });

    test('a malformed payload decodes to null rather than throwing', () {
      // Not JSON; a bare scalar; a tag this build does not know; a value that
      // contradicts its tag; a list holding a non-string. All five read as
      // absent — a row a local user edited by hand costs a default, not a
      // boot.
      expect(decodePreferencePayload('not json at all'), isNull);
      expect(decodePreferencePayload('7'), isNull);
      expect(decodePreferencePayload('{"type":"Duration","value":1}'), isNull);
      expect(decodePreferencePayload('{"type":"bool","value":"yes"}'), isNull);
      expect(
          decodePreferencePayload('{"type":"List<String>","value":[1]}'), isNull);
      expect(decodePreferencePayload('{"type":"int"}'), isNull);
    });

    test('the wire bytes are the ones already on disk', () {
      // Fixtures copied from real encoded values written by
      // `SqlitePreferences` before the codec was extracted. A change to any of
      // these makes every existing local row unreadable.
      const fixtures = <String, Object>{
        '{"type":"bool","value":true}': true,
        '{"type":"int","value":7}': 7,
        '{"type":"double","value":7.0}': 7.0,
        '{"type":"String","value":"7"}': '7',
        '{"type":"List<String>","value":["a","b"]}': ['a', 'b'],
      };
      for (final entry in fixtures.entries) {
        expect(decodePreferencePayload(entry.key), entry.value);
      }
      // And the encoder still produces exactly those bytes.
      expect(
          ConfigItem.of(
            kind: ConfigKind.preference,
            id: 'k',
            value: preferencePayload(kPrefBoolType, true),
          ).payload,
          '{"type":"bool","value":true}');
    });

    test('a whole-numbered double stored as 7 still reads as a double', () {
      final value = decodePreferencePayload('{"type":"double","value":7}');
      expect(value, isA<double>());
      expect(value, 7.0);
    });

    test('preferenceTypeOf names the five and refuses everything else', () {
      expect(preferenceTypeOf(true), kPrefBoolType);
      expect(preferenceTypeOf(7), kPrefIntType);
      expect(preferenceTypeOf(7.5), kPrefDoubleType);
      expect(preferenceTypeOf('7'), kPrefStringType);
      expect(preferenceTypeOf(const ['a']), kPrefStringListType);
      expect(preferenceTypeOf(const <String>[]), kPrefStringListType);
      expect(preferenceTypeOf(null), isNull);
      expect(preferenceTypeOf(const [1, 2]), isNull);
      expect(preferenceTypeOf(Duration.zero), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Task 2: the store.
  // -------------------------------------------------------------------

  group('reads', () {
    test('answer from the shared snapshot, typed', () async {
      await seedShared({
        'alarm_man_config': (kPrefStringType, '{"alarms":[]}'),
        'update_channel': (kPrefStringType, 'stable'),
        'a.recipes': (kPrefStringListType, const ['one', 'two']),
        'a_flag': (kPrefBoolType, true),
        'a_count': (kPrefIntType, 3),
      });

      expect(await prefs.getString('alarm_man_config'), '{"alarms":[]}');
      expect(await prefs.getString('update_channel'), 'stable');
      expect(await prefs.getStringList('a.recipes'), ['one', 'two']);
      expect(await prefs.getBool('a_flag'), isTrue);
      expect(await prefs.getInt('a_count'), 3);
      expect(await prefs.getKeys(), {
        'alarm_man_config',
        'update_channel',
        'a.recipes',
        'a_flag',
        'a_count',
      });
      expect(await prefs.containsKey('update_channel'), isTrue);
    });

    test('a missing key answers null, not a throw', () async {
      expect(await prefs.getString('never_written'), isNull);
      expect(await prefs.getBool('never_written'), isNull);
      expect(await prefs.containsKey('never_written'), isFalse);
    });

    test('station rows are invisible: this store reads shared scope only',
        () async {
      // The watermark and the import marker are `kind='preference'` rows at
      // station scope. A store that could see them would offer this station's
      // bookkeeping to every caller as a setting.
      await local.into(local.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.preference.wireName,
              id: 'startup_url',
              scope: kStationScope.wireName,
              payload: '{"type":"String","value":"/local"}',
              rev: const Value(1),
              updatedAt: DateTime.now(),
              updatedBy: 'anonymous',
            ),
          );
      await store.open();

      expect(await prefs.getString('startup_url'), isNull);
      expect(await prefs.getKeys(), isEmpty);
    });
  });

  group('writes', () {
    test('one preference write leaves its siblings alone', () async {
      await seedShared({
        'alarm_man_config': (kPrefStringType, 'a'),
        'collector_config': (kPrefStringType, 'b'),
        'update_channel': (kPrefStringType, 'stable'),
      });

      await prefs.setString('update_channel', 'beta');

      // Three rows, not one. `writeItems` replaces within kinds, so a write
      // that passed only the key it touched would delete the other two.
      final rows = await remotePreferenceRows();
      expect(rows.map((r) => r.id),
          ['alarm_man_config', 'collector_config', 'update_channel']);
      expect(await prefs.getString('alarm_man_config'), 'a');
      expect(await prefs.getString('collector_config'), 'b');
      expect(await prefs.getString('update_channel'), 'beta');
    });

    test('the change row and the audit row share one action id', () async {
      await prefs.setString('update_channel', 'beta');

      final changes = await remoteChanges();
      expect(changes, hasLength(1));
      expect(changes.single.entityId, 'update_channel');
      expect(changes.single.who, 'jon');
      expect(changes.single.roleName, 'Engineer');
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.actionId, changes.single.actionId);
      expect(sink.rows.single.itemKey, 'update_channel');
    });

    test('an unchanged value writes nothing at all', () async {
      await seedShared({'update_channel': (kPrefStringType, 'stable')});

      await prefs.setString('update_channel', 'stable');

      expect(await remoteChanges(), isEmpty);
      expect(sink.rows, isEmpty);
      expect((await remotePreferenceRows()).single.rev, 1);
    });

    test('int over a whole double is a change, because the tag differs',
        () async {
      await seedShared({'a_number': (kPrefDoubleType, 1.0)});

      await prefs.setInt('a_number', 1);

      expect(await prefs.getInt('a_number'), 1);
      expect(await remoteChanges(), hasLength(1));
    });

    test('remove deletes one row and keeps the rest', () async {
      await seedShared({
        'alarm_man_config': (kPrefStringType, 'a'),
        'update_channel': (kPrefStringType, 'stable'),
      });

      await prefs.remove('update_channel');

      expect((await remotePreferenceRows()).map((r) => r.id),
          ['alarm_man_config']);
      expect(await prefs.getString('update_channel'), isNull);
    });

    test('removing what was never there writes nothing', () async {
      await prefs.remove('never_written');
      expect(await remoteChanges(), isEmpty);
      expect(sink.rows, isEmpty);
    });

    test('clear takes the named keys and leaves the others', () async {
      await seedShared({
        'alarm_man_config': (kPrefStringType, 'a'),
        'collector_config': (kPrefStringType, 'b'),
        'update_channel': (kPrefStringType, 'stable'),
      });

      // The allow list is a REMOVAL list, the same reading `InMemoryPreferences`
      // and `SqlitePreferences` have. Inverted, this wipes the plant.
      await prefs.clear(allowList: {'collector_config'});

      expect((await remotePreferenceRows()).map((r) => r.id),
          ['alarm_man_config', 'update_channel']);
    });
  });

  group('the exempt keys', () {
    test('a key that merely looks like an image keeps its history', () async {
      // Between 04-05 and 04-09 this key was exempt by id prefix, because
      // `image_store.dart` was still writing images as preferences and
      // `config_change` is never pruned — both sides of a 6.7 MB base64
      // payload, per save and per garbage collection, would have been
      // permanent (C-3, through the preference door). 04-09 put the images on
      // `ConfigKind.pageImage`, which is exempt as a kind, and the prefix arm
      // came out with the writes it covered.
      await prefs.setString('page_editor_image:9f86d081', 'aGVsbG8gd29ybGQ=');

      expect((await remotePreferenceRows()).single.id,
          'page_editor_image:9f86d081');
      expect((await remoteChanges()).map((c) => c.entityId),
          ['page_editor_image:9f86d081'],
          reason: 'nothing writes this key any more; if something starts, its '
              'history is a defect worth seeing rather than a silent 13 MB');
      expect(await prefs.getString('page_editor_image:9f86d081'),
          'aGVsbG8gd29ybGQ=');
    });

    test('the envelope ciphertext is a row and no change row', () async {
      await prefs.setString('server_config_envelope', 'ciphertext');

      expect((await remotePreferenceRows()).single.id,
          'server_config_envelope');
      expect(await remoteChanges(), isEmpty);
    });

    test('an ordinary key beside an exempt one still gets its history',
        () async {
      await prefs.setString('server_config_envelope', 'ciphertext');
      await prefs.setString('update_channel', 'beta');

      final changes = await remoteChanges();
      expect(changes.map((c) => c.entityId), ['update_channel']);
    });
  });

  group('the bookkeeping rows', () {
    /// The migration marker as the plant holds it: `kind='preference'`, an
    /// underscore-prefixed id, at SHARED scope — `config_sync.dart` reads it
    /// there to tell an empty remote from an unmigrated one.
    Future<void> seedMarker() => seedShared({
          kPreferencesMigratedMarkerId: (kPrefStringType, '2026-09-08'),
        });

    test('remove refuses to delete one', () async {
      await seedMarker();
      await seedShared({'update_channel': (kPrefStringType, 'stable')});

      await prefs.remove(kPreferencesMigratedMarkerId);

      // The row is still there. Without the guard this deletes it, and every
      // station then reads a fully migrated shared store as one whose
      // migration has not run — after 04-12 has dropped
      // `flutter_preferences`, with nothing left to re-read.
      expect((await remotePreferenceRows()).map((r) => r.id),
          contains(kPreferencesMigratedMarkerId));
      expect(await remoteChanges(), isEmpty,
          reason: 'nothing was written, so there is nothing to historise');
      expect(sink.rows, isEmpty,
          reason: 'a refusal that never reached the guard is not a denial');
      // Silently, and that is the ruling: an internal id is `_`-prefixed and
      // never surfaced by getKeys, so no caller can name one and there is
      // nobody to tell. The assertion that matters is that the row survives.
    });

    test('the sibling beside it is still removable', () async {
      await seedMarker();
      await seedShared({'update_channel': (kPrefStringType, 'stable')});

      await prefs.remove('update_channel');

      expect((await remotePreferenceRows()).map((r) => r.id),
          [kPreferencesMigratedMarkerId]);
    });

    test('clear keeps one too — the two agree', () async {
      await seedMarker();
      await seedShared({
        'update_channel': (kPrefStringType, 'stable'),
        'collector_config': (kPrefStringType, '{}'),
      });

      await prefs.clear();

      expect((await remotePreferenceRows()).map((r) => r.id),
          [kPreferencesMigratedMarkerId]);
    });

    test('a write of an ordinary key does not carry one away', () async {
      await seedMarker();

      // `writeItems` replaces within a kind, so the marker has to be IN the
      // wanted set of every write — invisible is not the same as absent.
      await prefs.setString('update_channel', 'beta');

      expect((await remotePreferenceRows()).map((r) => r.id),
          [kPreferencesMigratedMarkerId, 'update_channel']);
    });

    test('reads are not filtered: the migration must be able to ask', () async {
      await seedMarker();

      // Deliberately asymmetric with the removal rule above. Reading a marker
      // is its entire purpose and destroys nothing; only the delete is
      // refused.
      expect(await prefs.containsKey(kPreferencesMigratedMarkerId), isTrue);
      // It is still no part of the preference surface.
      expect(await prefs.getKeys(), isEmpty);
      expect(await prefs.getAll(), isEmpty);
    });
  });

  group('the guard', () {
    test('resolves the group per key, not per kind', () async {
      // `alarm_man_config` is `configure`; `collector_config` is `administer`.
      // One session that holds configure and not administer must therefore be
      // allowed the first and refused the second.
      session = configureSession();

      await prefs.setString('alarm_man_config', '{"alarms":[]}');
      expect(sink.rows.single.groupRequired, AccessGroup.configure.name);

      await expectLater(
        prefs.setString('collector_config', '{}'),
        throwsA(isA<AccessDenied>()),
      );
      expect(denials.single.required, AccessGroup.administer);
    });

    test('a denied write fails closed: no row anywhere, and an audit row',
        () async {
      session = anonymous();

      await expectLater(
        prefs.setString('update_channel', 'beta'),
        throwsA(isA<AccessDenied>()),
      );

      expect(await remotePreferenceRows(), isEmpty);
      expect(await remoteChanges(), isEmpty);
      expect(sink.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('a key no rule names is administer, not open', () async {
      session = configureSession();
      await expectLater(
        prefs.setString('a_key_nobody_has_ever_heard_of', 'x'),
        throwsA(isA<AccessDenied>()),
      );
      expect(denials.single.required, AccessGroup.administer);
    });

    test('the system path writes with nobody signed in, marked system',
        () async {
      session = anonymous();

      await prefs.systemWrites.setString('alarm_man_config', '{"alarms":[]}');

      expect(await prefs.getString('alarm_man_config'), '{"alarms":[]}');
      expect(sink.rows.single.origin, 'system');
      expect(sink.rows.single.allowed, isTrue);
      expect(denials, isEmpty);
    });
  });

  group('offline', () {
    test('a shared write is refused, not queued and not dropped', () async {
      store.detachRemote();

      await expectLater(
        prefs.setString('update_channel', 'beta'),
        throwsA(isA<ConfigStoreOfflineException>()),
      );
      expect(await prefs.getString('update_channel'), isNull);
    });

    test('an unchanged value offline is refused too', () async {
      await seedShared({'update_channel': (kPrefStringType, 'stable')});
      store.detachRemote();

      // The store refuses before it diffs, deliberately: a caller whose write
      // cannot reach Postgres is told so every time rather than only when it
      // would have written something.
      await expectLater(
        prefs.setString('update_channel', 'stable'),
        throwsA(isA<ConfigStoreOfflineException>()),
      );
    });

    test('reads still answer from the mirror', () async {
      await seedShared({'update_channel': (kPrefStringType, 'stable')});
      store.detachRemote();

      expect(await prefs.getString('update_channel'), 'stable');
    });
  });

  group('secrets', () {
    test('never reach a row', () async {
      await prefs.setString('a_secret', 'hunter2', secret: true);

      expect(secrets.values['a_secret'], 'hunter2');
      expect(await remotePreferenceRows(), isEmpty);
      expect(await remoteChanges(), isEmpty);
      expect(await prefs.getString('a_secret', secret: true), 'hunter2');
      // And the non-secret read does not find it: the two stores are separate.
      expect(await prefs.getString('a_secret'), isNull);
    });

    test('are still checked and recorded, naming neither side of the value',
        () async {
      await prefs.setString('server_config_envelope', 'ciphertext',
          secret: true);

      // `GuardedPreferences` checked and recorded all seven of its write
      // members regardless of where the value landed, and the write that
      // stores the plant's database credentials is the one that must never
      // fall out of the trail.
      expect(sink.rows.single.itemKey, 'server_config_envelope');
      expect(sink.rows.single.allowed, isTrue);
      expect(sink.rows.single.groupRequired, AccessGroup.administer.name);
      // Reading the old value is the single edit that would copy a credential
      // into a permanent, replicated table.
      expect(sink.rows.single.oldValue, isNull);
      expect(sink.rows.single.newValue, isNull);
    });

    test('a session that may not set one is refused, and nothing is written',
        () async {
      session = configureSession();

      await expectLater(
        prefs.setString('server_config_envelope', 'ciphertext', secret: true),
        throwsA(isA<AccessDenied>()),
      );

      expect(secrets.values, isEmpty,
          reason: 'a refused secret write must not reach the keychain');
      expect(sink.rows.single.allowed, isFalse);
      expect(denials.single.required, AccessGroup.administer);
    });

    test('the system arm writes one with nobody signed in', () async {
      session = anonymous();

      await prefs.systemWrites
          .setString('state_man_config', '{"host":"x"}', secret: true);

      expect(secrets.values['state_man_config'], '{"host":"x"}');
      expect(sink.rows.single.origin, 'system');
      expect(sink.rows.single.allowed, isTrue);
    });
  });

  group('the change feed', () {
    test('a remote row change reaches a listener', () async {
      final seen = <String>[];
      final sub = prefs.onPreferencesChanged.listen(seen.add);

      // Somebody else's station wrote it; this one hears through the sweep.
      await seedShared({'alarm_man_config': (kPrefStringType, 'a')});
      await pumpEventQueue();

      expect(seen, contains('alarm_man_config'));
      await sub.cancel();
    });

    test('this station\'s own write fires it too', () async {
      final seen = <String>[];
      final sub = prefs.onPreferencesChanged.listen(seen.add);

      await prefs.setString('update_channel', 'beta');
      await pumpEventQueue();

      expect(seen, ['update_channel']);
      await sub.cancel();
    });
  });

  // -------------------------------------------------------------------
  // The families that ride the swap unchanged (04-09 Task 3). Proved rather
  // than assumed: all three keep their old call sites, and what changed under
  // them is where the value lives.
  // -------------------------------------------------------------------

  group('the recipe buckets', () {
    test('one row per bucket, and a second bucket leaves the first alone',
        () async {
      // `recipes.dart:132` builds the key as `'$bucket.recipes'` — the bucket
      // is a runtime value, so this is N keys and not one.
      await prefs.setString('mince.recipes', '[{"label":"80/20"}]');
      await prefs.setString('brine.recipes', '[{"label":"3%"}]');

      final rows = await remotePreferenceRows();
      expect(rows.map((r) => r.id), ['brine.recipes', 'mince.recipes']);
      // Replace-within-kind: the second bucket's write carries the first in
      // its wanted set, so writing it must not have moved it.
      expect(await prefs.getString('mince.recipes'), '[{"label":"80/20"}]');
      expect(await prefs.getString('brine.recipes'), '[{"label":"3%"}]');
    });

    test('a recipe change is checked at setpoints and gets its history',
        () async {
      session = setpointsSession();

      await prefs.setString('mince.recipes', '[{"label":"80/20"}]');

      expect(sink.rows.single.allowed, isTrue);
      expect(sink.rows.single.itemKey, 'mince.recipes');
      expect(sink.rows.single.groupRequired, 'setpoints');
      expect(sink.rows.single.who, 'sigga');
      // Not exempt, and deliberately so: which recipe the plant ran on a given
      // shift is exactly the trail this milestone exists for.
      final changes = await remoteChanges();
      expect(changes.map((c) => c.entityId), ['mince.recipes']);
      expect(changes.single.newValue, contains('80/20'));
    });

    test('an operator who may not set them is refused, and nothing is written',
        () async {
      session = configureSession();

      await expectLater(prefs.setString('mince.recipes', '[]'),
          throwsA(isA<AccessDenied>()));

      expect(await remotePreferenceRows(), isEmpty);
      expect(denials.single.required, AccessGroup.setpoints);
    });
  });

  group('page_editor_top_level_order', () {
    test('round-trips in order, and the order is what is stored', () async {
      // `page.dart:470` writes `jsonEncode(topLevelOrder)`, so the value is a
      // JSON list inside a string preference. Lists are meaning here — this is
      // the order the menu is drawn in — so the assertion is on the sequence
      // and not on the set.
      const order = ['/packing', '/freezer', '/baader', '/diagnostics'];
      await prefs.setString(
          'page_editor_top_level_order', jsonEncode(order));

      expect(
          jsonDecode(
              (await prefs.getString('page_editor_top_level_order'))!),
          order);

      // And off the row itself, not only off the snapshot this station wrote.
      final row = (await remotePreferenceRows()).single;
      expect(row.id, 'page_editor_top_level_order');
      expect(jsonDecode(decodePreferencePayload(row.payload)! as String),
          order);

      expect(sink.rows.single.groupRequired, 'configure');
      expect((await remoteChanges()).map((c) => c.entityId),
          ['page_editor_top_level_order']);
    });

    test('a reorder is one change row, not one per page', () async {
      const first = ['/a', '/b', '/c'];
      await prefs.setString('page_editor_top_level_order', jsonEncode(first));
      await prefs.setString(
          'page_editor_top_level_order', jsonEncode(['/c', '/b', '/a']));

      final changes = await remoteChanges();
      expect(changes, hasLength(2),
          reason: 'the order is one entity, so a reorder is one row');
      // Both sides of the change hold the whole ordering, which is what makes
      // an undo of a reorder writable without reconstructing anything.
      String orderIn(String? entity) =>
          (jsonDecode(jsonDecode(entity!)['payload']['value'] as String)
                  as List)
              .join(',');
      expect(orderIn(changes.last.oldValue), '/a,/b,/c');
      expect(orderIn(changes.last.newValue), '/c,/b,/a');
    });
  });

  group('update_channel', () {
    test('reads and writes at administer, and lands in the trail', () async {
      await prefs.setString('update_channel', 'latest');

      expect(await prefs.getString('update_channel'), 'latest');
      expect((await remotePreferenceRows()).single.id, 'update_channel');
      expect(sink.rows.single.allowed, isTrue);
      expect(sink.rows.single.groupRequired, 'administer');
      expect((await remoteChanges()).map((c) => c.entityId),
          ['update_channel']);
    });

    test('a Shift Leader cannot move the plant onto a prerelease', () async {
      session = setpointsSession();

      await expectLater(prefs.setString('update_channel', 'latest'),
          throwsA(isA<AccessDenied>()));

      expect(await remotePreferenceRows(), isEmpty);
      expect(denials.single.required, AccessGroup.administer);
    });
  });

  group('isKeyInDatabase', () {
    test('answers from the shared rows', () async {
      await seedShared({'update_channel': (kPrefStringType, 'stable')});
      expect(await prefs.isKeyInDatabase('update_channel'), isTrue);
      expect(await prefs.isKeyInDatabase('alarm_man_config'), isFalse);
    });
  });
}
