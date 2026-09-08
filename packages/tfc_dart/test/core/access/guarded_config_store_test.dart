/// The one place an operator's intent to change the plant's wiring meets the
/// access policy, and the one place a row about it is written.
///
/// Everything here runs against two in-memory SQLite databases — the station's
/// local mirror and a stand-in for the shared Postgres — so what is proved is
/// the store's real SQL and the real audit row, not a mock's idea of either.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

const String kStation = 'svn-nes-ot-cl02';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

const AccessPolicy kPolicy = AccessPolicy();

/// Anonymous is the Operator role by construction, and Operator holds
/// `operate` on a real station. An empty group set would make every denial
/// below pass for the wrong reason.
AccessSession anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// `key_mappings` is a `configure` key (`kPrefAccessRules`), so this is the
/// smallest session that may save one.
AccessSession configureSession() => const AccessSession(
      user: AuthenticatedUser(username: 'sigga', roleName: 'Shift Leader'),
      groups: {AccessGroup.operate, AccessGroup.configure},
    );

class RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;
late RecordingSink sink;
late List<AccessDenied> denials;
late AccessSession session;

GuardedConfigStore newGuard() => GuardedConfigStore(
      inner: store,
      policy: kPolicy,
      session: () => session,
      audit: sink,
      station: kStation,
      onDenied: denials.add,
    );

/// The mappings a save hands over. Built through the model so every payload is
/// codec output — a hand-written `{"opcua_node": …}` is structurally a
/// different payload and would make every key diff as changed.
KeyMappings mappingsOf(Map<String, String> keysToIdentifiers) => KeyMappings(
      nodes: {
        for (final entry in keysToIdentifiers.entries)
          entry.key: KeyMappingEntry(
            opcuaNode:
                OpcUANodeConfig(namespace: 4, identifier: entry.value),
          ),
      },
    );

Future<List<ConfigItemRow>> remoteMappingRows() =>
    (remote.select(remote.configItemTable)
          ..where((t) => t.kind.equals(ConfigKind.keyMapping.wireName)))
        .get();

