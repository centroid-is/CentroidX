/// The migration's safety net.
///
/// Everything else in the relational-config work can be redone if it turns out
/// wrong. A migration that silently drops a key cannot: the key stops
/// resolving, an asset on a mimic goes blank, and nothing says why. So the
/// round trip is asserted structurally — `blob -> items -> blob` must come
/// back holding exactly the same configuration — over a fixture built to carry
/// every shape the real plant blob contains.
///
/// ## Running it against the real blob
///
/// The committed fixture is representative, not real: the production
/// `key_mappings` value is half a megabyte of plant wiring and does not belong
/// in the repository. Point the test at a real dump instead with
///
///     CENTROIDX_KEY_MAPPINGS_BLOB=/path/to/key_mappings.json dart test
///
/// and the same assertions run over it. `tools/svn_apply_config.py
/// --backup-only` produces a file of the right shape.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Environment variable naming a real `key_mappings` dump to run against.
const String _realBlobEnv = 'CENTROIDX_KEY_MAPPINGS_BLOB';

/// A blob carrying one entry of every shape the real value contains.
///
/// Built as text rather than from the model classes on purpose: the point is
/// to prove that *stored* JSON survives the trip, and constructing it through
/// the same `toJson()` the codec uses would assert only that the codec agrees
/// with itself.
const String _fixtureBlob = '''
{
  "nodes": {
    "Line1.Motor1": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL_BatchLines.Drives_Line1[1].HMI",
        "array_index": null,
        "server_alias": null
      },
      "m2400_node": null,
      "io": null,
      "collect": {
        "key": "Line1.Motor1",
        "name": "Line1.Motor1",
        "retention": {"drop_after_min": 525600, "schedule_interval_min": null},
        "sample_interval_us": 5000000,
        "sample_expression": null
      }
    },
    "Line1.Motor1.Error": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL_BatchLines.Drives_Line1[1].HMI.p_stat_Error",
        "array_index": null,
        "server_alias": "st101"
      },
      "m2400_node": null,
      "io": null,
      "collect": null
    },
    "CN04.Belt.Speed": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL.Conveyors[4].Speed",
        "array_index": 2,
        "server_alias": "st201"
      },
      "collect": null,
      "bit_mask": 240,
      "bit_shift": 4
    },
    "BER01.Ready": {
      "modbus_node": {
        "server_alias": "ber01",
        "register_type": "holdingRegister",
        "address": 1024,
        "data_type": "uint16",
        "poll_group": "default"
      },
      "collect": null,
      "variable_name": "M_Elevator.i_isAuto"
    },
    "WEIGH.W3.Net": {
      "m2400_node": {
        "record_type": "recWgt",
        "field": "weight",
        "server_alias": "w3",
        "status_filter": null
      },
      "collect": {
        "key": "WEIGH.W3.Net",
        "name": "Weigher 3 net",
        "retention": {"drop_after_min": 10080, "schedule_interval_min": 60},
        "sample_interval_us": 1000000,
        "sample_expression": null
      }
    },
    "EL9222.Reset": {"io": true, "collect": null}
  }
}
''';

