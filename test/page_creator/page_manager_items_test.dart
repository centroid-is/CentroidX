@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/preferences_api.dart';

/// `PageManager.loadFromItems`: rows handed in, not read from a store.
///
/// The no-mirror arm's entry point. It has to land where `_loadFromRows` lands
/// — pages from the rows, the baseline set, `PageSource.rows` — and read the
/// top-level order out of the preference row the rows carry, because a
/// browser has no mirror to ask and its shared store is the relay.
void main() {
  List<ConfigItem> rowsFor(Map<String, AssetPage> pages) => pageItems(pages);

  AssetPage page(String path, String label) => AssetPage(
        menuItem: MenuItem(label: label, path: path, icon: Icons.factory),
        assets: [],
        mirroringDisabled: false,
      );

  test('pages come from the rows, and the source says so', () async {
    final manager = PageManager(pages: {}, prefs: InMemoryPreferences());
    await manager.loadFromItems(rowsFor({
      '/': page('/', 'Home'),
      '/packing': page('/packing', 'Packing'),
    }));

    expect(manager.pages.keys, containsAll(['/', '/packing']));
    expect(manager.source, PageSource.rows);
    expect(manager.servingFallback, isFalse,
        reason: 'rows are the plant\'s pages, not a fallback — the reload '
            'trigger for a station on the blob must stay disarmed');
    expect(manager.baselineItems, isNotNull);
  });

  test('the top-level order is read from the preference row in the same set',
      () async {
    final manager = PageManager(pages: {}, prefs: InMemoryPreferences());
    await manager.loadFromItems([
      ...rowsFor({'/': page('/', 'Home'), '/b': page('/b', 'B')}),
      ConfigItem(
        kind: ConfigKind.preference,
        id: PageManager.orderStorageKey,
        payload: jsonEncode({'type': kPrefStringType, 'value': '["/b","/"]'}),
      ),
    ]);
    expect(manager.topLevelOrder, ['/b', '/']);
  });

  test('no page rows falls through to the ordinary load', () async {
    final manager = PageManager(pages: {}, prefs: InMemoryPreferences());
    await manager.loadFromItems(const []);
    expect(manager.pages, isNotEmpty,
        reason: 'the built-in default, exactly as a fresh station gets');
    expect(manager.source, PageSource.builtInDefault);
  });
}
