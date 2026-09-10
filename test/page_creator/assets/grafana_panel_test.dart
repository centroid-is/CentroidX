import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/grafana_panel.dart';
import 'package:tfc/page_creator/assets/registry.dart';

/// A real 1x1 PNG, so `Image.memory` has something it can actually decode and
/// the success path is not testing a broken-image widget by accident.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

GrafanaPanelConfig _configured() => GrafanaPanelConfig(
      baseUrl: 'http://grafana:3000',
      dashboardUid: 'abc123',
      dashboardSlug: 'line-1',
      panelId: 3,
    );

Widget _host(GrafanaPanelConfig config) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 240,
            child: GrafanaPanelView(config: config),
          ),
        ),
      ),
    );

void main() {
  tearDown(() => GrafanaPanelView.debugFetcher = null);

  group('GrafanaPanelConfig JSON', () {
    test('fields survive a round trip', () {
      final config = GrafanaPanelConfig(
        baseUrl: 'https://plant/grafana',
        dashboardUid: 'abc123',
        dashboardSlug: 'line-1',
        panelId: 7,
        orgId: 2,
        from: 'now-24h',
        to: 'now-1h',
        timezone: 'Atlantic/Reykjavik',
        variables: {'machine': 'BER01'},
        refreshSeconds: 300,
        theme: GrafanaPanelTheme.dark,
        apiToken: 'glsa_secret',
      )
        ..text = 'Line 1 throughput'
        ..coordinates = Coordinates(x: 0.25, y: 0.5);

      final restored = GrafanaPanelConfig.fromJson(config.toJson());

      expect(restored.baseUrl, 'https://plant/grafana');
      expect(restored.dashboardUid, 'abc123');
      expect(restored.dashboardSlug, 'line-1');
      expect(restored.panelId, 7);
      expect(restored.orgId, 2);
      expect(restored.from, 'now-24h');
      expect(restored.to, 'now-1h');
      expect(restored.timezone, 'Atlantic/Reykjavik');
      expect(restored.variables, {'machine': 'BER01'});
      expect(restored.refreshSeconds, 300);
      expect(restored.theme, GrafanaPanelTheme.dark);
      expect(restored.apiToken, 'glsa_secret');
      expect(restored.text, 'Line 1 throughput');
    });

    test('registry parses it back out of page JSON', () {
      final parsed = AssetRegistry.parse({
        'page': [_configured().toJson()],
      });
      expect(parsed, hasLength(1));
      expect(parsed.single, isA<GrafanaPanelConfig>());
      expect((parsed.single as GrafanaPanelConfig).dashboardUid, 'abc123');
    });

    test('palette default is unconfigured', () {
      final preview = AssetRegistry.createDefaultAsset(GrafanaPanelConfig)
          as GrafanaPanelConfig;
      expect(preview.isConfigured, isFalse);
      expect(preview.refreshSeconds, 60);
      expect(preview.theme, GrafanaPanelTheme.auto);
    });

    test('reports no tag keys — it reads nothing from the PLC', () {
      expect(_configured().allKeys, isEmpty);
    });
  });

  group('parseGrafanaPanelLink', () {
    test('reads a panel opened full-screen', () {
      final link = parseGrafanaPanelLink(
          'http://grafana:3000/d/abc123/line-1?orgId=2&from=now-12h&to=now'
          '&viewPanel=3')!;
      expect(link.baseUrl, 'http://grafana:3000');
      expect(link.dashboardUid, 'abc123');
      expect(link.dashboardSlug, 'line-1');
      expect(link.panelId, 3);
      expect(link.orgId, 2);
      expect(link.from, 'now-12h');
      expect(link.to, 'now');
    });

    test("reads Grafana 11's panel-N form", () {
      final link = parseGrafanaPanelLink(
          'http://grafana:3000/d/abc123/line-1?viewPanel=panel-42')!;
      expect(link.panelId, 42);
    });

    test('reads a d-solo embed link', () {
      final link = parseGrafanaPanelLink(
          'http://grafana:3000/d-solo/abc123/line-1?panelId=9&theme=dark')!;
      expect(link.dashboardUid, 'abc123');
      expect(link.panelId, 9);
    });

    test('keeps a reverse-proxy subpath as the base URL', () {
      final link = parseGrafanaPanelLink(
          'https://plant.example/grafana/d/abc123/line-1?viewPanel=3')!;
      expect(link.baseUrl, 'https://plant.example/grafana');
    });

    test('base URL carries neither the query nor the fragment', () {
      // Uri.replace treats a null argument as "keep the original", so an
      // earlier version of this leaked the whole dashboard query string into
      // baseUrl and every rendered URL came out doubled.
      final link = parseGrafanaPanelLink(
          'http://grafana:3000/d/abc123/line-1?viewPanel=3&from=now-1h#tail')!;
      expect(link.baseUrl, 'http://grafana:3000');
    });

    test('a dashboard without a slug still resolves', () {
      final link =
          parseGrafanaPanelLink('http://grafana:3000/d/abc123?viewPanel=1')!;
      expect(link.dashboardUid, 'abc123');
      expect(link.dashboardSlug, isEmpty);
      expect(link.panelId, 1);
    });

    test('collects template variables without their var- prefix', () {
      final link = parseGrafanaPanelLink(
          'http://grafana:3000/d/abc123/line-1?viewPanel=3'
          '&var-machine=BER01&var-shift=night')!;
      expect(link.variables, {'machine': 'BER01', 'shift': 'night'});
    });

    test('a dashboard URL naming no panel parses with a null panel id', () {
      final link =
          parseGrafanaPanelLink('http://grafana:3000/d/abc123/line-1')!;
      expect(link.dashboardUid, 'abc123');
      expect(link.panelId, isNull);
    });

    test('rejects what is not a Grafana URL', () {
      expect(parseGrafanaPanelLink('http://grafana:3000/'), isNull);
      expect(parseGrafanaPanelLink('http://grafana:3000/admin/users'), isNull);
      expect(parseGrafanaPanelLink('file:///d/abc123/x'), isNull);
      expect(parseGrafanaPanelLink('not a url at all'), isNull);
      expect(parseGrafanaPanelLink(''), isNull);
    });
  });

  group('buildGrafanaRenderUri', () {
    Uri build({
      String baseUrl = 'http://grafana:3000',
      String uid = 'abc123',
      String slug = 'line-1',
      int? panelId = 3,
      String timezone = '',
      Map<String, String> variables = const {},
      double scale = 1.0,
    }) =>
        buildGrafanaRenderUri(
          baseUrl: baseUrl,
          dashboardUid: uid,
          dashboardSlug: slug,
          panelId: panelId,
          timezone: timezone,
          variables: variables,
          width: 800,
          height: 400,
          scale: scale,
          theme: 'dark',
        )!;

    test('targets /render/d-solo with the panel and box size', () {
      final uri = build();
      expect(uri.path, '/render/d-solo/abc123/line-1');
      expect(uri.queryParameters['panelId'], '3');
      expect(uri.queryParameters['width'], '800');
      expect(uri.queryParameters['height'], '400');
      expect(uri.queryParameters['theme'], 'dark');
      expect(uri.queryParameters['orgId'], '1');
      expect(uri.queryParameters['from'], 'now-6h');
      expect(uri.queryParameters['to'], 'now');
    });

    test('keeps a reverse-proxy subpath ahead of /render', () {
      final uri = build(baseUrl: 'https://plant.example/grafana');
      expect(uri.path, '/grafana/render/d-solo/abc123/line-1');
      expect(uri.host, 'plant.example');
      expect(uri.scheme, 'https');
    });

    test('tolerates a trailing slash on the base URL', () {
      expect(build(baseUrl: 'http://grafana:3000/').path,
          '/render/d-solo/abc123/line-1');
    });

    test('omits the slug when there is none', () {
      expect(build(slug: '').path, '/render/d-solo/abc123');
    });

    test('omits scale at 1.0 and sends it above', () {
      // The stations render at 1.0, so the URL they fetch carries no
      // parameter an older grafana-image-renderer might not recognise.
      expect(build().queryParameters.containsKey('scale'), isFalse);
      expect(build(scale: 2.0).queryParameters['scale'], '2');
      expect(build(scale: 1.5).queryParameters['scale'], '1.5');
    });

    test('omits an empty timezone and sends a set one', () {
      expect(build().queryParameters.containsKey('timezone'), isFalse);
      expect(build(timezone: 'Atlantic/Reykjavik').queryParameters['timezone'],
          'Atlantic/Reykjavik');
    });

    test('template variables regain their var- prefix', () {
      final uri = build(variables: {'machine': 'BER01'});
      expect(uri.queryParameters['var-machine'], 'BER01');
    });

    test('returns null when there is not enough to render', () {
      Uri? attempt({String base = 'http://grafana:3000', String uid = 'abc', int? panel = 3}) =>
          buildGrafanaRenderUri(
            baseUrl: base,
            dashboardUid: uid,
            panelId: panel,
            width: 800,
            height: 400,
            theme: 'light',
          );
      expect(attempt(panel: null), isNull);
      expect(attempt(uid: ''), isNull);
      expect(attempt(base: ''), isNull);
      expect(attempt(base: 'not a url'), isNull);
      expect(attempt(base: 'ftp://grafana:3000'), isNull);
      expect(attempt(), isNotNull);
    });
  });

  group('describeGrafanaFailure', () {
    test('names the missing renderer plugin, whatever the status', () {
      final message = describeGrafanaFailure(
          500, '{"message":"Rendering plugin not found"}');
      expect(message, contains('grafana-image-renderer'));
    });

    test('401 and 403 point at the token', () {
      expect(describeGrafanaFailure(401, ''), contains('401'));
      expect(describeGrafanaFailure(401, ''), contains('token'));
      expect(describeGrafanaFailure(403, ''), contains('Viewer'));
    });

    test('404 points at the UID and panel id', () {
      expect(describeGrafanaFailure(404, ''), contains('panel id'));
    });

    test('500 carries the first line of the body when there is one', () {
      expect(describeGrafanaFailure(500, 'boom\nstack\ntrace'),
          contains('boom'));
      expect(describeGrafanaFailure(500, ''), contains('500'));
    });

    test('an unexpected status still says what it was', () {
      expect(describeGrafanaFailure(502, ''), contains('502'));
    });
  });

  group('looksLikePng', () {
    test('accepts the PNG signature and rejects a login page', () {
      expect(looksLikePng(_png), isTrue);
      expect(looksLikePng(utf8.encode('<!DOCTYPE html><html>')), isFalse);
      expect(looksLikePng(const [0x89, 0x50]), isFalse);
    });
  });

  group('GrafanaPanelView', () {
    testWidgets('an unconfigured panel fetches nothing', (tester) async {
      var calls = 0;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        calls++;
        return _png;
      };
      await tester.pumpWidget(_host(GrafanaPanelConfig()));
      await tester.pump();
      expect(calls, 0);
      expect(find.text('No panel selected'), findsOneWidget);
    });

    testWidgets('renders the panel and asks for the box it was given',
        (tester) async {
      Uri? asked;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        asked = uri;
        return _png;
      };
      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(asked, isNotNull);
      expect(asked!.path, '/render/d-solo/abc123/line-1');
      // 320x240 quantised up to the next 32 px step.
      expect(asked!.queryParameters['width'], '320');
      expect(asked!.queryParameters['height'], '256');
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('auto theme follows the HMI theme', (tester) async {
      Uri? asked;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        asked = uri;
        return _png;
      };
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 240,
            child: GrafanaPanelView(config: _configured()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(asked!.queryParameters['theme'], 'dark');
    });

    testWidgets('a token is sent as a bearer header, and omitted when unset',
        (tester) async {
      Map<String, String>? sent;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        sent = headers;
        return _png;
      };

      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();
      expect(sent!.containsKey('Authorization'), isFalse);

      await tester.pumpWidget(
          _host(_configured()..apiToken = ' glsa_secret '));
      await tester.pumpAndSettle();
      expect(sent!['Authorization'], 'Bearer glsa_secret');
    });

    testWidgets('a first failure shows the reason', (tester) async {
      GrafanaPanelView.debugFetcher = (uri, headers) async =>
          throw const GrafanaRenderException('Grafana has no image renderer.');
      await tester.pumpWidget(_host(_configured()));
      await tester.pumpAndSettle();

      expect(find.text('Grafana has no image renderer.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a failed refresh keeps the last picture and marks it stale',
        (tester) async {
      // The rule the camera asset learned the hard way: a tile showing real
      // numbers does not go blank because one poll failed.
      var fail = false;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        if (fail) throw const GrafanaRenderException('Cannot reach Grafana');
        return _png;
      };
      final config = _configured()..refreshSeconds = 10;
      await tester.pumpWidget(_host(config));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('STALE'), findsNothing);

      fail = true;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget, reason: 'picture must stay');
      expect(find.text('STALE'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);

      // And it recovers on the next tick without operator intervention.
      fail = false;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('STALE'), findsNothing);
    });

    testWidgets('refreshSeconds 0 renders once and never polls',
        (tester) async {
      var calls = 0;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        calls++;
        return _png;
      };
      await tester.pumpWidget(_host(_configured()..refreshSeconds = 0));
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('a bad base URL says so instead of fetching', (tester) async {
      var calls = 0;
      GrafanaPanelView.debugFetcher = (uri, headers) async {
        calls++;
        return _png;
      };
      await tester.pumpWidget(_host(_configured()..baseUrl = 'grafana:3000'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('Grafana URL is not valid'), findsOneWidget);
    });
  });

  group('config editor', () {
    testWidgets('a pasted panel URL fills every field it carries',
        (tester) async {
      final config = GrafanaPanelConfig();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));

      await tester.enterText(
        find.widgetWithText(TextField, 'Paste a Grafana panel URL'),
        'https://plant.example/grafana/d/abc123/line-1'
            '?orgId=2&from=now-12h&to=now&viewPanel=panel-7&var-machine=BER01',
      );
      await tester.tap(find.byTooltip('Fill the fields below from this URL'));
      await tester.pumpAndSettle();

      expect(config.baseUrl, 'https://plant.example/grafana');
      expect(config.dashboardUid, 'abc123');
      expect(config.dashboardSlug, 'line-1');
      expect(config.panelId, 7);
      expect(config.orgId, 2);
      expect(config.from, 'now-12h');
      expect(config.variables, {'machine': 'BER01'});
      expect(config.isConfigured, isTrue);
    });

    testWidgets('a URL that is not Grafana is reported, not applied',
        (tester) async {
      final config = GrafanaPanelConfig();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));

      await tester.enterText(
        find.widgetWithText(TextField, 'Paste a Grafana panel URL'),
        'https://example.com/something/else',
      );
      await tester.tap(find.byTooltip('Fill the fields below from this URL'));
      await tester.pumpAndSettle();

      expect(config.baseUrl, isEmpty);
      expect(find.textContaining('Not a Grafana panel URL'), findsOneWidget);
    });

    testWidgets('a dashboard URL naming no panel says which half is missing',
        (tester) async {
      final config = GrafanaPanelConfig();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));

      await tester.enterText(
        find.widgetWithText(TextField, 'Paste a Grafana panel URL'),
        'http://grafana:3000/d/abc123/line-1',
      );
      await tester.tap(find.byTooltip('Fill the fields below from this URL'));
      await tester.pumpAndSettle();

      expect(config.dashboardUid, 'abc123');
      expect(config.panelId, isNull);
      expect(find.textContaining('names no panel'), findsOneWidget);
    });

    testWidgets('typed fields land on the config', (tester) async {
      final config = GrafanaPanelConfig();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Grafana URL'),
          ' http://grafana:3000 ');
      expect(config.baseUrl, 'http://grafana:3000');

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Dashboard UID'), 'abc123');
      expect(config.dashboardUid, 'abc123');

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Panel id'), 'panel-4');
      expect(config.panelId, 4);
    });
  });
}
