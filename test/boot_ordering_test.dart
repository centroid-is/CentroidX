/// The one ordering constraint in `main()`, and the singleton it exists for.
///
/// The device-local store is opened by `initDeviceLocalPreferences()` before
/// `runApp`. Everything that reads a preference is downstream of that call:
/// `PageManager.load()` immediately (before `runApp`, no `ProviderScope` yet),
/// the session and the NTP list later still, from providers that do not exist
/// until the scope is built. So there is exactly one ordering to defend, and
/// this file defends it two ways — the failure mode when init has not run, and
/// the order of the calls in the source.
///
/// Why a source-order check at all: the ordering is a property of one function
/// body that no unit test can execute (`_startApp` opens a database, a
/// keychain and a window). Reading the source is what makes SC-3 explicit
/// rather than incidental. Same idiom as `test/providers/guard_wiring_test.dart`
/// — comment lines are stripped first, so the comment explaining the rule
/// cannot be what satisfies the test enforcing it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/device_local_store.dart'
    show legacySharedPreferencesFileName;
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/providers/preferences.dart';

/// `main.dart` with every comment line removed.
///
/// The insertion carries a comment that quotes `pageManager.load()`, several
/// lines *above* the call it is about. Ordering the raw text would therefore
/// prove the opposite of what is meant.
String _mainWithoutComments() => File('centroid-hmi/lib/main.dart')
    .readAsLinesSync()
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  setUp(resetDeviceLocalPreferencesForTest);
  tearDown(resetDeviceLocalPreferencesForTest);

  group('the factory before init', () {
    test('throws a StateError naming initDeviceLocalPreferences', () {
      // The loud failure is the design. A lazy open would have to be async and
      // every caller is synchronous; a silent empty store is the exact failure
      // — "the station lost its pages" — the boot ordering exists to prevent.
      expect(
        createDeviceLocalPreferences,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('initDeviceLocalPreferences()'),
            contains('createDeviceLocalPreferences()'),
          ),
        )),
      );
    });
  });

  group('the singleton', () {
    test('the factory returns the store that was seeded', () {
      final seeded = InMemoryPreferences();
      setDeviceLocalPreferencesForTest(seeded);

      expect(createDeviceLocalPreferences(), same(seeded));
    });

    test('two calls return the same instance, not two wrappers', () {
      // C-6, as an assertion: `RecentColors.load`/`add` call the factory per
      // colour pick and `_SharedPrefsReader` news one up in a field
      // initialiser. A fresh instance per call is a fresh drift background
      // isolate and file handle each time.
      setDeviceLocalPreferencesForTest(InMemoryPreferences());

      expect(createDeviceLocalPreferences(),
          same(createDeviceLocalPreferences()));
    });

    test('a second init is a no-op, so it cannot swap the store underneath a '
        'holder', () async {
      final seeded = InMemoryPreferences();
      setDeviceLocalPreferencesForTest(seeded);

      // Would otherwise resolve a directory and open a database; the point is
      // that it returns without touching either.
      await initDeviceLocalPreferences();

      expect(createDeviceLocalPreferences(), same(seeded));
    });
  });

  group('the boot order in centroid-hmi/lib/main.dart', () {
    late String code;

    setUpAll(() => code = _mainWithoutComments());

    test('the store is opened before the first read of it', () {
      final init = code.indexOf('await initDeviceLocalPreferences();');
      final factory = code.indexOf('createDeviceLocalPreferences()');
      final load = code.indexOf('pageManager.load()');

      expect(init, isNot(-1),
          reason: 'main() no longer opens the device-local store; every read '
              'below it now throws a StateError at boot');
      expect(factory, isNot(-1));
      expect(load, isNot(-1));

      expect(init, lessThan(factory),
          reason: 'createDeviceLocalPreferences() runs before the store is '
              'open — it throws');
      expect(init, lessThan(load),
          reason: 'PageManager.load() is the earliest read of the store: a '
              'station that reaches it unimported comes up on the built-in '
              'default pages with its own pages gone, and persists that');
    });

    test('the mirror is opened before the pages are loaded from it, and both '
        'before runApp', () {
      // SC-5, as source order. `PageManager.load()` serves rows out of the
      // store's in-memory snapshot, and that snapshot is filled by `open()`.
      // A load that ran first would find an empty store, fall through to the
      // `page_editor_data` blob, and come up on a layout that may be a save
      // behind — silently, because a store that has not been opened and a
      // station with no rows yet are indistinguishable from the outside.
      final init = code.indexOf('await initDeviceLocalPreferences();');
      final db = code.indexOf('deviceLocalDatabase()');
      final open = code.indexOf('await configStore.open();');
      final load = code.indexOf('pageManager.load()');
      final menu = code.indexOf('pageManager.getRootMenuItems()');
      final run = code.indexOf('runApp(');

      for (final (name, at) in [
        ('deviceLocalDatabase()', db),
        ('await configStore.open();', open),
        ('pageManager.getRootMenuItems()', menu),
        ('runApp(', run),
      ]) {
        expect(at, isNot(-1), reason: '$name is gone from main()');
      }

      expect(init, lessThan(db),
          reason: 'deviceLocalDatabase() throws a StateError before the '
              'device-local store is open');
      expect(db, lessThan(open));
      expect(open, lessThan(load),
          reason: 'the pages are read out of the snapshot open() fills; a '
              'load before it silently serves the blob instead of the rows');
      expect(load, lessThan(menu),
          reason: 'the navigation menu and the route table are both built '
              'from what load() produced');
      expect(load, lessThan(run),
          reason: 'the pages are loaded before runApp, so the first frame is '
              'the plant and not a blank page');
    });

    test('the mirror open is guarded, so a station with an unreadable one '
        'still starts', () {
      // The rule the whole boot sequence is written to: degraded and loud
      // beats blank. `open()` inside a try means a mirror that will not read
      // leaves `store` null and `load()` falls back to the blob, which is
      // exactly the behaviour every station had before rows existed.
      final open = code.indexOf('await configStore.open();');
      final tryAt = code.lastIndexOf('try {', open);
      expect(tryAt, isNot(-1),
          reason: 'configStore.open() is not inside a try — a mirror that '
              'will not open would stop the station from booting');
      expect(code.indexOf('configStore = null;', open), isNot(-1),
          reason: 'the catch must leave no store at all, so load() takes the '
              'blob path rather than reading a half-open one');
    });

    test('it is awaited, not fired and forgotten', () {
      // An unawaited init races the import against the first read, which is a
      // bug that appears only on a slow disk on a station that has not
      // imported yet — i.e. once, at the customer.
      expect(code, contains('await initDeviceLocalPreferences();'));
    });

    test('the one insertion covers the marionette branch too', () {
      // `main()` branches on `_enableMarionette` and both branches call
      // `_startApp`, which is where the init lives. If that ever became two
      // entrypoints, this fails and the second one needs its own init.
      expect('_startApp('.allMatches(code).length, greaterThanOrEqualTo(3),
          reason: 'both branches of main() and the declaration');
    });
  });

  group('the store the init opens', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('boot_ordering_test');
    });

    tearDown(() async {
      // resetDeviceLocalPreferencesForTest (registered above) closes the
      // handle first; deleting the folder under an open background isolate is
      // how this test would start failing on Windows only.
      await resetDeviceLocalPreferencesForTest();
      if (folder.existsSync()) await folder.delete(recursive: true);
    });

    test('is the SQLite one, carrying what shared_preferences held', () async {
      // `SharedPreferencesAsync().getAll()` has no platform channel under
      // `flutter test`, so the import takes its documented second path and
      // reads this file — which is also the eLinux path where no plugin is
      // registered. Either way the values have to arrive.
      File('${folder.path}/$legacySharedPreferencesFileName').writeAsStringSync(
        '{"startup_url": "/pages/packing", "flutter.theme_mode": "dark"}',
      );

      await initDeviceLocalPreferences(directoryForTest: () async => folder);
      final store = createDeviceLocalPreferences();

      expect(store, isNot(isA<InMemoryPreferences>()),
          reason: 'the whole point of the plan is that this is now SQLite');
      expect(File('${folder.path}/config.sqlite').existsSync(), isTrue);
      expect(await store.getString('startup_url'), '/pages/packing');
      expect(await store.getString('theme_mode'), 'dark',
          reason: 'the legacy `flutter.` prefix is stripped on the way in');
    });
  });

  group('a station whose store cannot be opened still boots', () {
    // T-01-14, proved rather than asserted in a comment. `main()` awaits this
    // call before `runApp`: anything it throws is a panel that does not start,
    // in a fish factory, at 04:00.

    tearDown(resetDeviceLocalPreferencesForTest);

    test('when the data directory cannot be resolved', () async {
      await initDeviceLocalPreferences(
        directoryForTest: () async =>
            throw StateError('nowhere to put the store'),
      );

      final store = createDeviceLocalPreferences();
      expect(store, isA<InMemoryPreferences>());

      // Degraded, not broken: the app writes through it all day.
      await store.setString('startup_url', '/pages/packing');
      expect(await store.getString('startup_url'), '/pages/packing');
    });

    test('when config.sqlite is corrupt', () async {
      final folder =
          await Directory.systemTemp.createTemp('boot_ordering_corrupt');
      addTearDown(() async {
        if (folder.existsSync()) await folder.delete(recursive: true);
      });
      // Not a database. drift opens lazily, so this surfaces inside the
      // import — i.e. after the point a naive implementation would have
      // assigned the singleton.
      File('${folder.path}/config.sqlite')
          .writeAsBytesSync(List<int>.filled(4096, 0x41));

      await initDeviceLocalPreferences(directoryForTest: () async => folder);

      final store = createDeviceLocalPreferences();
      expect(store, isA<InMemoryPreferences>());
      await store.setBool('flag', true);
      expect(await store.getBool('flag'), isTrue);
    });

    test('when the directory is read-only', () async {
      final folder =
          await Directory.systemTemp.createTemp('boot_ordering_readonly');
      addTearDown(() async {
        // Restore the mode first or the delete fails for the same reason the
        // open did.
        await Process.run('chmod', ['u+w', folder.path]);
        if (folder.existsSync()) await folder.delete(recursive: true);
      });
      final chmod = await Process.run('chmod', ['a-w', folder.path]);
      expect(chmod.exitCode, 0,
          reason: 'could not make the directory read-only');

      await initDeviceLocalPreferences(directoryForTest: () async => folder);

      expect(createDeviceLocalPreferences(), isA<InMemoryPreferences>());
    }, testOn: '!windows');
  });
}
