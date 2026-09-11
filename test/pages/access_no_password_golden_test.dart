/// Two goldens of the one feature that changes what a person may do without
/// typing anything: an account with **no password**.
///
///  * `access_users_no_password_roster.png` — the users list with one open
///    account among three. The marker beside `line` is the whole point: a
///    roster that drew an open account exactly like a protected one would hide
///    the fact an administrator opened the screen to check. The image is what
///    proves the marker is *findable* — the right size, the right colour, next
///    to the name rather than lost in a column at the far edge.
///  * `access_users_no_password_dialog.png` — the create dialog with the tick
///    on: the password fields greyed and emptied, and the sentence saying what
///    was just chosen. The claim this image makes is that the consequence is
///    legible at a glance and is not a footnote — anybody at the panel can sign
///    in as this account.
///
/// **[AccessUsersSection], not [AccessAdminBody].** These are pictures of one
/// section and its dialog; pumping the whole page would put the roles list and
/// the honesty note in every frame and make both images sensitive to changes
/// that have nothing to do with passwords.
///
/// **Every fixture, fake and override here is this file's own.** Importing
/// `access_admin_golden_test.dart` would execute its top-level state and make a
/// baseline nobody can reproduce; the duplication is deliberate and is the same
/// ruling that file states.
///
/// **Fonts are loaded, twice**, and **the muted palette is used**, for the
/// reasons `access_admin_golden_test.dart` sets out at length: `test/pages/`
/// registers no font of its own, `lib/theme.dart` names `'roboto-mono'`, and
/// `HmiStateColors` falls back to `solarizedLight` outside a themed app. The
/// marker and the warning are both drawn in `colorScheme.error`, so a wrong
/// palette here would be a picture of the wrong colour making the wrong claim.
///
/// **Local-time fixtures**, again for that file's reason: the created column
/// renders `at.toLocal()`, so a UTC fixture would render differently in another
/// zone.
///
/// To update: flutter test test/pages/access_no_password_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/pages/access_users_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import '../helpers/golden_tolerance.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

List<AccessRole> _roles() => const [
      AccessRole(name: kOperatorRoleName, groups: {AccessGroup.operate}),
      AccessRole(
        name: 'Shift Leader',
        groups: {AccessGroup.operate, AccessGroup.setpoints},
      ),
      AccessRole(
        name: 'Engineering',
        groups: {
          AccessGroup.operate,
          AccessGroup.setpoints,
          AccessGroup.device,
          AccessGroup.force,
          AccessGroup.configure,
          AccessGroup.administer,
          AccessGroup.users,
        },
      ),
    ];

/// An account row.
///
/// [open] sets `hasPassword: false`, and there is no credential anywhere in
/// this fixture — not a marker, not a placeholder hash, not a salt.
///
/// It used to write the real `kNoPasswordMarker` into a `passwordHash` column,
/// because the section decoded that column with `isPasswordless()`. The roster
/// now carries the bit itself, so the fixture states the fact the image is
/// about instead of encoding it and having the widget decode it back.
UserSummary _user(
  String username,
  String roleName, {
  required DateTime createdAt,
  DateTime? lastLoginAt,
  bool open = false,
}) =>
    UserSummary(
      username: username,
      roleName: roleName,
      hasPassword: !open,
      createdAt: createdAt,
      lastLoginAt: lastLoginAt,
      stationAccount: false,
    );

/// The roster, by username, with exactly one open account.
///
/// One of three, not three of three: the image has to show the marker *against*
/// rows without it, because "can I pick the open account out of a list" is the
/// question it exists to answer.
List<UserSummary> _users() => [
      _user('admin', 'Engineering',
          createdAt: DateTime(2026, 6, 2, 8, 15),
          lastLoginAt: DateTime(2026, 8, 31, 7, 5)),
      _user('line', kOperatorRoleName,
          open: true,
          createdAt: DateTime(2026, 9, 1, 6, 0),
          lastLoginAt: DateTime(2026, 9, 8, 5, 45)),
      _user('linar', 'Shift Leader',
          createdAt: DateTime(2026, 7, 14, 6, 30),
          lastLoginAt: DateTime(2026, 8, 30, 22, 10)),
    ];

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// Answers the two reads this section makes and refuses everything else, so an
/// inherited `noSuchMethod` is the tripwire for a write a rendering pass should
/// never have made. Neither image submits its dialog.
class _AnsweringStore extends Fake implements AccessAdminStore {
  _AnsweringStore({required this.roleRows, required this.userRows});

