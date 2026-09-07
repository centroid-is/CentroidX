/// Goldens for the configuration history page: the five surfaces the phase
/// names, plus dark variants of the two that carry the most drawing.
///
/// Seven images:
///
/// * `config_history_populated.png`     — the default view: one save read as one action, three assets beneath it with a field row open, and beneath that a **parentless** action, flagged and open on arrival. 1100x700.
/// * `config_history_populated_dark.png`— the same frame on the dark scheme, which is where an invisible divider would show. Same size, so a diff between the two is a palette diff and not a reflow.
/// * `config_history_field_diff.png`    — `payload.coordinates.x`, a `parent_id` move and a `sort_index` reorder in one frame: the three shapes an entity encoding distinguishes, and the reason position is part of the stored entity at all. 1100x700.
/// * `config_history_field_diff_dark.png` — as above, dark.
/// * `config_history_insert_delete.png` — asymmetric rendering: an insert is one `New entity` row with a new side only, a delete one `Removed entity` row with an old side only, and neither carries an arrow. 1100x600.
/// * `config_history_empty.png`         — the query ran and matched nothing: the filter bar and the scope banner still on screen above the message. 1100x500.
/// * `config_history_unavailable.png`   — no database: the unavailable copy, and neither bar nor banner. 1100x500, **deliberately the same size as the empty image** so the two can be laid side by side and must not look alike.
///
/// The four traps `audit_trail_golden_test.dart` documents apply here
/// unchanged, and this file is modelled on it rather than importing from it:
///
/// **1. The muted (ISA-101) palette, not a bare `MaterialApp`.**
/// `HmiStateColors.of` falls back to the Solarized light palette when the theme
/// carries no extension, so a bare `MaterialApp` would put violet and magenta
/// into images whose subject includes one muted green and one muted orange.
///
/// **2. Fonts are loaded twice.** `flutter_test_config.dart` registers the TTF
/// under `'Roboto'` alone; `lib/theme.dart` names `'roboto-mono'` as the
/// theme's family, and an unregistered family falls back to Ahem, which would
/// capture every `Text` as a solid rectangle.
///
/// **The transition arrow is missing from these baselines, and it is a font gap
/// rather than a widget one** — `RobotoMono-Regular.ttf` carries no glyph for
/// U+2192. A field row therefore reads `0.31   0.42` with a blank where the
/// arrow belongs. The arrow's presence is pinned textually in
/// `config_history_test.dart`, which is where a character's presence belongs;
/// at runtime the theme's family is unresolved and the platform font draws it.
///
/// **3. The `RepaintBoundary` is deliberately not the direct child of
/// `Scaffold.body`.** Scaffold paints its background outside that subtree, and
/// a boundary placed there captures a transparent image.
///
/// **4. Every test asserts the state it claims before it captures it.** A frame
/// that had not decided yet matches its own wrong baseline perfectly on every
/// subsequent run. Each test names its own terminal key present and the
/// competing keys absent, and the expansions it is a picture of, and only then
/// opens the shutter.
///
/// **The seam is the two stores, not `configHistoryActionsProvider`.** Riverpod
/// 2's generated family carries no family-level `overrideWith`, and overriding
/// by resolved query would mean this file had to reconstruct the query the page
/// issues. Overriding the stores is also stronger: the real provider runs, so
/// the grouping, the header join and the parentless detection in these pictures
/// are the production ones.
///
/// To update: flutter test test/widgets/config_history_golden_test.dart --update-goldens
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
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/providers/config_history.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/config_change_row.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'config_history_fixture.dart';

/// The captured subtree. One key for every image in this file: each test pumps
/// its own host, so there is never more than one of these on screen.
const Key _boundary = Key('config-history-golden-boundary');

/// A change store that answers the fixture verbatim.
///
/// `extends Fake` rather than a real [ConfigChangeStore]: the real one needs an
/// `AppDatabase`, and a golden that stands up Drift to draw five rows is a
/// picture of two things at once. The fixture is written as *what the `WHERE`
/// clause returned* — every filter this page has is pushed into SQL.
class _GoldenChangeStore extends Fake implements ConfigChangeStore {
  _GoldenChangeStore({this.rows = const <ConfigChangeRecord>[]});

  final List<ConfigChangeRecord> rows;

  @override
  Future<List<ConfigChangeRecord>> changes(ConfigChangeQuery query) async =>
      rows;

  @override
  Future<Map<String, int>> changeCountsByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toList();
    return {
      for (final id in ids)
        id: rows.where((row) => row.change.actionId == id).length,
    };
  }
}

