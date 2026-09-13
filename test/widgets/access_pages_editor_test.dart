/// The Pages block, at both of its mounts.
///
/// The behaviour under test is the one the whole feature turns on: **null and
/// the empty set are different answers**. Null is "no whitelist" — every page
/// on a role, *follow the role* on an account — and the empty set is a
/// whitelist naming nothing, which is the "block all" the feature was asked
/// for by name. A widget that could not express both, or that let one turn
/// into the other by accident, would be the feature not working.
///
/// The goldens are of the restricted mode with pages ticked, because the open
/// mode is the state the screen already had and the access-admin goldens
/// already show it.
///
/// To update: scripts/goldens.sh --update test/widgets/access_pages_editor_test.dart
///
/// The file carries no library-level `@Tags(['golden'])`. It used to, and that
/// tag skipped the whole file — twelve behavioural tests included — on every
/// platform but Linux, so the rules this widget exists to enforce were checked
/// nowhere a developer works. Only the goldens need Linux, so only the golden
/// group carries [goldenSkip], which is what that helper is for.
library;

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/menu.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_pages_editor.dart';

import '../helpers/golden_platform.dart';

/// A published page at [path].
AssetPage _page(String label, String path, {List<MenuItem> children = const []}) =>
    AssetPage(
      menuItem: MenuItem(
          label: label, path: path, icon: Icons.home, children: children),
      assets: const [],
      mirroringDisabled: false,
    );

/// A page manager with a small plant: two ordinary pages and a section with
/// one page under it, so the picker's indentation has something to show.
PageManager _plant() => PageManager(
      pages: {
        '/': _page('Home', '/'),
        '/fillet': _page('Filleting', '/fillet'),
        '/packing': _page('Packing', '/packing'),
      },
      prefs: _NullPrefs(),
    );

/// The picker never writes, so the store behind the manager is never used.
class _NullPrefs implements PreferencesApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The app shell's composition, in miniature: the plant's pages, one top-level
/// built-in, and an Advanced section holding a raised route and the access
/// screen.
///
/// The real `buildTopLevelMenuItems` is not used because it lives in the app
/// shell package, which this one does not depend on — but the *shape* is what
/// the picker has to get right, so the shape is what is reproduced: a section
/// with children, one entry inside it that `kRaisedRoutes` raises, and
/// `/advanced/access`, which is never offered.
List<MenuItem> _compose(PageManager manager) => [
      ...manager.getRootMenuItems(),
      const MenuItem(
          label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm),
      const MenuItem(
        label: 'Advanced',
        path: '/advanced',
        icon: Icons.settings,
        isSection: true,
        children: [
          MenuItem(
              label: 'Page Editor',
              path: '/advanced/page-editor',
              icon: Icons.edit),
          MenuItem(
              label: 'Access',
              path: '/advanced/access',
              icon: Icons.manage_accounts),
        ],
      ),
    ];

