import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/last_route.dart';
import 'package:tfc/core/runner_liveness.dart';

class _BrokenPreferences extends InMemoryPreferences {
  @override
  Future<String?> getString(String key) async => throw StateError('broken');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('broken');
}

void main() {
  const firstEngine = EngineEpoch(epoch: 1, reason: 'initial start');
  const rebuilt =
      EngineEpoch(epoch: 2, reason: 'session change: remote connect');
  const routable = {'/', '/line', '/advanced/page-editor'};

  bool isRoutable(String path) => routable.contains(path);

  group('isEngineRebuild', () {
    test('only an epoch after the first counts', () {
      expect(isEngineRebuild(EngineEpoch.unknown), isFalse);
      expect(isEngineRebuild(firstEngine), isFalse);
      expect(isEngineRebuild(rebuilt), isTrue);
      expect(isEngineRebuild(const EngineEpoch(epoch: 7, reason: 'gpu loss')),
          isTrue);
    });
  });

  group('resolveResumePath', () {
    test('a rebuilt engine resumes the recorded route', () {
      expect(
        resolveResumePath(
          epoch: rebuilt,
          lastRoute: '/advanced/page-editor',
          startupPath: '/',
          isRoutable: isRoutable,
        ),
        '/advanced/page-editor',
      );
    });

    test('a process start opens the startup page whatever was recorded', () {
      expect(
        resolveResumePath(
          epoch: firstEngine,
          lastRoute: '/advanced/page-editor',
          startupPath: '/line',
          isRoutable: isRoutable,
        ),
        '/line',
      );
    });

    test('a platform with no runner never resumes', () {
      expect(
        resolveResumePath(
          epoch: EngineEpoch.unknown,
          lastRoute: '/line',
          startupPath: '/',
          isRoutable: isRoutable,
        ),
        '/',
      );
    });

    test('nothing recorded falls back to the startup page', () {
      expect(
        resolveResumePath(
          epoch: rebuilt,
          lastRoute: null,
          startupPath: '/line',
          isRoutable: isRoutable,
        ),
        '/line',
      );
    });

    test('a route that no longer leads anywhere falls back', () {
      expect(
        resolveResumePath(
          epoch: rebuilt,
          lastRoute: '/gone',
          startupPath: '/',
          isRoutable: isRoutable,
        ),
        '/',
      );
    });

    test('the query survives and routability is judged on the path', () {
      expect(
        resolveResumePath(
          epoch: rebuilt,
          lastRoute: '/line?tab=2',
          startupPath: '/',
          isRoutable: isRoutable,
        ),
        '/line?tab=2',
      );
    });

    test('a recorded value that is not an absolute path is ignored', () {
      expect(
        resolveResumePath(
          epoch: rebuilt,
          lastRoute: 'line',
          startupPath: '/',
          isRoutable: isRoutable,
        ),
        '/',
      );
    });
  });

  group('read / write', () {
    test('round-trips through the preferences store', () async {
      final prefs = InMemoryPreferences();
      await writeLastRoute(prefs, '/line?tab=2');
      expect(await readLastRoute(prefs), '/line?tab=2');
    });

    test('refuses to record anything that is not an absolute path', () async {
      final prefs = InMemoryPreferences();
      await writeLastRoute(prefs, 'main');
      expect(await prefs.containsKey(lastRoutePrefsKey), isFalse);
    });

    test('a stored value that is not a path reads as nothing', () async {
      final prefs = InMemoryPreferences();
      await prefs.setString(lastRoutePrefsKey, 'garbage');
      expect(await readLastRoute(prefs), isNull);
    });

    test('a broken store never throws into startup', () async {
      final prefs = _BrokenPreferences();
      await writeLastRoute(prefs, '/line');
      expect(await readLastRoute(prefs), isNull);
    });
  });
}
