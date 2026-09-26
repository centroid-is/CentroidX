/// The NOTIFY payload vocabulary, and the one property that makes it worth
/// having its own file.
///
/// [NotificationData] is what a listener on a Postgres `LISTEN` channel
/// decodes a payload into. It is hand-written — no drift annotation, no
/// generated half — and it needs `dart:convert` and nothing else. It used to
/// live at the foot of `database_drift.dart`, which meant every consumer of
/// those three declarations also imported `dart:io`, `dart:isolate`,
/// `drift/native.dart` and `drift_postgres`, none of which decoding a JSON
/// string has any use for.
///
/// Two claims are tested here, and the second is the reason the first is worth
/// pinning:
///
///  1. **Behaviour** — the decode is unchanged by the move. The arms below are
///     the first tests these three declarations have ever had; they were
///     written against the code as it stood in `database_drift.dart` and pass
///     unaltered against the code in its new home, which is what makes the
///     move a move rather than a rewrite.
///  2. **Imports** — `database_notification.dart` names nothing outside
///     `dart:convert`. Without this arm the file is one convenience import
///     away from being `database_drift.dart` again, and the next reader would
///     have no way to know that adding one costs anything. It is a source
///     scan rather than a compile-time property because the cost being
///     refused is transitive: a `dart:io` reached through a package import is
///     exactly as fatal to a web build as a direct one, and only the direct
///     one is visible to the analyser as a line in this file.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/database_notification.dart';

/// Where the library under test lives, relative to the package root.
const String _kSourcePath = 'lib/core/database_notification.dart';

/// The only import this file is allowed to hold.
///
/// Deliberately an allow-list rather than a deny-list of `dart:io` and
/// friends: a deny-list forbids the four things that were in the way on the
/// day it was written, and says nothing about the fifth.
const Set<String> _kPermittedImports = {'dart:convert'};

/// Every `import`/`export` target in [_kSourcePath].
List<String> _importTargets() {
  final file = File(_kSourcePath);
  // A throw, not an `expect`: this runs at load time where `expect` raises
  // OutsideTestException and hides why.
  if (!file.existsSync()) {
    throw StateError('Run this suite from packages/tfc_dart. Without '
        '$_kSourcePath there is nothing to scan and the import arm below '
        'would pass by scanning nothing.');
  }
  return RegExp(r"^\s*(?:import|export)\s+'([^']+)'", multiLine: true)
      .allMatches(file.readAsStringSync())
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  group('NotificationData.fromJson', () {
    test('decodes an insert and its row', () {
      final decoded = NotificationData.fromJson(
          '{"action":"INSERT","data":{"time":"2026-09-10T08:00:00Z",'
          '"value":42}}');

      expect(decoded.action, NotificationAction.insert);
      expect(decoded.data['time'], '2026-09-10T08:00:00Z');
      expect(decoded.data['value'], 42);
    });

    test('decodes the other two actions', () {
      expect(NotificationData.fromJson('{"action":"UPDATE","data":{}}').action,
          NotificationAction.update);
      expect(NotificationData.fromJson('{"action":"DELETE","data":{}}').action,
          NotificationAction.delete);
    });

    test('the action is matched case-insensitively', () {
      // Postgres trigger functions in this repo emit `TG_OP`, which is upper
      // case; the enum is lower case. The lowering is the whole reason
      // `byName` is reached through `toLowerCase()` and not called directly,
      // so a rewrite that dropped it would still pass every arm above if they
      // all shouted.
      expect(NotificationData.fromJson('{"action":"insert","data":{}}').action,
          NotificationAction.insert);
      expect(NotificationData.fromJson('{"action":"Insert","data":{}}').action,
          NotificationAction.insert);
    });

    test('an unknown action throws rather than being guessed at', () {
      // Not a silent default: a payload naming an operation this build does
      // not know about is a schema the reader is out of date with, and
      // treating it as an insert would append a row that was deleted.
      expect(() => NotificationData.fromJson('{"action":"TRUNCATE","data":{}}'),
          throwsArgumentError);
    });

    test('a payload that is not an object throws', () {
      expect(() => NotificationData.fromJson('not json'), throwsFormatException);
    });
  });

  group('the file stays web-safe', () {
    test('it imports nothing but dart:convert', () {
      final targets = _importTargets();

      // Anti-vacuity: an empty scan agrees with every claim about it. The
      // file does hold one import, so a regex that found none is broken.
      expect(targets, isNotEmpty,
          reason: 'found no import lines in $_kSourcePath. The scan is broken, '
              'not the file — and a broken scan forbids nothing while passing.');

      expect(targets.toSet().difference(_kPermittedImports), isEmpty,
          reason: 'an import crept into $_kSourcePath. These three '
              'declarations were moved out of database_drift.dart precisely so '
              'that decoding a NOTIFY payload does not drag dart:io, '
              'dart:isolate and drift_postgres in behind it. Anything that '
              'genuinely needs one of those belongs on the other side of the '
              'move. See docs/drift-codegen-boundary.md.');
    });
  });
}
