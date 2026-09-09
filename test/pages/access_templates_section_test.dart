/// The key repository's access-templates section (spec §7d).
///
/// MCP does the plant in a pass; this section is where somebody works out what
/// the rules should *be*. So the claims here are about **legibility and the
/// boundary**, not about the store — 04-03's own file already drives every
/// write through a `configure`-only session and reads the row counts back from
/// the database.
///
/// What is asserted here that nothing else can assert:
///
///  * a session without `users` sees every control, may press every one of
///    them, and is told what it needs — nothing is greyed,
///  * the delete dialog shows the bound keys **before** the confirm, and offers
///    no confirm at all while any key is bound,
///  * the rename dialog says, in words, that the bound keys become
///    unrestricted — the only warning that exists, since 04-03's `rename`
///    deliberately does not re-point them,
///  * rendering the list costs **no** per-template database query: the counts
///    come from the resolver's in-memory snapshot,
///  * a station with no database says why, rather than showing an empty list
///    that reads as "no templates exist".
///
/// The store is real, over an in-memory database, so a test that says "the
/// template was created" is reading the table rather than a mock's call log.
/// The recording subclass exists for the one claim a table cannot answer:
/// which methods were *called*.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/access_templates_section.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';
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

/// The real store, over the real (in-memory) tables, with a call log.
///
/// Subclassed rather than faked: the claims about *what happened* must be read
/// back from the tables, and only the claim about **which methods the section
/// reached for** needs a log. A hand-written fake would have let the
/// no-query-per-template test pass while the section quietly asked the
/// database something else.
class _RecordingStore extends AccessTemplateStore {
  _RecordingStore({
    required super.db,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
  });

  final List<String> calls = [];

  @override
  Future<List<AccessTemplate>> list() {
    calls.add('list');
    return super.list();
  }

  @override
  Future<Map<String, String>> bindings() {
    calls.add('bindings');
    return super.bindings();
  }

  @override
  Future<List<String>> keysBoundTo(String templateName) {
    calls.add('keysBoundTo:$templateName');
    return super.keysBoundTo(templateName);
  }

  @override
  Future<void> update(
    AccessTemplate value, {
    String origin = 'operator',
    String? reason,
  }) {
    calls.add('update:${value.name}:${AccessTemplate.encodeRules(value.rules)}');
    return super.update(value, origin: origin, reason: reason);
  }
}

/// A store whose `delete` loses the race: `keysBoundTo` answered "none", and
/// between that answer and the statement another station bound a key.
class _RacingStore extends _RecordingStore {
  _RacingStore({
    required super.db,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
  });

  /// What the delete throws, once. Cleared after it fires, so a second attempt
  /// behaves normally.
  List<String>? raceKeys;

  @override
  Future<void> delete(
    String name, {
    String origin = 'operator',
    String? reason,
  }) async {
    final keys = raceKeys;
    if (keys != null) {
      raceKeys = null;
      throw TemplateInUseException(name, keys);
    }
    return super.delete(name, origin: origin, reason: reason);
  }
}


/// A `StateMan` that answers one fixed value per key and counts the reads.
///
/// The count is the point of one of these tests: the suggestion list must cost
/// **one** read however many keys are bound.
class _FakeStateMan implements StateMan {
  _FakeStateMan({required this.values, this.readThrows});

  final Map<String, DynamicValue> values;
  final Object? readThrows;
  final List<String> reads = [];

  @override
  String resolveKey(String key) => key;

  @override
  Future<DynamicValue> read(String key) async {
    reads.add(key);
    if (readThrows != null) throw readThrows!;
    final value = values[key];
    if (value == null) throw StateError('no value for $key');
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not in test scope',
      );
}

