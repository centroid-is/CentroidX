/// The adapter's own behaviour, without a gateway on the other end.
///
/// Everything here is either pure translation or a member the adapter answers
/// locally. The wire itself is covered by `tfc_relay_client`'s own contract
/// suite, which runs the same 44 checks against `RemoteStateMan` and
/// `LocalStateMan`; repeating it here would test that package, not this one.
library;

import 'dart:collection';

import 'dart:io';

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

  group('value translation, gateway to panel — the type dictionary', () {
    const fd = rp.TypeDescriptor(
      ua: 'ns=4;i=3012',
      displayName: rp.LocalizedText('Frequency drive'),
      members: {
        'p_stat_RunMode': rp.TypeDescriptor(
          ua: 'ns=4;i=3001',
          enumFields: {
            0: rp.EnumField(value: 0, name: 'stopped'),
            2: rp.EnumField(
                value: 2,
                name: 'auto',
                displayName: rp.LocalizedText('Auto', locale: 'en')),
          },
        ),
      },
    );

    test('a struct member gets its enum table back, so a run mode has a name',
        () {
      final wire = rp.DynamicValue(value: <Object, rp.DynamicValue>{
        'p_stat_RunMode': rp.DynamicValue(value: 2),
        'p_stat_Speed': rp.DynamicValue(value: 12.5),
      });
      final value = toUaValue(wire, type: fd);
      final mode = value['p_stat_RunMode'];
      expect(mode.asInt, 2);
      expect(mode.enumFields?[mode.asInt]?.name, 'auto',
          reason: 'exactly the lookup readDriveState makes — the one that '
              'answered unknown in every browser and painted every conveyor '
              'purple');
      expect(mode.enumFields![2]!.displayName.locale, 'en');
      expect(mode.typeId?.toString(), 'ns=4;i=3001');
      expect(value.typeId?.toString(), 'ns=4;i=3012');
      expect(value.displayName?.value, 'Frequency drive');
      expect(value['p_stat_Speed'].enumFields, isNull,
          reason: 'a member the type says nothing about is built as before');
    });

    test('without a descriptor the value is built exactly as before', () {
      final value = toUaValue(rp.DynamicValue(value: 2));
      expect(value.asInt, 2);
      expect(value.enumFields, isNull);
      expect(value.typeId, isNull);
    });

    test('the attached metadata does not change what a write sends back', () {
      final wire = rp.DynamicValue(value: <Object, rp.DynamicValue>{
        'p_stat_RunMode': rp.DynamicValue(value: 2),
      });
      expect(plainValueOf(toUaValue(wire, type: fd)), {'p_stat_RunMode': 2},
          reason: 'plainValueOf reads the value graph only; the enum table '
              'is for reading names, and a write still sends the integer');
    });

    test('nodeIdFromText parses the spellings NodeId.toString produces, and '
        'refuses the rest', () {
      expect(nodeIdFromText('ns=4;i=3012').toString(), 'ns=4;i=3012');
      expect(nodeIdFromText('ns=2;s=Tag.A').toString(), 'ns=2;s=Tag.A');
      expect(nodeIdFromText('i=6').toString(), 'ns=0;i=6');
      expect(nodeIdFromText('nonsense'), isNull);
      expect(nodeIdFromText(''), isNull);
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

      // The first event is the map as it stood when the listener attached —
      // empty here — which is what `StateMan`'s seeded subject gives a station
      // too. After that, one announcement per distinct change.
      expect(seen, [
        <String, String>{},
        {'n': '1'},
        {'n': '2'}
      ]);
    });
  });

  // The Speedbatchers throughput readouts did not show on the first visit in
  // a browser. Their keys carry `$sb_line_stats_period`, filled in by the
  // page's own period selector, and a readout re-resolves its key when
  // `substitutionsChangedProvider` fires. On a station that stream is a
  // seeded `BehaviorSubject` (`state_man.dart`), so a watcher that arrives
  // after the selector published still receives the current map. Here it was
  // a plain broadcast controller, which replays nothing: when the selector
  // happened to build first, the readout never heard the value, stayed on the
  // unresolved key, and came right only after leaving the page and coming
  // back. Which widget builds first is not something a page can promise.
  group('substitutions reach a watcher that arrives late', () {
    test('a listener attached after a value was set receives the current map',
        () async {
      final adapter = _adapter();
      addTearDown(adapter.close);
      adapter.setSubstitution('sb_line_stats_period', 'Minute5');

      final seen = <Map<String, String>>[];
      adapter.substitutionsChanged.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isNotEmpty,
          reason: 'the selector published before this watcher arrived; a '
              'stream that does not replay leaves the readout on its '
              'unresolved key until the operator changes the period');
      expect(seen.last, {'sb_line_stats_period': 'Minute5'});
    });
  });

  group('the members the pipe cannot answer', () {
    test('no upstream client objects are handed out', () {
      final adapter = _adapter();
      addTearDown(adapter.close);
      // `clients` is deliberately absent rather than empty — asserting it were
      // empty would require this class to declare it, and declaring it names
      // `ClientWrapper` and so links `dart:ffi` into the one class whose point
      // is that this process holds no session. The arm below is what stands in
      // its place, and it is the stronger statement.
      expect(adapter.deviceClients, isEmpty);
      expect(adapter.connMetaAliases, isEmpty);
    });

    test('and `clients` is not a member of this class at all', () {
      final source =
          File('lib/core/gateway_state_man.dart').readAsStringSync();
      expect(source, isNot(contains('List<ClientWrapper>')),
          reason: 'an empty `clients` getter came back once already, from a '
              'merge that took the older side of this file. Absent, not '
              'empty: `StateMan` does not declare it, `opcUaSessionsOf` is '
              'how a caller asks for a live session, and the type name alone '
              'links open62541 into a browser build.');
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
