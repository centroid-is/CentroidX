// The rendering helper both diffs share.
//
// It was lifted out of `dynamic_value_diff.dart` rather than imported from it:
// that file imports open62541, and a config library that reached for its
// constants would link a native library into every binary that reads
// configuration (D-3 in `docs/relational-config-deferred-defects.md`). The
// last group in this file is what pins the lift.

import 'dart:io' show File;

import 'package:test/test.dart';
import 'package:tfc_dart/core/rendered_value.dart';

void main() {
  group('renderJsonValue', () {
    test('renders scalars, maps and lists as their JSON-ish shape', () {
      expect(renderJsonValue(42), '42');
      expect(renderJsonValue('hello'), 'hello');
      expect(renderJsonValue(true), 'true');
      expect(renderJsonValue({'a': 1, 'b': 2}), '{a: 1, b: 2}');
      expect(renderJsonValue([1, 2, 3]), '[1, 2, 3]');
      expect(
        renderJsonValue({
          'coordinates': {'x': 0.31, 'y': 2}
        }),
        '{coordinates: {x: 0.31, y: 2}}',
      );
    });

    test('renders a held null as the string "null", never as empty', () {
      // A caller distinguishes "absent" from "held null" by not calling this
      // at all for an absent key. Collapsing a held null onto '' here would
      // take that distinction away from every caller at once.
      expect(renderJsonValue(null), 'null');
      expect(renderJsonValue({'label': null}), '{label: null}');
      expect(renderJsonValue([null, 1]), '[null, 1]');
    });

    test('caps the result at kMaxRenderedValueLength and marks the cut', () {
      expect(kMaxRenderedValueLength, 256);

      final long = 'x' * (kMaxRenderedValueLength * 2);
      final rendered = renderJsonValue(long);

      expect(rendered, startsWith('x' * 10));
      expect(rendered, endsWith(kRenderTruncationMarker));
      expect(rendered.length,
          kMaxRenderedValueLength + kRenderTruncationMarker.length);
    });

    test('a value shorter than the cap is returned whole and unmarked', () {
      final rendered = renderJsonValue('x' * kMaxRenderedValueLength);
      expect(rendered.length, kMaxRenderedValueLength);
      expect(rendered.contains(kRenderTruncationMarker), isFalse);
    });
  });

  group('writeRenderedValue', () {
    test('bounds the intermediate buffer, not just the returned string', () {
      // The early return is what makes rendering a large structure cost the
      // cap rather than the structure: without it a 10k-element list builds
      // the whole megabyte and then throws all but 256 characters away.
      final out = StringBuffer();
      writeRenderedValue(out, [for (var i = 0; i < 10000; i++) 'x' * 10]);

      expect(out.length, greaterThan(kMaxRenderedValueLength));
      expect(out.length, lessThan(kMaxRenderedValueLength + 64));
    });

    test('a deeply nested structure terminates against the cap', () {
      Object? nested = 'leaf';
      for (var i = 0; i < 5000; i++) {
        nested = {'k': nested};
      }
      final out = StringBuffer();
      writeRenderedValue(out, nested);

      expect(out.length, greaterThan(kMaxRenderedValueLength));
      expect(out.length, lessThan(kMaxRenderedValueLength * 4));
    });

    test('unwrap is applied to map values and list elements', () {
      // The hook is how `dynamic_value_diff.dart` keeps its DynamicValue
      // unwrapping while the walker itself stays free of the type.
      final out = StringBuffer();
      writeRenderedValue(
        out,
        {
          'a': const _Boxed(1),
          'b': [const _Boxed(2)]
        },
        unwrap: (v) => v is _Boxed ? v.value : v,
      );
      expect(out.toString(), '{a: 1, b: [2]}');
    });
  });

  group('the dependency guard', () {
    test('rendered_value.dart imports no Flutter, FFI or open62541', () {
      final code = File('lib/core/rendered_value.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//') &&
              !l.trimLeft().startsWith('///'))
          .join('\n');

      expect(code, isNotEmpty);
      for (final forbidden in const [
        'package:flutter',
        'dart:ffi',
        'open62541',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: 'rendered_value.dart is imported by a config library that '
                'must stay reachable from a process with no Flutter engine and '
                'no native link ($forbidden)');
      }
    });
  });
}

/// A wrapper the walker knows nothing about, standing in for `DynamicValue`.
class _Boxed {
  const _Boxed(this.value);
  final Object? value;
}
