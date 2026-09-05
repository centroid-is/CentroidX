/// F1 from the rig sweep (RIG-TEST-FINDINGS.md): the live plant file carries
/// `"server_alias": null` on every OPC UA entry, and a link whose *name* is a
/// real string ("RIG", "ST101" — PIPE health keys require one) could never
/// claim those entries, because every adapter compared the entry's alias
/// against the link's name. `answers_to` separates the two facts the way
/// `UpstreamLinkBinding`'s doc always said they were separate: the name is
/// what the link is called; `answers_to` is which keymapping `server_alias`
/// it serves. Proven on the rig 2026-09-05: 14/14 keys errorConfig until the
/// file was hand-patched to name the link.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/modbus_client_wrapper.dart'
    show ModbusDataType;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

/// The one entry shape the live file ships: an OPC UA node with
/// `server_alias: null`.
KeyMappingEntry opcUaEntry({String? serverAlias}) {
  final node = OpcUANodeConfig(namespace: 4, identifier: 'MAIN.tag')
    ..serverAlias = serverAlias;
  return KeyMappingEntry()..opcuaNode = node;
}

KeyMappingEntry modbusEntry({String? serverAlias}) {
  final node = ModbusNodeConfig(
    registerType: ModbusRegisterType.holdingRegister,
    address: 0,
    dataType: ModbusDataType.uint16,
  )..serverAlias = serverAlias;
  return KeyMappingEntry()..modbusNode = node;
}

/// Claim never touches the wire, so the client can be inert.
final class _InertClient implements DeviceClient {
  @override
  Set<String> get subscribableKeys => const <String>{};
  @override
  bool canSubscribe(String key) => false;
  @override
  Stream<ua.DynamicValue> subscribe(String key) =>
      const Stream.empty();
  @override
  ua.DynamicValue? read(String key) => null;
  @override
  ConnectionStatus get connectionStatus => ConnectionStatus.disconnected;
  @override
  Stream<ConnectionStatus> get connectionStream => const Stream.empty();
  @override
  void connect() {}
  @override
  Future<void> write(String key, ua.DynamicValue value) async {}
  @override
  void dispose() {}
}

