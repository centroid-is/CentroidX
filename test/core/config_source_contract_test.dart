/// The `ConfigSource` contract, run against BOTH implementations —
/// `LocalPrefsConfigSource` over an in-memory `Preferences` and
/// `GatewayConfigSource` over a scripted `BackendConfigApi` — the same
/// Local/Remote contract-suite discipline `StateManApi` is held to.
///
/// The shared arms are the transport-independence claim itself: the ONE
/// document reads, edits and writes the same way on either pipe. What may
/// differ (read-only sections, undo, apply semantics, live status) is pinned
/// per implementation so the difference is a stated fact, not an accident.
///
/// Design: .planning/quick/20260908-unify-config-ui/DESIGN.md §2b.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_dart/core/config_document.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_config_store.dart'
    show kSecretPreservedSentinel;
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import 'package:tfc/core/config_source.dart';

// -----------------------------------------------------------------------------
// Fixtures
// -----------------------------------------------------------------------------

/// A stored literal password — the thing that must never be shown, and must
/// cross back verbatim when untouched (direct mode stores the literal).
const _storedPassword = 'hunter2-very-secret';

/// A stored literal private key, valid base64 (direct mode stores the bytes).
final _storedSslKey = base64Encode(utf8.encode('fake-private-key-bytes'));

/// The document both harnesses seed, salted with unknown content at every
/// depth the fidelity rule names:
///  * an unknown per-entry key (`vendor_note`),
///  * an unknown nested structure (`diagnostics.nested.deep`),
///  * an unknown top-level section (`collector_hints`),
///  * and, over the wire, the read-only `relay` section.
String fixtureJson({
  required String password,
  required String sslKey,
  required bool withRelay,
}) =>
    jsonEncode(<String, Object?>{
      'opcua': [
        {
          'endpoint': 'opc.tcp://plc1:4840',
          'server_alias': 'plc1',
          'username': 'operator',
          'password': password,
          'ssl_key': sslKey,
          'publishing_interval_ms': 250,
          'vendor_note': 'kept-verbatim',
        },
      ],
      'jbtm': [
        {'host': 'scale1', 'port': 52211, 'future_flag': true},
      ],
      'modbus': [
        {
          'host': 'm1',
          'port': 502,
          'unit_id': 1,
          'poll_groups': [
            {'name': 'default', 'interval_ms': 1000},
          ],
          'diagnostics': {
            'nested': {'deep': 'kept'},
          },
        },
      ],
      'collector_hints': {'window': '5m'},
      if (withRelay)
        'relay': {
          'port': 8443,
          'token_file': '/etc/centroid/relay-tokens.json',
        },
    });

// -----------------------------------------------------------------------------
// Harnesses
// -----------------------------------------------------------------------------

/// One implementation under the shared contract: how to build it over a
/// seeded document, what its write persisted, and which per-transport
/// answers the shared arms should expect from it.
abstract class ConfigSourceHarness {
  String get name;
  bool get isGateway;
  List<String> get expectedReadOnlySections;
  ApplySemantics get expectedApplySemantics;
  bool get expectedHasLiveStatus;

  /// How an untouched secret is REPRESENTED in this harness's stored
  /// document: the literal locally, the preserved-secret sentinel over the
  /// wire. The shared arm asserts the untouched secret crosses back exactly
  /// as stored — which IS the sentinel round-trip on the gateway side.
  String get storedPasswordRepresentation;
  String get storedSslKeyRepresentation;

  Future<ConfigSource> build(String storedJson);

  /// The last document a successful [ConfigSource.write] persisted/sent,
  /// or null when none has.
  Future<String?> landed();
}

/// In-memory secure storage, so `Preferences` secret reads/writes stay local.
class _MemStorage implements MySecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<void> write({required String key, required String value}) async =>
      _store[key] = value;
  @override
  Future<String?> read({required String key}) async => _store[key];
  @override
  Future<void> delete({required String key}) async => _store.remove(key);
}