/// The whole-struct value one conveyor key carries.
DynamicValue _struct(Map<String, Object?> members) {
  final value = DynamicValue();
  members.forEach((key, member) => value[key] = DynamicValue(value: member));
  return value;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The engineer the `users` gate exists for: they can open this page — the
/// route is `configure` — and must not be able to re-scope who may write what.
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
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _conveyorKeyA = 'ST101.CN01';
const String _conveyorKeyB = 'ST101.CN02';

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

void main() {
  late AppDatabase db;
  late _RecordingSink sink;
  late AccessSession session;
  late TagBindingResolver resolver;
  _RecordingStore? store;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    // Force the schema before the first store call, so a read on an empty
    // table finds a table rather than nothing.
    await db.customSelect('SELECT 1').getSingle();
    sink = _RecordingSink();
    session = _withUsers();
    resolver = TagBindingResolver();
    store = null;
  });

  tearDown(() => db.close());

  List<Override> overrides({
    AccessTemplateStore? withStore,
    bool noDatabase = false,
    Future<List<AccessTemplate>>? templates,
  }) =>
      [
        tagBindingResolverProvider.overrideWith((ref) => resolver),
        accessTemplateStoreProvider.overrideWith((ref) async {
          if (noDatabase) return null;
          return withStore ??
              (store = _RecordingStore(
                db: db,
                session: () => session,
                audit: sink,
                station: 'SVN-NES-OT-CL02',
                // The same wiring the real provider does, so a refusal here
                // reaches the shared prompt exactly as it does on the station.
                onDenied: (denial) => reportAccessDenial(ref, denial),
              ));
        }),
        // Deliberately NOT overriding `accessTemplatesProvider`: the real
        // loader is what fills the resolver, and a test that stubbed it would
        // stop checking that a write followed by an invalidate is visible.
        if (templates != null)
          accessTemplatesProvider.overrideWith((ref) => templates),
      ];

  /// The section on its own, under a real [AccessDeniedPrompt] — the prompt a
  /// refusal has to reach, rather than a listener of the test's own.
  Widget host(List<Override> o) => ProviderScope(
        overrides: o,
        child: const MaterialApp(
          home: Scaffold(
            body: AccessDeniedPrompt(child: AccessTemplatesSection()),
          ),
        ),
      );

  /// A store built outside the provider, for seeding rows before the pump.
  AccessTemplateStore seeder() => AccessTemplateStore(
        db: db,
        session: () => _withUsers(),
        audit: sink,
        station: 'SVN-NES-OT-CL02',
      );

  // -------------------------------------------------------------------------
  // The list
  // -------------------------------------------------------------------------

  group('the list', () {
    testWidgets('names every template with its rule count and how many keys '
        'it governs', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.create(_recipes());
      await seed.bind(_conveyorKeyA, 'conveyor');
      await seed.bind(_conveyorKeyB, 'conveyor');

      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      expect(find.text(kAccessTemplatesHeadline), findsOneWidget);
      expect(find.text('conveyor'), findsOneWidget);
      expect(find.text('recipes'), findsOneWidget);
      expect(find.text(kAccessTemplateSummary(2, 2)), findsOneWidget,
          reason: 'the conveyor template: two rules, two keys');
      expect(find.text(kAccessTemplateSummary(1, 0)), findsOneWidget,
          reason: 'recipes: one whole-key rule, nothing bound');
    });

    testWidgets(
        'the bound-key counts come from the resolver: rendering N templates '
        'asks the database nothing per template', (tester) async {
      final seed = seeder();
      for (var i = 0; i < 5; i++) {
        await seed.create(AccessTemplate(
            name: 'template$i', rules: const {'m': AccessGroup.device}));
        await seed.bind('KEY$i', 'template$i');
      }

      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      // The load is two queries for the whole section — `list` and `bindings`,
      // in one `setSnapshot`. What must not appear is a `keysBoundTo` per
      // template: five here, and a per-frame cost on a real station.
      expect(store!.calls.where((c) => c.startsWith('keysBoundTo')), isEmpty,
          reason: 'the store\'s keysBoundTo reads the database and is reserved '
              'for the delete block. Rendering must use the resolver.');
      expect(store!.calls, ['list', 'bindings']);

      // The list is bounded and lazy, so not every tile is built at once —
      // scrolling to the end must not turn the counts into queries either.
      await tester.drag(
          find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(store!.calls, ['list', 'bindings']);
      expect(find.text(kAccessTemplateSummary(1, 1)), findsAtLeastNWidgets(1));
    });

    testWidgets('while the templates are loading it renders nothing, not a '
        'spinner that flashes', (tester) async {
      // A load that never lands. Matching AccessLockBadge's and
      // AccessStatusAction's ruling: nothing, rather than a spinner for one
      // frame on every station that has no templates.
      final never = Completer<List<AccessTemplate>>().future;
      await tester.pumpWidget(host(overrides(templates: never)));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessTemplatesSectionKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(kAccessTemplatesHeadline), findsNothing);
    });

    testWidgets('with no database it says why, rather than showing an empty '
        'list that reads as "no templates"', (tester) async {
      await tester.pumpWidget(host(overrides(noDatabase: true)));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessTemplatesNoDatabaseKey), findsOneWidget);
      expect(find.text(kAccessTemplatesNoDatabaseNote), findsOneWidget);
      expect(find.text(kAccessTemplatesEmptyNote), findsNothing,
          reason: '"no templates yet" is a different claim from "this station '
              'cannot tell you", and only one of them is true here');
    });

    testWidgets('with a database and no templates it says so', (tester) async {
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      expect(find.text(kAccessTemplatesEmptyNote), findsOneWidget);
      expect(find.byKey(kAccessTemplatesNoDatabaseKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Create
  // -------------------------------------------------------------------------

  group('create', () {
    testWidgets('a users session creates a template and the list shows it',
        (tester) async {
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessTemplatesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessTemplateNameFieldKey), 'baader');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text('baader'), findsOneWidget);
      expect((await seeder().list()).map((t) => t.name), ['baader']);
    });

    testWidgets('a duplicate name is refused before the store is called',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessTemplatesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessTemplateNameFieldKey), 'conveyor');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessTemplateDuplicateNameNote), findsOneWidget);
      expect(store!.calls, isEmpty);
      expect((await seeder().list()).length, 1);
    });

    testWidgets('a name the store could not store is refused before the store '
        'is called', (tester) async {
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessTemplatesCreateKey));
      await tester.pumpAndSettle();
      // Untrimmed — `AccessTemplate.isValidTemplateName` refuses it, and a
      // typo is not an authorization event.
      await tester.enterText(
          find.byKey(kAccessTemplateNameFieldKey), ' conveyor ');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessTemplateInvalidNameNote), findsOneWidget);
      expect(store!.calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The users gate — nothing is greyed, and nothing gets through
  // -------------------------------------------------------------------------

  group('the users gate (T-04-37)', () {
    testWidgets('an anonymous session sees the create control enabled, and '
        'pressing it through says the users permission is what is missing',
        (tester) async {
      session = _anonymous();
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      final create =
          tester.widget<OutlinedButton>(find.byKey(kAccessTemplatesCreateKey));
      expect(create.onPressed, isNotNull,
          reason: 'no control on this section is greyed for lack of a '
              'permission — it is pressed, and then explained');

      await tester.tap(find.byKey(kAccessTemplatesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessTemplateNameFieldKey), 'baader');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget);
      expect(await seeder().list(), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a configure-only session — the one the gate exists for — is '
        'refused the same way', (tester) async {
      session = _configureOnly();
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessTemplatesCreateKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kAccessTemplateNameFieldKey), 'baader');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget,
          reason: 'spec §7c: somebody who can edit a page must not be able to '
              're-scope who may write what');
      expect(await seeder().list(), isEmpty);
    });

    testWidgets('the delete control is enabled for a session that cannot use '
        'it, and explains itself when pressed', (tester) async {
      await seeder().create(_conveyor());
      session = _anonymous();
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      final delete = tester.widget<IconButton>(
          find.byKey(kAccessTemplateDeleteKey('conveyor')));
      expect(delete.onPressed, isNotNull);

      await tester.tap(find.byKey(kAccessTemplateDeleteKey('conveyor')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget);
      expect((await seeder().list()).length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Rename — the only warning a silent unrestriction gets
  // -------------------------------------------------------------------------

  group('rename', () {
    testWidgets('with keys bound, the dialog says they become unrestricted and '
        'names them', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_conveyorKeyA, 'conveyor');
      await seed.bind(_conveyorKeyB, 'conveyor');

      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateRenameKey('conveyor')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessTemplateRenameWarningKey), findsOneWidget);
      expect(find.text(kAccessTemplateRenameWarning('conveyor', 2)),
          findsOneWidget);
      expect(find.text(_conveyorKeyA), findsOneWidget);
      expect(find.text(_conveyorKeyB), findsOneWidget);

      // A warning, not a block.
      final confirm =
          tester.widget<FilledButton>(find.byKey(kAccessTemplateConfirmKey));
      expect(confirm.onPressed, isNotNull);
    });

    testWidgets('with nothing bound there is no warning', (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateRenameKey('conveyor')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessTemplateRenameWarningKey), findsNothing);
    });

    testWidgets('renaming moves the name and the list follows', (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessTemplateRenameKey('conveyor')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessTemplateNameFieldKey), 'conveyor-line-4');
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(find.text('conveyor-line-4'), findsOneWidget);
      expect(find.text('conveyor'), findsNothing);
      expect((await seeder().list()).map((t) => t.name), ['conveyor-line-4']);
    });
  });

  // -------------------------------------------------------------------------
  // Delete — the list first, and no confirm while it would cost anything
  // -------------------------------------------------------------------------

  group('delete', () {
    testWidgets('with keys bound the dialog lists them and offers no delete',
        (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_conveyorKeyA, 'conveyor');

      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateDeleteKey('conveyor')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessTemplateDeleteBlockedKey), findsOneWidget);
      expect(find.text(kAccessTemplateDeleteBlockedNote('conveyor', 1)),
          findsOneWidget);
      expect(find.text(_conveyorKeyA), findsOneWidget);
      expect(find.byKey(kAccessTemplateConfirmKey), findsNothing,
          reason: 'spec §7d: show the keys and block. A control that is '
              'present and always refuses teaches the operator to press it '
              'twice, and no sign-in fixes this one.');

      // And the list came from the store, not the snapshot: this is the one
      // decision that must not rest on something a second stale.
      expect(store!.calls, contains('keysBoundTo:conveyor'));
    });

    testWidgets('with nothing bound it deletes', (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessTemplateDeleteKey('conveyor')));
      await tester.pumpAndSettle();
      expect(find.text(kAccessTemplateDeleteFreeNote), findsOneWidget);

      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(await seeder().list(), isEmpty);
      expect(find.text('conveyor'), findsNothing);
    });

    testWidgets('a race — another station bound a key between the question and '
        'the statement — re-renders the dialog with the new list, not an error',
        (tester) async {
      await seeder().create(_conveyor());
      final racing = _RacingStore(
        db: db,
        session: () => session,
        audit: sink,
        station: 'SVN-NES-OT-CL02',
      )..raceKeys = [_conveyorKeyA];

      await tester.pumpWidget(host(overrides(withStore: racing)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessTemplateDeleteKey('conveyor')));
      await tester.pumpAndSettle();
      // The database said nothing was bound, so the confirm is offered.
      expect(find.byKey(kAccessTemplateConfirmKey), findsOneWidget);

      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(kAccessTemplateDeleteBlockedKey), findsOneWidget);
      expect(find.text(_conveyorKeyA), findsOneWidget);
      expect(find.byKey(kAccessTemplateConfirmKey), findsNothing);
      expect((await seeder().list()).length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // The rules — spec §7d's second bullet
  // -------------------------------------------------------------------------

  group('the rules', () {
    Future<void> expand(WidgetTester tester, String name) async {
      await tester.tap(find.byKey(kAccessTemplateTileKey(name)));
      await tester.pumpAndSettle();
    }

    testWidgets('a template expands to its rules, and the whole-key row is '
        'named in words rather than as a bare *', (tester) async {
      await seeder().create(AccessTemplate(name: 'conveyor', rules: const {
        kWholeKeyMember: AccessGroup.device,
        'p_cmd_JogFwd': AccessGroup.operate,
      }));

      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await expand(tester, 'conveyor');

      expect(find.text(kWholeKeyMemberLabel), findsOneWidget);
      expect(find.text(kWholeKeyMember), findsNothing,
          reason: '"*" is a storage sentinel, not something to show a person');
      expect(find.text('p_cmd_JogFwd'), findsOneWidget);
    });

    testWidgets('the seven groups are offered and no eighth', (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await expand(tester, 'conveyor');

      final dropdown = tester.widget<DropdownButton<AccessGroup>>(
          find.byKey(kAccessTemplateRuleGroupKey('p_cmd_JogFwd')));
      expect(dropdown.items!.map((i) => i.value).toList(), AccessGroup.values);
      expect(dropdown.items, hasLength(7));
    });

    testWidgets('changing a row\'s group goes through update with exactly '
        'that rule', (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await expand(tester, 'conveyor');
      store!.calls.clear();

      await tester.tap(find.byKey(kAccessTemplateRuleGroupKey('p_cmd_JogFwd')));
      await tester.pumpAndSettle();
      await tester
          .tap(find
              .byKey(kAccessTemplateRuleGroupOptionKey(
                  'p_cmd_JogFwd', AccessGroup.force))
              .last);
      await tester.pumpAndSettle();

      expect(
          store!.calls,
          contains('update:conveyor:'
              '{"p_cfg_ManualFreq":"device","p_cmd_JogFwd":"force"}'));
      final stored = await seeder().template('conveyor');
      expect(stored!.rules, {
        'p_cfg_ManualFreq': AccessGroup.device,
        'p_cmd_JogFwd': AccessGroup.force,
      });
    });

    testWidgets('removing a row goes through update without it',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await expand(tester, 'conveyor');
      store!.calls.clear();

      await tester
          .tap(find.byKey(kAccessTemplateRuleRemoveKey('p_cmd_JogFwd')));
      await tester.pumpAndSettle();

      expect(store!.calls,
          contains('update:conveyor:{"p_cfg_ManualFreq":"device"}'));
      final stored = await seeder().template('conveyor');
      expect(stored!.rules, {'p_cfg_ManualFreq': AccessGroup.device});
    });

    testWidgets('a session without users may press every rule control and is '
        'told what it needs', (tester) async {
      await seeder().create(_conveyor());
      session = _configureOnly();
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await expand(tester, 'conveyor');

      final remove = tester.widget<IconButton>(
          find.byKey(kAccessTemplateRuleRemoveKey('p_cmd_JogFwd')));
      expect(remove.onPressed, isNotNull);
      final dropdown = tester.widget<DropdownButton<AccessGroup>>(
          find.byKey(kAccessTemplateRuleGroupKey('p_cmd_JogFwd')));
      expect(dropdown.onChanged, isNotNull);

      await tester
          .tap(find.byKey(kAccessTemplateRuleRemoveKey('p_cmd_JogFwd')));
      await tester.pumpAndSettle();

      expect(find.text(kAccessDeniedGroupNote(AccessGroup.users)),
          findsOneWidget);
      final stored = await seeder().template('conveyor');
      expect(stored!.rules, hasLength(2), reason: 'nothing was re-scoped');
    });
  });

  // -------------------------------------------------------------------------
  // Adding a rule — picking from a list rather than typing from memory
  // -------------------------------------------------------------------------

  group('adding a rule', () {
    Future<void> openAddRule(WidgetTester tester, String name) async {
      await tester.tap(find.byKey(kAccessTemplateTileKey(name)));
      await tester.pumpAndSettle();
      // The template list is bounded and scrolls on its own — see
      // kAccessTemplatesListMaxHeight, which is what keeps this section from
      // pushing the key list off a small panel.
      await tester.ensureVisible(find.byKey(kAccessTemplateAddRuleKey(name)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateAddRuleKey(name)));
      await tester.pumpAndSettle();
    }

    testWidgets('offers the members already seen on a bound key, and adding '
        'one goes through update with exactly that rule', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_conveyorKeyA, 'conveyor');
      final sm = _FakeStateMan(values: {
        _conveyorKeyA: _struct(const {
          'p_cmd_JogFwd': true,
          'p_cfg_ManualFreq': 12.0,
          'p_stat_Running': false,
        })
      });

      await tester.pumpWidget(host([
        ...overrides(),
        stateManProvider.overrideWith((ref) async => sm),
      ]));
      await tester.pumpAndSettle();
      await openAddRule(tester, 'conveyor');

      expect(find.byKey(kAccessTemplateSuggestionKey('p_stat_Running')),
          findsOneWidget);
      expect(find.byKey(kAccessTemplateSuggestionKey(kWholeKeyMember)),
          findsOneWidget,
          reason: 'the whole-key row is offered too, and by its name');
      expect(find.text(kAccessTemplateNoSuggestionsNote), findsNothing);

      await tester
          .tap(find.byKey(kAccessTemplateSuggestionKey('p_stat_Running')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateNewRuleGroupKey));
      await tester.pumpAndSettle();
      await tester
          .tap(find
              .byKey(kAccessTemplateNewRuleGroupOptionKey(AccessGroup.device))
              .last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      expect(
          store!.calls,
          contains('update:conveyor:{"p_cfg_ManualFreq":"device",'
              '"p_cmd_JogFwd":"operate","p_stat_Running":"device"}'));
      final stored = await seeder().template('conveyor');
      expect(stored!.rules['p_stat_Running'], AccessGroup.device);
    });

    testWidgets('reads one bound key, not all of them', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_conveyorKeyA, 'conveyor');
      await seed.bind(_conveyorKeyB, 'conveyor');
      await seed.bind('ST101.CN03', 'conveyor');
      final sm = _FakeStateMan(values: {
        _conveyorKeyA: _struct(const {'p_cmd_JogFwd': true}),
        _conveyorKeyB: _struct(const {'p_cmd_JogFwd': true}),
        'ST101.CN03': _struct(const {'p_cmd_JogFwd': true}),
      });

      await tester.pumpWidget(host([
        ...overrides(),
        stateManProvider.overrideWith((ref) async => sm),
      ]));
      await tester.pumpAndSettle();
      await openAddRule(tester, 'conveyor');

      expect(sm.reads, hasLength(1),
          reason: 'a PLC round trip per bound key behind a + button is what '
              'T-04-41 is about; the members are the same across keys sharing '
              'a template, which is what a template means');
    });

    testWidgets('a template with no bound key still lets a rule be typed',
        (tester) async {
      await seeder().create(_conveyor());
      await tester.pumpWidget(host(overrides()));
      await tester.pumpAndSettle();
      await openAddRule(tester, 'conveyor');

      expect(find.text(kAccessTemplateNoSuggestionsNote), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.enterText(
          find.byKey(kAccessTemplateMemberFieldKey), 'p_cfg_AutoFreq');
      await tester.tap(find.byKey(kAccessTemplateNewRuleGroupKey));
      await tester.pumpAndSettle();
      await tester
          .tap(find
              .byKey(
                  kAccessTemplateNewRuleGroupOptionKey(AccessGroup.setpoints))
              .last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessTemplateConfirmKey));
      await tester.pumpAndSettle();

      final stored = await seeder().template('conveyor');
      expect(stored!.rules['p_cfg_AutoFreq'], AccessGroup.setpoints,
          reason: 'a commissioning engineer writes the template before the '
              'PLC is on the network; free text is not a fallback, it is the '
              'other half of the design');
    });

    testWidgets('an unreadable bound key leaves a plain text field, no error '
        'and no spinner', (tester) async {
      final seed = seeder();
      await seed.create(_conveyor());
      await seed.bind(_conveyorKeyA, 'conveyor');

      await tester.pumpWidget(host([
        ...overrides(),
        stateManProvider.overrideWith((ref) async => _FakeStateMan(
            values: const {}, readThrows: StateError('no such node'))),
      ]));
      await tester.pumpAndSettle();
      await openAddRule(tester, 'conveyor');

      expect(tester.takeException(), isNull);
      expect(find.byKey(kAccessTemplateMemberFieldKey), findsOneWidget);
      expect(find.text(kAccessTemplateNoSuggestionsNote), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a scalar bound key offers the whole key and nothing else',
        (tester) async {
      final seed = seeder();
      await seed.create(AccessTemplate(name: 'scalar', rules: const {}));
      await seed.bind(_conveyorKeyA, 'scalar');

      await tester.pumpWidget(host([
        ...overrides(),
        stateManProvider.overrideWith((ref) async => _FakeStateMan(values: {
              _conveyorKeyA: DynamicValue(value: 12.0, typeId: NodeId.double),
            })),
      ]));
      await tester.pumpAndSettle();
      await openAddRule(tester, 'scalar');

      expect(find.text(kAccessTemplateNoSuggestionsNote), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The mount
  // -------------------------------------------------------------------------

  group('the mount', () {
    testWidgets('the key repository carries the section', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.byType(AccessTemplatesSection), findsOneWidget);
      // The page's own tests all run with no database, so this is also the
      // no-database line's only trip through the real page.
      expect(find.byKey(kAccessTemplatesNoDatabaseKey), findsOneWidget);
      expect(find.text('No keys configured'), findsOneWidget,
          reason: 'the key list still has room');
      expect(tester.takeException(), isNull);
    });
  });
}