void main() {
  group('UpstreamLinkConfig.answers_to', () {
    Map<String, dynamic> raw([Object? extra = _absent]) => <String, dynamic>{
          'alias': 'RIG',
          'protocol': 'opcua',
          'endpoint': 'opc.tcp://example:4840',
          if (!identical(extra, _absent)) 'answers_to': extra,
        };

    test('absent means the link answers to its own name', () {
      final config = UpstreamLinkConfig.fromJson(raw());
      expect(config.answersTo, 'RIG',
          reason: 'the default is the simple case KeyRouter.overLinks '
              'describes: integrators who named their servers change nothing');
    });

    test('null means the unnamed server — the live plant file', () {
      final config = UpstreamLinkConfig.fromJson(raw(null));
      expect(config.answersTo, '',
          reason: 'JSON null and "" are one bucket, exactly as '
              'StateManConfig.normalizeAlias already decided for the shipped '
              'config');
    });

    test('empty string spells the unnamed server too', () {
      expect(UpstreamLinkConfig.fromJson(raw('')).answersTo, '');
    });

    test('a string names a different alias than the link\'s own', () {
      expect(UpstreamLinkConfig.fromJson(raw('legacy')).answersTo, 'legacy');
    });
  });

  group('OpcUaUpstreamLink', () {
    test('answersTo "" claims the unnamed server\'s entries', () {
      final link = OpcUaUpstreamLink(
        alias: 'RIG',
        endpoint: 'opc.tcp://example:4840',
        useIsolate: false,
        answersTo: '',
      );
      addTearDown(link.dispose);
      expect(link.resolve('a.key', opcUaEntry(serverAlias: null)), isNotNull,
          reason: 'this is the rig defect: server_alias null with a named '
              'link was unroutable, every key errorConfig, silently');
      expect(link.resolve('a.key', opcUaEntry(serverAlias: 'RIG')), isNull,
          reason: 'a link answers to exactly one alias; claiming its own '
              'name too would put one PLC\'s key on another\'s page the day '
              'a second link answers to it');
    });

    test('answersTo omitted keeps the old behaviour: the name itself', () {
      final link = OpcUaUpstreamLink(
        alias: 'RIG',
        endpoint: 'opc.tcp://example:4840',
        useIsolate: false,
      );
      addTearDown(link.dispose);
      expect(link.resolve('a.key', opcUaEntry(serverAlias: 'RIG')), isNotNull);
      expect(link.resolve('a.key', opcUaEntry(serverAlias: null)), isNull);
    });
  });

  group('ModbusUpstreamLink', () {
    test('answersTo "" claims the unnamed server\'s entries', () {
      final link = ModbusUpstreamLink(
        alias: 'BER01',
        client: _InertClient(),
        answersTo: '',
      );
      addTearDown(link.dispose);
      expect(link.claim('a.key', modbusEntry(serverAlias: null)), isNotNull);
      expect(link.claim('a.key', modbusEntry(serverAlias: 'BER01')), isNull);
    });

    test('answersTo omitted keeps the old behaviour', () {
      final link = ModbusUpstreamLink(
        alias: 'BER01',
        client: _InertClient(),
      );
      addTearDown(link.dispose);
      expect(link.claim('a.key', modbusEntry(serverAlias: 'BER01')), isNotNull);
      expect(link.claim('a.key', modbusEntry(serverAlias: null)), isNull);
    });
  });

  group('the built gateway routes the live file shape', () {
    test('buildUpstreamLink + KeyRouter claim a server_alias:null key',
        () async {
      final config = UpstreamLinkConfig.fromJson(<String, dynamic>{
        'alias': 'RIG',
        'protocol': 'opcua',
        'endpoint': 'opc.tcp://example:4840',
        'answers_to': null,
      });
      final mappings = KeyMappings(nodes: {
        'cooler.temp.avg': opcUaEntry(serverAlias: null),
      });
      final link = await buildUpstreamLink(config, mappings: mappings);
      addTearDown(link.dispose);
      final router = KeyRouter(
        links: [
          // The binding constructor already buckets '' with null.
          UpstreamLinkBinding(link, serverAlias: config.answersTo),
        ],
        mappings: mappings,
      );
      final route = router.route('cooler.temp.avg');
      expect(route, isA<ClaimedRoute>(),
          reason: 'the whole point: a gateway built from configuration alone '
              'must be able to serve the file the plant already has');
      expect((route as ClaimedRoute).link.alias, 'RIG',
          reason: 'and the claim still names the link, because PIPE health '
              'keys and status notifications speak the name, not the '
              'answers-to');
    });
  });

  group('unclaimed keys are named, not silent', () {
    test('a mapped key no link claims appears in unclaimedKeys', () {
      final link = OpcUaUpstreamLink(
        alias: 'RIG',
        endpoint: 'opc.tcp://example:4840',
        useIsolate: false,
        // Answers to its own name, so the null-alias entry below is exactly
        // the rig's F2: mapped, servable-looking, permanently unroutable.
      );
      addTearDown(link.dispose);
      final router = KeyRouter(
        links: [UpstreamLinkBinding(link, serverAlias: link.alias)],
        mappings: KeyMappings(nodes: {
          'orphan.key': opcUaEntry(serverAlias: null),
          'served.key': opcUaEntry(serverAlias: 'RIG'),
        }),
      );
      expect(router.unclaimedKeys, {'orphan.key'},
          reason: 'the rig ran a whole shift with 14/14 keys in this state '
              'and the only trace was q=770 on the wire; the boot log is '
              'where a deployer looks first');
      expect(router.unclaimedKeys, isNot(contains('served.key')));
    });
  });
}

const _absent = Object();
