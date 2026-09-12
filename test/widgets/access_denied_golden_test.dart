/// Goldens for the one surface plan 03-07 puts in front of an operator: the
/// prompt a refused write produces, over the page the operator was standing on.
///
/// Two images:
///
/// * `access_denied_prompt.png`          — nobody signed in: the lock, the permission the write needed, what was refused, the no-replay line, and both actions.
/// * `access_denied_prompt_elevated.png` — the same refusal for somebody who *is* signed in and whose role lacks the group. The app bar names them; the prompt still offers to sign in as somebody else.
///
/// **The prompt itself carries no identity, and that is a finding rather than
/// a defect in this test.** Plan 03-12's `<behavior>` asks the elevated image
/// to "name who is signed in". `_AccessDeniedDialog`
/// (`lib/widgets/access_denied_prompt.dart:246-332`) renders only
/// `denial.required`, `denial.itemKey` and two constants — nothing session
/// dependent — so the two images would be pixel-identical if the prompt were
/// captured alone. They are captured inside the real app shell instead, where
/// `AccessStatusAction` in the app bar is what names the signed-in operator.
/// The pair then differs by exactly the two things that are actually different
/// between the two sessions, which is what makes them worth comparing.
///
/// **Orange appears in the elevated image, in the app bar, and must not appear
/// in the prompt.** `HmiStateColors.orange` means forced/override and — since
/// plan 01-08 — an elevated session, which is exactly what the app bar is
/// reporting. A lock is neither an override nor a fault, so the prompt paints
/// its glyph in `colorScheme.onSurfaceVariant`
/// (`access_denied_prompt.dart:296`). Both facts are asserted below, at the
/// widget, before the image is captured — an eye cannot tell
/// `onSurfaceVariant` from a near neighbour but a test can.
///
/// **The muted (ISA-101) palette, not solarized.** `HmiStateColors` falls back
/// to `solarizedLight` outside a themed app, which would put violet in a
/// picture whose subject is a deliberately muted lock.
///
/// **Fonts are loaded here, twice.** `test/widgets/flutter_test_config.dart`
/// registers the TTF under `'Roboto'` alone, but `lib/theme.dart:349` names
/// `'roboto-mono'` as the theme's family; an unregistered family falls back to
/// Ahem, so every themed `Text` would capture as solid rectangles.
///
/// **Pinned with `withClock`.** `base_scaffold.dart:217` renders `clock.now()`
/// — deliberately, so a scaffold golden can be frozen. Without it the header
/// timestamp churns on every run.
///
/// **`accessSessionProvider` is overridden in both images.** An unoverridden
/// one runs the real controller chain, and a frame captured before it settles
/// is `AsyncLoading`, in which `AccessStatusAction` renders
/// `SizedBox.shrink()` and the app bar looks empty.
///
/// To update: flutter test test/widgets/access_denied_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show HmiStateColors, muted;
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import '../helpers/golden_platform.dart';

/// The refusal both images show. A jog command on a real-looking tag, refused
/// for want of `force` — the shape `guarded_state_man_test.dart` drives.
const AccessDenied _denial =
    AccessDenied('ST101.CN01.p_cmd_JogFwd', AccessGroup.force);

/// A repository that answers nothing. Both images only ever ask whether one
/// exists.
class _StubRepository extends Fake implements AccessRepository {}

/// A session that resolves immediately to whatever the image needs.
///
/// Overriding [build] keeps the captured frame *chosen* rather than raced:
/// none of the real leaf providers — database, preferences, audit sink,
/// inactivity monitor — is ever constructed, so there is no I/O to settle
/// against and no timer to leak.
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

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The fictional operator in image 2: signed in, and short of the permission
/// the refused write needed. Not a real account.
AccessSession _elevated() => AccessSession(
      user: const AuthenticatedUser(
        username: 'lina',
        roleName: 'Line Lead',
        displayName: 'Lina R',
      ),
      groups: const {AccessGroup.operate, AccessGroup.setpoints},
      // Fixed, never `DateTime.now()`: nothing renders it, and a golden that
      // depended on the wall clock would be a latent churn.
      expiresAt: DateTime.utc(2026, 8, 30, 12, 0),
    );

