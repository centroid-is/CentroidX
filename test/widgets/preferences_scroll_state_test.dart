import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/widgets/preferences.dart';
import 'package:tfc_dart/core/preferences.dart';

import '../helpers/test_helpers.dart';

/// Regression tests: editing a preference value and then scrolling the entry
/// out of view must not discard the unsaved edit.
///
/// The preferences UI nests two lazy scrollables:
///
///   PreferencesPage        ListView          (outer, page level)
///     +- SizedBox(600)
///          +- PreferencesKeysWidget
///               +- ListView                  (inner, one row per pref key)
///                    +- _PreferenceKeyTile   the editor lives in here
///
/// Both unmount children scrolled past the cache extent, disposing their
/// State — and re-attaching the section rebuilds every row from scratch. So
/// the in-progress text has to be held above both lists to survive.
///
/// A focused TextField pins its own row alive (EditableText requests
/// keep-alive while focused), which masks the bug: these tests drop focus
/// first, as tapping anywhere else in the UI would.
///
/// (The outer ListView + SizedBox(600) layout is itself the Bug 9 overflow
/// fix — see test/pages/preferences_test.dart. This is its side effect.)

/// Sorts into the middle of the key list, so it can be scrolled *above* as
/// well as below — matching the reported symptom.
const _jsonKey = 'm_page_editor';
const _fillerCount = 40;

Future<Preferences> _seededPreferences() async {
  final prefs = Preferences(database: null, secureStorage: FakeSecureStorage());
  await prefs.setString(_jsonKey, jsonEncode({'pages': [], 'version': 1}));
  for (var i = 0; i < _fillerCount; i++) {
    final n = i.toString().padLeft(2, '0');
    // Half sort before the JSON key, half after.
    await prefs.setString(i.isEven ? 'a_filler_$n' : 'z_filler_$n', 'value $i');
  }
  return prefs;
}

/// One instance per test: invalidating the provider must resolve to the *same*
/// Preferences, or a delete would be undone by re-seeding. Created lazily on
/// first read so it lives inside the test's async zone.
Future<Preferences>? _prefs;

