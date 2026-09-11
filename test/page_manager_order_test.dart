/// The menu order is a **shared** preference row, and the pre-`runApp` page
/// manager — built over the device-local store, which never holds a shared
/// row — has to read it out of the mirror. Read from the device-local store
/// alone, the order the operator arranged came back in registration order on
/// every restart.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';

void main() {
  late AppDatabase local;
  late ConfigStore store;

  setUp(() async {
    local = AppDatabase.inMemoryForTest();
    store = ConfigStore(
      local: local,
      stationScope: ConfigScope.forStation('st1'),
      station: 'st1',
    );
  });

  tearDown(() async {
    await store.close();
    await local.close();
  });

  Future<void> seedSharedOrder(List<String> order) =>
      local.into(local.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: PageManager.orderStorageKey,
            scope: ConfigScope.shared.wireName,
            payload: ConfigItem.of(
              kind: ConfigKind.preference,
              id: PageManager.orderStorageKey,
              value: preferencePayload(kPrefStringType, jsonEncode(order)),
            ).payload,
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 9, 1),
            updatedBy: 'jon',
          ));

  test('the order comes from the shared row in the mirror', () async {
    await seedSharedOrder(['/alarms', '/']);
    await store.open();
    final manager =
        PageManager(pages: {}, prefs: InMemoryPreferences(), store: store);

    await manager.load();

    expect(manager.topLevelOrder, ['/alarms', '/']);
  });

  test('the shared row wins over a stale device-local copy', () async {
    await seedSharedOrder(['/alarms', '/']);
    await store.open();
    final prefs = InMemoryPreferences();
    await prefs.setString(
        PageManager.orderStorageKey, jsonEncode(['/', '/alarms']));
    final manager = PageManager(pages: {}, prefs: prefs, store: store);

    await manager.load();

    expect(manager.topLevelOrder, ['/alarms', '/']);
  });

  test('without a shared row the device-local copy still serves', () async {
    await store.open();
    final prefs = InMemoryPreferences();
    await prefs.setString(
        PageManager.orderStorageKey, jsonEncode(['/', '/alarms']));
    final manager = PageManager(pages: {}, prefs: prefs, store: store);

    await manager.load();

    expect(manager.topLevelOrder, ['/', '/alarms']);
  });
}