void main() {
  final realBlobPath = Platform.environment[_realBlobEnv];

  // See the same guard in `test/core/config/page_codec_test.dart`: the
  // cutover gate asks whether this suite ran green against *current
  // production data*, and a fixture fallback answers that green having opened
  // no dump at all.
  if (Platform.environment['CENTROIDX_REQUIRE_REAL_BLOB'] == '1' &&
      realBlobPath == null) {
    throw StateError('CENTROIDX_REQUIRE_REAL_BLOB=1 but $_realBlobEnv is not '
        'set: this run would have passed against the committed fixture and '
        'proved nothing about production data.');
  }

  final blob = realBlobPath != null
      ? File(realBlobPath).readAsStringSync()
      : _fixtureBlob;
  final source = realBlobPath ?? 'the committed fixture';

  group('key mapping codec, over $source', () {
    test('every key survives the trip', () {
      final items = keyMappingItemsFromBlob(blob);
      final original = KeyMappings.fromJson(
          jsonDecode(blob) as Map<String, dynamic>);

      expect(items, hasLength(original.nodes.length));
      expect(
        items.map((i) => i.id).toSet(),
        original.nodes.keys.toSet(),
        reason: 'a key that does not come back is a subscription that stops '
            'resolving, with nothing to say why',
      );
    });

    test('blob -> items -> blob is the same configuration', () {
      // Compared **through the model on both sides**, not byte for byte.
      //
      // `KeyMappingEntry.toJson()` emits an explicit null for every optional
      // field, so a stored entry written as `{"io": true, "collect": null}`
      // comes back as that plus `opcua_node`, `m2400_node`, `modbus_node`,
      // `bit_mask`, `bit_shift` and `variable_name`, all null. The round trip
      // is therefore *normalising*, and asserting byte equality here would
      // fail on a difference that is not one.
      //
      // This is not new behaviour and it loses nothing: the app already
      // rewrites the whole blob through the same `toJson()` on every save, so
      // production has been storing the normalised form for as long as anyone
      // has pressed Save. It does mean the compatibility view (§4 Q4) will
      // hand the Python tooling a textually larger blob than the one sitting
      // in `flutter_preferences` today, holding the same configuration.
      final viaItems = jsonDecode(keyMappingBlobOf(keyMappingItemsFromBlob(blob)));
      final viaModel = KeyMappings.fromJson(
              jsonDecode(blob) as Map<String, dynamic>)
          .toJson();

      expect(
        const DeepCollectionEquality()
            .equals(canonicalise(viaItems), canonicalise(viaModel)),
        isTrue,
        reason: 'the reassembled blob must hold exactly what the stored one '
            'did — this is what makes the cutover reversible',
      );
    });

    test('splitting into items loses no field the model can hold', () {
      // The stronger half of the claim above: normalisation is allowed to add
      // explicit nulls, but it must never drop a value that was set. Compared
      // entry by entry so a failure names the key.
      final rebuilt = keyMappingsOf(keyMappingItemsFromBlob(blob));
      final original =
          KeyMappings.fromJson(jsonDecode(blob) as Map<String, dynamic>);

      for (final key in original.nodes.keys) {
        expect(
          canonicalise(rebuilt.nodes[key]?.toJson()),
          canonicalise(original.nodes[key]!.toJson()),
          reason: 'entry \'$key\' did not survive the split',
        );
      }
    });

    test('items -> blob -> items is stable', () {
      final once = keyMappingItemsFromBlob(blob);
      final twice = keyMappingItemsFromBlob(keyMappingBlobOf(once));

      expect(twice, once,
          reason: 'a second pass that differs means the encoding is not '
              'canonical, and every save would rewrite every row');
    });

    test('items are ordered by key, so a diff of two reads is empty', () {
      final items = keyMappingItemsFromBlob(blob);
      final keys = items.map((i) => i.id).toList();

      expect(keys, equals(List.of(keys)..sort()));
      expect(
        diffConfigItems(stored: items, wanted: keyMappingItemsFromBlob(blob))
            .isEmpty,
        isTrue,
        reason: 'reading the same configuration twice must report no change, '
            'or every boot would write and audit every row',
      );
    });

    test('each item carries the kind, the key, and the shared scope', () {
      for (final item in keyMappingItemsFromBlob(blob)) {
        expect(item.kind, ConfigKind.keyMapping);
        expect(item.scope, ConfigScope.shared);
        expect(item.parentId, isNull);
        expect(item.sortIndex, isNull,
            reason: 'nodes is a map, so its order is not configuration');
      }
    });
  });

  group('the diff is what a save writes', () {
    final stored = keyMappingItemsFromBlob(_fixtureBlob);

    test('an unchanged save writes nothing', () {
      final diff = diffConfigItems(
          stored: stored, wanted: keyMappingItemsFromBlob(_fixtureBlob));
      expect(diff.isEmpty, isTrue);
      expect(diff.length, 0);
    });

    test('one edited key is one changed item, not five', () {
      final mappings = keyMappingsOf(stored);
      mappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier =
          'GVL.Conveyors[4].SpeedFiltered';

      final diff =
          diffConfigItems(stored: stored, wanted: keyMappingItems(mappings));

      expect(diff.changed.single.id, 'CN04.Belt.Speed');
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('an added key is an insert and touches nothing else', () {
      final mappings = keyMappingsOf(stored);
      mappings.nodes['CN05.Belt.Speed'] = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
            namespace: 4, identifier: 'GVL.Conveyors[5].Speed'),
      );

      final diff =
          diffConfigItems(stored: stored, wanted: keyMappingItems(mappings));

      expect(diff.added.single.id, 'CN05.Belt.Speed');
      expect(diff.changed, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('a removed key is a delete carrying what it held', () {
      final mappings = keyMappingsOf(stored);
      mappings.nodes.remove('EL9222.Reset');

      final diff =
          diffConfigItems(stored: stored, wanted: keyMappingItems(mappings));

      expect(diff.removed.single.id, 'EL9222.Reset');
      expect(diff.removed.single.payload, isNotEmpty,
          reason: 'the delete must carry the old payload, or the history '
              'cannot say what was lost and cannot put it back');
      expect(diff.added, isEmpty);
      expect(diff.changed, isEmpty);
    });

    test('re-encoding with different map order is not a change', () {
      // The same configuration, written with the keys of one entry in the
      // opposite order. Before canonical encoding existed this compared as an
      // edit, and every station's first save after a restart would have
      // rewritten every row.
      final reordered = jsonDecode(_fixtureBlob) as Map<String, dynamic>;
      final nodes = reordered['nodes'] as Map<String, dynamic>;
      final entry = nodes['Line1.Motor1.Error'] as Map<String, dynamic>;
      nodes['Line1.Motor1.Error'] = {
        'collect': entry['collect'],
        'io': entry['io'],
        'm2400_node': entry['m2400_node'],
        'opcua_node': entry['opcua_node'],
      };

      final diff = diffConfigItems(
        stored: stored,
        wanted: keyMappingItemsFromBlob(jsonEncode(reordered)),
      );

      expect(diff.isEmpty, isTrue);
    });
  });

  group('a blob that is not one', () {
    test('a JSON array is rejected rather than read as empty', () {
      expect(() => keyMappingItemsFromBlob('[]'), throwsFormatException);
    });

    test('a truncated blob is rejected', () {
      expect(() => keyMappingItemsFromBlob('{"nodes": {'),
          throwsFormatException);
    });
  });
}
