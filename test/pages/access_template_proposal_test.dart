/// The accept path for an `access_template` proposal (spec §7c).
///
/// An agent sweeps a plant and proposes; a person approves. This file is about
/// what happens at the approval, and it exists because §7c's three promises
/// are all about that moment and none of them can be checked in
/// `tfc_mcp_server`:
///
///  * the change goes through the **same** `users`-gated store the section's
///    own controls use, so an approver without `users` is refused and the
///    refusal is recorded (T-04-52),
///  * the row carries `origin: 'mcp'`, so an MCP-originated change is not
///    indistinguishable from a hand-made one (T-04-53),
///  * the row's `who` is the **approving human**, taken from the live session
///    and never from the proposal — the proposals here deliberately carry a
///    conflicting `operator_id` and the assertion is that it is ignored
///    (T-04-51).
///
/// The store is real, over a real in-memory database, and every claim about
/// what happened is read back from the tables or from the audit sink. A mock
/// store would have let "applied through AccessTemplateStore" be true of the
/// call and false of the row.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/access_templates_section.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
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

/// Records the decisions the section made on the batch.
class _RecordingProposals extends ProposalStateNotifier {
  final List<int> accepted = [];
  final List<int> rejected = [];

  @override
  Future<void> acceptProposal(int id) async {
    accepted.add(id);
    await super.acceptProposal(id);
  }

