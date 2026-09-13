import 'dart:async';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/feature_flags.dart';
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

/// A surface whose engine can be missing, i.e. the WebView2 shape.
///
/// Separate from [_FakeSurface] on purpose: the plain fake must keep *not*
/// implementing [WebViewSurfaceAvailability], so the tests can prove the view
/// asks only the surfaces that opt in.
class _FakeAbsentableSurface
    implements WebViewSurface, WebViewSurfaceAvailability {
  _FakeAbsentableSurface({this.available = true, this.error});

  final bool available;

  /// When set, the probe fails with this instead of answering, the way CEF
  /// reports a browser that never came up.
  final Object? error;
  final navigations = <Uri>[];
  bool disposed = false;
  int availabilityAsks = 0;

  /// Held open so a test can answer the probe at a moment of its choosing.
  final gate = Completer<bool>();
  bool useGate = false;

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-web'));

  @override
  Future<void> navigate(Uri uri) async => navigations.add(uri);

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Future<bool> get isAvailable {
    availabilityAsks++;
    if (error != null) return Future<bool>.error(error!);
    return useGate ? gate.future : Future<bool>.value(available);
  }
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
  tearDown(() async {
    WebViewAssetView.debugSurfaceFactory = null;
    // The pool is process-wide: a browser parked by one test would be taken
    // over by the next test on the same address.
    await WebViewSurfacePool.instance.clear();
    WebViewSurfacePool.instance = WebViewSurfacePool();
  });

  group('JSON', () {
    // Runs in both build modes on purpose. WebViewAssetConfig.fromJson is
    // deliberately NOT behind kWebViewEnabled — a flag-off build has to round-
    // trip a saved page carrying this asset rather than silently dropping it,
    // the same contract kKnowledgeEnabled keeps for DrawingViewerConfig.
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

    test('theme parameter fields survive a round trip', () {
      final config = WebViewAssetConfig(
        url: 'https://grafana.plant/public-dashboards/tok',
        themeParam: 'theme',
        themeDarkValue: 'midnight',
        themeLightValue: 'day',
      );

      final json = config.toJson();
      expect(json['themeParam'], 'theme');
      expect(json['themeDarkValue'], 'midnight');
      expect(json['themeLightValue'], 'day');

      final restored = WebViewAssetConfig.fromJson(json);
      expect(restored.themeParam, 'theme');
      expect(restored.themeDarkValue, 'midnight');
      expect(restored.themeLightValue, 'day');
    });

    test('a tile that never used the theme parameter saves no new keys', () {
      // Existing pages must save byte-for-byte what they saved before: the
      // fields are omitted while null rather than written as null.
      final json = WebViewAssetConfig(url: 'https://plant/dash').toJson();
      expect(json.containsKey('themeParam'), isFalse);
      expect(json.containsKey('themeDarkValue'), isFalse);
      expect(json.containsKey('themeLightValue'), isFalse);
    });

    test('JSON saved before the theme parameter existed still loads', () {
      final restored = WebViewAssetConfig.fromJson({
        'asset_name': 'WebViewAssetConfig',
        'coordinates': {'x': 0.1, 'y': 0.2},
        'size': {'width': 0.25, 'height': 0.2},
        'url': 'https://plant/dash?from=now-6h',
        'reloadSeconds': 60,
        'interactive': false,
      });

      expect(restored.themeParam, isNull);
      expect(restored.themeDarkValue, isNull);
      expect(restored.themeLightValue, isNull);
      expect(restored.effectiveUrl(Brightness.dark).toString(),
          'https://plant/dash?from=now-6h',
          reason: 'feature off: the configured URL is loaded as written');
      expect(restored.toJson().containsKey('themeParam'), isFalse);
    });

    test('defaults are a blank, non-interactive, never-reloading tile', () {
      final config = WebViewAssetConfig();
      expect(config.url, isEmpty);
      expect(config.reloadSeconds, 0);
      expect(config.interactive, isFalse,
          reason: 'a wall station cannot undo a stray tap on a link');
      expect(config.isConfigured, isFalse);
    });

    test('the palette entry follows the compile flag', () {
      // kWebViewEnabled is a compile-time const, so this asserts whichever
      // build mode the suite is running in rather than flipping it: present
      // in the palette (and to the MCP proposal path) when the asset is
      // compiled in, absent when it is not.
      final asset = AssetRegistry.createDefaultAssetByName('WebViewAssetConfig');
      if (kWebViewEnabled) {
        expect(asset, isA<WebViewAssetConfig>());
      } else {
        expect(asset, isNull);
      }
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

  group('withQueryParameter', () {
    test('appends to a URL with no query', () {
      expect(
        withQueryParameter(Uri.parse('https://g.plant/d/x'), 'theme', 'dark')
            .toString(),
        'https://g.plant/d/x?theme=dark',
      );
    });

    test('replaces an existing parameter where it stands', () {
      expect(
        withQueryParameter(
                Uri.parse('https://g.plant/d/x?orgId=1&theme=light&from=now-6h'),
                'theme',
                'dark')
            .toString(),
        'https://g.plant/d/x?orgId=1&theme=dark&from=now-6h',
      );
    });

    test('collapses a repeated parameter to the one value', () {
      expect(
        withQueryParameter(
                Uri.parse('https://g.plant/?theme=a&x=1&theme=b'), 'theme', 'dark')
            .toString(),
        'https://g.plant/?theme=dark&x=1',
      );
    });

    test('keeps every other parameter verbatim, repeats and encoding included',
        () {
      // Grafana template variables repeat (var-host=a&var-host=b), and a
      // round trip through queryParameters would merge them and re-encode
      // %20 as +.
      expect(
        withQueryParameter(
                Uri.parse(
                    'https://g.plant/d/x?var-host=a&var-host=b&q=a%20b&flag'),
                'theme',
                'light')
            .toString(),
        'https://g.plant/d/x?var-host=a&var-host=b&q=a%20b&flag&theme=light',
      );
    });

    test('keeps the fragment', () {
      expect(
        withQueryParameter(
                Uri.parse('https://g.plant/d/x?orgId=1#viewPanel=4'), 'theme', 'dark')
            .toString(),
        'https://g.plant/d/x?orgId=1&theme=dark#viewPanel=4',
      );
      expect(
        withQueryParameter(Uri.parse('https://g.plant/d/x#top'), 'theme', 'dark')
            .toString(),
        'https://g.plant/d/x?theme=dark#top',
      );
    });

    test('matches an encoded parameter name', () {
      expect(
        withQueryParameter(
                Uri.parse('https://g.plant/?ui%20theme=x&a=1'), 'ui theme', 'dark')
            .toString(),
        'https://g.plant/?ui+theme=dark&a=1',
      );
    });

    test('encodes a value that needs it', () {
      expect(
        withQueryParameter(Uri.parse('https://g.plant/'), 'theme', 'a&b')
            .queryParameters['theme'],
        'a&b',
      );
    });
  });

  group('effectiveWebViewUrl', () {
    const grafana = 'https://grafana.plant/public-dashboards/tok?orgId=1';

    test('off when the parameter name is null, empty or blank', () {
      for (final name in [null, '', '   ']) {
        for (final b in Brightness.values) {
          expect(
            effectiveWebViewUrl(grafana, brightness: b, themeParam: name)
                .toString(),
            grafana,
            reason: 'themeParam ${name == null ? 'null' : '"$name"'} is off',
          );
        }
      }
    });

    test('sends dark and light by default', () {
      expect(
        effectiveWebViewUrl(grafana,
                brightness: Brightness.dark, themeParam: 'theme')
            .toString(),
        '$grafana&theme=dark',
      );
      expect(
        effectiveWebViewUrl(grafana,
                brightness: Brightness.light, themeParam: 'theme')
            .toString(),
        '$grafana&theme=light',
      );
    });

    test('sends the configured values when set', () {
      Uri? at(Brightness b) => effectiveWebViewUrl(grafana,
          brightness: b,
          themeParam: 'mode',
          darkValue: 'night',
          lightValue: 'day');
      expect(at(Brightness.dark)!.queryParameters['mode'], 'night');
      expect(at(Brightness.light)!.queryParameters['mode'], 'day');
    });

    test('a blank value falls back to the default', () {
      expect(
        effectiveWebViewUrl(grafana,
                brightness: Brightness.dark,
                themeParam: 'theme',
                darkValue: '  ')!
            .queryParameters['theme'],
        'dark',
      );
    });

    test('replaces a theme already typed into the address', () {
      expect(
        effectiveWebViewUrl(
          'https://grafana.plant/public-dashboards/tok?theme=light&orgId=1',
          brightness: Brightness.dark,
          themeParam: 'theme',
        ).toString(),
        'https://grafana.plant/public-dashboards/tok?theme=dark&orgId=1',
      );
    });

    test('trims the parameter name', () {
      expect(
        effectiveWebViewUrl(grafana,
                brightness: Brightness.dark, themeParam: ' theme ')
            .toString(),
        '$grafana&theme=dark',
      );
    });

    test('an address that is not browsable stays null', () {
      expect(
        effectiveWebViewUrl('javascript:alert(1)',
            brightness: Brightness.dark, themeParam: 'theme'),
        isNull,
      );
      expect(
        effectiveWebViewUrl('',
            brightness: Brightness.dark, themeParam: 'theme'),
        isNull,
      );
    });
  });

  group('WebViewAvailability', () {
    test('the platforms with an OS-provided browser', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(WebViewAvailability.check(isWeb: false, platform: platform),
            isTrue,
            reason: '$platform has a webview implementation');
      }
    });

    test('a platform with no port at all does not', () {
      expect(
          WebViewAvailability.check(
              isWeb: false, platform: TargetPlatform.fuchsia),
          isFalse);
    });

    test('windows is the WebView2 platform, and nothing else is', () {
      // Two different questions: `check` asks whether a webview exists at
      // all, `usesWebView2` picks the engine and, with it, whether the engine
      // can be missing from the machine.
      expect(
          WebViewAvailability.usesWebView2(
              isWeb: false, platform: TargetPlatform.windows),
          isTrue);
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(
            WebViewAvailability.usesWebView2(isWeb: false, platform: platform),
            isFalse,
            reason: '$platform is not served by WebView2');
      }
      expect(
          WebViewAvailability.usesWebView2(
              isWeb: true, platform: TargetPlatform.windows),
          isFalse,
          reason: 'a browser tab is not WebView2');
    });

    test('linux is the CEF platform, and nothing else is', () {
      // Covers the eLinux stations too: flutter-elinux reports
      // TargetPlatform.linux, indistinguishable from the desktop build here,
      // and deliberately so — packages/webview_cef carries a port for each and
      // the plugin registrant picks at build time.
      expect(
          WebViewAvailability.usesCef(
              isWeb: false, platform: TargetPlatform.linux),
          isTrue);
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(WebViewAvailability.usesCef(isWeb: false, platform: platform),
            isFalse,
            reason: '$platform has a browser it does not have to ship');
      }
      expect(
          WebViewAvailability.usesCef(
              isWeb: true, platform: TargetPlatform.linux),
          isFalse,
          reason: 'a browser tab is not CEF');
    });

    test('the three engines never claim the same platform', () {
      // The factory checks WebView2 then CEF then falls through to
      // webview_flutter, so an overlap would silently give one platform the
      // wrong engine rather than fail.
      for (final platform in TargetPlatform.values) {
        final two = WebViewAvailability.usesWebView2(
            isWeb: false, platform: platform);
        final cef =
            WebViewAvailability.usesCef(isWeb: false, platform: platform);
        expect(two && cef, isFalse,
            reason: '$platform is claimed by both WebView2 and CEF');
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

  group('following the HMI theme', () {
    const base = 'https://grafana.plant/public-dashboards/tok?orgId=1';

    Widget themed(WebViewAssetConfig config, Brightness brightness,
            {Color? seed}) =>
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: seed,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 240,
              child: WebViewAssetView(config: config),
            ),
          ),
        );

    testWidgets('the loaded URL flips with the theme brightness',
        (tester) async {
      final surface = _FakeSurface();
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return surface;
      };
      final config = WebViewAssetConfig(url: base, themeParam: 'theme');

      await tester.pumpWidget(themed(config, Brightness.light));
      await tester.pump();
      expect(surface.navigations.map((u) => u.toString()),
          ['$base&theme=light']);

      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pumpAndSettle();
      expect(surface.navigations.map((u) => u.toString()),
          ['$base&theme=light', '$base&theme=dark']);

      await tester.pumpWidget(themed(config, Brightness.light));
      await tester.pumpAndSettle();
      expect(surface.navigations.last.toString(), '$base&theme=light');
      expect(surface.navigations, hasLength(3));

      expect(built, 1,
          reason: 'a theme flip re-navigates the browser, it does not '
              'build a new one');
      expect(surface.disposed, isFalse);
    });

    testWidgets('an unrelated rebuild does not reload', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      final config = WebViewAssetConfig(url: base, themeParam: 'theme');

      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pump();
      expect(surface.navigations, hasLength(1));

      // Same brightness, different theme: didChangeDependencies fires, the
      // effective URL does not move.
      await tester.pumpWidget(
          themed(config, Brightness.dark, seed: const Color(0xFF00897B)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pumpAndSettle();

      expect(surface.navigations, hasLength(1));
    });

    testWidgets('a tile without a theme parameter ignores theme flips',
        (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      final config = WebViewAssetConfig(url: base);

      await tester.pumpWidget(themed(config, Brightness.light));
      await tester.pump();
      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pumpAndSettle();

      expect(surface.navigations.map((u) => u.toString()), [base]);
    });

    testWidgets('a reload tick keeps the current theme', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      final config = WebViewAssetConfig(
          url: base, themeParam: 'theme', reloadSeconds: 30);

      await tester.pumpWidget(themed(config, Brightness.light));
      await tester.pump();
      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));

      expect(surface.navigations.last.toString(), '$base&theme=dark');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('setting the parameter in the editor re-navigates',
        (tester) async {
      final first = _FakeSurface();
      final second = _FakeSurface();
      var calls = 0;
      WebViewAssetView.debugSurfaceFactory =
          (_) => calls++ == 0 ? first : second;
      final config = WebViewAssetConfig(url: base);

      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pump();
      config.themeParam = 'theme';
      await tester.pumpWidget(themed(config, Brightness.dark));
      await tester.pump();

      expect(second.navigations.single.toString(), '$base&theme=dark');
    });
  });

  group('config editor theme fields', () {
    Future<void> pumpEditor(WidgetTester tester, WebViewAssetConfig config) async {
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));
    }

    testWidgets('value fields appear once a parameter name is typed',
        (tester) async {
      if (!kWebViewEnabled) return;
      final config = WebViewAssetConfig(url: 'https://grafana.plant/d/x');
      await pumpEditor(tester, config);

      expect(find.text('Theme URL parameter'), findsOneWidget);
      expect(find.text('Dark value'), findsNothing);

      await tester.enterText(
          find.byKey(const ValueKey('web-view-theme-param')), 'theme');
      await tester.pump();
      expect(config.themeParam, 'theme');
      expect(find.text('Dark value'), findsOneWidget);
      expect(find.text('Light value'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('web-view-theme-dark')), ' night ');
      await tester.pump();
      expect(config.themeDarkValue, 'night');

      await tester.enterText(
          find.byKey(const ValueKey('web-view-theme-param')), '  ');
      await tester.pump();
      expect(config.themeParam, isNull,
          reason: 'clearing the name turns the feature back off');
      expect(find.text('Dark value'), findsNothing);
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

      expect(first.disposed, isFalse,
          reason: 'the old browser is parked for its address, not torn down');
      expect(WebViewSurfacePool.instance.urls,
          ['https://grafana.plant/d/abc/line-1']);
      expect(second.navigations.single.toString(), 'https://other.plant/x');
    });

    testWidgets('disposing parks the browser on its address', (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(surface.disposed, isFalse);
      expect(WebViewSurfacePool.instance.urls,
          ['https://grafana.plant/d/abc/line-1']);
    });

    testWidgets('disposing tears the browser down when nothing is kept warm',
        (tester) async {
      WebViewSurfacePool.instance = WebViewSurfacePool(capacity: 0);
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;
      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(surface.disposed, isTrue);
      expect(WebViewSurfacePool.instance.size, 0);
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

  group('warm browsers', () {
    // Leaving a page tears its tiles down. Before the pool, coming back paid
    // for a new engine and a full page load every time -- three seconds of
    // cover on the plant for a dashboard the operator had just been looking
    // at. Now the browser is parked and the returning tile takes it over.

    testWidgets('a tile that comes back takes its browser over, unnavigated',
        (tester) async {
      final surface = _FakeSurface();
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return surface;
      };

      await tester.pumpWidget(_host(_configured()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(WebViewSurfacePool.instance.size, 1);

      await tester.pumpWidget(_host(_configured()));
      await tester.pump();

      expect(built, 1, reason: 'no second browser was started');
      expect(surface.navigations, hasLength(1),
          reason: 'the page is already there; navigating would reload it');
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
      expect(WebViewSurfacePool.instance.size, 0,
          reason: 'a browser on screen is not also parked');
      expect(surface.disposed, isFalse);
    });

    testWidgets('a different address starts its own browser', (tester) async {
      final surfaces = <_FakeSurface>[];
      WebViewAssetView.debugSurfaceFactory = (_) {
        final s = _FakeSurface();
        surfaces.add(s);
        return s;
      };

      await tester.pumpWidget(_host(_configured()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());

      await tester.pumpWidget(_host(_configured(url: 'https://other.plant/x')));
      await tester.pump();

      expect(surfaces, hasLength(2));
      expect(surfaces.last.navigations.single.toString(),
          'https://other.plant/x');
      expect(WebViewSurfacePool.instance.urls,
          ['https://grafana.plant/d/abc/line-1'],
          reason: 'the first browser waits for its own address');
    });

    testWidgets('the theme parameter is part of the address', (tester) async {
      // A parked dark dashboard is no use to a tile that wants the light one.
      final surfaces = <_FakeSurface>[];
      WebViewAssetView.debugSurfaceFactory = (_) {
        final s = _FakeSurface();
        surfaces.add(s);
        return s;
      };
      WebViewAssetConfig themed() => WebViewAssetConfig(
          url: 'https://grafana.plant/d/abc/line-1', themeParam: 'theme');
      Widget host(ThemeData theme) => MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SizedBox(
                  width: 320, height: 240, child: WebViewAssetView(config: themed())),
            ),
          );

      await tester.pumpWidget(host(ThemeData.dark()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(WebViewSurfacePool.instance.urls,
          ['https://grafana.plant/d/abc/line-1?theme=dark']);

      await tester.pumpWidget(host(ThemeData.light()));
      await tester.pump();
      expect(surfaces, hasLength(2));
      expect(surfaces.last.navigations.single.toString(),
          'https://grafana.plant/d/abc/line-1?theme=light');
    });

    testWidgets('a taken-back browser is not asked about its engine again',
        (tester) async {
      final surface = _FakeAbsentableSurface(available: true);
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();
      expect(surface.availabilityAsks, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(surface.availabilityAsks, 1,
          reason: 'it proved its engine present the first time');
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
    });

    testWidgets('a taken-back browser gets its reload interval back',
        (tester) async {
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured(reloadSeconds: 30)));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      // Parked: the tick belongs to the tile, and the tile is gone.
      await tester.pump(const Duration(seconds: 31));
      expect(surface.navigations, hasLength(1));

      await tester.pumpWidget(_host(_configured(reloadSeconds: 30)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(surface.navigations, hasLength(2));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the page editor parks the browser and gets it back',
        (tester) async {
      final surface = _FakeSurface();
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return surface;
      };
      final config = _configured();

      await tester.pumpWidget(_host(config));
      await tester.pump();
      await tester.pumpWidget(_host(config, editing: true));
      await tester.pump();
      expect(WebViewSurfacePool.instance.size, 1);
      expect(find.byKey(const ValueKey('fake-web')), findsNothing);

      await tester.pumpWidget(_host(config));
      await tester.pump();
      expect(built, 1);
      expect(surface.navigations, hasLength(1));
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
    });

    testWidgets('a browser whose engine turned out missing is not parked',
        (tester) async {
      final surface = _FakeAbsentableSurface(available: false);
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();
      expect(surface.disposed, isTrue);
      expect(WebViewSurfacePool.instance.size, 0);
    });

    group('WebViewSurfacePool', () {
      test('take hands back the newest browser on the address, once', () {
        final pool = WebViewSurfacePool(capacity: 3);
        final a = _FakeSurface();
        final b = _FakeSurface();
        pool.park('https://x/1', a);
        pool.park('https://x/1', b);

        expect(pool.take('https://x/2'), isNull);
        expect(pool.take('https://x/1'), same(b));
        expect(pool.take('https://x/1'), same(a));
        expect(pool.take('https://x/1'), isNull);
        expect(a.disposed, isFalse);
        expect(b.disposed, isFalse);
      });

      test('over capacity, the browser parked longest ago is disposed',
          () async {
        final pool = WebViewSurfacePool(capacity: 2);
        final a = _FakeSurface();
        final b = _FakeSurface();
        final c = _FakeSurface();
        pool.park('https://x/1', a);
        pool.park('https://x/2', b);
        pool.park('https://x/3', c);
        await Future<void>.delayed(Duration.zero);

        expect(a.disposed, isTrue);
        expect(b.disposed, isFalse);
        expect(c.disposed, isFalse);
        expect(pool.urls, ['https://x/2', 'https://x/3']);
      });

      test('capacity zero disposes on the spot', () async {
        final pool = WebViewSurfacePool(capacity: 0);
        final a = _FakeSurface();
        pool.park('https://x/1', a);
        await Future<void>.delayed(Duration.zero);

        expect(a.disposed, isTrue);
        expect(pool.size, 0);
      });

      test('clear disposes every parked browser', () async {
        final pool = WebViewSurfacePool(capacity: 3);
        final a = _FakeSurface();
        final b = _FakeSurface();
        pool.park('https://x/1', a);
        pool.park('https://x/2', b);
        await pool.clear();

        expect(a.disposed, isTrue);
        expect(b.disposed, isTrue);
        expect(pool.size, 0);
      });

      test('a browser that fails to dispose does not break the pool',
          () async {
        final pool = WebViewSurfacePool(capacity: 1);
        pool.park('https://x/1', _UndisposableSurface());
        pool.park('https://x/2', _UndisposableSurface());
        await Future<void>.delayed(Duration.zero);
        await pool.clear();
        expect(pool.size, 0);
      });

      test('the default lot holds a few browsers, not one and not many', () {
        expect(kWebViewWarmBrowsers, inInclusiveRange(2, 4));
        expect(WebViewSurfacePool().capacity, kWebViewWarmBrowsers);
      });
    });

    group('prewarm', () {
      // The cold open is the engine starting plus the dashboard's own scripts
      // running -- 3.8 s on a station -- and cannot be hurried. Starting the
      // browser before anyone asks is what makes the first visit a take-back.
      setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('starts a browser per address, navigated and parked', () async {
        final surfaces = <_FakeSurface>[];
        WebViewAssetView.debugSurfaceFactory = (_) {
          final s = _FakeSurface();
          surfaces.add(s);
          return s;
        };
        final pool = WebViewSurfacePool(capacity: 3);

        final started = pool.prewarm([
          _configured(url: 'https://grafana.plant/d/abc/line-1'),
          _configured(url: 'https://grafana.plant/d/abc/line-2'),
        ], brightness: Brightness.light);
        await Future<void>.delayed(Duration.zero);

        expect(started, 2);
        expect(surfaces, hasLength(2));
        expect(surfaces[0].navigations.single.toString(),
            'https://grafana.plant/d/abc/line-1');
        expect(surfaces[1].navigations.single.toString(),
            'https://grafana.plant/d/abc/line-2');
        expect(pool.urls, [
          'https://grafana.plant/d/abc/line-1',
          'https://grafana.plant/d/abc/line-2',
        ]);
      });

      testWidgets('a tile then takes the warm browser over', (tester) async {
        final surface = _FakeSurface();
        var built = 0;
        WebViewAssetView.debugSurfaceFactory = (_) {
          built++;
          return surface;
        };
        WebViewSurfacePool.instance
            .prewarm([_configured()], brightness: Brightness.light);
        expect(built, 1);

        await tester.pumpWidget(_host(_configured()));
        await tester.pump();

        expect(built, 1, reason: 'the first visit started no browser');
        expect(surface.navigations, hasLength(1),
            reason: 'the page the prewarm loaded is the page shown');
        expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
        // The widget binding checks foundation debug variables before the
        // group's tearDown runs, so a widget test resets this itself.
        debugDefaultTargetPlatformOverride = null;
      });

      test('warms the address for the brightness the tile will use', () {
        final surfaces = <_FakeSurface>[];
        WebViewAssetView.debugSurfaceFactory = (_) {
          final s = _FakeSurface();
          surfaces.add(s);
          return s;
        };
        final pool = WebViewSurfacePool(capacity: 3);
        pool.prewarm([
          WebViewAssetConfig(
              url: 'https://grafana.plant/d/abc/line-1', themeParam: 'theme'),
        ], brightness: Brightness.dark);
        expect(pool.urls, ['https://grafana.plant/d/abc/line-1?theme=dark']);
      });

      test('skips an address that is parked, on screen, or repeated', () {
        var built = 0;
        WebViewAssetView.debugSurfaceFactory = (_) {
          built++;
          return _FakeSurface();
        };
        final pool = WebViewSurfacePool(capacity: 3);
        pool.park('https://grafana.plant/d/abc/line-1', _FakeSurface());
        pool.claim('https://grafana.plant/d/abc/line-2');

        final started = pool.prewarm([
          _configured(url: 'https://grafana.plant/d/abc/line-1'),
          _configured(url: 'https://grafana.plant/d/abc/line-2'),
          _configured(url: 'https://grafana.plant/d/abc/line-3'),
          _configured(url: 'https://grafana.plant/d/abc/line-3'),
        ], brightness: Brightness.light);

        expect(started, 1);
        expect(built, 1);
        expect(pool.size, 2);
      });

      test('stops at capacity instead of evicting', () {
        WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
        final pool = WebViewSurfacePool(capacity: 2);
        final kept = _FakeSurface();
        pool.park('https://grafana.plant/d/abc/kept', kept);

        final started = pool.prewarm([
          _configured(url: 'https://grafana.plant/d/abc/line-1'),
          _configured(url: 'https://grafana.plant/d/abc/line-2'),
        ], brightness: Brightness.light);

        expect(started, 1);
        expect(kept.disposed, isFalse);
        expect(pool.urls, [
          'https://grafana.plant/d/abc/kept',
          'https://grafana.plant/d/abc/line-1',
        ]);
      });

      test('an unbrowsable address and an unconfigured tile start nothing',
          () {
        var built = 0;
        WebViewAssetView.debugSurfaceFactory = (_) {
          built++;
          return _FakeSurface();
        };
        final pool = WebViewSurfacePool(capacity: 3);
        final started = pool.prewarm([
          WebViewAssetConfig(),
          _configured(url: 'javascript:alert(1)'),
        ], brightness: Brightness.light);
        expect(started, 0);
        expect(built, 0);
      });

      test('a platform with no browser starts nothing', () {
        WebViewAssetView.debugSurfaceFactory = (_) => null;
        final pool = WebViewSurfacePool(capacity: 3);
        expect(pool.prewarm([_configured()], brightness: Brightness.light), 0);
        expect(pool.size, 0);
      });

      test('WebView2 is left cold: its view needs a widget to exist', () {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        var built = 0;
        WebViewAssetView.debugSurfaceFactory = (_) {
          built++;
          return _FakeSurface();
        };
        final pool = WebViewSurfacePool(capacity: 3);
        expect(pool.prewarm([_configured()], brightness: Brightness.light), 0);
        expect(built, 0);
      });

      test('a browser whose engine is missing is forgotten again', () async {
        final surface = _FakeAbsentableSurface(available: false);
        WebViewAssetView.debugSurfaceFactory = (_) => surface;
        final pool = WebViewSurfacePool(capacity: 3);

        pool.prewarm([_configured()], brightness: Brightness.light);
        expect(pool.size, 1);
        await Future<void>.delayed(Duration.zero);

        expect(pool.size, 0);
        expect(surface.disposed, isTrue);
      });

      test('a browser whose engine did not start is forgotten again',
          () async {
        final surface = _FakeAbsentableSurface(
            error: const WebViewUnavailable('did not start'));
        WebViewAssetView.debugSurfaceFactory = (_) => surface;
        final pool = WebViewSurfacePool(capacity: 3);

        pool.prewarm([_configured()], brightness: Brightness.light);
        await Future<void>.delayed(Duration.zero);

        expect(pool.size, 0);
        expect(surface.disposed, isTrue);
      });

      test('a browser whose first navigation throws is forgotten again',
          () async {
        WebViewAssetView.debugSurfaceFactory = (_) => _FailingSurface();
        final pool = WebViewSurfacePool(capacity: 3);

        pool.prewarm([_configured()], brightness: Brightness.light);
        await Future<void>.delayed(Duration.zero);

        expect(pool.size, 0);
      });

      testWidgets('a tile on screen counts as known, and stops when it goes',
          (tester) async {
        WebViewAssetView.debugSurfaceFactory = (_) => _FakeSurface();
        final pool = WebViewSurfacePool.instance;

        await tester.pumpWidget(_host(_configured()));
        await tester.pump();
        expect(pool.isKnown('https://grafana.plant/d/abc/line-1'), isTrue);
        expect(pool.size, 0);

        // Parked now, so still known.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(pool.isKnown('https://grafana.plant/d/abc/line-1'), isTrue);
        expect(pool.size, 1);

        await pool.clear();
        expect(pool.isKnown('https://grafana.plant/d/abc/line-1'), isFalse);
        debugDefaultTargetPlatformOverride = null;
      });
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

  group('WebView2 availability (Windows)', () {
    // WKWebView is part of macOS and cannot be missing. WebView2 is a separate
    // runtime, so a Windows tile has one state a macOS tile does not: the
    // engine reporting that it is not installed, after the tile has started.

    testWidgets('an engine that reports itself missing flips to the placeholder',
        (tester) async {
      final surface = _FakeAbsentableSurface(available: false);
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget,
          reason: 'the browser is on screen until the probe answers');

      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fake-web')), findsNothing);
      expect(find.text('Web view is not available on this platform'),
          findsOneWidget);
      expect(surface.disposed, isTrue,
          reason: 'a browser that cannot render should not be left running');
    });

    testWidgets('an engine that is present is left alone', (tester) async {
      final surface = _FakeAbsentableSurface(available: true);
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(surface.availabilityAsks, 1);
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
      expect(find.text('Web view is not available on this platform'),
          findsNothing);
      expect(surface.disposed, isFalse);
    });

    testWidgets('a surface that cannot be absent is never asked',
        (tester) async {
      // _FakeSurface does not implement WebViewSurfaceAvailability. If the
      // view asked every surface the separate interface would be pointless,
      // and macOS would be paying for a Windows problem.
      final surface = _FakeSurface();
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
      expect(surface.navigations, hasLength(1));
    });

    testWidgets('a probe answering after dispose does not throw',
        (tester) async {
      final surface = _FakeAbsentableSurface()..useGate = true;
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());

      surface.gate.complete(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a probe for a superseded surface does not blank the new one',
        (tester) async {
      // A URL edit restarts the browser. The old surface's probe can land
      // afterwards, and must not report on a tile that has moved on.
      final first = _FakeAbsentableSurface()..useGate = true;
      final second = _FakeAbsentableSurface(available: true);
      var built = 0;
      WebViewAssetView.debugSurfaceFactory =
          (_) => (built++ == 0) ? first : second;

      final config = _configured();
      await tester.pumpWidget(_host(config));
      await tester.pump();

      config.url = 'https://grafana.plant/d/abc/line-2';
      await tester.pumpWidget(_host(config));
      await tester.pumpAndSettle();
      expect(built, 2);

      first.gate.complete(false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget,
          reason: "the live surface must survive the dead one's answer");
      expect(find.text('Web view is not available on this platform'),
          findsNothing);
    });
  });

  group('an engine that is installed but does not start (CEF)', () {
    // Seen on a station 2026-09-11: CEF was in the image and `init` answered,
    // then its platform layer failed and the browser never came up. Before
    // this, the tile was a blank box with nothing on it to say why.
    const reason =
        'The web browser did not start. See the HMI log for the reason.';

    testWidgets('the placeholder carries the reason the engine gave',
        (tester) async {
      final surface =
          _FakeAbsentableSurface(error: const WebViewUnavailable(reason));
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fake-web')), findsNothing);
      expect(find.text(reason), findsOneWidget);
      expect(find.text('Web view is not available on this platform'),
          findsNothing,
          reason: 'the engine is installed; "not available" would be untrue');
      expect(surface.disposed, isTrue,
          reason: 'a browser that never came up should not be left running');
    });

    testWidgets('any other probe failure leaves the tile alone',
        (tester) async {
      // A probe that could not answer is not proof the browser is missing.
      final surface = _FakeAbsentableSurface(error: Exception('channel hiccup'));
      WebViewAssetView.debugSurfaceFactory = (_) => surface;

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
      expect(surface.disposed, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the URL afterwards clears the reason', (tester) async {
      final dead =
          _FakeAbsentableSurface(error: const WebViewUnavailable(reason));
      final live = _FakeAbsentableSurface(available: true);
      var built = 0;
      WebViewAssetView.debugSurfaceFactory =
          (_) => (built++ == 0) ? dead : live;

      final config = _configured();
      await tester.pumpWidget(_host(config));
      await tester.pumpAndSettle();
      expect(find.text(reason), findsOneWidget);

      config.url = 'https://grafana.plant/d/abc/line-2';
      await tester.pumpWidget(_host(config));
      await tester.pumpAndSettle();

      expect(find.text(reason), findsNothing);
      expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
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

/// Cannot even be torn down, the way a plugin with a dead native side fails.
class _UndisposableSurface implements WebViewSurface {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  Future<void> navigate(Uri uri) async {}
  @override
  Future<void> dispose() async => throw Exception('channel closed');
}