  final List<AccessRole> roleRows;
  final List<UserSummary> userRows;

  @override
  Future<List<AccessRole>> roles() async => roleRows;

  @override
  Future<List<UserSummary>> listUsers() async => userRows;
}

class _PresentRepository extends Fake implements AccessRepository {}

/// Resolves immediately, so the captured frame is chosen rather than raced: the
/// real controller reaches the database, the preferences store and the station
/// keychain, and a frame captured before it settles is `AsyncLoading`.
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

/// The administrator the `users` gate exists for.
AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(
        username: 'admin',
        roleName: 'Engineering',
        displayName: 'Anna S',
      ),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
        AccessGroup.configure,
        AccessGroup.administer,
        AccessGroup.users,
      },
    );

// ---------------------------------------------------------------------------
// Hosts
// ---------------------------------------------------------------------------

const Key _boundary = Key('access_no_password_golden');

List<Override> _overrides(AccessAdminStore store) => [
      accessRepositoryProvider.overrideWith((ref) async => _PresentRepository()),
      accessAdminStoreProvider.overrideWith((ref) async => store),
      accessSessionProvider.overrideWith(() => _FixedSession(_withUsers())),
    ];

/// The roster image's host.
///
/// The surface is painted **inside** the boundary: a `RepaintBoundary` captures
/// only its own subtree, so one placed at `Scaffold.body` captures a
/// transparent image that merely looks white in a viewer.
Widget _sectionHost(ThemeData theme, AccessAdminStore store) => ProviderScope(
      overrides: _overrides(store),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: RepaintBoundary(
            key: _boundary,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: const SingleChildScrollView(child: AccessUsersSection()),
            ),
          ),
        ),
      ),
    );

/// The dialog image's host: the whole `MaterialApp` is captured, because the
/// dialog lives in the root navigator's overlay and a boundary inside the body
/// would photograph the page and miss it.
Widget _dialogHost(ThemeData theme, AccessAdminStore store) => ProviderScope(
      overrides: _overrides(store),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: const SingleChildScrollView(child: AccessUsersSection()),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

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

  // Frames of prose on a real theme, not a small painter surface: the 0.01%
  // default absorbs antialiasing drift on a shape, not on a page of text.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('no-password goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    setUpAll(_loadRealFonts);

    testWidgets('the roster marks the one account that has no password',
        (tester) async {
      const size = Size(900, 420);
      _sizeView(tester, size);

      await tester.pumpWidget(_sectionHost(
        light,
        _AnsweringStore(roleRows: _roles(), userRows: _users()),
      ));
      await tester.pumpAndSettle();

      // Asserted before the pixels are compared, so the image is not a frame
      // that had not decided yet — and so a marker that silently stopped
      // rendering fails here rather than quietly rebaselining.
      expect(find.byKey(kAccessUsersSectionKey), findsOneWidget);
      expect(find.byKey(kAccessUserNoPasswordBadgeKey('line')), findsOneWidget);
      expect(find.byKey(kAccessUserNoPasswordBadgeKey('admin')), findsNothing);
      expect(find.byKey(kAccessUserNoPasswordBadgeKey('linar')), findsNothing);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(_boundary),
        matchesGoldenFile('goldens/access_users_no_password_roster.png'),
      );
    });

    testWidgets('the create dialog says what ticking the box means',
        (tester) async {
      const size = Size(900, 900);
      _sizeView(tester, size);

      await tester.pumpWidget(_dialogHost(
        light,
        _AnsweringStore(roleRows: _roles(), userRows: _users()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessUsersCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessUserUsernameFieldKey), 'line');
      await tester.tap(find.byKey(kAccessUserNoPasswordToggleKey));
      await tester.pumpAndSettle();

      // The two claims the image makes, asserted as widgets first.
      expect(find.byKey(kAccessUserNoPasswordWarningKey), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(kAccessUserPasswordFieldKey))
              .enabled,
          isFalse,
          reason: 'a field that still looks typeable would be a picture of a '
              'dialog offering something it will ignore');
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/access_users_no_password_dialog.png'),
      );
    });
  });
}
