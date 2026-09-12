/// Goldens for the audit trail page: the six states CONTEXT names, and nothing
/// else.
///
/// Six images:
///
/// * `audit_trail_populated.png`      — the default view: a denial, an allowed write, a `system` origin chip, an orange `login`, and Phase 6's `admin` surface rendering as an ordinary write. 1100x700, the width a 1080p station gives the page and enough height for every row plus the bar.
/// * `audit_trail_filter_bar.png`     — the bar alone, at rest: eight chips with `operate` deselected, the one-line note, the segments, the `Last 7 days` chip. 1100x220, the bar's own height at that width and no list under it to distract from the controls.
/// * `audit_trail_expanded_group.png` — a nine-member action of which three rows survived the filters, open on arrival, with `6 of 9 members hidden by filters` on the parent. 1100x700, the same width as the populated image so a layout diff between the two is a layout diff and not a reflow.
/// * `audit_trail_empty.png`          — the query ran and matched nothing: the bar still on screen above the message, and exactly one `Clear filters`. 1100x500, shorter than the populated image because there is no list to show and a taller frame would be mostly empty surface.
/// * `audit_trail_unavailable.png`    — no database: the unavailable copy, and no filter bar at all. 1100x500, deliberately the same size as the empty image so the two can be laid side by side and must not look alike.
/// * `audit_trail_denied.png`         — `AccessLockedBody(group: users)`, which the route gate renders and this page never does. 900x600, matching `access_locked_page.png` so the two locked bodies are comparable.
///
/// **The muted (ISA-101) palette, not a bare `MaterialApp`.**
/// `HmiStateColors.of` falls back to the Solarized light palette when the theme
/// carries no extension (`lib/theme.dart:134`), so a bare `MaterialApp` here
/// would put a violet-and-magenta palette into images whose entire subject is
/// one saturated red on a page that carries no other colour. The denial mark
/// and the orange sign-in mark are what these pictures are *of*; drawn from the
/// wrong palette they would be pictures of nothing this build ships.
///
/// **Fonts are loaded here, twice.** `test/widgets/flutter_test_config.dart`
/// registers the TTF under `'Roboto'` alone, but `lib/theme.dart:349` names
/// `'roboto-mono'` as the theme's family; an unregistered family falls back to
/// Ahem, so every themed `Text` would capture as a solid rectangle. Same helper
/// as `test/page_creator/assets/aircab_golden_test.dart:105-125` and
/// `access_gate_golden_test.dart`.
///
/// **The transition arrow is missing from these images, and it is a font gap
/// rather than a widget one.** `AuditEntryLine` renders
/// `old $kAuditTransitionArrow new` — the assertion below finds the string
/// `operate, users → operate` on screen, so the widget emits it — but
/// `lib/fonts/roboto-mono/RobotoMono-Regular.ttf` has no glyph for U+2192, and
/// neither does the Roboto in the SDK's `material_fonts` cache. Both fonts
/// carry the em dash and the middle dot this page also draws, so the gap is
/// specific to the arrow. In the baselines a transition therefore reads
/// `20   35` with a blank where the arrow belongs.
///
/// It is left that way on purpose. The two fixes available are both worse than
/// the gap: loading a macOS system font would make every one of these images
/// depend on an OS update, and changing `kAuditTransitionArrow` would change a
/// rendering decision that belongs to `lib/widgets/audit_trail_row.dart` to
/// suit a test font. The arrow's presence is pinned textually here and in
/// `audit_trail_row_test.dart`, which is where a character's presence belongs.
/// Note also that `roboto-mono` is declared in no `pubspec.yaml` in this repo,
/// so at runtime the theme's family is unresolved and the platform font — which
/// does have the arrow — draws it. These images are the test environment's
/// rendering, not the station's.
///
/// **The `RepaintBoundary` is deliberately not the direct child of
/// `Scaffold.body`.** Scaffold paints its background outside that subtree, and a
/// boundary placed there captures a transparent image. Phase 1 shipped two of
/// those before the trap was written down in `access_gate_golden_test.dart`.
///
/// **Every host in this file is this file's own.** The loader and the locked
/// page host are modelled on `access_gate_golden_test.dart` and copied rather
/// than imported: importing another test file executes its top-level state, and
/// a golden that depended on a neighbour's `setUp` is a baseline nobody can
/// reproduce. `audit_trail_fixture.dart` is the one import, and only because it
/// is inert — no `setUp`, no `setUpAll`, no top-level mutable state.
///
/// **Every test asserts the state it claims before it captures it.** A frame
/// that had not decided yet matches its own wrong baseline perfectly on every
/// subsequent run, which is exactly the failure the milestone's Definition of
/// Done exists to make unavoidable (T-05-70). So each test names its own
/// terminal key present and the competing keys absent, and only then opens the
/// shutter.
///
/// **The seam is `auditTrailStoreProvider`, not `auditTrailEntriesProvider`.**
/// Riverpod 2's generated `AuditTrailEntriesFamily` carries no family-level
/// `overrideWith` — only a *resolved* `auditTrailEntriesProvider(query)` has one
/// — and overriding by resolved query would mean this file had to reconstruct
/// the query the page issues. 05-06 found the same thing and took the same way
/// out. Overriding the store is also stronger: the real provider runs, so the
/// grouping, the companion count and the `reachedLimit` arithmetic in these
/// pictures are the production ones.
///
/// To update: flutter test test/widgets/audit_trail_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/audit_trail_filters.dart';
import 'package:tfc/widgets/audit_trail_row.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'audit_trail_fixture.dart';
import '../helpers/golden_platform.dart';