/// The page the operator was standing on when the write was refused.
///
/// Deliberately plain. The subject of both images is the prompt and the app
/// bar behind it; a mimic with its own colours would make "no off-scheme
/// colour appears" a judgement about the fixture rather than about the
/// prompt.
///
/// Top-left, not centred. A centred body lands exactly behind the dialog and
/// the first pass of these two images had a page that was in the tree and
/// invisible — "the prompt over a page" has to be legible as such.
class _PlantPage extends StatelessWidget {
  const _PlantPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Freezer infeed', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'ST101.CN01 — conveyor jog',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The top-level menu [BaseScaffold] draws its navigation bar from.
///
/// Two entries, not one: `NavigationBar` asserts `destinations.length >= 2`.
void _registerShellMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(const MenuItem(
      label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
}

/// A one-route Beamer shell around a real [BaseScaffold].
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped
/// without a router above it, and it is [BaseScaffold] that mounts
/// `AccessDeniedPrompt` (`base_scaffold.dart:404`) — which is the whole point
/// of capturing the shell rather than the dialog on its own. The
/// `ProviderScope` sits above `MaterialApp.router` so the root navigator's
/// overlay, where the dialog lands, is inside it.
Widget _shellHost({
  required ThemeData theme,
  required AccessSession session,
  required Stream<AccessDenied> denials,
}) {
  final router = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => const BeamPage(
            key: ValueKey('/'),
            title: 'Freezer infeed',
            child: BaseScaffold(title: 'Freezer infeed', body: _PlantPage()),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      accessDenialsProvider.overrideWithValue(denials),
    ],
    child: BeamerProvider(
      routerDelegate: router,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme,
        routerDelegate: router,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The Phase 1 lesson, copied deliberately: `find.text` passes on a string the
/// painter has clipped to "…will not repeat th…", which is how an ellipsised
/// honesty line shipped past a green assertion. Text present is not text
/// legible, so pin the properties that decide it and then measure the
/// paragraph at the width the prompt actually renders it at.
void _expectWrapsLegibly(WidgetTester tester, Key key, String expected) {
  final text = tester.widget<Text>(find.byKey(key));
  expect(text.data, expected);
  expect(text.maxLines, isNull);
  expect(text.overflow, isNot(TextOverflow.ellipsis));

  final rendered = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.byKey(key), matching: find.byType(RichText)),
  );
  expect(
    rendered.size.height,
    greaterThan(rendered.preferredLineHeight),
    reason: 'the line must wrap onto more than one line at the real width',
  );
  expect(rendered.didExceedMaxLines, isFalse);
}

/// Everything both images must be true of, checked at the widget before the
/// pixels are compared. A golden matching its own wrong baseline is the
/// failure mode this whole gate exists for; these are the parts of "wrong" a
/// machine can still catch.
void _expectPromptIsALock(WidgetTester tester, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;

  expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
  expect(find.text(kAccessDeniedHeadline), findsOneWidget);

  // The lock is painted in onSurfaceVariant, never in the elevation orange
  // and never in the fault red.
  final lock = tester.widget<Icon>(find.byKey(kAccessDeniedLockKey));
  expect(lock.icon, Icons.lock_outline);
  expect(lock.color, scheme.onSurfaceVariant);
  expect(lock.color, isNot(HmiStateColors.of(context).orange));
  expect(lock.color, isNot(scheme.error));

  // Both actions are live. A greyed control is what this milestone forbids
  // outright, and the image cannot show the difference.
  expect(find.byKey(kAccessDeniedSignInKey), findsOneWidget);
  expect(find.byKey(kAccessDeniedDismissKey), findsOneWidget);

  _expectWrapsLegibly(
      tester, kAccessDeniedNoReplayKey, kAccessDeniedNoReplayNote);
  final group = tester.widget<Text>(find.byKey(kAccessDeniedGroupKey));
  expect(group.data, kAccessDeniedGroupNote(_denial.required));
  expect(group.overflow, isNot(TextOverflow.ellipsis));
  final item = tester.widget<Text>(find.byKey(kAccessDeniedItemKey));
  expect(item.data, kAccessDeniedItemNote(_denial.itemKey));
  expect(item.overflow, isNot(TextOverflow.ellipsis));
}

void main() {
  final (light, _) = muted();

  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
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
  });

  tearDown(() => RouteRegistry().menuItems.clear());

  group('access denied goldens',
      skip: goldenSkip, () {
    testWidgets('the prompt over a page, nobody signed in', (tester) async {
      await withClock(Clock.fixed(DateTime.utc(2026, 8, 30, 9, 0)), () async {
        _sizeView(tester, const Size(1280, 800));
        _registerShellMenu();

        final denials = StreamController<AccessDenied>.broadcast();
        addTearDown(denials.close);

        await tester.pumpWidget(_shellHost(
          theme: light,
          session: _anonymous(),
          denials: denials.stream,
        ));
        await tester.pumpAndSettle();

        denials.add(_denial);
        await tester.pumpAndSettle();

        final context = tester.element(find.byKey(kAccessDeniedBodyKey));
        _expectPromptIsALock(tester, context);

        // Nobody is signed in, so the app bar offers the way in and names
        // nobody. This is the one thing the pair differs by.
        expect(find.byType(AccessStatusAction), findsOneWidget);
        expect(find.text('Lina R'), findsNothing);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_denied_prompt.png'),
        );
      });
    });

    testWidgets('the prompt over a page, signed in without the permission',
        (tester) async {
      await withClock(Clock.fixed(DateTime.utc(2026, 8, 30, 9, 0)), () async {
        _sizeView(tester, const Size(1280, 800));
        _registerShellMenu();

        final denials = StreamController<AccessDenied>.broadcast();
        addTearDown(denials.close);

        final session = _elevated();
        await tester.pumpWidget(_shellHost(
          theme: light,
          session: session,
          denials: denials.stream,
        ));
        await tester.pumpAndSettle();

        denials.add(_denial);
        await tester.pumpAndSettle();

        final context = tester.element(find.byKey(kAccessDeniedBodyKey));
        _expectPromptIsALock(tester, context);

        // The premise of this image: signed in, and genuinely short of the
        // group. If the session held `force` the picture would be a lie.
        expect(session.groups.contains(_denial.required), isFalse);

        // Who is signed in is named in the app bar — the prompt itself has no
        // identity to show. See the library comment.
        expect(find.text('Lina R'), findsOneWidget);
        expect(find.text('Line Lead'), findsOneWidget);

        // And the offer to sign in as somebody else is still there.
        expect(find.byKey(kAccessDeniedSignInKey), findsOneWidget);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/access_denied_prompt_elevated.png'),
        );
      });
    });
  });
}
