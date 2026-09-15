/// Accepting some of a staged `access_template` batch, and the order the
/// section applies a mixed batch in.
///
/// The case that was reported (2026-09-13): four template creates and one
/// binding sweep pending, three of them wanted. The section's one commit
/// applied the batch whole, so the operator rejected all five. It now offers
/// a commit and a discard per proposal id on [proposalItemActionsProvider],
/// reconciles the batch against the queue, applies creates before binds
/// before deletes, and holds back a binding whose template is still a
/// pending proposal rather than sending it to the store to fail.
///
/// Same rig as `access_template_proposal_test.dart`: a real store over an
/// in-memory database, every claim read back from the tables.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/access_templates_section.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _RecordingProposals extends ProposalStateNotifier {
  _RecordingProposals(StreamController<ProposalFeedback> feedback)
      : super(feedback: feedback);

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

AccessSession _approver() => const AccessSession(
      user: AuthenticatedUser(username: 'approver', roleName: 'Administrator'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

const String _kKey = 'line1.conveyor_a';

PendingProposal _create(int id, String name) => PendingProposal(
      id: id,
      proposalType: 'access_template',
      title: 'Access template "$name"',
      proposalJson: jsonEncode({
        'name': name,
        'rules': {'*': 'device'},
        '_proposal_type': 'access_template',
        '_op': 'create',
      }),
      operatorId: 'agent',
      createdAt: DateTime(2026, 9, 13),
    );

PendingProposal _bind(int id, String key, String template) => PendingProposal(
      id: id,
      proposalType: 'access_template',
      title: '1 key binding',
      proposalJson: jsonEncode({
        'bindings': [
          {'key': key, 'template': template},
        ],
        '_proposal_type': 'access_template',
        '_op': 'bind',
      }),
      operatorId: 'agent',
      createdAt: DateTime(2026, 9, 13),
    );

class _Staged {
  _Staged(this.container, this.proposals, this.sink, this.decisions);

  final ProviderContainer container;
  final _RecordingProposals proposals;
  final _RecordingSink sink;
  final List<ProposalFeedback> decisions;

  Future<void> Function()? get commit =>
      container.read(proposalCommitProvider);
  Map<int, ProposalItemActions> get items =>
      container.read(proposalItemActionsProvider);
  List<int> get pendingIds =>
      container.read(proposalStateProvider).proposals.map((p) => p.id).toList();
}

void main() {
  late AppDatabase db;
  late _RecordingSink sink;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    await db.customSelect('SELECT 1').getSingle();
    sink = _RecordingSink();
  });

  tearDown(() => db.close());

  AccessTemplateStore seeder() => AccessTemplateStore(
        db: db,
        session: _approver,
        audit: _RecordingSink(),
        station: 'station-1',
      );

  Future<_Staged> stage(
      WidgetTester tester, List<PendingProposal> pending) async {
    final feedback = StreamController<ProposalFeedback>.broadcast();
    addTearDown(feedback.close);
    final decisions = <ProposalFeedback>[];
    feedback.stream.listen(decisions.add);
    final proposals = _RecordingProposals(feedback);
    for (final p in pending) {
      proposals.addProposal(p);
    }

    final prefs = await createTestPreferences(
      keyMappings: KeyMappings(nodes: {
        _kKey: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'conv_a'),
        ),
      }),
    );

    final container = ProviderContainer(overrides: [
      tagBindingResolverProvider.overrideWith((ref) => TagBindingResolver()),
      accessTemplateStoreProvider.overrideWith((ref) async => AccessTemplateStore(
            db: db,
            session: _approver,
            audit: sink,
            station: 'station-1',
            onDenied: (denial) => reportAccessDenial(ref, denial),
          )),
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

    return _Staged(container, proposals, sink, decisions);
  }

  Future<List<String>> templateNames() async =>
      (await seeder().list()).map((t) => t.name).toList();
  Future<Map<String, String>> bindings() => seeder().bindings();

  testWidgets(
      'three of five accepted: exactly those three land, two stay pending '
      'and acceptable', (tester) async {
    final staged = await stage(tester, [
      _create(-1, 'conveyor'),
      _create(-2, 'gate'),
      _create(-3, 'sensor'),
      _create(-4, 'pump'),
      _bind(-5, _kKey, 'conveyor'),
    ]);
    expect(staged.items.keys, unorderedEquals([-1, -2, -3, -4, -5]),
        reason: 'every staged row is offered on its own');

    await staged.items[-1]!.commit(-1);
    await staged.items[-3]!.commit(-3);
    await staged.items[-5]!.commit(-5);
    await tester.pumpAndSettle();

    expect(await templateNames(), unorderedEquals(['conveyor', 'sensor']));
    expect(await bindings(), {_kKey: 'conveyor'});
    expect(staged.proposals.accepted, [-1, -3, -5]);
    expect(staged.pendingIds, [-2, -4],
        reason: 'the two not decided on are neither dropped nor accepted');
    expect(staged.items.keys, unorderedEquals([-2, -4]));
    expect(staged.commit, isNotNull);

    // What the MCP client is told: one decision per press, naming it.
    final accepted =
        staged.decisions.where((d) => d.action == 'accepted').toList();
    expect(accepted.map((d) => d.proposals.map((p) => p.title).toList()), [
      ['Access template "conveyor"'],
      ['Access template "sensor"'],
      ['1 key binding'],
    ]);

    // And the remainder is still acceptable, as a batch.
    await staged.commit!();
    await tester.pumpAndSettle();
    expect(await templateNames(),
        unorderedEquals(['conveyor', 'gate', 'sensor', 'pump']));
    expect(staged.pendingIds, isEmpty);
    expect(staged.commit, isNull);
  });

  testWidgets('rejecting one row leaves the others staged', (tester) async {
    final staged = await stage(tester, [
      _create(-1, 'conveyor'),
      _create(-2, 'gate'),
    ]);

    await staged.items[-2]!.discard(-2);
    await tester.pumpAndSettle();

    expect(staged.proposals.rejected, [-2]);
    expect(staged.pendingIds, [-1]);
    expect(staged.items.keys, [-1]);
    expect(await templateNames(), isEmpty, reason: 'a reject writes nothing');
    expect(staged.sink.rows, isEmpty,
        reason: 'a rejected proposal is not an authorization event');

    await staged.commit!();
    await tester.pumpAndSettle();
    expect(await templateNames(), ['conveyor']);
  });

  testWidgets('a row rejected straight from the queue is un-staged too',
      (tester) async {
    final staged = await stage(tester, [
      _create(-1, 'conveyor'),
      _create(-2, 'gate'),
    ]);

    await staged.proposals.rejectProposal(-1);
    await tester.pumpAndSettle();
    expect(staged.items.keys, [-2]);

    await staged.commit!();
    await tester.pumpAndSettle();
    expect(await templateNames(), ['gate'],
        reason: 'the rejected template must not be written by Accept all');
  });

  testWidgets(
      'a binding accepted before its template waits, and says which template',
      (tester) async {
    final staged = await stage(tester, [
      _create(-1, 'conveyor'),
      _bind(-2, _kKey, 'conveyor'),
    ]);

    await staged.items[-2]!.commit(-2);
    await tester.pumpAndSettle();

    expect(await bindings(), isEmpty,
        reason: 'nothing to bind to yet; the store was not even asked');
    expect(staged.sink.rows, isEmpty);
    expect(staged.proposals.accepted, isEmpty);
    expect(staged.pendingIds, [-1, -2],
        reason: 'the binding stays pending, not failed');
    expect(find.textContaining('still a pending proposal'), findsOneWidget);
    expect(find.textContaining('"conveyor"'), findsWidgets,
        reason: 'the note names the row to accept first');

    // In the order the dependency wants, both land.
    await staged.items[-1]!.commit(-1);
    await staged.items[-2]!.commit(-2);
    await tester.pumpAndSettle();
    expect(await templateNames(), ['conveyor']);
    expect(await bindings(), {_kKey: 'conveyor'});
    expect(staged.pendingIds, isEmpty);
  });

  testWidgets(
      'Accept all applies the template before the binding, whatever order '
      'the agent proposed them in', (tester) async {
    final staged = await stage(tester, [
      _bind(-1, _kKey, 'conveyor'),
      _create(-2, 'conveyor'),
    ]);

    await staged.commit!();
    await tester.pumpAndSettle();

    expect(await templateNames(), ['conveyor']);
    expect(await bindings(), {_kKey: 'conveyor'});
    expect(staged.proposals.accepted, unorderedEquals([-1, -2]));
    expect(staged.sink.rows.map((r) => r.itemKey), [
      'access_template.conveyor',
      'access_key_binding.$_kKey',
    ], reason: 'the trail shows the create landing first');
    expect(staged.pendingIds, isEmpty);
  });
}