/// The header side of the same read. An action id it does not carry is a
/// parentless action, which is how the populated image gets one without a
/// special case anywhere in the page.
class _GoldenAuditStore extends Fake implements AuditTrailStore {
  _GoldenAuditStore({this.headers = const <AuditEntryData>[]});

  final List<AuditEntryData> headers;

  @override
  Future<List<AuditEntryData>> entriesByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toSet();
    return headers.where((row) => ids.contains(row.actionId)).toList();
  }

  @override
  Future<Map<String, int>> memberCountsByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toList();
    return {
      for (final id in ids)
        id: headers.where((row) => row.actionId == id).length,
    };
  }
}

/// [ConfigHistoryBody] over the two stores, at [size], on the muted surface.
///
/// A **null** change store is the station with no reachable database — null
/// rather than a throw, because null is what a station with no Postgres
/// actually produces.
Widget _bodyHost({
  required ThemeData theme,
  required ConfigChangeStore? changeStore,
  required Size size,
  AuditTrailStore? auditStore,
}) {
  return ProviderScope(
    overrides: <Override>[
      configChangeStoreProvider.overrideWith((ref) async => changeStore),
      auditTrailStoreProvider.overrideWith((ref) async => auditStore),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        // Center -> RepaintBoundary -> Material -> SizedBox. The boundary is
        // not the direct child of `Scaffold.body`; see the library doc.
        //
        // `Material` and not `ColoredBox`: an opaque non-`Material` box between
        // a `ListTile` and its ink controller trips
        // `_debugCheckHasMaterialInkController`, and every action here is an
        // `ExpansionTile`, which is a `ListTile`.
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: const ConfigHistoryBody(),
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

/// Bounded settle — ten 50 ms pumps, and never `pumpAndSettle`.
///
/// The filter bar holds a focus-capable `TextField`, and a blinking caret
/// schedules a frame forever: `pumpAndSettle` would time out rather than
/// return.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Open one tile by the text on its header, and wait out the expansion.
Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
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

    // Both families, deliberately. See the library doc.
    await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

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

    // This file renders a `TextField`, so the caret has to stop blinking or the
    // image would depend on which millisecond the shutter opened.
    EditableText.debugDeterministicCursor = true;
  });

  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  group('config history goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    Future<void> pumpPopulated(WidgetTester tester, ThemeData theme) async {
      _sizeView(tester, const Size(1100, 700));
      await tester.pumpWidget(_bodyHost(
        theme: theme,
        changeStore:
            _GoldenChangeStore(rows: configGoldenPopulatedChanges()),
        auditStore:
            _GoldenAuditStore(headers: configGoldenPopulatedHeaders()),
        size: const Size(1100, 700),
      ));
      await _settle(tester);
      await _open(tester, 'jon changed 3 assets');
      await _open(tester, 'asset:/roe/CN04');
    }

    /// What the populated frame must be showing before it is captured.
    void expectPopulated(WidgetTester tester) {
      expect(find.byKey(kConfigHistoryListKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyKey), findsNothing);
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing);

      // Two actions, five rows: one save read as one line, and one action whose
      // header never landed. The second is the picture's whole point, so it is
      // asserted rather than assumed.
      expect(find.byType(ConfigActionTile), findsNWidgets(2));
      expect(find.text('jon changed 3 assets'), findsOneWidget);
      expect(find.byKey(kConfigParentlessKey), findsOneWidget);
      expect(find.byKey(kConfigParentlessNoteKey), findsOneWidget);

      // The save is open, with one of its entities open under it — without this
      // the image could lose the field rows it exists to show and still match
      // its own baseline forever.
      expect(find.text('asset:/roe/CN04'), findsOneWidget);
      expect(find.text('payload.coordinates.x'), findsOneWidget);

      // And the two sentences that are true whatever the list holds.
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsOneWidget);
      expect(find.byKey(kConfigHistorySilentNoteKey), findsOneWidget);
    }

    testWidgets('the default view: one save, three assets, and an orphan',
        (tester) async {
      await pumpPopulated(tester, light);
      expectPopulated(tester);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_populated.png'),
      );
    });

    testWidgets('the same frame on the dark scheme', (tester) async {
      // The variant that would catch a divider drawn from `colorScheme.outline`
      // — unset in both of this app's schemes, and invisible on this one.
      await pumpPopulated(tester, dark);
      expectPopulated(tester);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_populated_dark.png'),
      );
    });

    Future<void> pumpFieldDiff(WidgetTester tester, ThemeData theme) async {
      _sizeView(tester, const Size(1100, 700));
      await tester.pumpWidget(_bodyHost(
        theme: theme,
        changeStore:
            _GoldenChangeStore(rows: configGoldenFieldDiffChanges()),
        auditStore:
            _GoldenAuditStore(headers: configGoldenFieldDiffHeaders()),
        size: const Size(1100, 700),
      ));
      await _settle(tester);
      await _open(tester, 'jon changed 2 assets');
      await _open(tester, 'asset:/baader/CN21');
      await _open(tester, 'asset:/baader/CN22');
    }

    void expectFieldDiff(WidgetTester tester) {
      expect(find.byKey(kConfigHistoryListKey), findsOneWidget);
      // The three shapes, in one frame: a payload value, a page move and a
      // paint-order move. The last two are top-level rows precisely because the
      // stored entity carries position.
      expect(find.text('payload.coordinates.x'), findsOneWidget);
      expect(find.text('parent_id'), findsOneWidget);
      expect(find.text('sort_index'), findsOneWidget);
      expect(find.byType(ConfigFieldRow), findsNWidgets(4));
    }

    testWidgets('a payload value, a page move and a reorder in one frame',
        (tester) async {
      await pumpFieldDiff(tester, light);
      expectFieldDiff(tester);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_field_diff.png'),
      );
    });

    testWidgets('the field rows on the dark scheme', (tester) async {
      await pumpFieldDiff(tester, dark);
      expectFieldDiff(tester);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_field_diff_dark.png'),
      );
    });

    testWidgets('an insert and a delete, rendered asymmetrically',
        (tester) async {
      _sizeView(tester, const Size(1100, 600));
      await tester.pumpWidget(_bodyHost(
        theme: light,
        changeStore:
            _GoldenChangeStore(rows: configGoldenInsertDeleteChanges()),
        auditStore:
            _GoldenAuditStore(headers: configGoldenInsertDeleteHeaders()),
        size: const Size(1100, 600),
      ));
      await _settle(tester);
      await _open(tester, 'jon changed 2 assets');
      await _open(tester, 'asset:/roe/CN07');
      await _open(tester, 'asset:/roe/CN03');

      expect(find.byKey(kConfigHistoryListKey), findsOneWidget);
      // One whole-entity row each, and the two badges that say which is which.
      expect(find.text(kConfigEntityAddedLabel), findsOneWidget);
      expect(find.text(kConfigEntityRemovedLabel), findsOneWidget);
      expect(find.text('added'), findsOneWidget);
      expect(find.text('removed'), findsOneWidget);
      // Green added, orange removed, and no third mark: an update would carry
      // an equally sized transparent placeholder instead.
      expect(find.byKey(kConfigOpMarkKey), findsNWidgets(2));

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_insert_delete.png'),
      );
    });

    testWidgets('the query ran and matched nothing', (tester) async {
      _sizeView(tester, const Size(1100, 500));
      // A store that answers an empty list: a real answer from a database that
      // was reached, and a different thing entirely from the null below.
      await tester.pumpWidget(_bodyHost(
        theme: light,
        changeStore: _GoldenChangeStore(),
        auditStore: _GoldenAuditStore(),
        size: const Size(1100, 500),
      ));
      await _settle(tester);

      expect(find.byKey(kConfigHistoryEmptyKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryListKey), findsNothing);
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing);
      expect(find.text(kConfigHistoryEmptyUnderFilters), findsOneWidget);
      // The bar and the banner stay above the message: the copy claims nothing
      // about the table, and the sentence explaining what this view cannot show
      // is most needed by somebody looking at an empty one.
      expect(find.byKey(kConfigHistoryFilterBarKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyClearFiltersKey), findsOneWidget);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_empty.png'),
      );
    });

    testWidgets('the history is unavailable', (tester) async {
      _sizeView(tester, const Size(1100, 500));
      // **Null, not a throw and not an empty list.** Null is what a station
      // with no Postgres actually produces, and picturing this screen from the
      // cause that happens on a station is what makes the comparison with the
      // empty image honest — the whole reason it exists is that the two must
      // not look alike.
      await tester.pumpWidget(_bodyHost(
        theme: light,
        changeStore: null,
        size: const Size(1100, 500),
      ));
      await _settle(tester);

      expect(find.byKey(kConfigHistoryUnavailableKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyKey), findsNothing);
      expect(find.byKey(kConfigHistoryListKey), findsNothing);
      expect(find.text(kConfigHistoryUnavailable), findsOneWidget);
      // Neither controls nor banner over an unreachable database: there is
      // nothing to filter, and a sentence about what this view shows would be
      // describing a view that is showing nothing.
      expect(find.byKey(kConfigHistoryFilterBarKey), findsNothing);
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsNothing);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/config_history_unavailable.png'),
      );
    });
  });
}