Widget _wrap(Widget child) {
  return ProviderScope(
    overrides: [
      preferencesProvider
          .overrideWith((ref) => _prefs ??= _seededPreferences()),
      databaseProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

ScrollPosition _positionAt(WidgetTester tester, int index) =>
    tester.state<ScrollableState>(find.byType(Scrollable).at(index)).position;

/// Expands the JSON pref row, replaces the editor contents, then drops focus.
Future<void> _editJsonAndUnfocus(WidgetTester tester, String newText) async {
  await tester.tap(find.textContaining(_jsonKey));
  await tester.pumpAndSettle();

  // Only the expanded row has a TextField; the rest are collapsed.
  final field = find.byType(TextField);
  expect(field, findsOneWidget,
      reason: 'expanded JSON pref row should expose exactly one editor');

  await tester.enterText(field, newText);
  await tester.pumpAndSettle();
  expect(find.text(newText), findsOneWidget);

  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  setUp(Preferences.clearSecretCache);
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    _prefs = null;
  });

  group('unsaved preference edits survive scrolling', () {
    testWidgets('key list: scroll up above the edited row and back',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const SizedBox(height: 600, child: PreferencesKeysWidget())),
      );
      await tester.pumpAndSettle();

      // Scroll down to the mid-list JSON key.
      await tester.scrollUntilVisible(
        find.textContaining(_jsonKey),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final offset = _positionAt(tester, 0).pixels;

      const edited = '{"pages": [], "version": 1234}';
      await _editJsonAndUnfocus(tester, edited);

      // Scroll up above the edited row, far enough to unmount it.
      _positionAt(tester, 0).jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text(edited), findsNothing,
          reason: 'edited row should be scrolled out of view');

      _positionAt(tester, 0).jumpTo(offset);
      await tester.pumpAndSettle();

      expect(find.text(edited), findsOneWidget,
          reason: 'unsaved edit was discarded when the row scrolled offscreen');
    });

    testWidgets('page list: scroll above the keys section and back',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Mirrors PreferencesPage: a tall section above the fixed-height keys
      // section, all inside the page-level ListView.
      await tester.pumpWidget(
        _wrap(
          ListView(
            children: const [
              SizedBox(height: 900, child: Placeholder()),
              SizedBox(height: 600, child: PreferencesKeysWidget()),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scrollable 0 is the page list, 1 is the key list. Drive them by
      // position: a drag would go to whichever is innermost under the pointer.
      _positionAt(tester, 0).jumpTo(900);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining(_jsonKey),
        200,
        scrollable: find.byType(Scrollable).at(1),
      );
      await tester.pumpAndSettle();

      const edited = '{"pages": [], "version": 4242}';
      await _editJsonAndUnfocus(tester, edited);

      // Scroll the whole section out of view, then back to it.
      _positionAt(tester, 0).jumpTo(0);
      await tester.pumpAndSettle();

      _positionAt(tester, 0).jumpTo(900);
      await tester.pumpAndSettle();

      expect(find.text(edited), findsOneWidget,
          reason: 'unsaved edit was discarded when scrolling above the '
              'preferences keys section');
    });

    testWidgets('two rows stay expanded independently across a scroll',
        (tester) async {
      // Rows expand independently, so opening a second one must not collapse
      // the first when the list is rebuilt.
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const SizedBox(height: 600, child: PreferencesKeysWidget())),
      );
      await tester.pumpAndSettle();

      // Open the first two rows. Note .first must come after .descendant:
      // find.byType(Text).first would resolve globally before filtering.
      Finder titleOf(int i) => find
          .descendant(
              of: find.byType(ExpansionTile).at(i), matching: find.byType(Text))
          .first;
      await tester.tap(titleOf(0));
      await tester.pumpAndSettle();
      await tester.tap(titleOf(1));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(2),
          reason: 'both rows should be open at once');

      // Force a rebuild of the rows by scrolling away and back.
      final at = _positionAt(tester, 0);
      final offset = at.pixels;
      at.jumpTo(at.maxScrollExtent);
      await tester.pumpAndSettle();
      _positionAt(tester, 0).jumpTo(offset);
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(2),
          reason: 'opening the second row must not collapse the first');
    });
  });

  _deleteDialogTests();
}

/// The delete confirmation is used repeatedly when clearing out stale keys,
/// so the Delete button takes focus on open and Enter confirms it.
///
/// Confirming is observed through the local store rather than the rendered
/// list: the row is labelled "(Local)", so the dialog's confirm branch calls
/// remove() on the device-local store. Dismissing must leave it untouched.
void _deleteDialogTests() {
  group('delete preference confirmation', () {
    /// Opens the confirmation for the first row and returns its key.
    Future<String> openDeleteDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(const SizedBox(height: 600, child: PreferencesKeysWidget())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(FontAwesomeIcons.trash.data).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete preference'), findsOneWidget);

      final prompt = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .firstWhere((s) => s.startsWith('Delete "'));
      final key = RegExp(r'Delete "(.+)"\?').firstMatch(prompt)!.group(1)!;

      // Mirror the row into the local store so the confirm branch has
      // something observable to remove. Since v1.2 plan 01-05 that store is
      // the one the factory answers, not the `SharedPreferencesAsync` platform
      // instance — the widget writes through `localPreferencesProvider`.
      await createDeviceLocalPreferences().setString(key, 'seeded');
      return key;
    }

    testWidgets('Enter confirms the delete', (tester) async {
      final key = await openDeleteDialog(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Delete preference'), findsNothing,
          reason: 'Enter should activate the focused Delete button');
      expect(await createDeviceLocalPreferences().getString(key), isNull,
          reason: 'Enter should confirm, not merely dismiss, the dialog');
    });

    testWidgets('Escape dismisses without deleting', (tester) async {
      final key = await openDeleteDialog(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Delete preference'), findsNothing);
      expect(await createDeviceLocalPreferences().getString(key), 'seeded',
          reason: 'Escape must not delete anything');
    });
  });
}