Future<List<ConfigChangeRow>> remoteChanges() =>
    (remote.select(remote.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = ConfigStore(
      local: local,
      stationScope: kStationScope,
      station: kStation,
    );
    sink = RecordingSink();
    denials = <AccessDenied>[];
    session = configureSession();
    await store.open();
  });

  tearDown(() async {
    await store.close();
    await local.close();
    await remote.close();
  });

  /// Points the store at the stand-in remote with the sync engine off: these
  /// tests drive the write path, and a background reconcile would answer for
  /// them.
  void attach() => store.attachRemoteDatabase(remote, startSync: false);

  group('a permitted save', () {
    test(
        'writes one audit row whose action id is the one the config_change '
        'rows carry', () async {
      attach();
      final guard = newGuard();

      final result = await guard.saveKeyMappings(
          mappingsOf({'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'}));

      expect(sink.rows, hasLength(1));
      final row = sink.rows.single;
      expect(row.surface, 'pref');
      expect(row.itemKey, 'key_mappings');
      expect(row.allowed, isTrue);
      expect(row.who, 'sigga');
      expect(row.roleName, 'Shift Leader');
      expect(row.station, kStation);
      expect(row.groupRequired, AccessGroup.configure.name);
      expect(row.origin, 'operator');

      // SC-2's trail: one audit row, N change rows, joined by action_id.
      final changes = await remoteChanges();
      expect(changes, hasLength(1));
      expect(changes.single.actionId, row.actionId);
      expect(changes.single.entityId, 'CN04.Belt.Speed');
      expect(result.actionId, row.actionId);
      expect(result.diff.added.single.id, 'CN04.Belt.Speed');
    });

    test('the audit row names the keys and carries no mapping payload',
        () async {
      attach();
      final guard = newGuard();

      await guard.saveKeyMappings(mappingsOf({
        'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed',
        'CN07.Belt.Speed': 'GVL.Conveyors[7].Speed',
      }));

      final row = sink.rows.single;
      expect(row.oldValue, isNull,
          reason: 'the old side is the config_change rows, never the audit row');
      final summary = jsonDecode(row.newValue!) as Map<String, dynamic>;
      expect(summary['added'], ['CN04.Belt.Speed', 'CN07.Belt.Speed']);
      expect(summary['changed'], isEmpty);
      expect(summary['removed'], isEmpty);
      expect(row.newValue, isNot(contains('opcua_node')));
      expect(row.newValue, isNot(contains('GVL.Conveyors')));
    });

    test('a save that removes and changes keys says so, by name', () async {
      attach();
      final guard = newGuard();
      await guard.saveKeyMappings(mappingsOf({
        'A.Key': 'gvl.A',
        'B.Key': 'gvl.B',
      }));
      sink.rows.clear();

      await guard.saveKeyMappings(mappingsOf({
        'A.Key': 'gvl.A2',
        'C.Key': 'gvl.C',
      }));

      final summary =
          jsonDecode(sink.rows.single.newValue!) as Map<String, dynamic>;
      expect(summary['added'], ['C.Key']);
      expect(summary['changed'], ['A.Key']);
      expect(summary['removed'], ['B.Key']);
    });

    test('a 3000-key import stays under a kilobyte and says how many it did '
        'not name', () async {
      attach();
      final guard = newGuard();

      await guard.saveKeyMappings(mappingsOf({
        for (var i = 0; i < 3000; i++)
          'CN${i.toString().padLeft(4, '0')}.Belt.Speed': 'GVL.Conveyors[$i]',
      }));

      final row = sink.rows.single;
      expect(utf8.encode(row.newValue!).length, lessThanOrEqualTo(1024));
      final summary = jsonDecode(row.newValue!) as Map<String, dynamic>;
      expect(summary['truncated'], isA<int>());
      expect(summary['truncated'] as int, greaterThan(0));
      expect(
          (summary['added'] as List).length + (summary['truncated'] as int),
          3000);
      expect(row.newValue, isNot(contains('opcua_node')));
    });

    test('the row is written after the store returns, never before', () async {
      // The ordering the class doc commits to, asserted rather than asserted
      // about: the sink counts the shared rows at the instant it is called. A
      // row written first would see zero — and would be claiming a save that
      // an offline store or a lost compare-and-swap could still refuse.
      attach();
      final observed = <int>[];
      final guard = GuardedConfigStore(
        inner: store,
        policy: kPolicy,
        session: () => session,
        audit: _ObservingSink(() async => (await remoteMappingRows()).length,
            observed),
        station: kStation,
      );

      await guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'}));

      expect(observed, [1]);
    });
  });

  group('a save nobody may make', () {
    test('is refused, recorded as refused, and touches nothing', () async {
      attach();
      session = anonymous();
      final guard = newGuard();

      await expectLater(
        guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'})),
        throwsA(isA<AccessDenied>()),
      );

      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.itemKey, 'key_mappings');
      expect(sink.rows.single.who, 'anonymous');
      expect(denials.single.itemKey, 'key_mappings');
      expect(denials.single.required, AccessGroup.configure);
      expect(await remoteMappingRows(), isEmpty);
      expect(await remoteChanges(), isEmpty);
      expect(store.keyMappings.nodes, isEmpty);
    });
  });

  group('a save that changes nothing', () {
    test('leaves no trail at all — Save pressed twice is not an event',
        () async {
      attach();
      final guard = newGuard();
      await guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'}));
      sink.rows.clear();

      final result =
          await guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'}));

      expect(result.diff.isEmpty, isTrue);
      expect(sink.rows, isEmpty);
      expect(await remoteChanges(), hasLength(1));
    });
  });

  group('a save with nowhere to go', () {
    test('throws the store\'s own exception, unwrapped, and writes no row',
        () async {
      final guard = newGuard();

      await expectLater(
        guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'})),
        throwsA(isA<ConfigStoreOfflineException>()),
      );

      // The editor catches the store's type. A wrapper of it would make
      // 02-06's three catch arms unreachable.
      expect(sink.rows, isEmpty);
    });
  });

  group('a kind the table does not name', () {
    test('is an ArgumentError at the call site, not an administer denial',
        () async {
      attach();
      final guard = newGuard();

      // `preference` is the kind the table does not name — and cannot, since
      // a preference row belongs to one station. Pages joined the table when
      // the page editor's save landed (03-06).
      await expectLater(
        guard.write(const <ConfigItem>[],
            kinds: const {ConfigKind.keyMapping},
            checkKind: ConfigKind.preference),
        throwsA(isA<ArgumentError>()),
      );

      expect(sink.rows, isEmpty);
      expect(await remoteMappingRows(), isEmpty);
    });
  });

  group('the kind-generic write', () {
    // Phase 3 writes a page and its assets in one save: the two kinds are one
    // replace set, and `ConfigStore.writeItems` needs both named or the assets
    // would be inserted and never removed. What the guard adds is that the
    // *check* stays one key from one table.

    test('a preference write is refused before any check', () async {
      // `preference` came under sync in 04-05, so it is no longer caught by
      // the shared-set gate — and that is precisely why it needs its own.
      // This call names `keyMapping` as the check kind, so without the refusal
      // it would replace every shared preference in the plant on a `configure`
      // check while the trail recorded a key-mappings edit. Per-key checking
      // is what `writePreference` is for.
      attach();
      final guard = newGuard();

      await expectLater(
        guard.write(const <ConfigItem>[],
            kinds: const {ConfigKind.preference},
            checkKind: ConfigKind.keyMapping),
        throwsA(isA<ArgumentError>()),
      );

      expect(sink.rows, isEmpty, reason: 'refused before the check, so there '
          'is no denial to record either');
      expect(await remoteChanges(), isEmpty);
    });

    test('a page save is checked and recorded as page_editor_data', () async {
      // The gate is `kConfigWriteKeys`, and until 03-06 added the `page` entry
      // this call threw — which is what stopped the page editor's save routing
      // around the check. Both kinds resolve to the one key the policy already
      // classes as `configure` and the trail already uses for a layout change.
      expect(kConfigWriteKeys[ConfigKind.page], 'page_editor_data');
      expect(kConfigWriteKeys[ConfigKind.asset],
          kConfigWriteKeys[ConfigKind.page],
          reason: 'an asset is not separately permissioned from its page');

      attach();
      final guard = newGuard();

      await guard.write(const <ConfigItem>[],
          kinds: const {ConfigKind.page, ConfigKind.asset},
          checkKind: ConfigKind.page);

      expect(await remoteChanges(), isEmpty,
          reason: 'an empty wanted over an empty store is a no-op write');
    });

    test('save is write over exactly one kind', () async {
      attach();
      final guard = newGuard();

      final result = await guard.write(
        keyMappingItems(mappingsOf({'A.Key': 'gvl.A'})),
        kinds: const {ConfigKind.keyMapping},
        checkKind: ConfigKind.keyMapping,
      );

      expect(result.diff.added.map((i) => i.id), ['A.Key']);
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.itemKey, kKeyMappingsPrefKey);
    });
  });

  group('saveKeyMappings', () {
    test('is save(keyMappingItems(wanted), kind: keyMapping) and nothing more',
        () async {
      attach();
      final spy = _SpyingGuard(
        inner: store,
        policy: kPolicy,
        session: () => session,
        audit: sink,
        station: kStation,
      );
      final wanted = mappingsOf({'A.Key': 'gvl.A', 'B.Key': 'gvl.B'});

      await spy.saveKeyMappings(wanted, reason: 'because');

      expect(spy.calls, hasLength(1));
      final call = spy.calls.single;
      expect(call.kind, ConfigKind.keyMapping);
      expect(call.reason, 'because');
      final expected = keyMappingItems(wanted);
      expect(call.wanted.map((i) => i.id), expected.map((i) => i.id));
      expect(call.wanted.map((i) => i.payload), expected.map((i) => i.payload));
      expect(call.wanted.map((i) => i.kind), expected.map((i) => i.kind));
      expect(call.wanted.map((i) => i.scope.wireName),
          expected.map((i) => i.scope.wireName));
    });
  });

  group('the boot seed', () {
    test('writes the example key once, as the system, with a row', () async {
      attach();
      session = anonymous();
      final guard = newGuard();

      await guard.seedDefaultIfEmpty();

      expect(store.keyMappings.nodes.keys, ['exampleKey']);
      expect(await remoteMappingRows(), hasLength(1));
      final row = sink.rows.single;
      expect(row.origin, 'system');
      expect(row.allowed, isTrue,
          reason: 'the machine\'s own default is not a denial');
      expect(row.itemKey, 'key_mappings');
      expect(row.groupRequired, AccessGroup.configure.name,
          reason: 'the trail shows what authority was skipped, not none');
      expect((await remoteChanges()).single.actionId, row.actionId);
    });

    test('is a silent no-op offline — a station with no Postgres has no '
        'shared configuration', () async {
      final guard = newGuard();

      await guard.seedDefaultIfEmpty();

      expect(store.keyMappings.nodes, isEmpty);
      expect(sink.rows, isEmpty);
    });

    test('is a no-op when the plant already has mappings', () async {
      attach();
      final guard = newGuard();
      await guard.saveKeyMappings(mappingsOf({'A.Key': 'gvl.A'}));
      sink.rows.clear();

      await guard.seedDefaultIfEmpty();

      expect(store.keyMappings.nodes.keys, ['A.Key']);
      expect(sink.rows, isEmpty);
    });

    test('a station that loses the race writes nothing and does not throw',
        () async {
      // Another station seeded the same key between this station's reconcile
      // and its seed. The insert loses on the primary key; a boot path must
      // absorb that rather than take the panel down.
      attach();
      final guard = newGuard();
      await remote.into(remote.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.keyMapping.wireName,
              id: 'exampleKey',
              scope: ConfigScope.shared.wireName,
              payload: keyMappingItems(kExampleKeyMappings).single.payload,
              rev: const Value(1),
              updatedAt: DateTime.utc(2026, 1, 1),
              updatedBy: 'the-other-station',
            ),
          );

      await guard.seedDefaultIfEmpty();

      expect(await remoteMappingRows(), hasLength(1));
      expect(sink.rows, isEmpty);
    });
  });

  group('the audit summary builder', () {
    test('names every key when it fits', () {
      final summary = auditSummaryOf(ConfigDiff(
        added: keyMappingItems(mappingsOf({'A.Key': 'gvl.A'})),
        changed: const [],
        removed: const [],
      ));

      expect(jsonDecode(summary), {
        'added': ['A.Key'],
        'changed': <String>[],
        'removed': <String>[],
      });
    });

    test('truncates to the byte budget and counts what it dropped', () {
      final items = keyMappingItems(mappingsOf({
        for (var i = 0; i < 3000; i++)
          'a.very.long.key.name.number.${i.toString().padLeft(5, '0')}':
              'gvl.$i',
      }));
      final summary = auditSummaryOf(
          ConfigDiff(added: items, changed: const [], removed: const []));

      final decoded = jsonDecode(summary) as Map<String, dynamic>;
      expect(utf8.encode(summary).length, lessThanOrEqualTo(1024));
      expect((decoded['added'] as List).length + (decoded['truncated'] as int),
          3000);
      expect((decoded['added'] as List), isNotEmpty,
          reason: 'a summary that names nothing is not a summary');
    });

    test('an unnameably large diff still produces valid JSON', () {
      final items = keyMappingItems(mappingsOf({
        for (var i = 0; i < 40; i++) 'k' * 200 + '$i': 'gvl.$i',
      }));
      final summary = auditSummaryOf(
          ConfigDiff(added: items, changed: const [], removed: const []));

      final decoded = jsonDecode(summary) as Map<String, dynamic>;
      expect(utf8.encode(summary).length, lessThanOrEqualTo(1024));
      expect(decoded['truncated'], greaterThan(0));
    });
  });

  group('the dependency guard (D-3)', () {
    test('neither the store nor its guard imports Flutter or dart:ffi', () {
      // D-3 in `docs/relational-config-deferred-defects.md` is what this is
      // for: the config codec's import of `state_man.dart` dragged an
      // open62541 link into the MCP server binary. `ConfigStore` is reached by
      // the backend, the collector and `tfc_mcp_server`, none of which has a
      // Flutter engine — and the guarded wrapper is what Phase 3 will hand
      // pages to, which is exactly where a `package:flutter` import would
      // arrive.
      for (final path in const [
        'lib/core/access/guarded_config_store.dart',
        'lib/core/config/config_store.dart',
        'lib/core/config/config_sync.dart',
      ]) {
        final code = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(code, isNotEmpty);
        expect(code.contains('package:flutter'), isFalse,
            reason: '$path must stay reachable from a process with no Flutter '
                'engine');
        expect(code.contains("dart:ffi"), isFalse,
            reason: '$path must not link a native library into every binary '
                'that reads configuration');
      }
    });
  });
}

/// An [AuditSink] that records what the world looked like when it was called.
class _ObservingSink implements AuditSink {
  _ObservingSink(this._observe, this.observed);

  final Future<int> Function() _observe;
  final List<int> observed;

  @override
  Future<void> record(AuditRecord entry) async => observed.add(await _observe());
}

/// One recorded call to [GuardedConfigStore.save].
class _SavedCall {
  _SavedCall(this.wanted, this.kind, this.reason);

  final List<ConfigItem> wanted;
  final ConfigKind kind;
  final String? reason;
}

/// A guard whose [save] records and does nothing, so the convenience member
/// can be proved to be exactly one delegation.
class _SpyingGuard extends GuardedConfigStore {
  _SpyingGuard({
    required super.inner,
    required super.policy,
    required super.session,
    required super.audit,
    required super.station,
  });

  final List<_SavedCall> calls = [];

  @override
  Future<ConfigWriteResult> save(List<ConfigItem> wanted,
      {required ConfigKind kind, String? reason}) async {
    calls.add(_SavedCall(wanted, kind, reason));
    return ConfigWriteResult(diff: ConfigDiff.none, actionId: 'spy');
  }
}
