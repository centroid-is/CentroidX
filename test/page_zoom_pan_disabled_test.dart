/// `AssetPage.zoomPanDisabled` — the per-page switch beside mirroring that
/// locks the plant view at 1:1. The canvas side is covered in
/// `widgets/zoomable_canvas_zoom_pan_disabled_test.dart`; this is the model,
/// the page dialog, and the AI page context.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/chat/page_context_menu.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';

AssetPage _page({bool zoomPanDisabled = false}) => AssetPage(
      menuItem:
          const MenuItem(label: 'Line 1', path: '/line-1', icon: Icons.factory),
      assets: [],
      mirroringDisabled: false,
      zoomPanDisabled: zoomPanDisabled,
    );

void main() {
  group('json', () {
    test('page data written before the flag existed stays zoomable', () {
      final page = AssetPage.fromJson({
        'menu_item': {
          'label': 'Line 1',
          'path': '/line-1',
          'icon': 'home',
          'children': [],
        },
        'assets': [],
        'mirroring_disabled': false,
      });
      expect(page.zoomPanDisabled, isFalse);
    });

    test('round-trips under zoom_pan_disabled', () {
      // Through a real encode, the way PageManager stores it: toJson() alone
      // leaves menu_item as a MenuItem.
      final json = jsonDecode(jsonEncode(_page(zoomPanDisabled: true).toJson()))
          as Map<String, dynamic>;
      expect(json['zoom_pan_disabled'], isTrue);
      expect(AssetPage.fromJson(json).zoomPanDisabled, isTrue);
    });

    test('copyWith keeps it unless told otherwise', () {
      final page = _page(zoomPanDisabled: true);
      expect(page.copyWith(published: false).zoomPanDisabled, isTrue);
      expect(page.copyWith(zoomPanDisabled: false).zoomPanDisabled, isFalse);
    });
  });

  group('page dialog', () {
    Future<AssetPage?> editAndSave(
      WidgetTester tester,
      AssetPage initial, {
      bool toggle = false,
    }) async {
      AssetPage? saved;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => Dialog(
                  child: CreatePageWidget(
                    initialPage: initial,
                    onSave: (page) {
                      saved = page;
                      return true;
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final toggleSwitch = find.byKey(const ValueKey('page-zoom-pan-disabled'));
      expect(toggleSwitch, findsOneWidget);
      expect(tester.widget<Switch>(toggleSwitch).value, initial.zoomPanDisabled,
          reason: 'the switch starts from the page being edited');
      if (toggle) {
        await tester.tap(toggleSwitch);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('turning it on saves the page locked', (tester) async {
      final saved = await editAndSave(tester, _page(), toggle: true);
      expect(saved!.zoomPanDisabled, isTrue);
    });

    testWidgets('an untouched locked page stays locked', (tester) async {
      final saved = await editAndSave(tester, _page(zoomPanDisabled: true));
      expect(saved!.zoomPanDisabled, isTrue);
    });
  });

  test('the AI page context says whether zoom and pan are disabled', () {
    expect(buildPageContextBlock('/line-1', _page(zoomPanDisabled: true)),
        contains('Zoom and pan disabled: true'));
  });
}
