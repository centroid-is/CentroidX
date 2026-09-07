// Reducing one change row's two entity strings to the fields that moved.
//
// Every fixture here is built from an independently constructed `ConfigItem`
// whose `rev`, `updatedAt` and `updatedBy` differ across the two sides, and
// then encoded. That is deliberate: `ConfigItem`'s own equality includes those
// three fields and all three move on every write, so a diff written against
// `ConfigItem ==` would report every entity changed on every save — the
// wrapper-comparison failure `dynamic_value_diff.dart` documents, wearing a
// config costume. Building the sides separately means such a regression fails
// these tests rather than passing them.

import 'dart:io' show File;

import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_field_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/rendered_value.dart';

/// One side of a change row: a real item, encoded the way the store encodes it.
///
/// [rev], [updatedAt] and [updatedBy] are settable and differ between the two
/// sides of every fixture on purpose — see the note at the top of this file.
String entity(
  Object? payload, {
  String? parentId,
  int? sortIndex,
  int rev = 1,
  String updatedBy = 'jon',
  DateTime? updatedAt,
}) =>
    ConfigItem(
      kind: ConfigKind.asset,
      id: 'A1',
      payload: canonicalJson(payload),
      parentId: parentId,
      sortIndex: sortIndex,
      rev: rev,
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
      updatedBy: updatedBy,
    ).encodeEntity();

/// The one change [changes] holds, failing loudly when it holds anything else.
FieldChange only(List<FieldChange> changes) {
  expect(changes, hasLength(1), reason: 'expected one row, got $changes');
  return changes.single;
}

