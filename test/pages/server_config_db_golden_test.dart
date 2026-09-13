/// Golden images of the database store/load flows, for design review and PR
/// descriptions.
///
/// Frames: the Import/Export card with the new database buttons, the store
/// dialog where the operator picks the encryption password (including its
/// validation error), and the load dialog with the stored-config metadata
/// (including the wrong-password retry state).
///
/// To update: flutter test test/pages/server_config_db_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:drift/drift.dart' show Value;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import 'package:tfc/core/server_config_db.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

/// Wide enough for the card header to stay on one row (it collapses below
/// 500px) and tall enough for the dialogs.
const Size _viewport = Size(860, 620);

Widget _buildCard(Database? database) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences()),
      databaseProvider.overrideWith((ref) async => database),
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
    ],
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child:
              Align(alignment: Alignment.topCenter, child: ImportExportCard()),
        ),
      ),
    ),
  );
}

Future<void> _pumpCard(WidgetTester tester, Database? database) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await pumpAndLoad(tester, _buildCard(database));
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

/// An in-memory database for the dialogs to fetch from. Each test must end
/// with `await db.dispose()` — the wrapper's periodic flush timer otherwise
/// trips the framework's pending-timer check, which runs before tearDowns.
Database _testDatabase(WidgetTester tester) {
  final appDb = AppDatabase.inMemoryForTest();
  final db = Database(appDb);
  addTearDown(() async => appDb.close());
  return db;
}

/// Seeds the stored config the dialogs read back.
///
/// Straight into the `config_item` row `ServerConfigDb.fetch` selects — the
/// shape another station would have left it in. Going through a store instead
/// would drag a whole `ConfigStore` and its guard into a file whose subject is
/// pixels; the dialogs read the row, so the row is what this seeds. None of
/// these images move.
Future<void> _seed(Database db, StoredServerConfig config) =>
    db.db.into(db.db.configItemTable).insertOnConflictUpdate(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: ServerConfigDb.prefsKey,
            scope: ConfigScope.shared.wireName,
            payload: ConfigItem.of(
              kind: ConfigKind.preference,
              id: ServerConfigDb.prefsKey,
              value: preferencePayload(
                  kPrefStringType, jsonEncode(config.toJson())),
            ).payload,
            rev: const Value(1),
            updatedAt: DateTime.now(),
            updatedBy: 'other-station',
          ),
        );

// ---------------------------------------------------------------------------
// Fonts — see server_config_reorder_golden_test.dart for the why.
// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }

  final faRoot = _packageRoot('font_awesome_flutter');
  if (faRoot != null) {
    await load('packages/font_awesome_flutter/FontAwesomeSolid',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Solid-900.otf');
    await load('packages/font_awesome_flutter/FontAwesomeRegular',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Regular-400.otf');
  }
}

String? _packageRoot(String package) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final packages = (jsonDecode(config.readAsStringSync())
      as Map<String, dynamic>)['packages'] as List<dynamic>;
  for (final entry in packages.cast<Map<String, dynamic>>()) {
    if (entry['name'] == package) {
      return Uri.parse(entry['rootUri'] as String).toFilePath();
    }
  }
  return null;
}

void main() {
  setUpAll(_loadFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    // Production-strength PBKDF2 takes tens of seconds per derivation in the
    // debug-mode test VM; the dialogs under capture look the same either way.
    SecureEnvelope.kdfIterationsForTest = 10;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc-hmi',
        'packageName': 'is.centroid.tfc',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );
  });

  testWidgets('card — file and database transfer side by side', (tester) async {
    await _pumpCard(tester, null);
    await _expectGolden(tester, 'server_config_db_card.png');
  });

  testWidgets('store dialog — password choice, replace warning',
      (tester) async {
    final db = _testDatabase(tester);
    // An envelope is already stored, so the dialog shows what gets replaced.
    await _seed(
      db,
      StoredServerConfig(
        savedAt: DateTime(2026, 8, 18, 9, 30),
        savedBy: 'packing-hall-1',
        envelope: {'version': 1},
      ),
    );

    await _pumpCard(tester, db);
    await tester.tap(find.text('Store in Database'));
    await settle(tester);

    await _expectGolden(tester, 'server_config_db_store_dialog.png');

    await db.dispose();
  });

  testWidgets('store dialog — passwords do not match', (tester) async {
    final db = _testDatabase(tester);
    await _pumpCard(tester, db);
    await tester.tap(find.text('Store in Database'));
    await settle(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'hunter22');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'hunter23');
    await tester.tap(find.text('Store'));
    await settle(tester);

    await _expectGolden(tester, 'server_config_db_store_mismatch.png');

    await db.dispose();
  });

  testWidgets('load dialog — stored metadata and overwrite warning',
      (tester) async {
    final db = _testDatabase(tester);
    final envelope = await SecureEnvelope.encrypt(
      jsonConfig: {'opcua': []},
      compiledPrefix: 'Flottur köttur:',
      exportPostfix: 'hunter22',
    );
    await _seed(
      db,
      StoredServerConfig(
        savedAt: DateTime(2026, 8, 18, 9, 30),
        savedBy: 'packing-hall-1',
        envelope: envelope,
      ),
    );

    await _pumpCard(tester, db);
    await tester.tap(find.text('Load from Database'));
    await settle(tester);

    await _expectGolden(tester, 'server_config_db_load_dialog.png');

    await db.dispose();
  });

  testWidgets('load dialog — wrong password keeps the dialog open',
      (tester) async {
    final db = _testDatabase(tester);
    final envelope = await SecureEnvelope.encrypt(
      jsonConfig: {'opcua': []},
      compiledPrefix: 'Flottur köttur:',
      exportPostfix: 'hunter22',
    );
    await _seed(
      db,
      StoredServerConfig(
        savedAt: DateTime(2026, 8, 18, 9, 30),
        savedBy: 'packing-hall-1',
        envelope: envelope,
      ),
    );

    await _pumpCard(tester, db);
    await tester.tap(find.text('Load from Database'));
    await settle(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'wrong-password');
    await tester.tap(find.text('Decrypt & import'));
    await settle(tester);

    await _expectGolden(tester, 'server_config_db_load_wrong_password.png');

    await db.dispose();
  });
}