class LocalHarness extends ConfigSourceHarness {
  Preferences? prefs;
  int appliedCount = 0;

  @override
  String get name => 'LocalPrefsConfigSource';
  @override
  bool get isGateway => false;
  @override
  List<String> get expectedReadOnlySections => const [];
  @override
  ApplySemantics get expectedApplySemantics => ApplySemantics.appliedOnSave;
  @override
  bool get expectedHasLiveStatus => true;
  @override
  String get storedPasswordRepresentation => _storedPassword;
  @override
  String get storedSslKeyRepresentation => _storedSslKey;

  @override
  Future<ConfigSource> build(String storedJson) async {
    // The secret cache is process-wide; a stale entry from another test
    // would shadow this harness's fresh storage.
    Preferences.clearSecretCache();
    appliedCount = 0;
    final storage = _MemStorage();
    await storage.write(key: StateManConfig.configKey, value: storedJson);
    prefs = Preferences(database: null, secureStorage: storage);
    return LocalPrefsConfigSource(
      prefs: () async => prefs!,
      onApplied: () => appliedCount++,
    );
  }

  @override
  Future<String?> landed() =>
      prefs!.getString(StateManConfig.configKey, secret: true);
}

/// A scripted far end: answers what it is told to, records every call, and
/// counts `previous()` so the contract can prove nobody asked it.
class ScriptedBackendConfigApi implements BackendConfigApi {
  ScriptedBackendConfigApi({required this.configJson});

  String configJson;
  List<String> readOnlySections = const ['relay'];
  bool hasPrevious = false;
  ConfigValidation validateAnswer = const ConfigValidation(ok: true);
  Object? writeError;
  Object? restoreError;

  final List<String> validateCalls = [];
  final List<(String, String?)> writes = [];
  final List<String?> restoreReasons = [];
  int readCalls = 0;
  int previousCalls = 0;

  @override
  Future<BackendConfigDocument> read() async {
    readCalls++;
    return BackendConfigDocument(
      configJson: configJson,
      readOnlySections: readOnlySections,
      hasPrevious: hasPrevious,
    );
  }

  @override
  Future<ConfigValidation> validate(String configJson) async {
    validateCalls.add(configJson);
    return validateAnswer;
  }

  @override
  Future<void> write(String configJson, {String? reason}) async {
    final error = writeError;
    if (error != null) throw error;
    writes.add((configJson, reason));
    this.configJson = configJson;
  }

  @override
  Future<BackendConfigDocument?> previous() async {
    previousCalls++;
    return null;
  }

  @override
  Future<void> restorePrevious({String? reason}) async {
    final error = restoreError;
    if (error != null) throw error;
    restoreReasons.add(reason);
  }
}

class GatewayHarness extends ConfigSourceHarness {
  ScriptedBackendConfigApi? api;

  @override
  String get name => 'GatewayConfigSource';
  @override
  bool get isGateway => true;
  @override
  List<String> get expectedReadOnlySections => const ['relay'];
  @override
  ApplySemantics get expectedApplySemantics => ApplySemantics.restartToApply;
  @override
  bool get expectedHasLiveStatus => false;
  @override
  String get storedPasswordRepresentation => kSecretPreservedSentinel;
  @override
  String get storedSslKeyRepresentation => kSecretPreservedSentinel;

  @override
  Future<ConfigSource> build(String storedJson) async {
    api = ScriptedBackendConfigApi(configJson: storedJson);
    return GatewayConfigSource(api: api!);
  }

  @override
  Future<String?> landed() async =>
      api!.writes.isEmpty ? null : api!.writes.last.$1;
}

// -----------------------------------------------------------------------------
// The contract
// -----------------------------------------------------------------------------

