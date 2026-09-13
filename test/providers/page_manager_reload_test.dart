// The rollout-day window, and the trigger that closes it.
//
// Page rows cannot pre-exist the migration that mints them, so on cutover day
// every station loads before its mirror holds any: it comes up on the
// `page_editor_data` blob, read-only, holding pages with no row identity.
// Without the listener under test the manager holds those id-less pages for
// the whole session, and the first Save mints fresh random ids for all of them
// and rewrites ~410 rows — severing every identity the migration just minted,
// and committing cleanly while it does. Nothing downstream detects that.
//
// This is the read-side half. The other half — a save adopting the identities
// the rows carry — is 03-06's.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings, OpcUANodeConfig;

import '../helpers/test_helpers.dart';

AssetPage _page(String label, String path) => AssetPage(
      menuItem: MenuItem(label: label, path: path, icon: Icons.pageview),
      assets: [],
      mirroringDisabled: false,
    );

/// A container whose page manager is built over [store], with [blob] already
/// in device-local preferences.
Future<({ProviderContainer container, int Function() notifications})> _wiring({
  required GuardedConfigStore store,
  Map<String, AssetPage>? blob,
}) async {
  final prefs = await createTestPreferences();
  if (blob != null) {
    await prefs.setString(
      PageManager.storageKey,
      jsonEncode(blob.map((path, page) => MapEntry(path, page.toJson()))),
    );
  }

  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async => prefs),
    configStoreProvider.overrideWith((ref) async => store),
  ]);
  addTearDown(container.dispose);

  var notifications = 0;
  container.listen(pageManagerProvider, (_, __) => notifications++);
  return (container: container, notifications: () => notifications);
}

Future<void> _writePages(
    GuardedConfigStore store, Map<String, AssetPage> pages) async {
  await store.inner.writeItems(
    kinds: const {ConfigKind.page, ConfigKind.asset},
    wanted: pageItems(pages),
    actionId: 'reconcile',
    who: 'migration',
    roleName: 'system',
  );
}

void main() {
  group('rows arriving over a blob fallback', () {
    test('the provider-held manager re-loads from rows and notifies', () async {
      final store = await createTestConfigStore();
      final w = await _wiring(store: store, blob: {'/': _page('Home', '/')});

      final manager = await w.container.read(pageManagerProvider.future);
      // The window is open: a full layout in memory, none of it row-backed.
      expect(manager.source, PageSource.blob);
      expect(manager.servingFallback, isTrue);
      expect(manager.pages.containsKey('/'), isTrue);
      final before = w.notifications();

      // What the migration's reconcile delivers, seconds later.
      await _writePages(store, {
        '/': _page('Home', '/'),
        '/plant': _page('Plant', '/plant'),
      });
      await pumpEventQueue();

      // The same instance — the editor and every widget holding it keep the
      // object they have.
      expect(identical(await w.container.read(pageManagerProvider.future),
          manager), isTrue);
      expect(manager.source, PageSource.rows);
      expect(manager.servingFallback, isFalse);
      expect(manager.pages.containsKey('/plant'), isTrue);
      expect(w.notifications(), greaterThan(before),
          reason: 'a re-load nobody is told about redraws nothing');
    });

    test('a diff carrying no page or asset rows is not this trigger\'s '
        'business', () async {
      final store = await createTestConfigStore();
      final w = await _wiring(store: store, blob: {'/': _page('Home', '/')});

      final manager = await w.container.read(pageManagerProvider.future);
      expect(manager.source, PageSource.blob);
      final before = w.notifications();

      await store.inner.writeKeyMappings(
        KeyMappings(nodes: {
          'alpha': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'N'),
          ),
        }),
        actionId: 'unrelated',
        who: 'test',
        roleName: 'system',
      );
      await pumpEventQueue();

      expect(manager.source, PageSource.blob);
      expect(w.notifications(), before,
          reason: 'a key-mapping save must not redraw the plant');
    });

    test('a manager already on rows is left alone', () async {
      final store = await createTestConfigStore();
      await _writePages(store, {'/': _page('Home', '/')});
      final w = await _wiring(store: store);

      final manager = await w.container.read(pageManagerProvider.future);
      expect(manager.source, PageSource.rows);
      final before = w.notifications();

      // Re-loading a live layout out from under an operator on every incoming
      // diff is a different feature with a different blast radius (Phase 4).
      await _writePages(store, {
        '/': _page('Home', '/'),
        '/roe': _page('Roe', '/roe'),
      });
      await pumpEventQueue();

      expect(manager.pages.containsKey('/roe'), isFalse);
      expect(w.notifications(), before);
    });

    test('a virgin station picks the rows up too', () async {
      // No blob either — the built-in default is a fallback exactly as the
      // blob is, and a station that boots on it before the migration reaches
      // it must not be left there for the session.
      final store = await createTestConfigStore();
      final w = await _wiring(store: store);

      final manager = await w.container.read(pageManagerProvider.future);
      expect(manager.source, PageSource.builtInDefault);
      expect(manager.servingFallback, isTrue);

      await _writePages(store, {'/plant': _page('Plant', '/plant')});
      await pumpEventQueue();

      expect(manager.source, PageSource.rows);
      expect(manager.pages.containsKey('/plant'), isTrue);
    });
  });
}
