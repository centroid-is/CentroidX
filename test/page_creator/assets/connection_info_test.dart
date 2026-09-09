import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/connection_info.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc_dart/core/state_man.dart' show StateMan, StateManException;

// ---------------------------------------------------------------------------
// Fakes — a StateMan that answers `@conn/<alias>/<field>` subscribes with
// canned DynamicValues, and errors for any other alias/field (mirroring the
// real ConnMetaRouter, which throws on an unknown alias).
// ---------------------------------------------------------------------------

class _FakeConnStateMan extends Fake implements StateMan {
  _FakeConnStateMan({required this.knownAlias, required this.fields});

  final String knownAlias;
  final Map<String, DynamicValue> fields;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    // key shape: @conn/<alias>/<field>
    final parts = key.split('/');
    if (parts.length != 3 || parts[0] != '@conn' || parts[1] != knownAlias) {
      throw StateError("unknown connection meta key '$key'");
    }
    final value = fields[parts[2]];
    if (value == null) {
      throw StateError("unknown field '${parts[2]}'");
    }
    return Stream<DynamicValue>.value(value);
  }

  @override
  Stream<Map<String, DynamicValue>> subscribeConnMeta(String alias) {
    if (alias != knownAlias) {
      throw StateManException(
          "connection metadata key names unknown server alias '$alias'");
    }
    return Stream<Map<String, DynamicValue>>.value(fields);
  }

  @override
  List<({String alias, bool isModbus})> get connMetaAliases =>
      [(alias: knownAlias, isModbus: fields.containsKey('unitId'))];
}

Map<String, DynamicValue> _modbusFields({
  String state = 'connected',
  bool connected = true,
  double requestsPerSec = 12.3,
  String lastError = '',
}) =>
    {
      'state': DynamicValue(value: state),
      'connected': DynamicValue(value: connected),
      'destIp': DynamicValue(value: '192.168.1.50'),
      'destPort': DynamicValue(value: 502),
      'requestsPerSec': DynamicValue(value: requestsPerSec),
      'uptimeSec': DynamicValue(value: 3725.0),
      'reconnectCount': DynamicValue(value: 2),
      'lastError': DynamicValue(value: lastError),
      'unitId': DynamicValue(value: 1),
      'sourcePort': DynamicValue(value: 49152),
      'pollIntervalMs': DynamicValue(value: 100),
    };

Map<String, DynamicValue> _opcuaFields({
  String state = 'disconnected',
  bool connected = false,
  double requestsPerSec = 4.5,
  String lastError = 'BadTimeout',
}) =>
    {
      'state': DynamicValue(value: state),
      'connected': DynamicValue(value: connected),
      'destIp': DynamicValue(value: 'opc.example.com'),
      'destPort': DynamicValue(value: 4840),
      'requestsPerSec': DynamicValue(value: requestsPerSec),
      'uptimeSec': DynamicValue(value: 0.0),
      'reconnectCount': DynamicValue(value: 5),
      'lastError': DynamicValue(value: lastError),
      'endpoint': DynamicValue(value: 'opc.tcp://opc.example.com:4840'),
      'channelState': DynamicValue(value: 'closed'),
      'sessionState': DynamicValue(value: 'closed'),
      'statusCode': DynamicValue(value: 2148007936),
      'subscribedKeys': DynamicValue(value: 8),
      'lastDataAgeSec': DynamicValue(value: 30.0),
    };

Widget _wrap(Widget child, {StateMan? stateMan}) {
  return ProviderScope(
    overrides: [
      if (stateMan != null)
        stateManProvider.overrideWith((ref) async => stateMan),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 260, height: 220, child: child),
        ),
      ),
    ),
  );
}

Color? _chipColor(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.byKey(const ValueKey('connection-info-state-chip')),
  );
  final decoration = container.decoration as BoxDecoration?;
  return decoration?.color;
}

