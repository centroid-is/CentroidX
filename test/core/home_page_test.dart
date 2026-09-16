/// Which path a home page resolves to, and the retirement of the per-station
/// `startup_url` preference it replaced.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/home_page.dart';
import 'package:tfc/models/menu_item.dart';

const _menu = [
  MenuItem(label: 'Home', path: '/', icon: Icons.home),
  MenuItem(label: 'Packing', path: '/pages/packing', icon: Icons.inventory),
  MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: 'Server Config',
          path: '/advanced/server-config',
          icon: Icons.dns),
    ],
  ),
];

class _CapturingOutput extends LogOutput {
  final lines = <String>[];

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

void main() {
  group('resolveHomePath', () {
    test('no page of its own is Home', () {
      expect(resolveHomePath(null, menuItems: _menu), homePageDefault);
      expect(resolveHomePath('', menuItems: _menu), homePageDefault);
    });

    test('a routable page is kept, nested ones included', () {
      expect(resolveHomePath('/pages/packing', menuItems: _menu),
          '/pages/packing');
      expect(resolveHomePath('/advanced/server-config', menuItems: _menu),
          '/advanced/server-config');
    });

    test('a page that routes nowhere falls back to Home', () {
      expect(resolveHomePath('/pages/deleted', menuItems: _menu),
          homePageDefault);
    });

    test('a section is not a page', () {
      expect(resolveHomePath('/advanced', menuItems: _menu), homePageDefault);
    });
  });

  group('dropRetiredStartupUrl', () {
    test('removes the key and names the page it held', () async {
      final local = InMemoryPreferences();
      await local.setString(kRetiredStartupUrlPrefKey, '/pages/packing');
      final output = _CapturingOutput();

      await dropRetiredStartupUrl(local,
          logger: Logger(output: output, printer: SimplePrinter()));

      expect(await local.containsKey(kRetiredStartupUrlPrefKey), isFalse);
      expect(output.lines.join('\n'), contains('/pages/packing'),
          reason: 'the station\'s old choice must be recoverable from the log');
    });

    test('nothing stored touches nothing and says nothing', () async {
      final local = InMemoryPreferences();
      final output = _CapturingOutput();

      await dropRetiredStartupUrl(local,
          logger: Logger(output: output, printer: SimplePrinter()));

      expect(output.lines, isEmpty);
    });
  });
}
