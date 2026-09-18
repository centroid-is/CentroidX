/// Goldens for the audit trail as one trail: the full scope, with a
/// configuration action drawn as the configuration history draws it.
///
/// Two images:
///
/// * `audit_trail_unified.png`      — the full trail at `/advanced/audit-trail`: the Everything | Configuration lens, a page save opened to its entities and their field rows with Undo beside it, and beneath it the ordinary audit lines (a sign-in, a denial, a setpoint write) exactly as the trail has always drawn them. 1100x760.
/// * `audit_trail_unified_dark.png` — the same frame on the dark scheme, where a divider drawn from `colorScheme.outline` would vanish. Same size, so a diff between the two is a palette diff and not a reflow.
///
/// What the picture exists to show is that the two halves are one list: the
/// page save is no longer a bare `page.save` line here with its diff one menu
/// entry away.
///
/// The traps `audit_trail_golden_test.dart` and `config_history_golden_test.dart`
/// document apply unchanged — the muted palette rather than a bare
/// `MaterialApp`, both font families loaded, the `RepaintBoundary` one level
/// below `Scaffold.body`, and every test asserting the state it claims before
/// it captures it. The transition arrow draws in the field rows: DejaVu Sans
/// has U+2192.
///
/// **The seam is the two stores**, as in the config history's goldens: the real
/// providers run, so the kind counts in the title, the lazy read on opening and
/// the merge of header and entity rows are the production ones.
///
/// To update: scripts/goldens.sh --update test/widgets/audit_trail_unified_golden_test.dart
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/core/config_change_store.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/config_history.dart' show configHistoryUndoKey;
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/providers/config_history.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/audit_trail_row.dart';
import 'package:tfc/widgets/config_change_row.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'audit_trail_fixture.dart';
import 'config_history_fixture.dart';
import '../helpers/golden_platform.dart';

const Key _boundary = Key('audit-trail-unified-golden-boundary');

/// The full trail's rows: the page save's header, newest, then three ordinary
/// audit lines — a sign-in, a refused setpoint write and an allowed one.
///
/// Written as what the `WHERE` clause returned, newest first.
List<AuditEntryData> _trailRows() => <AuditEntryData>[
      ...configGoldenFieldDiffHeaders(),
      ...auditGoldenPopulatedRows().take(3),
    ];

/// The trail's side of the read.
class _GoldenAuditStore extends Fake implements AuditTrailStore {
  _GoldenAuditStore(this.rows);

  final List<AuditEntryData> rows;

  @override
  Future<List<AuditEntryData>> entries(AuditQuery query) async => rows;

  @override
  Future<Map<String, int>> memberCountsByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toList();
    return {for (final id in ids) id: ids.where((other) => other == id).length};
  }

  @override
  Future<List<String>> distinctWho() async => kAuditGoldenWhoOptions;
}

/// The change log's side: the page save's two entities, and nothing for any
/// other action — which is what makes those draw as audit lines.
class _GoldenChangeStore extends Fake implements ConfigChangeStore {
  final List<ConfigChangeRecord> records = configGoldenFieldDiffChanges();

  @override
  Future<Map<String, ActionChangeCounts>> changeKindCountsByAction(
      Iterable<String> actionIds) async {
    if (!actionIds.contains(kConfigGoldenActionId)) return const {};
    return {
      kConfigGoldenActionId: ActionChangeCounts(
        byKind: {ConfigKind.asset: records.length},
        total: records.length,
      ),
    };
  }

  @override
  Future<Map<String, List<ConfigChangeRecord>>> changesByAction(
      Iterable<String> actionIds) async {
    if (!actionIds.contains(kConfigGoldenActionId)) return const {};
    return {kConfigGoldenActionId: records};
  }
}

Widget _host({required ThemeData theme, required Size size}) {
  return ProviderScope(
    overrides: <Override>[
      auditTrailStoreProvider
          .overrideWith((ref) async => _GoldenAuditStore(_trailRows())),
      configChangeStoreProvider
          .overrideWith((ref) async => _GoldenChangeStore()),
      auditWhoOptionsProvider
          .overrideWith((ref) async => kAuditGoldenWhoOptions),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        // Center -> RepaintBoundary -> Material -> SizedBox, for the reasons
        // `audit_trail_golden_test.dart` gives: the boundary is not the direct
        // child of `Scaffold.body`, and `Material` is the ink controller the
        // `ExpansionTile`s need.
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: const AuditTrailView(scope: AuditTrailScope.everything),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Bounded settle — never `pumpAndSettle`: the filter bar's `TextField` holds a
/// caret that schedules frames forever.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await _settle(tester);
}

void main() {
  final (light, dark) = muted();

  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(
                Future.value(ByteData.view(file.readAsBytesSync().buffer))))
          .load();
    }

    await loadFont('Roboto', 'lib/fonts/dejavu-sans/DejaVuSans.ttf');
    await loadFont(
        'dejavu-sans', 'lib/fonts/dejavu-sans/DejaVuSans.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }

    EditableText.debugDeterministicCursor = true;
  });

  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  group('unified audit trail goldens', skip: goldenSkip, () {
    const size = Size(1100, 760);

    Future<void> pumpUnified(WidgetTester tester, ThemeData theme) async {
      _sizeView(tester, size);
      await tester.pumpWidget(_host(theme: theme, size: size));
      await _settle(tester);
      await _open(tester, 'jon changed 2 assets');
      await _open(tester, 'asset:/baader/CN21');
    }

    void expectUnified() {
      // The full scope, on Everything.
      expect(find.byKey(kAuditTrailLensKey), findsOneWidget);
      expect(find.byKey(kAuditTrailListKey), findsOneWidget);

      // The page save, titled by what it changed, opened to its entities and
      // one of them to its fields — the configuration history's rendering.
      expect(find.byType(DeferredConfigActionTile), findsOneWidget);
      expect(find.byType(ConfigChangeTile), findsNWidgets(2));
      expect(find.text('parent_id'), findsOneWidget);
      expect(find.text('payload.coordinates.x'), findsOneWidget);
      expect(find.byKey(configHistoryUndoKey(kConfigGoldenActionId)),
          findsOneWidget);

      // And the ordinary lines beside it, drawn as they always were.
      expect(find.byKey(kAuditAuthMarkKey), findsOneWidget);
      expect(find.byKey(kAuditDenialMarkKey), findsOneWidget);
      expect(find.text('ST101.CN04.p_par_SpeedRef'), findsOneWidget);
    }

    testWidgets('a page save and the audit lines around it, as one list',
        (tester) async {
      await pumpUnified(tester, light);
      expectUnified();

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_unified.png'),
      );
    });

    testWidgets('the same frame on the dark scheme', (tester) async {
      await pumpUnified(tester, dark);
      expectUnified();

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_unified_dark.png'),
      );
    });
  });
}
