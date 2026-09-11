/// Goldens for the two access surfaces this phase puts in front of an
/// operator: the app-bar affordance and the sign-in dialog.
///
/// Seven images, one per state that looks different:
///
/// * `access_appbar_anonymous.png`   — nobody signed in: the Sign in icon, no name.
/// * `access_appbar_elevated.png`    — signed in: who, their role, and Sign out, in orange.
/// * `access_sign_in_dialog.png`     — the form at rest, honesty subtitle showing.
/// * `access_sign_in_dialog_error.png` — the same form after a rejected password.
/// * `access_panel_commit_prompt.png` — the prompt a station account gets, over the form.
/// * `access_session_card_committed.png`   — the Session card on a committed panel.
/// * `access_session_card_uncommitted.png` — the same card on an uncommitted one.
///
/// The last pair is the read-out support reads. Both sentences are long, and
/// the failure a `find.text` cannot catch is exactly the one that matters
/// here: a line that ellipsises instead of wrapping tells the reader the
/// panel's account is `freeze…`.
///
/// **The muted (ISA-101) palette, not solarized.** `HmiStateColors.orange` is
/// the token plan 01-08 added for an elevated session, and in the muted
/// palettes it resolves to `MutedColors.forcedOrange` — a value that exists
/// nowhere else. Rendering these under solarized would exercise
/// `SolarizedColors.orange` instead and leave the new constant unreviewed,
/// which is the one colour judgement this phase's golden gate asks for.
///
/// **Both dialog images have the commissioning window open**, so the "Create
/// the first account" link is in the picture. The pair then differs by exactly
/// one thing — the inline error row — which is what makes them worth comparing.
///
/// **Fonts are loaded here, twice.** `test/widgets/flutter_test_config.dart`
/// registers the TTF under `'Roboto'` alone, but `lib/theme.dart` names
/// `'roboto-mono'` as the theme's family; an unregistered family falls back to
/// Ahem, so every themed `Text` would capture as solid rectangles. Same helper
/// as `test/page_creator/assets/aircab_golden_test.dart:105-125`.
///
/// **Nothing here renders a clock**, so no `withClock` is needed — but the
/// session's `expiresAt` is a fixed `DateTime` rather than `DateTime.now()`,
/// because a golden must not depend on when it ran.
///
/// To update: flutter test test/widgets/access_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/access_session_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc_access/tfc_access.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;

const _appBarBoundary = Key('access_appbar_golden');
const _dialogBoundary = Key('access_sign_in_dialog_golden');
const _commitBoundary = Key('access_panel_commit_golden');
const _sessionCardBoundary = Key('access_session_card_golden');

/// A session that resolves immediately to whatever the image needs.
///
/// Overriding [build] is what keeps the captured frame *chosen* rather than
/// raced: none of the real leaf providers — database, preferences, audit sink,
/// inactivity monitor — is ever constructed, so there is no I/O to settle
/// against and no timer to leak. `AccessStatusAction` renders nothing at all
/// under `AsyncLoading`, so a golden that let the real chain run could capture
/// an empty app bar.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session, {this.result = AccessSignInResult.ok, this.signsInAs});

  AccessSession _session;

  /// What [signIn] answers. The error image needs `badCredentials`.
  final AccessSignInResult result;

  /// Who a successful [signIn] publishes. The panel-commitment image needs a
  /// station account, because the prompt it captures is only offered to one.
  final AuthenticatedUser? signsInAs;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async {
    final user = signsInAs;
    if (result == AccessSignInResult.ok && user != null) {
      // Assigned to the field as well as to `state`, so a `build()` that has
      // not resolved yet cannot land behind this and publish the old session.
      _session = AccessSession(user: user, groups: const {AccessGroup.operate});
      state = AsyncData(_session);
    }
    return result;
  }

  @override
  Future<bool> commitPanelAccount() async => true;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// The fictional panel account in the commitment image. Not a real account.
const _freezer = AuthenticatedUser(
  username: 'freezer',
  roleName: kOperatorRoleName,
  stationAccount: true,
);

