/// One golden: the access-templates section, as an administrator holding
/// `users` sees it, with two templates, their bound-key counts and one of them
/// open on its member-to-group rules.
///
/// `access_templates_section.png` — 04-07 built this section and reviewed it
/// through throwaway frames that were deleted; the plan said a golden **of the
/// section** was still owed, and this is it. The three key-repository goldens
/// beside this file are of the *page*, taken before the section existed and
/// re-recorded when it was mounted; none of them shows this card, because they
/// all run with `databaseProvider -> null` and the section renders only the
/// "no reachable database" line in that state.
///
/// **What the image is supposed to show**, so a later reader can check the
/// file rather than a memory:
///
///  * the card header — a shield glyph, `Access templates`, and a live
///    `New template` button (nothing here is greyed for a session that may not
///    use it; the store refuses and the shared prompt explains),
///  * `conveyor`, collapsed, with `2 rules · 2 keys bound` under its name, a
///    rename control and a delete control,
///  * `recipes` below it with `1 rule · 1 key bound`, **expanded** onto its one
///    rule: `The whole key` needing `setpoints`, with the permission in a live
///    dropdown and a remove control beside it,
///  * a scrollbar thumb on the right, because the list is bounded at
///    `kAccessTemplatesListMaxHeight` so it cannot push the key list off a
///    panel — and a bounded list with no scrollbar reads as a list that *ends*
///    where it was cut. `Add rule` is the row below the cut.
///
/// Which template is opened is forced rather than chosen; see the comment at
/// the tap.
///
/// **Fonts are loaded here, twice, deliberately.** `test/pages/` uses
/// `test/flutter_test_config.dart`, which registers **no font at all**, and
/// `lib/theme.dart:349` names `'roboto-mono'` as the theme's family. Without
/// both registrations every `Text` on this card captures as Ahem rectangles
/// and the question this image exists to answer — are the rules legible? —
/// cannot be asked.
///
/// **The themed app**, or `HmiStateColors` falls back to `solarizedLight` and
/// puts violet into a picture of a muted page.
///
/// **Pinned**: `withClock`, an overridden `accessSessionProvider`, and a
/// snapshot already in the resolver — nothing here waits on a loader, so the
/// captured frame is chosen rather than raced.
///
/// **Every fixture is this file's own.** Importing another test file executes
/// its top-level state and makes a baseline nobody can reproduce.
///
/// To update: flutter test test/pages/access_templates_section_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/access_templates_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../helpers/golden_tolerance.dart';
import '../helpers/golden_platform.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

const String _station = 'SVN-NES-OT-CL02';

/// The instant this image is frozen at.
final DateTime _frozen = DateTime.utc(2026, 8, 30, 9, 0);

/// Spec §7b's worked example, trimmed to the two members the phase's
/// acceptance sentence is about.
AccessTemplate _conveyor() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        'p_cfg_ManualFreq': AccessGroup.setpoints,
        'p_cmd_JogFwd': AccessGroup.operate,
      },
    );

/// The other shape a template takes: one whole-key row, which the editor
/// renders as `The whole key` because `*` is a sentinel nobody can type.
AccessTemplate _recipes() => AccessTemplate(
      name: 'recipes',
      rules: const {kWholeKeyMember: AccessGroup.setpoints},
    );

/// Two keys on the conveyor template and one on recipes, so the two tiles
/// carry different counts and a reader can tell the count is computed rather
/// than printed.
TagBindingResolver _resolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {
      'ST101.CN01': 'conveyor',
      'ST101.CN02': 'conveyor',
      'ST101.RCP01': 'recipes',
    },
    templates: {
      'conveyor': _conveyor(),
      'recipes': _recipes(),
    },
  );

/// The administrator the `users` gate exists for.
AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
        AccessGroup.users,
      },
    );

/// A session that answers one fixed value without standing up the real
/// controller chain (database, preferences, audit sink, inactivity monitor).
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

/// Swallows the rows a write would produce. This image drives no write.
class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

/// Loads the two families the theme needs plus the icon font.
Future<void> _loadRealFonts() async {
  Future<void> loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

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
}

void main() {
  final (light, _) = muted();

  // A card of real text on a real theme: the 0.01% default absorbs
  // antialiasing drift on small painter goldens, not on a frame of prose.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('access templates section golden',
      skip: goldenSkip, () {
    setUpAll(_loadRealFonts);

    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.inMemoryForTest();
      // Force the schema before the first store call, so a read on an empty
      // table finds a table rather than nothing.
      await db.customSelect('SELECT 1').getSingle();
    });

    tearDown(() async {
      await db.close();
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    testWidgets('two templates, their rules and their bound-key counts',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
        view.devicePixelRatio = 1.0;
        view.physicalSize = const Size(760, 340);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            // A real store over an in-memory database: the section renders
            // its "no reachable database" line when this resolves null, and
            // that is the state the page's own goldens already capture.
            accessTemplateStoreProvider.overrideWith((ref) async =>
                AccessTemplateStore(
                    db: db,
                    session: _withUsers,
                    audit: _NullSink(),
                    station: _station)),
            // The loader, answered directly. The snapshot below is what the
            // counts come from; this is what the list comes from.
            accessTemplatesProvider
                .overrideWith((ref) async => [_conveyor(), _recipes()]),
            tagBindingResolverProvider.overrideWith((ref) => _resolver()),
            accessSessionProvider
                .overrideWith(() => _FixedSession(_withUsers())),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AccessTemplatesSection(),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        // `recipes` is the one opened, and the choice is forced rather than
        // arbitrary. The list is capped at `kAccessTemplatesListMaxHeight`
        // (168 px) so it cannot push the key list off a panel, and a tile is
        // ~48 px: opening `conveyor` — two rule rows plus the Add-rule button
        // — pushes the second tile out of the viewport entirely, and the
        // image would then show one template rather than two. Opening
        // `recipes` fits both tiles, its rule row, and the top of Add rule,
        // so the picture carries both counts *and* a rule.
        //
        // The rule it carries is the more informative one anyway: the
        // whole-key row, rendered as `The whole key` because `*` is a
        // sentinel nobody can type, is one of the two spec readings 04-01
        // decided.
        await tester.tap(find.byKey(kAccessTemplateTileKey('recipes')));
        await tester.pumpAndSettle();

        // The claims the image is supposed to make, asserted before the pixels
        // are compared. An eye can read `2 rules · 2 keys bound`; it cannot see
        // that the create control's `onPressed` is non-null.
        expect(find.byKey(kAccessTemplatesSectionKey), findsOneWidget);
        expect(find.text(kAccessTemplateSummary(2, 2)), findsOneWidget);
        expect(find.text(kAccessTemplateSummary(1, 1)), findsOneWidget);
        expect(find.text(kWholeKeyMemberLabel), findsOneWidget);
        expect(find.text('*'), findsNothing,
            reason: 'the sentinel is never shown to an operator');
        expect(
            tester
                .widget<OutlinedButton>(
                    find.byKey(kAccessTemplatesCreateKey))
                .onPressed,
            isNotNull,
            reason: 'no control on this section is greyed for lack of a '
                'permission; the store refuses and the prompt explains');
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_templates_section.png'),
        );
      });
    });
  });
}
