/// Binding a key to an access template, from the key's own card — and the
/// three claims the phase's honesty requirement rests on.
///
/// Spec §7b is deliberately fail-open: an unbound key is unrestricted, and so
/// is a member no bound template mentions. **Nothing enforces that somebody
/// remembered.** So enforcement is replaced by visibility, and this file is
/// where that visibility is checked rather than asserted in prose:
///
///  * a key names its template on its own card, and the binding is written
///    straight into the `users`-gated table — never into the key-mapping blob,
///    which is `configure`-classified,
///  * the keys nobody bound are one number and one filter away, dangling
///    bindings included, with **one** definition of "unbound" shared with the
///    guard,
///  * a `configure`-grade session cannot reach a binding through any of the
///    three paths that used to lead there, and — the half that closes the set
///    rather than enumerating it — no file in `lib/` names the table except
///    the one store that gates it,
///  * an exported key map carries no bindings, and both halves of the
///    import/export card say so before it matters.
///
/// The store is real, over an in-memory database, so "the row landed" is read
/// back from `access_key_binding` rather than from a mock's call log. The
/// preferences are real and **guarded**, so "Save wrote no binding" is driven
/// through the same `GuardedPreferences` the station runs.
library;

import 'dart:convert';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/key_mapping_sections.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A file picker that answers with paths the test controls.
///
/// `_onImport` and `_onExport` both go through `FilePicker.platform`, and the
/// import half is one of the three paths the closure test drives end to end —
/// so it has to be driven for real, dialog and all, rather than by calling
/// something underneath it.
class _FakePicker extends FilePicker {
  _FakePicker({this.pickPath, this.savePath});

  String? pickPath;
  String? savePath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('has no effect') bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final picked = pickPath;
    if (picked == null) return null;
    return FilePickerResult([
      PlatformFile(
        path: picked,
        name: picked.split(Platform.pathSeparator).last,
        size: File(picked).lengthSync(),
      )
    ]);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      savePath;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

const String _station = 'SVN-NES-OT-CL02';

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The engineer the `users` gate exists for. `/advanced/key-repository` is
/// behind `configure`, so this session can open the page, edit every key
/// mapping and press Save — and must not be able to change who may write what.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
      groups: {
        AccessGroup.operate,
        AccessGroup.configure,
        AccessGroup.users,
      },
    );

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _keyA = 'ST101.CN01';
const String _keyB = 'ST101.CN02';
const String _keyC = 'ST101.CN03';

KeyMappings _keys(List<String> names) => KeyMappings(nodes: {
      for (final name in names)
        name: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'GVL.$name')
            ..serverAlias = 'main_server',
        ),
    });

AccessTemplate _conveyor() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        'p_cfg_ManualFreq': AccessGroup.device,
        'p_cmd_JogFwd': AccessGroup.operate,
      },
    );

AccessTemplate _recipes() => AccessTemplate(
      name: 'recipes',
      rules: const {kWholeKeyMember: AccessGroup.setpoints},
    );

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

/// Asserts the text at [finder] renders at its **un-clipped** height.
///
/// `find.text` passing is not the same as the line being legible: an
/// ellipsised disclosure shipped past a green assertion in Phase 1. This lays
/// the same span out with no line limit at the width it actually got and
/// compares heights, so a `maxLines` that cuts the copy — or a box too short
/// for it — fails here rather than on a station.
void expectUnclipped(WidgetTester tester, Finder finder, {String? reason}) {
  final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)).first);
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textAlign: paragraph.textAlign,
    textScaler: paragraph.textScaler,
  )..layout(maxWidth: paragraph.size.width);
  expect(paragraph.size.height, painter.height,
      reason: reason ??
          'the line is clipped: it renders ${paragraph.size.height}px tall '
              'where the whole text needs ${painter.height}px at '
              '${paragraph.size.width}px wide');
}