Widget _host({
  required ThemeData theme,
  required AccessPagesLevel level,
  required Set<String>? selection,
  required ValueChanged<Set<String>?> onChanged,
  PageManager? manager,
}) {
  return ProviderScope(
    overrides: [
      bootstrapPageManagerProvider.overrideWithValue(manager ?? _plant()),
      // The picker reads the whole navigation tree, so the test has to compose
      // one — the same hook `main()` overrides.
      menuComposerProvider.overrideWithValue(_compose),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AccessPagesEditor(
            level: level,
            owner: 'Operator',
            selection: selection,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
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
  group('the three states', () {
    testWidgets('null selects the open mode and shows no page list',
        (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: null,
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      expect(find.text(kAccessPagesOpenLabel(AccessPagesLevel.role)),
          findsOneWidget);
      // No rows at all: there is nothing to tick when there is no whitelist.
      expect(find.byKey(kAccessPagesRowKey('Operator', '/')), findsNothing);
    });

    testWidgets('choosing the restricted mode starts at block-all, not at all',
        (tester) async {
      Set<String>? latest = null;
      var calls = 0;
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: null,
        onChanged: (next) {
          latest = next;
          calls++;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessPagesRestrictedKey('Operator')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      // The empty set, not null and not every page. Ticking is then always a
      // deliberate widening.
      expect(latest, isNotNull);
      expect(latest, isEmpty);
    });

    testWidgets('switching back to open clears the list rather than keeping it',
        (tester) async {
      Set<String>? latest = {'/fillet'};
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const {'/fillet'},
        onChanged: (next) => latest = next,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessPagesOpenKey('Operator')));
      await tester.pumpAndSettle();

      // Null, not an empty set and not a remembered list: a hidden remembered
      // whitelist would come back the next time somebody flipped the radio.
      expect(latest, isNull);
    });
  });

  group('ticking', () {
    testWidgets('a tick adds exactly that path', (tester) async {
      Set<String>? latest;
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const <String>{},
        onChanged: (next) => latest = next,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessPagesRowKey('Operator', '/fillet')));
      await tester.pumpAndSettle();

      expect(latest, {'/fillet'});
    });

    testWidgets('unticking the last page leaves block-all, never null',
        (tester) async {
      Set<String>? latest;
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const {'/fillet'},
        onChanged: (next) => latest = next,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessPagesRowKey('Operator', '/fillet')));
      await tester.pumpAndSettle();

      // Empty, not null: unticking the last box must not silently reopen every
      // page, which is the direction that fails OPEN.
      expect(latest, isNotNull);
      expect(latest, isEmpty);
    });

    testWidgets('every destination is offered — built-ins included',
        (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const <String>{},
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      // The plant's pages, the top-level built-in, and the raised route under
      // Advanced. The last one is the bug this list grew for: the menu filter
      // has always hidden built-ins from a whitelisted session, so a picker
      // that offered only page-manager pages could not grant them back.
      for (final path in [
        '/',
        '/fillet',
        '/packing',
        '/alarm-view',
        '/advanced/page-editor',
      ]) {
        expect(find.byKey(kAccessPagesRowKey('Operator', path)), findsOneWidget,
            reason: '$path should be offered');
      }
    });

    testWidgets('the access screen is never offered', (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const <String>{},
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      // No whitelist state may hide it, so there is nothing to grant and a
      // tick box would be a control that does nothing. It is also the layer
      // that stops a bad whitelist becoming a station nobody can repair.
      expect(find.byKey(kAccessPagesRowKey('Operator', '/advanced/access')),
          findsNothing);
    });

    testWidgets('a section is a heading, not a tick box', (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const <String>{},
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      // A section is not a route, so a tick on one would have to mean "and its
      // children" — an inheritance rule evaluated against a stale copy of the
      // tree shape. It renders as a heading over the leaves instead.
      expect(find.byKey(kAccessPagesSectionKey('Operator', 'Advanced')),
          findsOneWidget);
      expect(find.byKey(kAccessPagesRowKey('Operator', '/advanced')),
          findsNothing);
    });

    testWidgets('a raised route says which group it still needs',
        (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const <String>{},
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      // The whitelist narrows and never grants: ticking the page editor for a
      // role without `configure` leaves it shut, and the row says so rather
      // than letting somebody find out on the floor.
      expect(
        find.text('/advanced/page-editor  ·  needs Configure'),
        findsOneWidget,
      );
      // An unraised page carries no such note — `operate` is what every
      // undeclared route resolves to and says nothing worth a line.
      expect(find.text('/fillet'), findsOneWidget);
    });

    testWidgets('a built-in can be ticked like any other page', (tester) async {
      Set<String>? latest;
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const {'/'},
        onChanged: (next) => latest = next,
      ));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(kAccessPagesRowKey('Operator', '/alarm-view')));
      await tester.pumpAndSettle();

      expect(latest, {'/', '/alarm-view'});
    });
  });

  group('stale entries', () {
    testWidgets('a stored path with no page is shown, not silently dropped',
        (tester) async {
      Set<String>? latest;
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: const {'/fillet', '/old-line'},
        onChanged: (next) => latest = next,
      ));
      await tester.pumpAndSettle();

      final stale = find.byKey(kAccessPagesStaleKey('Operator', '/old-line'));
      expect(stale, findsOneWidget,
          reason: 'a path can be stale because another station has not synced '
              'its pages yet, so Save must not be destructive');

      await tester.tap(
          find.descendant(of: stale, matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();

      expect(latest, {'/fillet'});
    });
  });

  group('the two mounts word the open option differently', () {
    testWidgets('a role sees every page; an account follows its role',
        (tester) async {
      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.role,
        selection: null,
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();
      expect(find.text('Sees every page'), findsOneWidget);

      await tester.pumpWidget(_host(
        theme: ThemeData.light(),
        level: AccessPagesLevel.user,
        selection: null,
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();
      // The distinction that stops a reader treating a blank account as
      // unrestricted.
      expect(find.text("Follows this account's role"), findsOneWidget);
      expect(find.text('Sees every page'), findsNothing);
    });
  });

  group('goldens', skip: goldenSkip, () {
    setUpAll(_loadRealFonts);

    final (light, dark) = muted();

    Future<void> shoot(
      WidgetTester tester, {
      required ThemeData theme,
      required AccessPagesLevel level,
      required String file,
    }) async {
      tester.view.physicalSize = const Size(720, 620);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(
        theme: theme,
        level: level,
        // The state the feature is about: restricted, with one page granted
        // and one stale path kept.
        selection: const {'/fillet', '/old-line'},
        onChanged: (_) {},
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AccessPagesEditor),
        matchesGoldenFile('goldens/$file'),
      );
    }

    testWidgets('role mount, light', (tester) async {
      await shoot(tester,
          theme: light,
          level: AccessPagesLevel.role,
          file: 'access_pages_role_light.png');
    });

    testWidgets('role mount, dark', (tester) async {
      // Dark as well as light, because nothing here may lean on
      // `colorScheme.outline` — neither scheme sets it, and a separator drawn
      // with it is invisible on one of the two.
      await shoot(tester,
          theme: dark,
          level: AccessPagesLevel.role,
          file: 'access_pages_role_dark.png');
    });

    testWidgets('account mount, light', (tester) async {
      await shoot(tester,
          theme: light,
          level: AccessPagesLevel.user,
          file: 'access_pages_user_light.png');
    });
  });
}
