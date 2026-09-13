/// Where the device-local store lives, and how the legacy one is read.
///
/// The directory test is the only one here that touches the real filesystem
/// layout, and it is deliberately narrow: it asserts that the resolution
/// *works*, not what the path spells. The path is `path_provider`'s to decide
/// — the whole point of the rule is that this code does not invent one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:tfc/core/device_local_store.dart';

/// Captures log lines so a test can assert that a silent-looking branch is not
/// actually silent.
class _CapturingOutput extends LogOutput {
  final List<String> lines = <String>[];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

class _EverythingFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}

({Logger logger, List<String> lines}) capturingLogger() {
  final output = _CapturingOutput();
  return (
    logger: Logger(
      output: output,
      filter: _EverythingFilter(),
      printer: SimplePrinter(printTime: false, colors: false),
    ),
    lines: output.lines,
  );
}

void main() {
  group('normalizeLegacyKeys', () {
    test('strips the legacy flutter. prefix', () {
      expect(
        normalizeLegacyKeys({'flutter.theme_mode': 'dark'}),
        {'theme_mode': 'dark'},
      );
    });

    test('leaves an unprefixed key untouched', () {
      expect(
        normalizeLegacyKeys({'startup_url': '/roe', 'access.session': '{}'}),
        {'startup_url': '/roe', 'access.session': '{}'},
      );
    });

    test('the unprefixed value wins a collision, and the collision is logged',
        () {
      final capture = capturingLogger();

      final normalized = normalizeLegacyKeys(
        {'flutter.x': 1, 'x': 2},
        logger: capture.logger,
      );

      expect(normalized, {'x': 2},
          reason: 'the unprefixed key is the one the app has been reading '
              'through PreferencesApi');
      expect(capture.lines.join('\n'), contains('x'));
      expect(capture.lines, isNotEmpty,
          reason: 'the two key sets are disjoint today, so a collision means '
              'someone renamed a key — it must not pass silently');
    });

    test('the unprefixed value wins whichever order the keys arrive in', () {
      expect(normalizeLegacyKeys({'x': 2, 'flutter.x': 1}), {'x': 2});
    });

    test('a bare "flutter." is not a prefix of anything', () {
      expect(normalizeLegacyKeys({'flutter.': 1}), {'flutter.': 1});
    });

    test('an empty store normalizes to an empty store', () {
      expect(normalizeLegacyKeys({}), isEmpty);
    });
  });

  group('readLegacySharedPreferences falls back to the file', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('device-local-store-test');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    /// `flutter test` registers no `SharedPreferencesAsync` platform
    /// implementation, so every call in this group takes the fallback — which
    /// is the branch that matters, because it is the one an eLinux station
    /// without plugin registration would take.
    File legacyFile() => File('${dir.path}/shared_preferences.json');

    test('it reads a hand-written shared_preferences.json', () async {
      legacyFile().writeAsStringSync(jsonEncode({
        'startup_url': '/roe',
        'flutter.theme_mode': 'dark',
        'access.inactivity_disabled': true,
        'access.inactivity_timeout_minutes': 15,
        'ntp_servers': ['a.pool', 'b.pool'],
      }));

      final read = await readLegacySharedPreferences(dir);

      expect(read['startup_url'], '/roe');
      expect(read['flutter.theme_mode'], 'dark',
          reason: 'reading is not normalizing — the prefix is stripped later');
      expect(read['access.inactivity_disabled'], isTrue);
      expect(read['access.inactivity_timeout_minutes'], 15);
      expect(read['ntp_servers'], ['a.pool', 'b.pool']);
    });

    test('no file at all is an empty store, not a failure', () async {
      expect(await readLegacySharedPreferences(dir), isEmpty);
    });

    test('a corrupt file costs the import, never the boot', () async {
      legacyFile().writeAsStringSync('{not json');
      final capture = capturingLogger();

      expect(
        await readLegacySharedPreferences(dir, logger: capture.logger),
        isEmpty,
      );
      expect(capture.lines, isNotEmpty,
          reason: 'a station that silently imported nothing would look '
              'identical to one that had nothing to import');
    });

    test('a JSON array where an object belongs reads as empty', () async {
      legacyFile().writeAsStringSync('["startup_url"]');

      expect(await readLegacySharedPreferences(dir), isEmpty);
    });

    test('a directory that does not exist reads as empty', () async {
      final missing = Directory('${dir.path}/nope');

      expect(await readLegacySharedPreferences(missing), isEmpty);
    });
  });

  group('deviceLocalStoreDirectory', () {
    test(
      'resolves to a directory that exists and can be written',
      () async {
        final dir = await deviceLocalStoreDirectory();

        expect(dir.existsSync(), isTrue,
            reason: 'path_provider creates the application support directory');

        final probe = File('${dir.path}/.device-local-store-probe');
        probe.writeAsStringSync('ok');
        addTearDown(() {
          if (probe.existsSync()) probe.deleteSync();
        });
        expect(probe.readAsStringSync(), 'ok');
      },
      skip: Platform.isMacOS
          ? 'The macOS branch calls path_provider\'s '
              'getApplicationSupportDirectory(), which needs a platform '
              'channel `flutter test` does not provide; mocking '
              'PathProviderPlatform would test the mock. The Linux and Windows '
              'branches construct the path_provider_* classes directly — no '
              'channel — so they run here and on CI, which is where stations '
              'actually run.'
          : false,
    );
  });
}