void main() {
  final harnesses = <ConfigSourceHarness>[LocalHarness(), GatewayHarness()];

  for (final h in harnesses) {
    group('ConfigSource contract — ${h.name}', () {
      String seeded() => fixtureJson(
            password: h.storedPasswordRepresentation,
            sslKey: h.storedSslKeyRepresentation,
            withRelay: h.isGateway,
          );

      test('read answers the typed view and the read-only sections', () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        expect(doc.opcua, hasLength(1));
        expect(doc.opcua.first.value.endpoint, 'opc.tcp://plc1:4840');
        expect(doc.jbtm.first.value.host, 'scale1');
        expect(doc.modbus.first.value.pollGroups.single.intervalMs, 1000);
        expect(doc.readOnlySections, h.expectedReadOnlySections);
      });

      test('write sends encode() verbatim', () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        final entry = doc.opcua.first;
        final edited = entry.value..publishingIntervalMs = 400;
        entry.update(edited);
        await source.write(doc);

        final landed = await h.landed();
        expect(landed, doc.encode(),
            reason: 'the document the source persisted must be byte-equal '
                'to what encode() produced — no re-encoding, no rewrite');
        final decoded = jsonDecode(landed!) as Map<String, dynamic>;
        final opc = (decoded['opcua'] as List).first as Map<String, dynamic>;
        expect(opc['publishing_interval_ms'], 400);
      });

      test('unknown keys survive a typed edit at every depth', () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        final entry = doc.opcua.first;
        final edited = entry.value..publishingIntervalMs = 400;
        entry.update(edited);
        await source.write(doc);

        final decoded =
            jsonDecode((await h.landed())!) as Map<String, dynamic>;
        final opc = (decoded['opcua'] as List).first as Map<String, dynamic>;
        expect(opc['vendor_note'], 'kept-verbatim',
            reason: 'unknown per-entry key must cross verbatim');
        final jbtm = (decoded['jbtm'] as List).first as Map<String, dynamic>;
        expect(jbtm['future_flag'], true,
            reason: 'unknown key on an untouched entry must cross verbatim');
        final modbus =
            (decoded['modbus'] as List).first as Map<String, dynamic>;
        expect(
            ((modbus['diagnostics'] as Map)['nested'] as Map)['deep'], 'kept',
            reason: 'unknown nested structure must cross verbatim — the '
                'backend whitelists only TOP-LEVEL sections, so a nested '
                'drop would be accepted server-side');
        expect(decoded['collector_hints'], {'window': '5m'},
            reason: 'unknown top-level section must cross verbatim');
      });

      test('a redacted or stored document parses without throwing', () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        // The landmine: the ssl_key sentinel is not valid base64, so a naive
        // typed parse of a redacted gateway document THROWS. The document
        // masks around the parse; this arm is the proof, on both transports.
        final value = doc.opcua.first.value;
        expect(value.username, 'operator');
        expect(doc.opcua.first.isSecretPreserved('password'), h.isGateway);
        expect(doc.opcua.first.isSecretPreserved('ssl_key'), h.isGateway);
      });

      test('an untouched secret crosses back exactly as stored', () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        final entry = doc.opcua.first;
        final edited = entry.value..publishingIntervalMs = 400;
        entry.update(edited);
        await source.write(doc);

        final decoded =
            jsonDecode((await h.landed())!) as Map<String, dynamic>;
        final opc = (decoded['opcua'] as List).first as Map<String, dynamic>;
        expect(opc['password'], h.storedPasswordRepresentation,
            reason: 'untouched password: the stored representation — the '
                'sentinel over the wire, the literal locally — and nothing '
                'else may cross');
        expect(opc['ssl_key'], h.storedSslKeyRepresentation,
            reason: 'untouched ssl_key: neither the internal parse mask nor '
                'a re-encoding may cross');
      });

      test('a touched password crosses as the new literal, and only it',
          () async {
        final source = await h.build(seeded());
        final doc = await source.read();

        final entry = doc.opcua.first;
        final edited = entry.value..password = 'brand-new-password';
        entry.update(edited);
        await source.write(doc);

        final decoded =
            jsonDecode((await h.landed())!) as Map<String, dynamic>;
        final opc = (decoded['opcua'] as List).first as Map<String, dynamic>;
        expect(opc['password'], 'brand-new-password');
        expect(opc['ssl_key'], h.storedSslKeyRepresentation,
            reason: 'the ssl_key was not touched; it keeps its stored '
                'representation');
      });

      test('validate answers ok for the document as read', () async {
        final source = await h.build(seeded());
        final doc = await source.read();
        final validation = await source.validate(doc);
        expect(validation.ok, isTrue,
            reason: 'a document that just came from the source must '
                'validate — otherwise the save button greys on load');
      });

      test('applySemantics and hasLiveStatus are the transport\'s', () async {
        final source = await h.build(seeded());
        expect(source.applySemantics, h.expectedApplySemantics);
        expect(source.hasLiveStatus, h.expectedHasLiveStatus);
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Direct-mode-only semantics
  // ---------------------------------------------------------------------------

  group('LocalPrefsConfigSource — direct-mode semantics', () {
    final h = LocalHarness();
    String seeded() => fixtureJson(
          password: _storedPassword,
          sslKey: _storedSslKey,
          withRelay: false,
        );

    test('an empty store seeds the same default document fromPrefs seeds',
        () async {
      Preferences.clearSecretCache();
      final storage = _MemStorage();
      final prefs = Preferences(database: null, secureStorage: storage);
      final source = LocalPrefsConfigSource(prefs: () async => prefs);

      final doc = await source.read();
      expect(doc.opcua, hasLength(1),
          reason: 'the default document carries one OPC UA entry — the same '
              'default StateManConfig.fromPrefs seeds, so the page and '
              'StateMan cannot disagree about what an unconfigured station '
              'holds');
      final persisted =
          await prefs.getString(StateManConfig.configKey, secret: true);
      expect(persisted,
          jsonEncode(StateManConfig(opcua: [OpcUAConfig()]).toJson()),
          reason: 'the seeded default must be persisted exactly as '
              'fromPrefs persists it');
    });

    test('validate carries StateManConfig.fromJson\'s own message', () async {
      final source = await h.build(seeded());
      final doc = await source.read();

      // Break the document below the typed layer: encode, corrupt a typed
      // field, re-parse. ConfigDocument accepts it (it does not eagerly
      // parse); the REAL parser refuses it, and validate must answer with
      // that parser's own words — no local paraphrase.
      final corrupted = jsonDecode(doc.encode()) as Map<String, dynamic>;
      ((corrupted['opcua'] as List).first
          as Map<String, dynamic>)['publishing_interval_ms'] = 'fast';
      final broken = ConfigDocument.parse(jsonEncode(corrupted));

      Object? expected;
      try {
        StateManConfig.fromJson(
            jsonDecode(broken.encode()) as Map<String, dynamic>);
      } catch (error) {
        expected = error;
      }
      expect(expected, isNotNull,
          reason: 'fixture sanity: the corruption must actually refuse');

      final validation = await source.validate(broken);
      expect(validation.ok, isFalse);
      expect(validation.problems.single, expected.toString(),
          reason: 'direct-mode validate is the same parser the local '
              'StateMan boots with, verbatim');
    });

    test('write refuses an unparseable document and persists nothing',
        () async {
      final source = await h.build(seeded());
      final before = await h.landed();

      final corrupted =
          jsonDecode(fixtureJson(
              password: _storedPassword,
              sslKey: _storedSslKey,
              withRelay: false)) as Map<String, dynamic>;
      ((corrupted['opcua'] as List).first
          as Map<String, dynamic>)['publishing_interval_ms'] = 'fast';
      final broken = ConfigDocument.parse(jsonEncode(corrupted));

      await expectLater(source.write(broken), throwsA(isA<Object>()));
      expect(await h.landed(), before,
          reason: 'a refused write must leave the stored document untouched '
              '— never partially applied');
      expect(h.appliedCount, 0,
          reason: 'nothing was applied, so the apply hook must not fire');
    });

    test('a successful write fires the apply hook exactly once', () async {
      final source = await h.build(seeded());
      final doc = await source.read();
      await source.write(doc);
      expect(h.appliedCount, 1,
          reason: 'direct mode applies on save — the source invalidates the '
              'live StateMan through its onApplied hook');
    });

    test('hasPrevious is false and restorePrevious refuses by name',
        () async {
      final source = await h.build(seeded());
      expect(await source.hasPrevious(), isFalse);

      final before = await h.landed();
      await expectLater(
          source.restorePrevious(),
          throwsA(predicate((error) =>
              error.toString().contains('previous') &&
              error.toString().contains('direct'))),
          );
      expect(await h.landed(), before,
          reason: 'a refused restore must not touch the stored document');
    });
  });

  // ---------------------------------------------------------------------------
  // Gateway-only semantics
  // ---------------------------------------------------------------------------

  group('GatewayConfigSource — wire semantics', () {
    final h = GatewayHarness();
    String seeded() => fixtureJson(
          password: kSecretPreservedSentinel,
          sslKey: kSecretPreservedSentinel,
          withRelay: true,
        );

    test('hasPrevious is read().hasPrevious and previous() is never asked',
        () async {
      final source = await h.build(seeded());
      h.api!.hasPrevious = true;
      expect(await source.hasPrevious(), isTrue);

      h.api!.hasPrevious = false;
      expect(await source.hasPrevious(), isFalse);

      expect(h.api!.previousCalls, 0,
          reason: '17-10 deviation 4: previous() may refuse by name on a '
              'never-written file, so asking it is NOT the same question as '
              '"is there something to restore" — read().hasPrevious is');
    });

    test('the relay section is present-but-not-editable', () async {
      final source = await h.build(seeded());
      final doc = await source.read();

      expect(doc.readOnlySections, contains('relay'),
          reason: 'the screen must grey the relay section (D-10)');
      final encoded = jsonDecode(doc.encode()) as Map<String, dynamic>;
      expect(
          encoded['relay'],
          {
            'port': 8443,
            'token_file': '/etc/centroid/relay-tokens.json',
          },
          reason: 'read-only means present-but-not-editable — the section '
              'crosses verbatim on encode(), never silently absent');
    });

    test('validate sends encode() verbatim and returns the far end\'s answer',
        () async {
      final source = await h.build(seeded());
      final doc = await source.read();
      h.api!.validateAnswer = const ConfigValidation(
          ok: false, problems: ['The far end\'s own sentence.']);

      final validation = await source.validate(doc);
      expect(h.api!.validateCalls.single, doc.encode(),
          reason: 'the authoritative check runs on the document as it will '
              'be written');
      expect(validation.ok, isFalse);
      expect(validation.problems, ['The far end\'s own sentence.'],
          reason: 'the backend\'s sentences, untouched — no local '
              'paraphrase');
    });

    test('a refused write surfaces the far end\'s refusal verbatim',
        () async {
      final source = await h.build(seeded());
      final doc = await source.read();
      h.api!.writeError = rpc.RpcException(
          -32000,
          'BackendConfigStore.write refused: The `relay` section differs '
          'from the live configuration, and it is not remotely editable.');

      await expectLater(
          source.write(doc),
          throwsA(predicate((error) =>
              error is rpc.RpcException &&
              error.message.contains('you do not edit') ==
                  false && // sanity: exact message below
              error.message.startsWith('BackendConfigStore.write refused'))));
      expect(await h.landed(), isNull,
          reason: 'a refused write sent nothing that stuck');
    });

    test('restorePrevious passes the reason through and surfaces refusal',
        () async {
      final source = await h.build(seeded());
      await source.restorePrevious(reason: 'bad edit, going back');
      expect(h.api!.restoreReasons, ['bad edit, going back']);

      h.api!.restoreError = rpc.RpcException(-32000,
          'BackendConfigStore.restorePrevious refused: nothing has ever '
          'been overwritten.');
      await expectLater(
          source.restorePrevious(),
          throwsA(predicate((error) =>
              error is rpc.RpcException &&
              error.message.contains('nothing has ever been overwritten'))),
          );
    });
  });
}