/// The captured subtree. One key for every image in this file: each test pumps
/// its own host, so there is never more than one of these on screen.
const Key _boundary = Key('audit-trail-golden-boundary');

// ---------------------------------------------------------------------------
// The access overrides every host carries
// ---------------------------------------------------------------------------

/// A repository that answers nothing.
///
/// Nothing in these images asks it a question — the page holds no session and
/// the locked body only asks whether one exists — but an *unoverridden*
/// `accessRepositoryProvider` reaches `databaseProvider`,
/// `DatabaseConfig.fromPrefs()` and the station keychain, which is neither
/// deterministic nor available in a widget test.
class _StubRepository extends Fake implements AccessRepository {}

Future<AccessRepository?> _presentRepository() async => _StubRepository();

/// A session that resolves immediately.
///
/// Overriding `build` is what keeps the captured frame chosen rather than
/// raced: none of the real leaf providers — database, preferences, audit sink,
/// inactivity monitor — is ever constructed, so there is no I/O to settle
/// against and no timer to leak. An unoverridden `accessSessionProvider` would
/// still be `AsyncLoading` at capture time.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// Nobody signed in, holding the one group an anonymous station grants.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

List<Override> _accessOverrides() => <Override>[
      accessSessionProvider.overrideWith(() => _FixedSession(_anonymous())),
      accessRepositoryProvider.overrideWith((ref) => _presentRepository()),
    ];

// ---------------------------------------------------------------------------
// The store the images are drawn from
// ---------------------------------------------------------------------------

/// A store that answers the fixture verbatim.
///
/// `extends Fake` rather than a real [AuditTrailStore]: the real one needs an
/// `AppDatabase`, and a golden that stands up Drift to draw seven rows is a
/// picture of two things at once. The fixture is written as *what the `WHERE`
/// clause returned* — every filter this page has is pushed into SQL, so a fake
/// that re-filtered in Dart would be modelling a code path the page does not
/// have.
class _GoldenStore extends Fake implements AuditTrailStore {
  _GoldenStore({
    this.rows = const <AuditEntryData>[],
    this.totals = const <String, int>{},
  });

  final List<AuditEntryData> rows;

  /// What `memberCountsByAction` answers.
  ///
  /// Empty is the flat case: every action's true row count equals its visible
  /// one, so nothing is partial and no `N of M hidden` line appears. The
  /// expanded image supplies a map saying nine against three visible rows,
  /// which is the only way that number can exist — the six excluded siblings
  /// are not in the result set at all.
  final Map<String, int> totals;

