@TestOn('vm')
/// The structural half of the hold registry's guarantees.
///
/// **Why this file exists, and why it is separate.**
///
/// `tfc_dart/test/core/relay/backend_hold_test.dart:637-663` carries two source
/// scans over `lib/core/relay/backend_hold.dart` — "has no clock of its own"
/// and "every fire-and-forget future carries its own handler". Plan 18-05 moves
/// the live set, the engage guard and the teardown loop OUT of that file, so
/// those scans stop reading half of what they were written to guard. That is
/// the failure mode 18-03 hit and named: **a pin that reads a PATH goes vacuous
/// when content moves — silently, staying green.**
///
/// The repair is not to weaken the scans on the `tfc_dart` side (they still
/// hold, and `_tick` deliberately stayed there so their live control stays
/// live). It is to scan the file the content moved INTO, for the same
/// prohibitions, with a live control of its own so this file cannot decay into
/// a scan of a file that no longer says anything.
///
/// `@TestOn('vm')` for one reason only: `dart:io`. Every behavioural arm lives
/// in `hold_registry_test.dart`, which stays `dart:io`-free so it runs under
/// `-p chrome` as well.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Read relative to the package root, which is where `dart test` runs.
String get _source => File('lib/src/hold_registry.dart').readAsStringSync();

List<String> get _codeLines => <String>[
      for (final line in File('lib/src/hold_registry.dart').readAsLinesSync())
        if (!line.trimLeft().startsWith('///') &&
            !line.trimLeft().startsWith('//'))
          line,
    ];

void main() {
  group('the shipping registry', () {
    test('the live control: the file still holds the things these scans guard',
        () {
      final source = _source;
      expect(source.contains('class HoldRegistry'), isTrue);
      expect(source.contains('releaseAll'), isTrue);
      expect(source.contains('awaitReleases'), isTrue,
          reason: 'without this control every prohibition below would pass '
              'against an empty file, which is exactly how a path-reading pin '
              'goes vacuous');
    });

    test('has no clock of its own — only a tick advances the counter', () {
      final offenders = <String>[
        for (final line in _codeLines)
          if (line.contains('Timer') ||
              line.contains('Stopwatch') ||
              line.contains('DateTime.now') ||
              line.contains('DateTime.timestamp'))
            line.trim(),
      ];

      expect(offenders, isEmpty,
          reason: 'a clock inside the deadman feeds it without an operator. '
              'The caller chooses the cadence — 100 ms against a ~1 s PLC '
              'deadman — precisely so that the thing keeping the machine '
              'alive is a finger and not a scheduler. A source that helpfully '
              'kept a deadman fed would pass every other property in the hold '
              'contract');
    });

    test('every fire-and-forget future carries its own handler', () {
      expect(_source.contains('unawaited' '('), isFalse,
          reason: 'a bare fire-and-forget wrapper attaches NO error handler; '
              'the future it swallows still reaches the zone, and it fails '
              'whichever unrelated test happens to be running when it lands '
              'rather than the hold that stopped being fed');
      expect(_source.contains('.catchError('), isTrue,
          reason: 'the teardown releases are fire-and-forget under '
              'awaitReleases: false, so each one has to carry an explicit '
              'handler');
    });

    test('no deadline on any teardown path', () {
      final offenders = <String>[
        for (final line in _codeLines)
          if (line.contains('.timeout(')) line.trim(),
      ];

      expect(offenders, isEmpty,
          reason: 'a release that waited for the plant to confirm would hang '
              'on exactly the dead link that caused the teardown, and a '
              'dispose that gave up half way leaves the thing it was '
              'disposing in a state nobody owns. Neither side of this '
              'argument wants a deadline here');
    });

    test('the package floor holds: no logger, no dart:io, no dependency at all',
        () {
      final imports = <String>[
        for (final line in _codeLines)
          if (line.trimLeft().startsWith('import ')) line.trim(),
      ];

      expect(imports, isNotEmpty,
          reason: 'the live control for this arm: a file with no imports at '
              'all would pass every prohibition below trivially');
      for (final import in imports) {
        expect(import.contains('package:'), isFalse,
            reason: '`$import` — tfc_relay_protocol has ZERO runtime '
                'dependencies and must keep them. The registry takes an '
                'onLostWrite callback precisely so each call site wires its '
                'own Logger: the registry does not know what a log line costs '
                'in the process it is running in');
        expect(import.contains('dart:io'), isFalse,
            reason: '`$import` — dart:io would make every consumer of this '
                'file VM-only, and Flutter web is a hard constraint');
      }
    });
  });
}
