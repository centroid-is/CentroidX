import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/web_view.dart';

/// Stands in for WKWebView so no test ever opens a browser. Records what it
/// was asked to do, which is the whole contract the widget has with it.
class _FakeSurface implements WebViewSurface {
  final navigations = <Uri>[];
  bool disposed = false;

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-web'));

  @override
  Future<void> navigate(Uri uri) async => navigations.add(uri);

  @override
  Future<void> dispose() async => disposed = true;
}

WebViewAssetConfig _configured({
  String url = 'https://grafana.plant/d/abc/line-1',
  int reloadSeconds = 0,
  bool interactive = false,
}) =>
    WebViewAssetConfig(
      url: url,
      reloadSeconds: reloadSeconds,
      interactive: interactive,
    );

Widget _host(WebViewAssetConfig config, {bool editing = false, double w = 320, double h = 240}) {
  final view = WebViewAssetView(config: config);
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: w,
          height: h,
          child: editing ? AssetEditModeScope(child: view) : view,
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => WebViewAssetView.debugSurfaceFactory = null);

  group('JSON', () {
    test('fields survive a round trip', () {
      final config = WebViewAssetConfig(
        url: 'https://plant/dash',
        reloadSeconds: 300,
        interactive: true,
      )
        ..text = 'Line 1'
        ..coordinates = Coordinates(x: 0.25, y: 0.5);

      final restored = WebViewAssetConfig.fromJson(config.toJson());

      expect(restored.url, 'https://plant/dash');
      expect(restored.reloadSeconds, 300);
      expect(restored.interactive, isTrue);
      expect(restored.text, 'Line 1');
      expect(restored.coordinates.x, 0.25);
    });

    test('defaults are a blank, non-interactive, never-reloading tile', () {
      final config = WebViewAssetConfig();
      expect(config.url, isEmpty);
      expect(config.reloadSeconds, 0);
      expect(config.interactive, isFalse,
          reason: 'a wall station cannot undo a stray tap on a link');
      expect(config.isConfigured, isFalse);
    });

    test('the registry can build one by name — the MCP proposal path', () {
      final asset = AssetRegistry.createDefaultAssetByName('WebViewAssetConfig');
      expect(asset, isA<WebViewAssetConfig>());
    });
  });

  group('parseWebViewUrl', () {
    test('accepts http and https', () {
      expect(parseWebViewUrl('http://plant/x')?.host, 'plant');
      expect(parseWebViewUrl('https://plant:3000/x?a=b')?.host, 'plant');
    });

    test('trims surrounding whitespace', () {
      expect(parseWebViewUrl('  https://plant/x  ')?.host, 'plant');
    });

    test('rejects empty and whitespace', () {
      expect(parseWebViewUrl(''), isNull);
      expect(parseWebViewUrl('   '), isNull);
    });

    test('rejects a scheme that is not http(s)', () {
      // Not pedantry: a page config is not a secret store and not a sandbox.
      expect(parseWebViewUrl('file:///etc/passwd'), isNull);
      expect(parseWebViewUrl('javascript:alert(1)'), isNull);
      expect(parseWebViewUrl('ftp://plant/x'), isNull);
    });

    test('rejects a URL with no host', () {
      expect(parseWebViewUrl('https://'), isNull);
      expect(parseWebViewUrl('not a url'), isNull);
    });
  });

  group('WebViewAvailability', () {
    test('the three platforms webview_flutter implements', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        expect(WebViewAvailability.check(isWeb: false, platform: platform),
            isTrue,
            reason: '$platform has a webview_flutter implementation');
      }
    });

    test('the platforms we actually run on the plant floor do not', () {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(WebViewAvailability.check(isWeb: false, platform: platform),
            isFalse,
            reason: '$platform would need a bundled browser engine');
      }
    });

    test('web is excluded even though an iframe would be trivial', () {
      expect(
        WebViewAvailability.check(isWeb: true, platform: TargetPlatform.macOS),
        isFalse,
        reason: 'HtmlElementView is a different implementation, not wired up',
      );
    });
  });

  group('webViewReloadLabel', () {
    test('names each offered interval', () {
      expect(webViewReloadLabel(0), 'Never');
      expect(webViewReloadLabel(30), '30 seconds');
      expect(webViewReloadLabel(60), '1 minute');
      expect(webViewReloadLabel(300), '5 minutes');
      expect(webViewReloadLabel(900), '15 minutes');
    });

    test('every offered choice has a label and 0 means never', () {
      expect(kWebViewReloadChoices.first, 0);
      for (final seconds in kWebViewReloadChoices) {
        expect(webViewReloadLabel(seconds), isNotEmpty);
      }
    });
  });

  group('states', () {
    testWidgets('an unconfigured tile says so instead of erroring',
        (tester) async {
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return _FakeSurface();
      };
      await tester.pumpWidget(_host(WebViewAssetConfig()));
      await tester.pump();

      expect(find.text('No address'), findsOneWidget);
      expect(built, 0, reason: 'nothing to navigate to, so no browser');
    });

    testWidgets('a bad URL is treated as unconfigured, not as a page to open',
        (tester) async {
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return _FakeSurface();
      };
      await tester
          .pumpWidget(_host(_configured(url: 'javascript:alert(1)')));
      await tester.pump();

      expect(find.text('No address'), findsOneWidget);
      expect(built, 0);
    });

    testWidgets('a platform with no browser names the reason', (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => null;
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      expect(
        find.text('Web view is not available on this platform'),
        findsOneWidget,
      );
    });

    testWidgets('a supported platform navigates to the configured URL',
        (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
      expect(surface.navigations.single.toString(),
          'https://grafana.plant/d/abc/line-1');
    });
  });

  group('the editor canvas', () {
    testWidgets('shows a placeholder and starts no browser', (tester) async {
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return _FakeSurface();
      };
      await tester.pumpWidget(_host(_configured(), editing: true));
      await tester.pump();

      expect(find.byKey(const ValueKey('fake-web')), findsNothing);
      expect(find.text('grafana.plant'), findsOneWidget,
          reason: 'the host names which tile this is while laying out a page');
      // The point of the placeholder: a page of tiles must not be a page of
      // browsers, each reloading on every nudge of an asset. Constructing one
      // and declining to paint it would satisfy the two expectations above.
      expect(built, 0, reason: 'no browser is constructed on the canvas');
    });

    testWidgets('the placeholder names the host, not the whole URL',
        (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
      await tester.pumpWidget(_host(
        _configured(url: 'https://plant/grafana/d/abc/line-1?from=now-6h'),
        editing: true,
      ));
      await tester.pump();

      expect(find.text('plant'), findsOneWidget);
    });
  });

  group('interaction', () {
    testWidgets('a tile is a picture by default', (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      final ignore = tester.widgetList<IgnorePointer>(
        find.ancestor(
          of: find.byKey(const ValueKey('fake-web')),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignore.any((w) => w.ignoring), isTrue,
          reason: 'an operator must not be able to navigate a wall tile away');
    });

    testWidgets('turning interaction on lets pointers through',
        (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
      await tester.pumpWidget(_host(_configured(interactive: true)));
      await tester.pump();

      final ignore = tester.widgetList<IgnorePointer>(
        find.ancestor(
          of: find.byKey(const ValueKey('fake-web')),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignore.any((w) => w.ignoring), isFalse);
    });
  });

  group('reloading', () {
    testWidgets('re-navigates on the interval', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured(reloadSeconds: 30)));
      await tester.pump();
      expect(surface.navigations, hasLength(1));

      await tester.pump(const Duration(seconds: 30));
      expect(surface.navigations, hasLength(2));
      await tester.pump(const Duration(seconds: 30));
      expect(surface.navigations, hasLength(3));

      // Every reload goes back to the configured address rather than
      // reloading in place, so a tile that wandered comes home.
      expect(
        surface.navigations.every(
            (u) => u.toString() == 'https://grafana.plant/d/abc/line-1'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('never, when the interval is 0', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured(reloadSeconds: 0)));
      await tester.pump();

      await tester.pump(const Duration(minutes: 30));
      expect(surface.navigations, hasLength(1));
    });
  });

  group('lifecycle', () {
    testWidgets('editing the URL re-navigates', (tester) async {
      final first = _FakeSurface();
      final second = _FakeSurface();
      var calls = 0;
      WebViewAssetView.debugSurfaceFactory = (_) => calls++ == 0 ? first : second;

      final config = _configured();
      await tester.pumpWidget(_host(config));
      await tester.pump();
      expect(first.navigations, hasLength(1));

      config.url = 'https://other.plant/x';
      await tester.pumpWidget(_host(config));
      await tester.pump();

      expect(first.disposed, isTrue, reason: 'the old browser is torn down');
      expect(second.navigations.single.toString(), 'https://other.plant/x');
    });

    testWidgets('disposing tears the browser down', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(surface.disposed, isTrue);
    });

    testWidgets('being disposed mid-navigation throws nothing', (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => _SlowSurface();
      await tester.pumpWidget(_host(_configured()));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a navigation that fails does not take the tile down',
        (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => _FailingSurface();
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    testWidgets('an unbounded box lays out instead of throwing',
        (tester) async {
      // A layout exception on the canvas takes the whole page down, not just
      // this tile — so an asset dropped in a Row without an Expanded must
      // still lay out.
      WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [WebViewAssetView(config: _configured())],
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tile too small for a caption still shows its glyph',
        (tester) async {
      WebViewAssetView.debugSurfaceFactory = (_) => null;
      await tester.pumpWidget(_host(_configured(), w: 40, h: 40));
      await tester.pump();

      expect(find.byIcon(Icons.public_off), findsOneWidget);
      expect(find.text('Web view is not available on this platform'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Never completes its navigation — for the dispose-mid-flight case.
class _SlowSurface implements WebViewSurface {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  Future<void> navigate(Uri uri) => Completer<void>().future;
  @override
  Future<void> dispose() async {}
}

/// Fails every navigation, the way an unreachable host does.
class _FailingSurface implements WebViewSurface {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  Future<void> navigate(Uri uri) async => throw Exception('unreachable');
  @override
  Future<void> dispose() async {}
}