  @override
  Future<List<AuditEntryData>> entries(AuditQuery query) async => rows;

  @override
  Future<Map<String, int>> memberCountsByAction(
    Iterable<String> actionIds,
  ) async {
    if (totals.isNotEmpty) return totals;
    final ids = actionIds.toList();
    return {for (final id in ids) id: ids.where((other) => other == id).length};
  }

  @override
  Future<List<String>> distinctWho() async => kAuditGoldenWhoOptions;
}

// ---------------------------------------------------------------------------
// The hosts
// ---------------------------------------------------------------------------

/// [AuditTrailBody] over [store], at [size], on the muted surface.
///
/// A **null** [store] is the station with no reachable database, which is what
/// `auditTrailEntriesProvider` turns into a resolved null and the page turns
/// into the unavailable screen. Null rather than a throw, because null is what
/// a station with no Postgres actually produces.
Widget _bodyHost({
  required ThemeData theme,
  required AuditTrailStore? store,
  required Size size,
}) {
  return ProviderScope(
    overrides: <Override>[
      ..._accessOverrides(),
      auditTrailStoreProvider.overrideWith((ref) async => store),
      // Overridden as well as answered by the store above, so the dropdown's
      // options are the same list in every image whatever the store is.
      auditWhoOptionsProvider.overrideWith((ref) async => kAuditGoldenWhoOptions),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        // Center -> RepaintBoundary -> Material -> SizedBox. The boundary is
        // not the direct child of `Scaffold.body`; see the library doc.
        //
        // `Material` and not `ColoredBox`, which is what
        // `access_gate_golden_test.dart` uses: an opaque non-`Material` box
        // between a `ListTile` and its ink controller trips
        // `_debugCheckHasMaterialInkController`, and the expanded image's
        // `ExpansionTile` is a `ListTile`. `Material` paints the same opaque
        // surface — which is what stops the captured image being transparent —
        // and is an ink controller as well.
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: const AuditTrailBody(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The filter bar on its own, with no page under it.
///
/// The bar takes its whole state as parameters and issues no query, so it needs
/// no store at all — which is the point of 05-05's shape and the reason this
/// image is cheap to keep.
Widget _filterBarHost({
  required ThemeData theme,
  required Size size,
  required AuditTrailFilters filters,
}) {
  return ProviderScope(
    overrides: _accessOverrides(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: size.width,
                height: size.height,
                // The page's own arrangement, copied rather than approximated:
                // `Column(stretch) -> Padding(8, 8, 8, 4) -> bar`. An `Align`
                // here would let the bar shrink to its intrinsic width and the
                // image would be of a bar no station ever renders.
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: AuditTrailFilterBar(
                        filters: filters,
                        whoOptions: kAuditGoldenWhoOptions,
                        resultSummary: auditTrailResultSummary(
                          count: auditGoldenPopulatedRows().length,
                          filters: filters,
                        ),
                        onChanged: (_) {},
                        onRefresh: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// [AccessLockedBody] for the group the audit trail route requires.
///
/// The denied image **reuses** the locked body rather than rebuilding a locked
/// state: `kRaisedRoutes['/advanced/audit-trail']` renders it before the page is
/// reached, and `lib/pages/audit_trail.dart` never builds one — a second,
/// weaker check on the page could disagree with the first and the disagreement
/// would be an open page (T-05-60).
///
/// `AccessGroup.users` is a parameter of the body, so this is
/// `access_locked_page.png` with one argument changed and not a new widget.
Widget _lockedHost({
  required ThemeData theme,
  required Size size,
  required AccessGroup group,
}) {
  return ProviderScope(
    overrides: _accessOverrides(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: AccessLockedBody(group: group),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// The ritual
// ---------------------------------------------------------------------------

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Bounded settle — ten 50 ms pumps, and never `pumpAndSettle`.
///
/// The filter bar holds a focus-capable `TextField`, and a blinking caret
/// schedules a frame forever: `pumpAndSettle` would time out rather than
/// return. A fixed number of frames is also one fewer thing that can hang, and
/// it drains the store and entries futures with room to spare.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final (light, _) = muted();

  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(
                Future.value(ByteData.view(file.readAsBytesSync().buffer))))
          .load();
    }

    // Both families, deliberately. `flutter_test_config.dart` registers only
    // the first; `lib/theme.dart:349` asks for the second.
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

  group('audit trail goldens',
      skip: goldenSkip, () {
    testWidgets('the default view, with something in it', (tester) async {
      _sizeView(tester, const Size(1100, 700));
      await tester.pumpWidget(_bodyHost(
        theme: light,
        store: _GoldenStore(rows: auditGoldenPopulatedRows()),
        size: const Size(1100, 700),
      ));
      await _settle(tester);

      // The picture must be of the list, not of a frame that has not decided
      // yet. Exactly one of the three terminal states is ever on screen.
      expect(find.byKey(kAuditTrailListKey), findsOneWidget);
      expect(find.byKey(kAuditTrailEmptyKey), findsNothing);
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing);

      // Phase 6's surface is provably *in the frame* rather than filtered out
      // of it. Without this the image could lose the row it exists to prove and
      // still match its own baseline forever.
      expect(find.text('role.update'), findsOneWidget);
      expect(
        find.text('operate, users $kAuditTransitionArrow operate'),
        findsOneWidget,
      );

      // Two denials, two red marks, and one orange sign-in beside them. The
      // page holds exactly as much red as it holds refusals.
      expect(find.byKey(kAuditDenialMarkKey), findsNWidgets(2));
      expect(find.byKey(kAuditAuthMarkKey), findsOneWidget);
      // The `system` and `mcp` rows carry chips; the five `operator` rows do
      // not.
      expect(find.byKey(kAuditOriginChipKey), findsNWidgets(2));

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_populated.png'),
      );
    });

    testWidgets('the filter bar at rest, operate deselected', (tester) async {
      _sizeView(tester, const Size(1100, 220));
      // The value a freshly opened page holds: `operate` out, the other six
      // groups and auth in, no search, no range, outcome `any`.
      const filters = AuditTrailFilters();
      await tester.pumpWidget(_filterBarHost(
        theme: light,
        size: const Size(1100, 220),
        filters: filters,
      ));
      await _settle(tester);

      // The exclusion is a visible control, so the image has to be of a chip
      // that is *there* and unselected rather than of a chip that is missing.
      final operate = tester.widget<FilterChip>(
        find.byKey(auditGroupChipKey(AccessGroup.operate.name)),
      );
      expect(operate.selected, isFalse);
      for (final group in AccessGroup.values) {
        if (group == AccessGroup.operate) continue;
        expect(
          tester
              .widget<FilterChip>(find.byKey(auditGroupChipKey(group.name)))
              .selected,
          isTrue,
          reason: '${group.name} is selected by default',
        );
      }
      // And the note that explains the deselection is on screen with it —
      // hidden behaviour reads as a bug and the row count would otherwise be
      // inexplicable.
      expect(find.byKey(kAuditTrailOperateNoteKey), findsOneWidget);
      // Default filters, so the bar renders no `Clear filters` of its own.
      expect(find.byKey(kAuditTrailClearFiltersKey), findsNothing);
      expect(find.text(kAuditTrailDefaultRangeLabel), findsOneWidget);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_filter_bar.png'),
      );
    });

    testWidgets('a partly filtered action, open on arrival', (tester) async {
      _sizeView(tester, const Size(1100, 700));
      await tester.pumpWidget(_bodyHost(
        theme: light,
        store: _GoldenStore(
          rows: auditGoldenPartialGroupRows(),
          totals: auditGoldenPartialGroupTotals(),
        ),
        size: const Size(1100, 700),
      ));
      await _settle(tester);

      expect(find.byKey(kAuditTrailListKey), findsOneWidget);
      expect(find.byKey(kAuditTrailEmptyKey), findsNothing);
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing);

      // **No `tester.tap` anywhere in this test, deliberately.** 05-04 opens a
      // partial group on arrival — the operator filtered for one of those
      // children and making them tap again to see the row they searched for is
      // the behaviour CONTEXT's clause exists to prevent. The three member rows
      // below are asserted against the frame as it landed, so the image is of
      // the arrival state rather than of an interaction.
      expect(find.byType(AuditEntryLine), findsNWidgets(3));
      expect(find.byKey(kAuditHiddenMembersKey), findsOneWidget);
      expect(
        find.text(kAuditHiddenMembersNote(6, kAuditGoldenGroupTotal)),
        findsOneWidget,
      );
      // A partly filtered action that read as complete would be a false record,
      // so the parent still says what the whole action did.
      expect(
        find.text(kAuditMembersChangedLabel(kAuditGoldenGroupTotal)),
        findsOneWidget,
      );

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_expanded_group.png'),
      );
    });

    testWidgets('the query ran and matched nothing', (tester) async {
      _sizeView(tester, const Size(1100, 500));
      // A store that answers an empty list: a real answer from a database that
      // was reached, and a different thing entirely from the null below.
      await tester.pumpWidget(_bodyHost(
        theme: light,
        store: _GoldenStore(),
        size: const Size(1100, 500),
      ));
      await _settle(tester);

      expect(find.byKey(kAuditTrailEmptyKey), findsOneWidget);
      expect(find.byKey(kAuditTrailListKey), findsNothing);
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing);
      expect(find.text(kAuditTrailEmptyUnderFilters), findsOneWidget);

      // The bar stays above the message precisely so the operator can see and
      // undo what excluded everything. This copy claims nothing about the
      // table, only about the filters, so the controls have to be in frame.
      expect(find.byType(AuditTrailFilterBar), findsOneWidget);

      // Exactly one `Clear filters`, never zero and never two. Under **default**
      // filters 05-05's bar renders none and this page's empty body renders its
      // own; the two together cover every state once.
      expect(find.byKey(kAuditTrailClearFiltersKey), findsNothing);
      expect(find.byKey(kAuditTrailEmptyClearFiltersKey), findsOneWidget);
      expect(find.text(kAuditTrailClearFiltersLabel), findsOneWidget);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_empty.png'),
      );
    });

    testWidgets('the trail is unavailable', (tester) async {
      _sizeView(tester, const Size(1100, 500));
      // **Null, not a throw and not an empty list.** Null is what a station
      // with no Postgres actually produces: `databaseProvider` answers null,
      // `auditTrailStoreProvider` answers null, and
      // `auditTrailEntriesProvider` resolves null. An error is the *other*
      // cause of the same screen and belongs to the widget test, not here — the
      // whole reason this image exists is that it must not look like the empty
      // one, and picturing it from the cause that actually happens on a
      // station is what makes the comparison honest.
      await tester.pumpWidget(_bodyHost(
        theme: light,
        store: null,
        size: const Size(1100, 500),
      ));
      await _settle(tester);

      expect(find.byKey(kAuditTrailUnavailableKey), findsOneWidget);
      expect(find.byKey(kAuditTrailEmptyKey), findsNothing);
      expect(find.byKey(kAuditTrailListKey), findsNothing);
      expect(find.text(kAuditTrailUnavailable), findsOneWidget);

      // No bar over an unreachable database: there is nothing to filter, and
      // controls that cannot change the answer would invite trying.
      expect(find.byType(AuditTrailFilterBar), findsNothing);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_unavailable.png'),
      );
    });

    testWidgets('the locked body the route gate renders', (tester) async {
      _sizeView(tester, const Size(900, 600));
      await tester.pumpWidget(_lockedHost(
        theme: light,
        size: const Size(900, 600),
        group: kAuditTrailGroup,
      ));
      await _settle(tester);

      expect(find.byKey(kAccessLockedBodyKey), findsOneWidget);
      // The repository is present, so this is the ordinary shut page rather
      // than the no-database variant, which has its own image next door.
      expect(find.byKey(kAccessLockedNoDatabaseKey), findsNothing);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/audit_trail_denied.png'),
      );
    });
  });
}