/// The fictional operator in the images. Not a real account (T-01-71).
AccessSession _elevated() => AccessSession(
      user: const AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
      ),
      groups: const {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
      // Fixed, never `DateTime.now()`: nothing renders it, and a golden that
      // depended on the wall clock would be a latent churn.
      expiresAt: DateTime.utc(2026, 8, 28, 12, 0),
    );

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The right-hand cluster of `BaseScaffold`'s app bar, at app-bar height and
/// on the bar's own surface colour.
///
/// Not the whole `BaseScaffold`: that needs a Beamer ancestor and would put a
/// logo, a clock and a theme toggle in a picture whose subject is the
/// affordance. The placement is the one `base_scaffold.dart:325-333` uses —
/// first child of a right-aligned, min-size `Row`.
Widget _appBarHost({required ThemeData theme, required AccessSession session}) {
  return ProviderScope(
    overrides: [accessSessionProvider.overrideWith(() => _FixedSession(session))],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _appBarBoundary,
            child: Material(
              color: theme.colorScheme.surface,
              child: SizedBox(
                width: 720,
                height: kToolbarHeight,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Text('Overview', style: theme.textTheme.titleLarge),
                    const Spacer(),
                    const AccessStatusAction(),
                    const SizedBox(width: 16),
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

Widget _dialogHost({required ThemeData theme, required _FixedSession session}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => session),
      // Open, so the commissioning link is part of the picture. See the
      // library comment.
      firstUserWindowOpenProvider.overrideWith((ref) async => true),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _dialogBoundary,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: const SizedBox(
                width: 620,
                height: 620,
                child: AccessSignInDialog(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The sign-in form with a route-pushed dialog on top of it.
///
/// The boundary sits **above** `MaterialApp`, unlike [_dialogHost]'s. A
/// confirm dialog is a pushed route and renders in the Navigator's overlay; a
/// boundary inside the `Scaffold` would capture the form with a hole where the
/// prompt is.
Widget _commitHost({required ThemeData theme, required _FixedSession session}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => session),
      firstUserWindowOpenProvider.overrideWith((ref) async => false),
    ],
    child: RepaintBoundary(
      key: _commitBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Consumer(
          builder: (context, ref, _) {
            // Listened from the first frame, as `BaseScaffold` does. Without
            // it the notifier is not built until `_submit` reads it, and the
            // session `signIn` publishes is clobbered by the pending `build()`
            // completing behind it.
            ref.watch(accessSessionProvider);
            return Scaffold(
              backgroundColor: theme.colorScheme.surface,
              body: const Center(
                child: SizedBox(
                  width: 620,
                  height: 620,
                  child: AccessSignInDialog(),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// The Session card, with the panel committed to [panelAccount] or to nobody.
///
/// The audit sink is overridden to a no-op rather than left real: the card
/// records a row on every change it makes, and a golden must not need a
/// database to render a card it is not changing anything on.
Widget _sessionCardHost({required ThemeData theme, String? panelAccount}) {
  final prefs = FakeEditorPreferences();
  if (panelAccount != null) {
    prefs.setString(kAccessPanelAccountPrefKey, panelAccount);
  }
  return ProviderScope(
    overrides: [
      localPreferencesProvider.overrideWithValue(prefs),
      accessSessionAuditProvider.overrideWithValue(
        (station: 'ST301', audit: _NullAudit()),
      ),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _sessionCardBoundary,
            // Scrollable, as `access_admin.dart` mounts it: a bare `Center`
            // hands the card the whole viewport height and it captures with a
            // third of the image empty below the last line.
            child: const SizedBox(
              width: 620,
              child: SingleChildScrollView(child: AccessSessionSection()),
            ),
          ),
        ),
      ),
    ),
  );
}

class _NullAudit implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

/// Bounded settle.
///
/// `pumpAndSettle` cannot be used once a `TextField` has focus: the caret
/// blink schedules frames forever. [EditableText.debugDeterministicCursor]
/// (set in `setUpAll`) freezes the caret on, and this drains the provider
/// futures in a fixed number of frames — the same shape as
/// `test/helpers/test_helpers.dart`'s `settle`.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
    // the first; `lib/theme.dart:334` asks for the second.
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

    EditableText.debugDeterministicCursor = true;
  });

  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  group('access goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('app bar, anonymous', (tester) async {
      _sizeView(tester, const Size(800, 200));
      await tester.pumpWidget(
        _appBarHost(theme: light, session: _anonymous()),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_appBarBoundary),
        matchesGoldenFile('goldens/access_appbar_anonymous.png'),
      );
    });

    testWidgets('app bar, elevated', (tester) async {
      _sizeView(tester, const Size(800, 200));
      await tester.pumpWidget(
        _appBarHost(theme: light, session: _elevated()),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_appBarBoundary),
        matchesGoldenFile('goldens/access_appbar_elevated.png'),
      );
    });

    testWidgets('sign-in dialog at rest', (tester) async {
      _sizeView(tester, const Size(700, 760));
      await tester.pumpWidget(
        _dialogHost(theme: light, session: _FixedSession(_anonymous())),
      );
      await _settle(tester);

      await expectLater(
        find.byKey(_dialogBoundary),
        matchesGoldenFile('goldens/access_sign_in_dialog.png'),
      );
    });

    testWidgets('sign-in dialog after a rejected password', (tester) async {
      _sizeView(tester, const Size(700, 760));
      await tester.pumpWidget(
        _dialogHost(
          theme: light,
          session: _FixedSession(
            _anonymous(),
            result: AccessSignInResult.badCredentials,
          ),
        ),
      );
      await _settle(tester);

      // Drive the real rejection path rather than fabricating the error
      // string: the image has to show what an operator actually gets after a
      // wrong password, inline and readable, not a framework exception box.
      await tester.enterText(find.byKey(kAccessSignInUsernameKey), 'jon');
      await tester.enterText(
          find.byKey(kAccessSignInPasswordKey), 'not-my-password');
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await _settle(tester);

      expect(find.text(kAccessSignInBadCredentialsMessage), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(_dialogBoundary),
        matchesGoldenFile('goldens/access_sign_in_dialog_error.png'),
      );
    });

    testWidgets('the panel commitment prompt', (tester) async {
      _sizeView(tester, const Size(700, 760));
      await tester.pumpWidget(
        _commitHost(
          theme: light,
          session: _FixedSession(_anonymous(), signsInAs: _freezer),
        ),
      );
      await _settle(tester);

      // Driven, not fabricated: the prompt is reached the way an operator
      // reaches it, so the image cannot show a dialog the app would never
      // actually put on screen.
      await tester.enterText(find.byKey(kAccessSignInUsernameKey), 'freezer');
      await tester.enterText(find.byKey(kAccessSignInPasswordKey), 'panel pw');
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await _settle(tester);

      // The long sentence is the subject of this image — it has to be legible
      // and wrapped, not ellipsised, which is the failure a `find.text` alone
      // would not catch (see the honesty-line comment in the dialog).
      expect(find.text(kAccessSignInCommitTitle('freezer')), findsOneWidget);
      expect(find.text(kAccessSignInCommitMessage('freezer')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(_commitBoundary),
        matchesGoldenFile('goldens/access_panel_commit_prompt.png'),
      );
    });

    testWidgets('the Session card on a committed panel', (tester) async {
      _sizeView(tester, const Size(700, 460));
      await tester.pumpWidget(
        _sessionCardHost(theme: light, panelAccount: 'freezer'),
      );
      await _settle(tester);

      expect(find.text(kAccessSessionPanelCommittedNote('freezer')),
          findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(_sessionCardBoundary),
        matchesGoldenFile('goldens/access_session_card_committed.png'),
      );
    });

    testWidgets('the Session card on an uncommitted panel', (tester) async {
      _sizeView(tester, const Size(700, 460));
      await tester.pumpWidget(_sessionCardHost(theme: light));
      await _settle(tester);

      expect(find.text(kAccessSessionPanelUncommittedNote), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(_sessionCardBoundary),
        matchesGoldenFile('goldens/access_session_card_uncommitted.png'),
      );
    });
  });
}