  @override
  Future<void> rejectProposal(int id) async {
    rejected.add(id);
    await super.rejectProposal(id);
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// The approver §7c means: a person, at the panel, holding `users`.
AccessSession _approver() => const AccessSession(
      user: AuthenticatedUser(username: 'gudrun', roleName: 'Administrator'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

/// The engineer the gate exists for. They can open the key repository — the
/// route is `configure` — and must not be able to apply an authorization
/// change an agent proposed.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The name the proposal claims made it. Never the name that should reach a
/// row: `who` is decided at the accept, from the live session.
const String _kAgent = 'sweeper-agent';

const String _kConveyorKey = 'ST101.CN01';

/// A proposal as the MCP server wraps one, with a conflicting `operator_id`
/// baked in on purpose.
PendingProposal _proposal(
  int id,
  String op,
  Map<String, dynamic> body,
) =>
    PendingProposal(
      id: id,
      proposalType: 'access_template',
      title: body['title'] as String? ?? 'proposal',
      proposalJson: jsonEncode({
        ...body,
        // The forgery attempt, in the two shapes an attacker would reach for.
        'operator_id': _kAgent,
        'who': _kAgent,
        '_proposal_type': 'access_template',
        '_op': op,
      }),
      operatorId: _kAgent,
      createdAt: DateTime(2026, 8, 30),
    );

class _Staged {
  _Staged(this.container, this.proposals, this.sink, this.prefs);

  final ProviderContainer container;
  final _RecordingProposals proposals;
  final _RecordingSink sink;
  final Preferences prefs;

  Future<void> Function()? get commit =>
      container.read(proposalCommitProvider);

  Future<void> Function()? get discard =>
      container.read(proposalDiscardProvider);

  /// The rows the store wrote, in order.
  List<AuditRecord> get rows => sink.rows;
}

void main() {
  late AppDatabase db;
  late _RecordingSink sink;
  late AccessSession session;
  late TagBindingResolver resolver;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    await db.customSelect('SELECT 1').getSingle();
    sink = _RecordingSink();
    session = _approver();
    resolver = TagBindingResolver();
  });

  tearDown(() => db.close());

  /// A store built outside the provider, for seeding rows before the pump.
  AccessTemplateStore seeder() => AccessTemplateStore(
        db: db,
        session: () => _approver(),
        audit: _RecordingSink(),
        station: 'SVN-NES-OT-CL02',
      );

  /// Mounts the section with [pending] already in the proposal queue.
  Future<_Staged> stage(
    WidgetTester tester,
    List<PendingProposal> pending, {
    bool noDatabase = false,
  }) async {
    final proposals = _RecordingProposals();
    for (final p in pending) {
      proposals.addProposal(p);
    }

    final prefs = await createTestPreferences(
      keyMappings: KeyMappings(nodes: {
        _kConveyorKey: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'CN01'),
        ),
      }),
    );

    final container = ProviderContainer(overrides: [
      tagBindingResolverProvider.overrideWith((ref) => resolver),
      accessTemplateStoreProvider.overrideWith((ref) async {
        if (noDatabase) return null;
        return AccessTemplateStore(
          db: db,
          session: () => session,
          audit: sink,
          station: 'SVN-NES-OT-CL02',
          // The same wiring the real provider does, so a refusal reaches the
          // shared prompt exactly as it does on the station.
          onDenied: (denial) => reportAccessDenial(ref, denial),
        );
      }),
      preferencesProvider.overrideWith((ref) async => prefs),
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
      proposalStateProvider.overrideWith((ref) => proposals),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const PromptedApp(
        home: Scaffold(
          body: AccessTemplatesSection(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    return _Staged(container, proposals, sink, prefs);
  }

  Future<List<AccessTemplate>> templates() => seeder().list();
  Future<Map<String, String>> bindings() => seeder().bindings();

  // -------------------------------------------------------------------------
  group('the routing table knows the type', () {
    test('access_template routes to the key repository', () {
      expect(proposalRoutes['access_template'], '/advanced/key-repository');
    });

    test('editorLabel names the key repository', () {
      final proposal = _proposal(-1, 'create', {'name': 'conveyor'});
      expect(proposal.editorLabel, 'Key Repository');
      expect(proposal.editorRoute, '/advanced/key-repository');
    });

    test('the _op field is what says what accepting does', () {
      expect(_proposal(-1, 'create', {'name': 'c'}).action, ProposalOp.create);
      expect(_proposal(-2, 'update', {'name': 'c'}).action, ProposalOp.update);
      expect(_proposal(-3, 'delete', {'name': 'c'}).action, ProposalOp.delete);
    });
  });

  // -------------------------------------------------------------------------
  group('an accepted proposal is applied through the users-gated store', () {
    testWidgets('a create lands, with origin mcp and who = the approver — '
        'never the name in the proposal', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'create', {
          'title': 'Access template "conveyor"',
          'name': 'conveyor',
          'rules': {'p_cmd_JogFwd': 'operate', '*': 'device'},
          'reason': 'swept ST101',
        }),
      ]);

      expect(staged.commit, isNotNull,
          reason: 'the section must publish a commit callback to the banner');
      await staged.commit!();
      await tester.pumpAndSettle();

      final stored = await templates();
      expect(stored, hasLength(1));
      expect(stored.single.name, 'conveyor');
      expect(stored.single.rules, {
        'p_cmd_JogFwd': AccessGroup.operate,
        kWholeKeyMember: AccessGroup.device,
      });

      expect(staged.rows, hasLength(1));
      final row = staged.rows.single;
      expect(row.origin, 'mcp',
          reason: 'an MCP-originated change that looked hand-made would be '
              'unattributable a year later (T-04-53)');
      expect(row.who, 'gudrun',
          reason: 'the trail names the person who approved it');
      expect(row.who, isNot(_kAgent),
          reason: 'the proposal JSON carries operator_id "$_kAgent" and a '
              '"who" field; neither may become an identity (T-04-51)');
      expect(row.allowed, isTrue);
      expect(row.groupRequired, AccessGroup.users.name);
      expect(row.reason, contains('swept ST101'));

      expect(staged.proposals.accepted, [-1]);
      expect(staged.commit, isNull,
          reason: 'the batch is done, so the banner stops offering Accept');
    });

    testWidgets('a bind lands in access_key_binding — not in access_template, '
        'and not in the key_mappings preference', (tester) async {
      await seeder().create(
          AccessTemplate(name: 'conveyor', rules: const {'*': AccessGroup.device}));

      final staged = await stage(tester, [
        _proposal(-1, 'bind', {
          'title': '1 key binding',
          'bindings': [
            {'key': _kConveyorKey, 'template': 'conveyor'},
          ],
        }),
      ]);
      final keyMappingsBefore = await staged.prefs.getString('key_mappings');
      expect(keyMappingsBefore, isNotNull,
          reason: 'sanity: the blob this test claims is untouched exists');

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await bindings(), {_kConveyorKey: 'conveyor'});
      expect((await templates()).map((t) => t.name), ['conveyor'],
          reason: 'a bind changes the binding table and nothing else');
      expect(await staged.prefs.getString('key_mappings'), keyMappingsBefore,
          reason: 'the 2026-08-30 ruling moved bindings out of the '
              'configure-gated key_mappings blob. A bind that still wrote it '
              'would inherit the weaker gate (T-04-56).');

      final row = staged.rows.single;
      expect(row.origin, 'mcp');
      expect(row.who, 'gudrun');
      expect(row.itemKey, 'access_key_binding.$_kConveyorKey');
      expect(staged.proposals.accepted, [-1]);
    });

    testWidgets('a bulk bind of three keys is one approval and three rows',
        (tester) async {
      await seeder().create(
          AccessTemplate(name: 'conveyor', rules: const {'*': AccessGroup.device}));

      final staged = await stage(tester, [
        _proposal(-1, 'bind', {
          'title': '3 key bindings',
          'bindings': [
            {'key': 'ST101.CN01', 'template': 'conveyor'},
            {'key': 'ST101.CN02', 'template': 'conveyor'},
            {'key': 'ST101.CN03', 'template': 'conveyor'},
          ],
        }),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await bindings(), {
        'ST101.CN01': 'conveyor',
        'ST101.CN02': 'conveyor',
        'ST101.CN03': 'conveyor',
      });
      expect(staged.rows, hasLength(3),
          reason: 'one audit row per binding — the approval is bulk, the '
              'trail is not');
      for (final row in staged.rows) {
        expect(row.origin, 'mcp');
        expect(row.who, 'gudrun');
      }
      expect(staged.proposals.accepted, [-1],
          reason: 'one proposal, one approval');
    });

    testWidgets('an unbind travels in the same proposal type', (tester) async {
      await seeder().create(
          AccessTemplate(name: 'conveyor', rules: const {'*': AccessGroup.device}));
      await seeder().bind(_kConveyorKey, 'conveyor');

      final staged = await stage(tester, [
        _proposal(-1, 'bind', {
          'bindings': [
            {'key': _kConveyorKey, 'template': null},
          ],
        }),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await bindings(), isEmpty);
      expect(staged.rows.single.origin, 'mcp');
      expect(staged.rows.single.who, 'gudrun');
      expect(staged.proposals.accepted, [-1]);
    });
  });

  // -------------------------------------------------------------------------
  group('an approver without users is refused, and the refusal is recorded',
      () {
    testWidgets('the row is allowed:false with origin mcp, and the proposal '
        'stays pending', (tester) async {
      session = _configureOnly();

      final staged = await stage(tester, [
        _proposal(-1, 'create', {
          'name': 'conveyor',
          'rules': {'*': 'device'},
        }),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await templates(), isEmpty,
          reason: 'a configure engineer must not be able to re-scope who may '
              'write what by pressing Accept (T-04-52)');

      expect(staged.rows, hasLength(1));
      final row = staged.rows.single;
      expect(row.allowed, isFalse);
      expect(row.origin, 'mcp',
          reason: 'a denial is where the trail matters most, and it must say '
              'the change came from an agent');
      expect(row.who, 'engineer');
      expect(row.groupRequired, AccessGroup.users.name);

      expect(staged.proposals.accepted, isEmpty,
          reason: 'a proposal that was not applied must stay pending, or it '
              'is lost with nothing written');
      expect(staged.commit, isNotNull,
          reason: 'the banner must keep offering Accept for somebody who may');

      // The shared prompt, not a message of this file's own.
      expect(find.byType(AccessDeniedPrompt), findsOneWidget);
      expect(find.textContaining(AccessGroup.users.name), findsWidgets,
          reason: 'the refusal names the group that would resolve it');
    });

    testWidgets('signing in as somebody who may lets the same proposal through',
        (tester) async {
      session = _configureOnly();
      final staged = await stage(tester, [
        _proposal(-1, 'create', {
          'name': 'conveyor',
          'rules': {'*': 'device'},
        }),
      ]);
      await staged.commit!();
      await tester.pumpAndSettle();
      expect(await templates(), isEmpty);

      session = _approver();
      await staged.commit!();
      await tester.pumpAndSettle();

      expect((await templates()).map((t) => t.name), ['conveyor']);
      expect(staged.rows.map((r) => r.allowed), [false, true]);
      expect(staged.rows.map((r) => r.who), ['engineer', 'gudrun'],
          reason: 'the session is read at the accept, not captured when the '
              'proposal was staged');
      expect(staged.proposals.accepted, [-1]);
    });
  });

  // -------------------------------------------------------------------------
  group('a delete the store blocks leaves the proposal pending', () {
    testWidgets('and the section names the keys still bound', (tester) async {
      await seeder().create(
          AccessTemplate(name: 'conveyor', rules: const {'*': AccessGroup.device}));

      final staged = await stage(tester, [
        _proposal(-1, 'delete', {
          'name': 'conveyor',
          // What the agent saw when it made the proposal: nothing bound.
          'bound_keys': <String>[],
        }),
      ]);

      // Bound *after* the proposal was made and before it was approved. The
      // block has to be decided at the accept, from the store's own read, or
      // a sweep made an hour ago unrestricts a key bound since (T-04-54).
      await seeder().bind(_kConveyorKey, 'conveyor');

      await staged.commit!();
      await tester.pumpAndSettle();

      expect((await templates()).map((t) => t.name), ['conveyor'],
          reason: 'the delete must not have happened');
      expect(staged.proposals.accepted, isEmpty);
      expect(staged.commit, isNotNull);
      expect(find.textContaining(_kConveyorKey), findsWidgets,
          reason: 'the operator has to be told which keys blocked it, or the '
              'Accept button simply did nothing');
    });
  });

  // -------------------------------------------------------------------------
  group('what the section refuses to stage', () {
    testWidgets('a malformed proposal is ignored without throwing',
        (tester) async {
      final staged = await stage(tester, [
        PendingProposal(
          id: -1,
          proposalType: 'access_template',
          title: 'nonsense',
          proposalJson: 'not json at all',
          operatorId: _kAgent,
          createdAt: DateTime(2026, 8, 30),
        ),
        PendingProposal(
          id: -2,
          proposalType: 'access_template',
          title: 'no name',
          proposalJson:
              jsonEncode({'_proposal_type': 'access_template', '_op': 'create'}),
          operatorId: _kAgent,
          createdAt: DateTime(2026, 8, 30),
        ),
        PendingProposal(
          id: -3,
          proposalType: 'access_template',
          title: 'no bindings',
          proposalJson:
              jsonEncode({'_proposal_type': 'access_template', '_op': 'bind'}),
          operatorId: _kAgent,
          createdAt: DateTime(2026, 8, 30),
        ),
      ]);

      expect(tester.takeException(), isNull);
      expect(staged.commit, isNull,
          reason: 'nothing was staged, so there is nothing to accept');
      expect(staged.rows, isEmpty);
    });

    testWidgets('a proposal of another type is left to its own editor',
        (tester) async {
      final staged = await stage(tester, [
        PendingProposal(
          id: -1,
          proposalType: 'key_mapping',
          title: 'a key mapping',
          proposalJson: jsonEncode({
            '_proposal_type': 'key_mapping',
            'key': _kConveyorKey,
          }),
          operatorId: _kAgent,
          createdAt: DateTime(2026, 8, 30),
        ),
      ]);

      expect(staged.commit, isNull);
      expect(staged.rows, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('a batch that cannot be applied stays up', () {
    testWidgets('a station with no database keeps the proposal and says why',
        (tester) async {
      final staged = await stage(
        tester,
        [
          _proposal(-1, 'create', {
            'name': 'conveyor',
            'rules': {'*': 'device'},
          }),
        ],
        noDatabase: true,
      );

      expect(staged.commit, isNull,
          reason: 'with no store there is nothing to publish an accept for; '
              'the proposal stays pending until the station has one');
      expect(staged.proposals.accepted, isEmpty);
      expect(await templates(), isEmpty);
    });

    testWidgets('rejecting the batch touches neither table', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'create', {
          'name': 'conveyor',
          'rules': {'*': 'device'},
        }),
      ]);

      await staged.discard!();
      await tester.pumpAndSettle();

      expect(await templates(), isEmpty);
      expect(await bindings(), isEmpty);
      expect(staged.rows, isEmpty,
          reason: 'a rejected proposal is not an authorization event');
      expect(staged.proposals.rejected, [-1]);
      expect(staged.discard, isNull);
    });
  });
}