void main() {
  group('the entity envelope', () {
    test('identical configuration written twice is no change at all', () {
      final changes = diffConfigEntities(
        entity({'label': 'CN01', 'coordinates': {'x': 0.31, 'y': 0.5}},
            parentId: '/roe', sortIndex: 3, rev: 7, updatedBy: 'jon'),
        entity({'label': 'CN01', 'coordinates': {'x': 0.31, 'y': 0.5}},
            parentId: '/roe',
            sortIndex: 3,
            rev: 8,
            updatedBy: 'sigga',
            updatedAt: DateTime.utc(2026, 9, 6)),
      );
      expect(changes, isEmpty,
          reason: 'rev, updatedAt and updatedBy describe the write, not the '
              'configuration');
    });

    test('a move renders as one parent_id row', () {
      // Nothing inside the asset changed. A diff rooted at `payload` would
      // report no change at all, which is exactly what folding position into
      // encodeEntity() exists to prevent.
      final change = only(diffConfigEntities(
        entity({'label': 'CN01'}, parentId: '/roe', sortIndex: 3),
        entity({'label': 'CN01'}, parentId: '/baader', sortIndex: 3, rev: 2),
      ));
      expect(change.field, 'parent_id');
      expect(change.oldValue, '/roe');
      expect(change.newValue, '/baader');
      expect(change.noBaseline, isFalse);
    });

    test('a reorder renders as one sort_index row', () {
      final change = only(diffConfigEntities(
        entity({'label': 'CN01'}, parentId: '/roe', sortIndex: 3),
        entity({'label': 'CN01'}, parentId: '/roe', sortIndex: 1, rev: 2),
      ));
      expect(change.field, 'sort_index');
      expect(change.oldValue, '3');
      expect(change.newValue, '1');
    });

    test('several moved fields render in a stable order', () {
      final changes = diffConfigEntities(
        entity({'label': 'CN01'}, parentId: '/roe', sortIndex: 3),
        entity({'label': 'CN02'}, parentId: '/baader', sortIndex: 1, rev: 2),
      );
      expect(changes.map((c) => c.field).toList(),
          ['parent_id', 'payload.label', 'sort_index']);
    });
  });

  group('nested objects', () {
    test('one moved leaf is one dotted-path row, not "the object changed"', () {
      final change = only(diffConfigEntities(
        entity({
          'label': 'CN01',
          'coordinates': {'x': 0.31, 'y': 0.5}
        }, parentId: '/roe'),
        entity({
          'label': 'CN01',
          'coordinates': {'x': 0.42, 'y': 0.5}
        }, parentId: '/roe', rev: 2),
      ));
      expect(change.field, 'payload.coordinates.x');
      expect(change.oldValue, '0.31');
      expect(change.newValue, '0.42');
    });

    test('a member present on one side only is one row, with no descent', () {
      final change = only(diffConfigEntities(
        entity({'label': 'CN01'}),
        entity({
          'label': 'CN01',
          'coordinates': {'x': 0.42, 'y': 0.5}
        }, rev: 2),
      ));
      expect(change.field, 'payload.coordinates');
      expect(change.oldValue, isNull);
      expect(change.newValue, '{x: 0.42, y: 0.5}');
    });

    test('an object replaced by a scalar is one row at that path', () {
      final change = only(diffConfigEntities(
        entity({
          'coordinates': {'x': 0.42}
        }),
        entity({'coordinates': 'origin'}, rev: 2),
      ));
      expect(change.field, 'payload.coordinates');
      expect(change.oldValue, '{x: 0.42}');
      expect(change.newValue, 'origin');
    });

    test('deep nesting keeps the whole path', () {
      final change = only(diffConfigEntities(
        entity({
          'a': {
            'b': {'c': 1}
          }
        }),
        entity({
          'a': {
            'b': {'c': 2}
          }
        }, rev: 2),
      ));
      expect(change.field, 'payload.a.b.c');
    });
  });

  group('lists', () {
    test('a reorder is one row for the list, never a row per index', () {
      final change = only(diffConfigEntities(
        entity({
          'waypoints': [
            {'x': 1},
            {'x': 2},
            {'x': 3}
          ]
        }),
        entity({
          'waypoints': [
            {'x': 3},
            {'x': 1},
            {'x': 2}
          ]
        }, rev: 2),
      ));
      expect(change.field, 'payload.waypoints');
      expect(change.oldValue, '[{x: 1}, {x: 2}, {x: 3}]');
      expect(change.newValue, '[{x: 3}, {x: 1}, {x: 2}]');
    });

    test('an unchanged list is not a change', () {
      expect(
        diffConfigEntities(
          entity({
            'waypoints': [1, 2, 3]
          }),
          entity({
            'waypoints': [1, 2, 3]
          }, rev: 2),
        ),
        isEmpty,
      );
    });

    test('two long lists that truncate identically are still compared', () {
      // The rendered forms of these two are the same 256 characters. Comparing
      // renderings rather than structure would call them equal, and a diff
      // that misses a change because the values were long is the defect this
      // whole file exists to remove.
      final longA = [for (var i = 0; i < 200; i++) i];
      final longB = [...longA]..[199] = 999;

      final change = only(diffConfigEntities(
        entity({'recipe': longA}),
        entity({'recipe': longB}, rev: 2),
      ));
      expect(change.field, 'payload.recipe');
      expect(change.oldValue, change.newValue,
          reason: 'the fixture is only meaningful if the renderings collide');
      expect(change.oldValue, endsWith(kRenderTruncationMarker));
    });
  });

  group('explicit null against absent', () {
    test('absent to explicitly null emits nothing', () {
      expect(
        diffConfigEntities(
          entity({'label': 'CN01'}),
          entity({'label': 'CN01', 'label_offset': null}, rev: 2),
        ),
        isEmpty,
      );
    });

    test('explicitly null to absent emits nothing', () {
      expect(
        diffConfigEntities(
          entity({'label': 'CN01', 'label_offset': null}),
          entity({'label': 'CN01'}, rev: 2),
        ),
        isEmpty,
      );
    });

    test('a held null renders as the string "null"', () {
      final toNull = only(diffConfigEntities(
        entity({'label_offset': 4}),
        entity({'label_offset': null}, rev: 2),
      ));
      expect(toNull.oldValue, '4');
      expect(toNull.newValue, 'null');

      final fromNull = only(diffConfigEntities(
        entity({'label_offset': null}),
        entity({'label_offset': 4}, rev: 2),
      ));
      expect(fromNull.oldValue, 'null');
      expect(fromNull.newValue, '4');
    });

    test('an absent key renders as Dart null, distinct from "null"', () {
      final appeared = only(diffConfigEntities(
        entity(<String, Object?>{}),
        entity({'label_offset': 4}, rev: 2),
      ));
      expect(appeared.oldValue, isNull);
      expect(appeared.newValue, '4');

      final vanished = only(diffConfigEntities(
        entity({'label_offset': 4}),
        entity(<String, Object?>{}, rev: 2),
      ));
      expect(vanished.oldValue, '4');
      expect(vanished.newValue, isNull);
    });

    test('adding a nullable field to a config class renders as zero rows',
        () {
      // Adding a nullable field to any @JsonSerializable config class makes
      // every entity of that kind emit one more explicit null, so the next
      // save writes and logs all of them. Preventing that write is a
      // write-path concern; keeping the resulting action readable is this
      // file's, and readable means nothing rather than 300 rows each saying
      // `payload.label_offset: <none> -> null`.
      final rows = <FieldChange>[];
      for (var i = 0; i < 300; i++) {
        rows.addAll(diffConfigEntities(
          entity({'label': 'CN$i', 'x': i}, parentId: '/roe', sortIndex: i),
          entity({'label': 'CN$i', 'x': i, 'label_offset': null},
              parentId: '/roe', sortIndex: i, rev: 2),
        ));
      }
      expect(rows, isEmpty);
    });
  });

  group('a missing side', () {
    test('no old entity is one marked row carrying the whole new value', () {
      final change = only(diffConfigEntities(
        null,
        entity({'label': 'CN01'}, parentId: '/roe', sortIndex: 3),
      ));
      expect(change.field, isNull);
      expect(change.noBaseline, isTrue);
      expect(change.oldValue, isNull);
      expect(change.newValue, contains('CN01'));
      expect(change.newValue, contains('/roe'));
    });

    test('no new entity is one row whose new side is null', () {
      final change = only(diffConfigEntities(
        entity({'label': 'CN01'}, parentId: '/roe'),
        null,
      ));
      expect(change.field, isNull);
      expect(change.noBaseline, isFalse);
      expect(change.oldValue, contains('CN01'));
      expect(change.newValue, isNull);
    });

    test('neither side is nothing to say', () {
      expect(diffConfigEntities(null, null), isEmpty);
    });
  });

  group('malformed history', () {
    test('a side that will not parse is one opaque whole-entity row', () {
      // Never a swallowed exception and never an empty diff: a change list
      // silently emptied is the failure this file exists to prevent, and a
      // history row written by a version that is gone must still render.
      final change = only(diffConfigEntities(
        entity({'label': 'CN01'}),
        '{not json at all',
      ));
      expect(change.field, isNull);
      expect(change.oldValue, contains('CN01'));
      expect(change.newValue, '{not json at all');
    });

    test('two identical unparseable sides are still no change', () {
      expect(diffConfigEntities('<<legacy>>', '<<legacy>>'), isEmpty);
    });

    test('an entity that is not an object is opaque, not a crash', () {
      final change = only(diffConfigEntities('[1, 2]', '[1, 3]'));
      expect(change.field, isNull);
      expect(change.oldValue, '[1, 2]');
      expect(change.newValue, '[1, 3]');
    });
  });

  group('rendering', () {
    test('a long value is capped and marked', () {
      final change = only(diffConfigEntities(
        entity({'note': 'a' * 1000}),
        entity({'note': 'b' * 1000}, rev: 2),
      ));
      expect(change.oldValue, endsWith(kRenderTruncationMarker));
      expect(change.oldValue!.length,
          kMaxRenderedValueLength + kRenderTruncationMarker.length);
    });
  });

  group('the dependency guard (D-3)', () {
    test('config_field_diff.dart links neither Flutter, FFI nor open62541',
        () {
      final code = File('lib/core/config/config_field_diff.dart')
          .readAsLinesSync()
          .where((l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
          .join('\n');

      expect(code, isNotEmpty);
      for (final forbidden in const [
        'package:flutter',
        'dart:ffi',
        'open62541',
        'dynamic_value_diff',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: 'the display diff is read by every process that reads '
                'configuration; importing $forbidden links a native library '
                'into all of them (D-3)');
      }
    });
  });
}
