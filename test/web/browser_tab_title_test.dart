/// The browser tab is titled "CentroidX", whatever page is showing.
///
/// Read off the source, as the other guards in this directory are: the web
/// entry point imports `package:web` and cannot be loaded in a VM test.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('centroid-hmi/lib/main_web.dart').readAsStringSync();

  test('the router does not retitle the tab', () {
    expect(source, contains('setBrowserTabTitle: false'),
        reason: 'left on, Beamer sets the tab to the page title or, for a '
            'plant page, to the bare URL path — "/speedbatchers" in the tab '
            'where the product name should be');
  });

  test('the app and the page both name the product', () {
    expect(source, contains("title: 'CentroidX'"));
    final index = File('centroid-hmi/web/index.html').readAsStringSync();
    expect(index, contains('<title>CentroidX</title>'));
  });
}
