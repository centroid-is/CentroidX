/// The round-trip fidelity contract for the unified config editor
/// (quick/20260908-unify-config-ui).
///
/// The one catastrophic failure mode a typed form over a JSON document can
/// have is SILENTLY DROPPING what it did not understand: the backend's
/// document may carry sections and per-entry keys this build has never heard
/// of, and a parse→edit→re-serialise through `StateManConfig` alone loses
/// them (json_serializable ignores unknown keys on the way in and cannot
/// re-emit them on the way out). `ConfigDocument` exists so that cannot
/// happen, and this file is the instrument that proves it — including a
/// seeded property arm over documents salted with keys no form models.
///
/// The fidelity boundary is stated by arms 8 and 9 together: an *untouched*
/// substructure survives verbatim at any depth; an *edited* substructure is
/// rewritten by the model and loses unknown keys inside it. Arm 9 asserts
/// the loss on purpose — it is the anti-vacuity half that proves arm 8 is
/// not trivially green, and the arm a future recursive merge flips
/// deliberately.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config_document.dart';
import 'package:tfc_dart/core/relay/backend_config_store.dart'
    show kSecretPreservedSentinel;
import 'package:tfc_dart/core/state_man.dart';

import 'dart:math';

const _eq = DeepCollectionEquality();

Map<String, Object?> _decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

/// A gateway-shaped document: the three sections, a relay section the form
/// must never rewrite, and unknown content at three depths.
String _saltedDocument() => jsonEncode({
      'opcua': [
        {
          'endpoint': 'opc.tcp://10.104.29.10:4840',
          'server_alias': 'ST101',
          'username': 'panel',
          'password': 'hunter2-very-secret',
          'ssl_key': base64Encode(utf8.encode('fake-private-key-bytes')),
          'x_entry_unknown': {'added_by': 'a newer build'},
        },
        {
          'endpoint': 'opc.tcp://10.104.29.11:4840',
          'server_alias': 'ST201',
          'x_entry_unknown': 'second marker',
        },
      ],
      'modbus': [
        {
          'host': '10.104.29.60',
          'port': 502,
          'unit_id': 1,
          'poll_groups': [
            {
              'name': 'default',
              'interval_ms': 1000,
              'x_nested_unknown': 'inside a poll group',
            },
          ],
          'x_entry_unknown': 'modbus marker',
        },
      ],
      'relay': {
        'port': 9443,
        'tls': {'cert_file': '/etc/centroid/relay.pem'},
        'token_file': '/etc/centroid/relay-tokens.json',
        'x_relay_unknown': true,
      },
      'x_future_section': {
        'aggregator': [1, 2, 3],
      },
    });