void main() {
  // -------------------------------------------------------------------------
  // Serialization safety — the page-wipe hazard.
  // -------------------------------------------------------------------------
  group('Serialization safety', () {
    test('fromJson({}) does not throw and yields safe defaults', () {
      late ConnectionInfoConfig config;
      expect(() => config = ConnectionInfoConfig.fromJson({}), returnsNormally);
      expect(config.serverAlias, '');
      expect(config.protocol, ConnectionProtocol.modbus);
      // BaseAsset keys back-filled rather than throwing.
      expect(config.coordinates.x, 0.0);
      expect(config.size.width, 0.18);
    });

    test('fromJson of a minimal map keeps its alias, defaults the rest', () {
      final config = ConnectionInfoConfig.fromJson({'serverAlias': 'plc1'});
      expect(config.serverAlias, 'plc1');
      expect(config.protocol, ConnectionProtocol.modbus);
    });

    test('unknown protocol string falls back to modbus, does not throw', () {
      final config = ConnectionInfoConfig.fromJson(
          {'serverAlias': 'plc1', 'protocol': 'bogus'});
      expect(config.protocol, ConnectionProtocol.modbus);
    });

    test('toJson → fromJson round-trips alias and protocol', () {
      final original = ConnectionInfoConfig(
          serverAlias: 'opc-a', protocol: ConnectionProtocol.opcua);
      final restored = ConnectionInfoConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.serverAlias, 'opc-a');
      expect(restored.protocol, ConnectionProtocol.opcua);
    });
  });

  // -------------------------------------------------------------------------
  // Registry — palette + round-trip.
  // -------------------------------------------------------------------------
  group('Registry', () {
    test('default factory produces a ConnectionInfoConfig', () {
      final asset = AssetRegistry.createDefaultAsset(ConnectionInfoConfig);
      expect(asset, isA<ConnectionInfoConfig>());
      expect(asset.displayName, 'Connection Info');
    });

    test('parse round-trips a serialized ConnectionInfoConfig', () {
      // Production feeds `parse` a JSON-decoded map (plain nested maps), so
      // round-trip through encode/decode rather than the raw toJson() map
      // (whose 'coordinates'/'size' values are still model objects).
      final json = jsonDecode(
              jsonEncode(ConnectionInfoConfig(serverAlias: 'plc1').toJson()))
          as Map<String, dynamic>;
      final parsed = AssetRegistry.parse(json);
      expect(parsed, hasLength(1));
      expect(parsed.first, isA<ConnectionInfoConfig>());
    });
  });

  // -------------------------------------------------------------------------
  // Pure helpers.
  // -------------------------------------------------------------------------
  group('Formatters and state visual', () {
    test('requests/sec format', () {
      expect(formatRequestsPerSec(12.34), '12.3 req/s');
    });
    test('uptime h:mm:ss format', () {
      expect(formatUptime(3725), '1:02:05');
      expect(formatUptime(0), '0:00:00');
    });
    test('state visual priority', () {
      expect(
        ConnectionStateVisual.resolve(
                connected: true, state: 'connected', lastError: '')
            .color,
        Colors.green,
      );
      expect(
        ConnectionStateVisual.resolve(
                connected: false, state: 'connecting', lastError: '')
            .color,
        Colors.amber,
      );
      expect(
        ConnectionStateVisual.resolve(
                connected: false, state: 'disconnected', lastError: 'boom')
            .color,
        Colors.red,
      );
      expect(
        ConnectionStateVisual.resolve(
                connected: false, state: 'disconnected', lastError: '')
            .color,
        Colors.grey,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Widget rendering against a fake connection source.
  // -------------------------------------------------------------------------
  group('Widget rendering', () {
    testWidgets('Modbus card: green chip, req/s text, no error row',
        (tester) async {
      final config = ConnectionInfoConfig(
          serverAlias: 'plc1', protocol: ConnectionProtocol.modbus);
      final stateMan =
          _FakeConnStateMan(knownAlias: 'plc1', fields: _modbusFields());
      await tester.pumpWidget(
          _wrap(ConnectionInfoCard(config: config), stateMan: stateMan));
      await tester.pumpAndSettle();

      expect(_chipColor(tester), Colors.green);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('12.3 req/s'), findsOneWidget);
      expect(find.text('192.168.1.50:502'), findsOneWidget);
      // Modbus extras present.
      expect(find.text('Unit ID'), findsOneWidget);
      expect(find.text('100 ms'), findsOneWidget);
      // No error row when lastError is blank.
      expect(find.text('Error'), findsNothing);
      // OPC-UA-only labels absent.
      expect(find.text('Endpoint'), findsNothing);
    });

    testWidgets('OPC-UA card: red chip, req/s text, error visible',
        (tester) async {
      final config = ConnectionInfoConfig(
          serverAlias: 'opc1', protocol: ConnectionProtocol.opcua);
      final stateMan =
          _FakeConnStateMan(knownAlias: 'opc1', fields: _opcuaFields());
      await tester.pumpWidget(
          _wrap(ConnectionInfoCard(config: config), stateMan: stateMan));
      await tester.pumpAndSettle();

      expect(_chipColor(tester), Colors.red);
      expect(find.text('4.5 req/s'), findsOneWidget);
      // Last error row is shown (and only appears when non-empty).
      expect(find.text('BadTimeout'), findsOneWidget);
      // OPC-UA extras present, Modbus extras absent.
      expect(find.text('Endpoint'), findsOneWidget);
      expect(find.text('Subscribed'), findsOneWidget);
      expect(find.text('Unit ID'), findsNothing);
    });

    testWidgets('blank alias renders the unconfigured placeholder',
        (tester) async {
      final config = ConnectionInfoConfig(serverAlias: '');
      await tester.pumpWidget(_wrap(ConnectionInfoCard(config: config)));
      await tester.pump();
      expect(find.text('No connection selected'), findsOneWidget);
    });

    testWidgets('unknown alias degrades to "connection not found"',
        (tester) async {
      final config = ConnectionInfoConfig(serverAlias: 'ghost');
      // Fake only knows 'plc1'; every subscribe for 'ghost' errors.
      final stateMan =
          _FakeConnStateMan(knownAlias: 'plc1', fields: _modbusFields());
      await tester.pumpWidget(
          _wrap(ConnectionInfoCard(config: config), stateMan: stateMan));
      await tester.pumpAndSettle();
      expect(find.text('Connection not found'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Config editor — mutation drives a rebuild (no stateless-pane bug).
  // -------------------------------------------------------------------------
  group('Config editor', () {
    testWidgets('protocol SegmentedButton mutates config and rebuilds',
        (tester) async {
      final config = ConnectionInfoConfig(
          serverAlias: 'plc1', protocol: ConnectionProtocol.modbus);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => config.configure(context)),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('OPC-UA'));
      await tester.pumpAndSettle();
      expect(config.protocol, ConnectionProtocol.opcua);
    });
  });
}