void main() {
  late AppDatabase db;
  late _RecordingSink sink;
  late AccessSession session;
  late TagBindingResolver resolver;
  late Directory tmp;
  AccessTemplateStore? store;
  Preferences? prefs;
  GuardedConfigStore? configStore;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    // Force the schema before the first store call, so a read on an empty
    // table finds a table rather than nothing.
    await db.customSelect('SELECT 1').getSingle();
    sink = _RecordingSink();
    session = _withUsers();
    resolver = TagBindingResolver();
    store = null;
    prefs = null;
    tmp = await Directory.systemTemp.createTemp('key-binding-test');
    FilePicker.platform = _FakePicker();
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A store built outside the provider, for seeding and for reading back.
  AccessTemplateStore seeder() => AccessTemplateStore(
        db: db,
        session: _withUsers,
        audit: _RecordingSink(),
        station: _station,
      );

  /// The whole key-repository page, with a real guarded preferences store and
  /// a real template store over the in-memory database.
  Future<Widget> host({
    KeyMappings? keyMappings,
    bool noDatabase = false,
    bool reusePrefs = false,
  }) async {
    // The plant's wiring lives in `config_item` rows since v1.2 phase 2 plan
    // 06, so the page loads and saves through the configuration store. The
    // preferences store below still supplies `state_man_config`, which is not
    // this milestone's key.
    configStore = configStore != null && reusePrefs
        ? configStore
        : await createTestConfigStore(
            keyMappings: keyMappings ?? _keys([]),
            session: kConfiguringTestSession,
          );
    // Re-mounting the page over the **same** preferences is how the import
    // tests see what the operator sees on coming back to it: the import card
    // writes the blob, and the key section has never reloaded itself.
    final inner = prefs = reusePrefs && prefs != null
        ? prefs!
        : await createTestPreferences(
            keyMappings: keyMappings ?? _keys([]),
            // The fixture keys name `main_server`, so the config has to know
            // it — otherwise the card's server dropdown holds a value with no
            // matching item and asserts before any of this file's claims are
            // reached.
            stateManConfig: sampleStateManConfig(),
          );
    return ProviderScope(
      overrides: [
        // The **guarded** wrapper, not the raw store: the closure test's third
        // path is a preferences write, and driving it through anything less
        // than what the station runs would be checking a different thing.
        preferencesProvider.overrideWith((ref) async => GuardedPreferences(
              inner: inner,
              policy: ref.watch(accessPolicyProvider),
              session: () => session,
              audit: sink,
              station: _station,
              onDenied: (denial) => reportAccessDenial(ref, denial),
            )),
        configStoreProvider.overrideWith((ref) async => configStore!),
        databaseProvider.overrideWith((ref) async => null),
        stateManProvider
            .overrideWith((ref) => throw StateError('No StateMan in tests')),
        tagBindingResolverProvider.overrideWith((ref) => resolver),
        accessTemplateStoreProvider.overrideWith((ref) async {
          if (noDatabase) return null;
          return store = AccessTemplateStore(
            db: db,
            session: () => session,
            audit: sink,
            station: _station,
            onDenied: (denial) => reportAccessDenial(ref, denial),
          );
        }),
        // Deliberately NOT overriding `accessTemplatesProvider`: the real
        // loader is what fills the resolver, so a write followed by an
        // invalidate has to actually become visible.
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AccessDeniedPrompt(child: KeyRepositoryContent()),
        ),
      ),
    );
  }

  /// Opens [name]'s card so its body — and the template control — is built.
  Future<void> expand(WidgetTester tester, String name) async {
    await revealKeyCard(tester, name);
    await tester.ensureVisible(find.text(name).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
  }

  /// Picks [template] (or "None") on [name]'s dropdown.
  Future<void> choose(
      WidgetTester tester, String name, String? template) async {
    await tester.ensureVisible(find.byKey(kKeyAccessTemplateDropdownKey(name)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kKeyAccessTemplateDropdownKey(name)));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(kKeyAccessTemplateOptionKey(name, template)).last);
    await tester.pumpAndSettle();
  }

  /// The binding table, read straight back.
  Future<Map<String, String>> bindings() => seeder().bindings();

  /// Taps something whose handler does **real** file I/O.
  ///
  /// `dart:io`'s async reads never complete inside a widget test's fake-async
  /// zone, so a plain `tap` + `pumpAndSettle` on the import or export button
  /// returns before the file has been touched — and, because no frame is
  /// scheduled in the meantime, `pumpAndSettle` returns after a single pump
  /// having settled nothing. Both halves of the import/export card have to be
  /// driven end to end here, so the tap happens inside [WidgetTester.runAsync]
  /// where the real event loop runs.
  Future<void> tapWithIo(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  /// The one [Text] inside [key]'s badge.
  String badgeText(WidgetTester tester, String key) => tester
      .widget<Text>(find
          .descendant(
              of: find.byKey(kKeyBindingBadgeKey(key)),
              matching: find.byType(Text))
          .first)
      .data!;

  // -------------------------------------------------------------------------
  // Task 1 — the control
  // -------------------------------------------------------------------------

  group('the binding control', () {
    testWidgets('binds a key, and the row lands in the binding table',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();

      await expand(tester, _keyA);
      await choose(tester, _keyA, 'conveyor');

      expect(await bindings(), {_keyA: 'conveyor'});
    });

    testWidgets('a binding is not an unsaved change, and Save writes none',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      final before = jsonEncode(configStore!.inner.keyMappings.toJson());

      await expand(tester, _keyA);
      await choose(tester, _keyA, 'conveyor');

      // The Save button is the page's own statement about whether anything is
      // pending. A binding must not move it: the other fields on this card are
      // parts of one `configure`-gated JSON blob, and a binding is a row in a
      // `users`-gated table.
      expect(find.text('All Changes Saved'), findsOneWidget);
      expect(find.text('Save Key Mappings'), findsNothing);
      expect(jsonEncode(configStore!.inner.keyMappings.toJson()), before,
          reason: 'the binding must not have touched the key mappings');
    });

    testWidgets('clearing a binding removes the row', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();

      await expand(tester, _keyA);
      await choose(tester, _keyA, null);

      expect(await bindings(), isEmpty);
    });

    testWidgets('the card names the template that governs the key',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.create(_recipes());
      await seed.bind(_keyA, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      expect(badgeText(tester, _keyA), 'conveyor');
      // And the one nobody bound says so, because templates exist to bind to.
      expect(badgeText(tester, _keyB), kKeyBindingUnboundBadge);
    });

    testWidgets(
        'a dangling binding renders as a gap, never as an ordinary binding',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');
      // Somebody removed the row by hand. 04-03 blocks the delete while a key
      // is bound, so this is the `psql` case the resolver's fail-open arm and
      // this surface exist for.
      await db.customStatement(
          "DELETE FROM access_template WHERE name = 'conveyor'");

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();

      expect(badgeText(tester, _keyA), kKeyBindingMissingBadge,
          reason: 'a key naming a template nobody can find is a gap');

      await expand(tester, _keyA);
      expect(find.text(kKeyAccessTemplateMissingLabel('conveyor')),
          findsAtLeastNWidgets(1),
          reason: 'the name is still shown — it is what has to be fixed — but '
              'marked as missing rather than offered as a binding');
      expect(find.text(kKeyAccessTemplateMissingNote), findsOneWidget);
    });

    testWidgets(
        'a session without users sees a live dropdown, is told what it needs, '
        'and changes nothing', (tester) async {
      await seeder().create(_conveyor());
      session = _anonymous();

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      await expand(tester, _keyA);

      // Nothing is greyed: the control is live for every session.
      final dropdown = tester.widget<DropdownButton<String?>>(
          find.byKey(kKeyAccessTemplateDropdownKey(_keyA)));
      expect(dropdown.onChanged, isNotNull,
          reason: 'a control a session may not use still shows its value, is '
              'tappable, and explains what it needs');

      await choose(tester, _keyA, 'conveyor');

      expect(await bindings(), isEmpty,
          reason: 'the refusal must leave the table alone');
      expect(
          find.text(kAccessDeniedGroupNote(AccessGroup.users)), findsOneWidget,
          reason: 'the shared prompt names the group, once');
    });

    testWidgets(
        'a configure-only session is refused too — that is the whole point of '
        'the ruling', (tester) async {
      await seeder().create(_conveyor());
      session = _configureOnly();

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      await expand(tester, _keyA);
      await choose(tester, _keyA, 'conveyor');

      expect(await bindings(), isEmpty);
      expect(
          find.text(kAccessDeniedGroupNote(AccessGroup.users)), findsOneWidget);
    });

    testWidgets(
        'with no database it says so in one line, not an empty dropdown',
        (tester) async {
      await tester.pumpWidget(
          await host(keyMappings: _keys([_keyA]), noDatabase: true));
      await tester.pumpAndSettle();
      await expand(tester, _keyA);

      expect(find.text(kKeyAccessTemplateNoDatabaseNote), findsOneWidget);
      expect(find.byKey(kKeyAccessTemplateDropdownKey(_keyA)), findsNothing);
      expect(find.byKey(kKeyBindingBadgeKey(_keyA)), findsNothing,
          reason: 'a station that cannot tell you must not claim "unbound"');
    });

    testWidgets(
        'with a database and no templates the card says there is nothing to '
        'bind to', (tester) async {
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      await expand(tester, _keyA);

      expect(find.text(kKeyAccessTemplateNoTemplatesNote), findsOneWidget);
      expect(find.byKey(kKeyBindingBadgeKey(_keyA)), findsNothing,
          reason: 'with nothing to bind to, an "Unbound" badge on every card '
              'is noise that trains people to ignore it — the shipped state is '
              'reported once, by the section header count');
    });

    testWidgets('binding one key leaves the others alone', (tester) async {
      await seeder().create(_conveyor());
      await tester
          .pumpWidget(await host(keyMappings: _keys([_keyA, _keyB, _keyC])));
      await tester.pumpAndSettle();

      await expand(tester, _keyB);
      await choose(tester, _keyB, 'conveyor');

      expect(await bindings(), {_keyB: 'conveyor'});
    });

    test('the control added no third key_mappings write site', () {
      final source = File('lib/pages/key_repository.dart').readAsStringSync();
      // Since v1.2 phase 2 plan 06 the two sites write rows through the
      // guarded configuration store rather than the preference blob. The
      // count is what this test is about, not the spelling.
      final sites = RegExp(r"store\.saveKeyMappings\(").allMatches(source);
      expect(sites, hasLength(2),
          reason: 'the two pre-existing sites are `_saveKeyMappings` and '
              '`_onImport`. A binding is a row in a `users`-gated table, not a '
              'field in a `configure`-gated set of rows — a third site here '
              'would be the 2026-08-30 ruling undone.');
      expect(RegExp(r"setString\('key_mappings'").allMatches(source), isEmpty,
          reason: 'the blob is not a write path any more');
    });
  });

  // -------------------------------------------------------------------------
  // Task 2 — the keys nobody bound
  // -------------------------------------------------------------------------

  /// The header count, by the text it actually renders.
  String countText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(kUnboundKeysCountKey)).data!;

  Future<void> toggleUnboundFilter(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(kUnboundKeysFilterKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kUnboundKeysFilterKey));
    await tester.pumpAndSettle();
  }

  group('unbound keys are findable', () {
    testWidgets('the count reports bound, unbound and dangling together',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.create(_recipes());
      await seed.bind(_keyA, 'conveyor');
      await seed.bind(_keyB, 'recipes');
      await seed.unbind(_keyB);
      // _keyB is unbound; _keyC gets a binding whose template is then removed
      // by hand, so it is a gap wearing a template name.
      await seed.bind(_keyC, 'recipes');
      await db.customStatement(
          "DELETE FROM access_template WHERE name = 'recipes'");

      await tester
          .pumpWidget(await host(keyMappings: _keys([_keyA, _keyB, _keyC])));
      await tester.pumpAndSettle();

      expect(countText(tester), kUnboundKeysCount(2, 3),
          reason: 'the dangling key counts as unbound, because it is');
    });

    testWidgets('the shipped state — no templates — is stated as the default '
        'rather than rendered as a zero', (tester) async {
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      expect(countText(tester), kUnboundKeysNoTemplates(2));
      expect(kUnboundKeysNoTemplates(2), isNot(kUnboundKeysCount(2, 2)),
          reason: '"nothing is configured yet" and "two keys were forgotten" '
              'are different claims and only one is true on a fresh station');
    });

    testWidgets('with every key bound the count says so in words',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');
      await seed.bind(_keyB, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      expect(countText(tester), kUnboundKeysAllBound(2));
      expect(kUnboundKeysAllBound(2), isNot(kUnboundKeysCount(0, 2)),
          reason: 'a bare 0 reads as "not computed"');
      expect(kUnboundKeysAllBound(2), isNot(kUnboundKeysNoTemplates(2)));
    });

    testWidgets('the filter shows exactly the keys unboundKeys names',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.create(_recipes());
      await seed.bind(_keyA, 'conveyor');
      await seed.bind(_keyC, 'recipes');
      // `bind` refuses a name with no row, so the dangling case is made the
      // way it actually happens: somebody removes the template in `psql`.
      await db.customStatement(
          "DELETE FROM access_template WHERE name = 'recipes'");

      const all = [_keyA, _keyB, _keyC];
      await tester.pumpWidget(await host(keyMappings: _keys(all)));
      await tester.pumpAndSettle();

      await toggleUnboundFilter(tester);

      // One definition, checked: whatever the resolver says is unbound is
      // exactly what the list shows. A second predicate here is how the filter
      // and the guard start disagreeing (T-04-46).
      final expected = resolver.unboundKeys(all).toSet();
      expect(expected, {_keyB, _keyC},
          reason: 'the dangling binding is one of them');
      for (final key in all) {
        expect(find.text(key),
            expected.contains(key) ? findsOneWidget : findsNothing,
            reason: '$key');
      }
    });

    testWidgets('the filter composes with the search rather than replacing it',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind('ST101.PUMP', 'conveyor');

      await tester.pumpWidget(await host(
          keyMappings: _keys([_keyA, _keyB, 'ST101.PUMP', 'ST201.PUMP'])));
      await tester.pumpAndSettle();

      await toggleUnboundFilter(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Search keys...'), 'pump');
      await tester.pumpAndSettle();

      expect(find.text('ST201.PUMP'), findsOneWidget,
          reason: 'matches the search and is unbound');
      expect(find.text('ST101.PUMP'), findsNothing,
          reason: 'matches the search but is bound');
      expect(find.text(_keyA), findsNothing,
          reason: 'unbound but does not match the search');
    });

    testWidgets('turning the filter off brings the bound keys back',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      await toggleUnboundFilter(tester);
      expect(find.text(_keyA), findsNothing);
      await toggleUnboundFilter(tester);
      expect(find.text(_keyA), findsOneWidget);
    });

    testWidgets('binding a key from its card moves the count, with no reload',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();
      expect(countText(tester), kUnboundKeysCount(2, 2));

      await expand(tester, _keyA);
      await choose(tester, _keyA, 'conveyor');

      expect(countText(tester), kUnboundKeysCount(1, 2),
          reason: 'the write, the invalidate and the count are one path');
    });

    testWidgets('with no database there is no count and no filter',
        (tester) async {
      await tester.pumpWidget(
          await host(keyMappings: _keys([_keyA]), noDatabase: true));
      await tester.pumpAndSettle();

      // Not a second copy of "this station has no database" — the templates
      // section below says it once, and a number nobody can compute must not
      // be rendered as a zero.
      expect(find.byKey(kUnboundKeysCountKey), findsNothing);
      expect(find.byKey(kUnboundKeysFilterKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Task 2 — the closure, in two halves
  // -------------------------------------------------------------------------

  group('no configure-grade path reaches a binding', () {
    /// One binding, and the session the ruling exists for.
    Future<Map<String, String>> seedOneBinding() async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');
      session = _configureOnly();
      return seed.bindings();
    }

    testWidgets('(a) the page\'s own Save leaves the table byte-unchanged',
        (tester) async {
      final before = await seedOneBinding();
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      // A real edit, so Save actually writes.
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      expect(find.text('Key mappings saved successfully!'), findsOneWidget,
          reason: 'the save has to succeed, or this asserts nothing');
      expect(await bindings(), before);
    });

    testWidgets('(b) confirm-and-import leaves the table byte-unchanged, '
        'including the row it orphaned', (tester) async {
      final before = await seedOneBinding();
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();

      // A file that does **not** contain _keyA, so importing it orphans the
      // binding row rather than leaving it merely untouched.
      final file = File('${tmp.path}/km.json')
        ..writeAsStringSync(jsonEncode(_keys(['ST301.NEW']).toJson()));
      (FilePicker.platform as _FakePicker).pickPath = file.path;

      await tester.ensureVisible(find.text('Import'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.text('Import'));
      await tapWithIo(
          tester, find.widgetWithText(TextButton, 'Import').hitTestable());

      expect(await bindings(), before,
          reason: 'an import that removed the key must not remove its binding '
              'either: silently unbinding is the failure spec §7d forbids on '
              'delete, and the orphan is what Task 2\'s surface reports');
    });

    testWidgets('(c) a preferences write of an arbitrary key leaves the table '
        'byte-unchanged', (tester) async {
      final before = await seedOneBinding();
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
          tester.element(find.byType(KeyRepositoryContent)));
      final guarded = await container.read(preferencesProvider.future);
      // A key this session is *allowed* to write — `page_editor_data` is
      // `configure` in `kPrefAccessRules`. A denied write proving nothing
      // happened would be the weaker test; this one succeeds and still cannot
      // reach the binding.
      await guarded.setString('page_editor_data', '{"pages":[]}');
      expect(await guarded.getString('page_editor_data'), '{"pages":[]}');

      expect(await bindings(), before);
    });

    test('the structural half: the binding table is named in one file',
        () async {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Comment lines are stripped before the search. Prose *about* the
        // table is not a path *to* it — three files explain the ruling in
        // their doc comments — and a mechanical gate that a reader has to
        // classify by hand stops being mechanical.
        final code = entity
            .readAsLinesSync()
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        // Separators normalised — the expectation below spells its path with
        // forward slashes, and listSync gives backslashes on Windows.
        if (code.contains('access_key_binding')) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(offenders, ['lib/core/access_template_store.dart'],
          reason: 'The 2026-08-30 ruling moved bindings out of the '
              '`configure`-classified key-mapping blob and into their own '
              'table so that no `configure`-grade path could reach them. '
              'Driving three named paths pins three paths; this is what '
              'closes the set — a fourth cannot be added without naming the '
              'table, and naming it fails here.\n'
              '\n'
              'What it does NOT cover: a caller reaching the table through '
              'Drift\'s generated accessor (`accessKeyBindingTable`) rather '
              'than the literal string. That is why 04-03 keeps the store\'s '
              'own `key_mappings|CASCADE` grep, and why this is one half of a '
              'pair rather than a single test.');
    });

    test('no bulk-bind action exists anywhere in lib/', () async {
      // Spec §7b: "Binding is explicit, per key, always. No inference from
      // asset type, no pattern matching on key names." A "bind all" control is
      // that inference one dialog removed. The bulk path is the MCP tools,
      // where an agent proposes explicit per-key bindings and a human holding
      // `users` approves them.
      final bulk = RegExp(
          r'bindAll|bindMany|bindEvery|bindByPattern|bindMatching|autoBind',
          caseSensitive: false);
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (bulk.hasMatch(entity.readAsStringSync())) offenders.add(entity.path);
      }
      expect(offenders, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Task 3 — an exported key map carries no bindings, and says so
  // -------------------------------------------------------------------------

  group('the import/export card discloses what the file does not carry', () {
    testWidgets('the import confirmation says it before the import runs, '
        'un-ellipsised', (tester) async {
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();

      final file = File('${tmp.path}/km.json')
        ..writeAsStringSync(jsonEncode(_keys(['ST301.NEW']).toJson()));
      (FilePicker.platform as _FakePicker).pickPath = file.path;

      await tester.ensureVisible(find.text('Import'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.text('Import'));

      final body = find.textContaining(kKeyMappingsImportBindingsNote);
      expect(body, findsOneWidget,
          reason: 'the disclosure comes before the button, not after it');
      // `find.text` passing is not the same as the line being readable.
      expectUnclipped(tester, body);
      expect(tester.getRect(body).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(Dialog).first).bottom),
          reason: 'the whole message has to be inside the dialog, not merely '
              'un-ellipsised inside a box that is itself cut off');
    });

    testWidgets('the export result says the same, un-ellipsised',
        (tester) async {
      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      (FilePicker.platform as _FakePicker).savePath = '${tmp.path}/out.json';

      await tester.ensureVisible(find.text('Export'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.text('Export'));

      final line = find.text(kKeyMappingsExportBindingsNote);
      expect(line, findsOneWidget);
      // The snackbar is the likelier ellipsis of the two: one fixed-width
      // strip with no room to grow sideways.
      expectUnclipped(tester, line);
    });

    testWidgets('the exported file carries no bindings key', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA])));
      await tester.pumpAndSettle();
      final out = '${tmp.path}/out.json';
      (FilePicker.platform as _FakePicker).savePath = out;

      await tester.ensureVisible(find.text('Export'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.text('Export'));

      final written =
          jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
      expect(written.keys.toList(), KeyMappings(nodes: {}).toJson().keys.toList(),
          reason: 'the file\'s top-level shape is exactly what it was before '
              'this phase. An export/import pair that carried bindings would '
              'put an authorization write behind a `configure`-gated card, in '
              'portable form — the path the 2026-08-30 ruling closed.');
      expect(File(out).readAsStringSync(), isNot(contains('conveyor')),
          reason: 'the bound template\'s name is nowhere in the file');
    });

    testWidgets('after an import the unbound count agrees with what the '
        'disclosure promised', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_keyA, 'conveyor');

      await tester.pumpWidget(await host(keyMappings: _keys([_keyA, _keyB])));
      await tester.pumpAndSettle();
      expect(countText(tester), kUnboundKeysCount(1, 2));

      // Three keys, none of them the one that was bound.
      final file = File('${tmp.path}/km.json')
        ..writeAsStringSync(jsonEncode(
            _keys(['ST301.A', 'ST301.B', 'ST301.C']).toJson()));
      (FilePicker.platform as _FakePicker).pickPath = file.path;

      await tester.ensureVisible(find.text('Import'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.text('Import'));
      await tapWithIo(
          tester, find.widgetWithText(TextButton, 'Import').hitTestable());

      // The page does not reload its own key list after an import (it never
      // has), so this is what the operator sees on coming back to it.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(await host(reusePrefs: true));
      await tester.pumpAndSettle();

      expect(countText(tester), kUnboundKeysCount(3, 3),
          reason: 'every key that arrived from the file is unbound, which is '
              'exactly what the confirmation said would happen');
      expect(await bindings(), {_keyA: 'conveyor'},
          reason: 'and the row for the key the import removed is still there — '
              'orphaned, surfaced, never silently deleted');
    });

    test('the decision not to export bindings is written at _onExport, with '
        'its reasoning', () {
      final source = File('lib/pages/key_repository.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _onExport');
      final end = source.indexOf('Future<void> _onImport');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      for (final phrase in [
        // what was decided
        'bindings',
        // why: the gate the card sits behind, and the one a binding needs
        'configure',
        'users',
        // and where the supported path is instead
        'bind_key_access_template',
      ]) {
        expect(body, contains(phrase),
            reason: 'the next person who thinks "we should round-trip the '
                'whole configuration" has to find the answer here rather than '
                'the omission. Missing: "$phrase".');
      }
    });
  });
}