void main() {
  group('ConfigDocument', () {
    test('arm 1: seeded property — unknown keys survive random edits and '
        'reorders, attached to the right entry', () {
      final rng = Random(20260908);
      for (var iteration = 0; iteration < 60; iteration++) {
        // Build a document of 1..5 opcua entries, each wearing a marker key
        // the form has never heard of, tied to its endpoint.
        final count = 1 + rng.nextInt(5);
        final entries = [
          for (var i = 0; i < count; i++)
            {
              'endpoint': 'opc.tcp://plc-$i:4840',
              if (rng.nextBool()) 'server_alias': 'alias-$i',
              'x_marker': 'marker-$i',
              if (rng.nextBool())
                'x_nested': {
                  'depth': [
                    {'x_deep': i}
                  ]
                },
            }
        ];
        final extraSections = {
          if (rng.nextBool()) 'x_future_${rng.nextInt(3)}': {'v': iteration},
        };
        final doc = ConfigDocument.parse(jsonEncode({
          'opcua': entries,
          ...extraSections,
          'relay': {'port': 9443},
        }));

        // Edit a random subset of entries through the typed view — the only
        // path a form would use.
        final edited = <int>{};
        for (var i = 0; i < doc.opcua.length; i++) {
          if (rng.nextBool()) continue;
          edited.add(i);
          final value = doc.opcua[i].value;
          value.endpoint = 'opc.tcp://edited-$i:4840';
          doc.opcua[i].update(value);
        }
        // Random adjacent swaps — reorder must carry unknown keys along.
        for (var s = 0; s < rng.nextInt(4); s++) {
          if (doc.opcua.length < 2) break;
          final a = rng.nextInt(doc.opcua.length - 1);
          final entry = doc.opcua.removeAt(a);
          doc.opcua.insert(a + 1, entry);
        }

        final out = _decode(doc.encode());
        final outOpcua = (out['opcua'] as List).cast<Map<String, Object?>>();
        expect(outOpcua, hasLength(count),
            reason: 'iteration $iteration lost or invented an entry');
        for (final raw in outOpcua) {
          // Every marker must still sit beside its own endpoint: marker-i
          // belongs to plc-i (or edited-i when that index was edited).
          final marker = raw['x_marker'] as String;
          final i = int.parse(marker.split('-').last);
          final expectedEndpoint = edited.contains(i)
              ? 'opc.tcp://edited-$i:4840'
              : 'opc.tcp://plc-$i:4840';
          expect(raw['endpoint'], expectedEndpoint,
              reason: 'iteration $iteration mispaired $marker');
          final original = entries[i];
          if (original.containsKey('x_nested')) {
            expect(_eq.equals(raw['x_nested'], original['x_nested']), isTrue,
                reason: 'iteration $iteration lost nested unknown content');
          }
        }
        for (final entry in extraSections.entries) {
          expect(_eq.equals(out[entry.key], entry.value), isTrue,
              reason: 'iteration $iteration lost top-level ${entry.key}');
        }
        expect(_eq.equals(out['relay'], {'port': 9443}), isTrue,
            reason: 'iteration $iteration rewrote the relay section');
      }
    });

    test('arm 2: a redacted document parses — the ssl_key sentinel must not '
        'reach the base64 decoder raw', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {
            'endpoint': 'opc.tcp://plc:4840',
            'password': kSecretPreservedSentinel,
            'ssl_key': kSecretPreservedSentinel,
          }
        ],
      }));
      // The typed view exists (no FormatException out of Base64Converter)…
      final value = doc.opcua.single.value;
      expect(value.endpoint, 'opc.tcp://plc:4840');
      // …and the entry knows which of its secrets are markers, so a screen
      // can say "saved — leave blank to keep it" instead of treating the
      // marker as the credential.
      expect(doc.opcua.single.isSecretPreserved('password'), isTrue);
      expect(doc.opcua.single.isSecretPreserved('ssl_key'), isTrue);
      expect(doc.opcua.single.isSecretPreserved('username'), isFalse);
    });

    test('arm 3: untouched secrets round-trip the sentinel VERBATIM — '
        'neither a literal nor a mask may land in the payload', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {
            'endpoint': 'opc.tcp://plc:4840',
            'password': kSecretPreservedSentinel,
            'ssl_key': kSecretPreservedSentinel,
          }
        ],
      }));
      // A benign edit that does not touch either secret.
      final value = doc.opcua.single.value;
      value.serverAlias = 'renamed';
      doc.opcua.single.update(value);

      final out = _decode(doc.encode());
      final entry = (out['opcua'] as List).single as Map<String, Object?>;
      expect(entry['password'], kSecretPreservedSentinel);
      expect(entry['ssl_key'], kSecretPreservedSentinel,
          reason: 'the mask the typed view needed internally must never '
              'cross the wire');
      expect(entry['server_alias'], 'renamed');
    });

    test('arm 4: a touched secret crosses as the new literal, and only that '
        'one — the sibling secret keeps its sentinel', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {
            'endpoint': 'opc.tcp://plc:4840',
            'password': kSecretPreservedSentinel,
            'ssl_key': kSecretPreservedSentinel,
          }
        ],
      }));
      final value = doc.opcua.single.value;
      value.password = 'a-new-password';
      doc.opcua.single.update(value);

      final out = _decode(doc.encode());
      final entry = (out['opcua'] as List).single as Map<String, Object?>;
      expect(entry['password'], 'a-new-password');
      expect(entry['ssl_key'], kSecretPreservedSentinel);
    });

    test('arm 5: the relay section and unknown sections are tree-identical '
        'after edits elsewhere', () {
      final input = _decode(_saltedDocument());
      final doc = ConfigDocument.parse(_saltedDocument(),
          readOnlySections: const ['relay']);
      final value = doc.opcua.first.value;
      value.endpoint = 'opc.tcp://moved:4840';
      doc.opcua.first.update(value);

      final out = _decode(doc.encode());
      expect(_eq.equals(out['relay'], input['relay']), isTrue);
      expect(_eq.equals(out['x_future_section'], input['x_future_section']),
          isTrue);
      expect(doc.readOnlySections, ['relay']);
    });

    test('arm 6: a cleared field stays cleared — the original value must '
        'not resurrect out of the raw entry', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {
            'endpoint': 'opc.tcp://plc:4840',
            'server_alias': 'about-to-be-cleared',
            'x_marker': 'kept',
          }
        ],
      }));
      final value = doc.opcua.single.value;
      value.serverAlias = null;
      doc.opcua.single.update(value);

      final out = _decode(doc.encode());
      final entry = (out['opcua'] as List).single as Map<String, Object?>;
      expect(entry['server_alias'], isNull,
          reason: 'preserving unknown keys must not preserve DELETED known '
              'ones');
      expect(entry['x_marker'], 'kept');
      // Sabotage finding (mutation e): an EDITED entry must not have its
      // absent defaults materialised either — arm 7 only covered the
      // untouched path, and a mutant that wrote every default on edit
      // stayed green until this assertion existed.
      expect(entry.containsKey('enabled'), isFalse,
          reason: 'editing one field must not rewrite the entry into this '
              'build\'s dialect');
      expect(entry.containsKey('publishing_interval_ms'), isFalse);
      // And the round trip agrees.
      expect(StateManConfig.fromJson(out).opcua.single.serverAlias, isNull);
    });

    test('arm 7: defaults are not materialised — an entry that never had '
        '`enabled` still has no `enabled` after an untouched round trip', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {'endpoint': 'opc.tcp://plc:4840'}
        ],
      }));
      // Round-trip with no edit at all.
      final out = _decode(doc.encode());
      final entry = (out['opcua'] as List).single as Map<String, Object?>;
      expect(entry.containsKey('enabled'), isFalse,
          reason: 'a form that saves must not rewrite every station\'s '
              'document into its own dialect');
    });

    test('arm 8: an UNTOUCHED substructure survives verbatim at any depth — '
        'editing the modbus host keeps the poll group\'s unknown key', () {
      final doc = ConfigDocument.parse(_saltedDocument());
      final value = doc.modbus.single.value;
      value.host = '10.104.29.61';
      doc.modbus.single.update(value);

      final out = _decode(doc.encode());
      final entry = (out['modbus'] as List).single as Map<String, Object?>;
      expect(entry['host'], '10.104.29.61');
      final group = (entry['poll_groups'] as List).single as Map;
      expect(group['x_nested_unknown'], 'inside a poll group');
    });

    test('arm 9: the stated boundary — an EDITED substructure is the '
        'model\'s rewrite and loses unknown keys inside it', () {
      final doc = ConfigDocument.parse(_saltedDocument());
      final value = doc.modbus.single.value;
      value.pollGroups = [
        ModbusPollGroupConfig(name: 'default', intervalMs: 500),
      ];
      doc.modbus.single.update(value);

      final out = _decode(doc.encode());
      final entry = (out['modbus'] as List).single as Map<String, Object?>;
      final group = (entry['poll_groups'] as List).single as Map;
      expect(group['interval_ms'], 500);
      // This assertion is the boundary said out loud, not a wish: when a
      // recursive merge ever lands, flip it deliberately.
      expect(group.containsKey('x_nested_unknown'), isFalse);
      // The entry's own unknown key is above the rewrite and survives.
      expect(entry['x_entry_unknown'], 'modbus marker');
    });

    test('arm 10: a document whose top level is not an object refuses with '
        'a sentence, not a cast error', () {
      expect(
        () => ConfigDocument.parse('[1, 2, 3]'),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('JSON object'))),
      );
      expect(() => ConfigDocument.parse('not json at all'),
          throwsA(isA<FormatException>()));
    });

    test('arm 11: added and removed entries encode as expected — an add '
        'carries only what the model wrote', () {
      final doc = ConfigDocument.parse(jsonEncode({
        'opcua': [
          {'endpoint': 'opc.tcp://old:4840', 'x_marker': 'old'}
        ],
      }));
      doc.opcua.add(ConfigEntry.fresh(
          OpcUAConfig()..endpoint = 'opc.tcp://new:4840'));
      doc.opcua.removeAt(0);

      final out = _decode(doc.encode());
      final entries = (out['opcua'] as List).cast<Map<String, Object?>>();
      expect(entries, hasLength(1));
      expect(entries.single['endpoint'], 'opc.tcp://new:4840');
      expect(entries.single.containsKey('x_marker'), isFalse,
          reason: 'a removed entry\'s unknown keys must not haunt its '
              'replacement');
    });

    test('arm 12: encode of an untouched document is tree-equal to the '
        'input (formatting is conceded, content is not)', () {
      final input = _decode(_saltedDocument());
      final doc = ConfigDocument.parse(_saltedDocument());
      expect(_eq.equals(_decode(doc.encode()), input), isTrue);
    });

    test('arm 13: the typed round trip through the REAL parser — the '
        'encoded document is what StateManConfig.fromJson accepts', () {
      final doc = ConfigDocument.parse(_saltedDocument());
      final value = doc.opcua.first.value;
      value.endpoint = 'opc.tcp://edited:4840';
      doc.opcua.first.update(value);
      // The sentinels must be resolved server-side; strip them the way the
      // store would before asking the boot parser. Here the document carries
      // real literals, so fromJson must simply accept the whole encode.
      final parsed = StateManConfig.fromJson(_decode(doc.encode()));
      expect(parsed.opcua.first.endpoint, 'opc.tcp://edited:4840');
      expect(parsed.modbus.single.pollGroups.single.name, 'default');
    });
  });
}
