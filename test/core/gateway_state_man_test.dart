/// The adapter's own behaviour, without a gateway on the other end.
///
/// Everything here is either pure translation or a member the adapter answers
/// locally. The wire itself is covered by `tfc_relay_client`'s own contract
/// suite, which runs the same 44 checks against `RemoteStateMan` and
/// `LocalStateMan`; repeating it here would test that package, not this one.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' as ua;
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// A client pointed at a port nothing is listening on.
///
/// `RemoteStateMan`'s constructor is documented as never throwing and never
/// blocking — it starts dialling and the supervisor backs off — so this is a
/// legitimate object for the cases below, none of which touch the wire.
RemoteStateMan _offlineClient({Set<String> keys = const {}}) => RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:1'),
      config: ClientConfig(),
      keys: keys,
    );

GatewayStateMan _adapter({KeyMappings? keyMappings}) => GatewayStateMan(
      remote: _offlineClient(),
      config: StateManConfig(opcua: const []),
      keyMappings: keyMappings ??
          KeyMappings(nodes: {
            'Line1.speed': KeyMappingEntry(
                opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'speed')),
          }),
    );

void main() {
  group('value translation, gateway to panel', () {
    test('a scalar arrives as itself', () {
      final value = toUaValue(rp.DynamicValue(value: 42));
      expect(value.value, 42);
      expect(value.asInt, 42);
    });

    test('a bad-quality reading arrives as null, as the relay nulls it', () {
      final value =
          toUaValue(rp.DynamicValue(value: null, quality: rp.Quality.badCommFault));
      expect(value.isNull, isTrue);
    });

    // The property that matters: a struct must arrive as a real open62541
    // object graph, not as a Map hiding inside one DynamicValue. Every asset
    // in `lib/page_creator/assets` indexes into structs with `value['member']`.
    test('a struct is rebuilt member by member', () {
      final wire = rp.DynamicValue(value: {
        'running': rp.DynamicValue(value: true),
        'speed': rp.DynamicValue(value: 12.5),
      });

      final value = toUaValue(wire);
      expect(value.isObject, isTrue);
      expect(value['running'].asBool, isTrue);
      expect(value['speed'].asDouble, 12.5);
      expect(value['speed'].name, 'speed');
    });

    test('an array is rebuilt element by element', () {
      final wire = rp.DynamicValue(value: [
        rp.DynamicValue(value: 1),
        rp.DynamicValue(value: 2),
        rp.DynamicValue(value: 3),
      ]);

      final value = toUaValue(wire);
      expect(value.isArray, isTrue);
      expect(value[0].asInt, 1);
      expect(value[2].asInt, 3);
    });

    test('nesting survives', () {
      final wire = rp.DynamicValue(value: {
        'axes': rp.DynamicValue(value: [
          rp.DynamicValue(value: {'pos': rp.DynamicValue(value: 7)}),
        ]),
      });

      expect(toUaValue(wire)['axes'][0]['pos'].asInt, 7);
    });
  });

  group('value translation, panel to gateway', () {
    test('a scalar goes as itself', () {
      expect(plainValueOf(ua.DynamicValue(value: 3.5)), 3.5);
    });

    test('a struct is unwrapped to plain maps', () {
      final value = ua.DynamicValue.fromMap(
          LinkedHashMap<String, dynamic>.from({'a': 1, 'b': 2}));
      expect(plainValueOf(value), {'a': 1, 'b': 2});
    });

    // The round trip is the real assertion: a value that goes out and comes
    // back must be the same value, or a readback confirmation means nothing.
    test('a struct round-trips through both translations', () {
      final original = ua.DynamicValue.fromMap(
          LinkedHashMap<String, dynamic>.from({'running': true, 'speed': 12}));

      final backAgain =
          toUaValue(rp.DynamicValue(value: plainValueOf(original)));

      expect(backAgain['running'].asBool, isTrue);
      expect(backAgain['speed'].asInt, 12);
    });
  });

  group('substitution stays on the panel', () {
    test('an unset variable leaves the key alone', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      expect(adapter.resolveKey(r'Line$n.speed'), r'Line$n.speed');
    });

    test('a set variable is substituted', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      adapter.setSubstitution('n', '1');
      expect(adapter.resolveKey(r'Line$n.speed'), 'Line1.speed');
      expect(adapter.getSubstitution('n'), '1');
      expect(adapter.substitutions, {'n': '1'});
    });

    test('a change is announced exactly once per distinct value', () async {
      final adapter = _adapter();
      addTearDown(adapter.close);
      final seen = <Map<String, String>>[];
      adapter.substitutionsChanged.listen(seen.add);

      adapter.setSubstitution('n', '1');
      adapter.setSubstitution('n', '1'); // same value: no announcement
      adapter.setSubstitution('n', '2');
      await Future<void>.delayed(Duration.zero);

      expect(seen, [
        {'n': '1'},
        {'n': '2'}
      ]);
    });
  });

  group('the members the pipe cannot answer', () {
    test('no upstream client objects are handed out', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      expect(adapter.clients, isEmpty);
      expect(adapter.deviceClients, isEmpty);
      expect(adapter.connMetaAliases, isEmpty);
    });

    test('connection metadata refuses rather than answering emptily', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      expect(() => adapter.subscribeConnMeta('plc1'),
          throwsA(isA<StateManException>()));
    });

    // The picker must offer a configured tag that has not ticked yet, exactly
    // as direct mode does. RemoteStateMan.keys deliberately answers something
    // else -- keys a value has arrived for -- which is right for its own
    // picker and wrong here.
    test('keys come from the mapping, not from what has arrived', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      expect(adapter.keys, contains('Line1.speed'));
    });

    test('nothing is locally disabled: the gateway owns that', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      expect(adapter.isKeyDisabled('Line1.speed'), isFalse);
    });

    test('a mapping edit asks for a full reload', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      final result = adapter.updateKeyMappings(KeyMappings(nodes: {
        'Line2.speed': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'speed')),
      }));

      expect(result.requiresReload, isTrue);
      expect(adapter.keys, contains('Line2.speed'));
    });
  });
}
