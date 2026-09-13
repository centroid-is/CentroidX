import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

/// Assertions for key_repository.dart proposal handling.
///
/// The shape they pin changed on 2026-08-18. Proposals used to be staged one
/// at a time and accepted from an inline amber bar inside this page. An MCP
/// client fires create_key_mapping one call per mapping, so a batch of 28
/// arrived as 28 proposals and cost 28 reviews and 28 saves — and the inline
/// bar was a second place to act on a proposal, competing with the black
/// banner. Both are gone: the page stages the whole queue and publishes
/// commit/discard to the banner, which is now the only place to accept.
///
/// Most of the file reads the source as a string, which pins shape and not
/// behaviour. The 2026-08-21 incident — 16 mappings written with not one
/// proposal marked accepted — went straight past assertions like those, so
/// the paths that failed that day are covered by the widget tests at the
/// bottom instead.
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/pages/key_repository.dart').readAsStringSync();
  });

  group('KeyRepositoryPage proposal support', () {
    test('has proposalData parameter', () {
      expect(source, contains('proposalData'));
    });

    test('passes proposalData down to KeyRepositoryContent', () {
      expect(source, contains('KeyRepositoryContent(proposalData:'));
    });
  });

  group('proposals are staged as a batch, not one at a time', () {
    test('stages every pending key_mapping proposal', () {
      expect(source, contains('_stageKeyMappingProposals'));
    });

    test('keeps a list of staged mappings and their proposal ids', () {
      expect(source, contains('_proposedMappings'));
      expect(source, contains('_proposalIds'));
    });

    test('_isProposal is derived from the batch, not a separate flag', () {
      expect(source, contains('bool get _isProposal => _proposedMappings.isNotEmpty'));
    });

    test('skips ids already staged so re-entry cannot double-apply', () {
      expect(source, contains('_proposalIds.contains(p.id)'));
    });

    test('only accepts key_mapping proposals', () {
      expect(source, contains("p.proposalType != 'key_mapping'"));
      expect(source, contains("decoded['_proposal_type'] != 'key_mapping'"));
    });

    test('tolerates a malformed proposal without dropping the batch', () {
      expect(source, contains('jsonDecode(p.proposalJson)'));
      expect(source, contains('is! Map<String, dynamic>'));
    });
  });

  group('the banner owns accept/reject — nothing inline', () {
    test('publishes commit and discard to the banner', () {
      expect(source, contains('proposalCommitProvider'));
      expect(source, contains('proposalDiscardProvider'));
      expect(source, contains('_commitProposals'));
      expect(source, contains('_discardProposals'));
    });

    test('no inline Accept/Reject buttons remain in this page', () {
      // The amber bar carried an ElevatedButton 'Accept' and an
      // OutlinedButton 'Reject'. Two competing controls meant an operator
      // could accept in one place while the other still showed it pending.
      expect(source, isNot(contains("child: const Text('Accept')")));
      expect(source, isNot(contains("child: const Text('Reject')")));
    });

    test('clears the callbacks once the batch is resolved', () {
      // Cleared through the stored slots rather than `ref.read(...)`: these
      // run from the banner, which outlives this section, and `ref` throws
      // once the widget is disposed. See the disposal group below.
      expect(
        RegExp(r'_commitSlot\?\.state = null')
            .allMatches(source)
            .length,
        greaterThanOrEqualTo(2),
        reason: 'both commit and discard must clear the banner callbacks',
      );
    });
  });

  group('commit applies before it accepts', () {
    test('saves the mappings, then marks the proposals accepted', () {
      final commit = source.substring(source.indexOf('_commitProposals'));
      final save = commit.indexOf('_saveKeyMappings()');
      final accept = commit.indexOf('acceptProposal');
      expect(save, greaterThan(-1));
      expect(accept, greaterThan(-1));
      expect(save, lessThan(accept),
          reason: 'acceptProposal marks the row accepted in the database, so '
              'doing it before the save would lose the mapping if the save '
              'failed');
    });

    test('awaits each accept rather than firing and forgetting', () {
      expect(source, contains('await notifier.acceptProposal(id)'));
    });

    test('applies the proposed opcua node onto a real KeyMappingEntry', () {
      expect(source, contains('OpcUANodeConfig.fromJson(opcuaNode)'));
      expect(source, contains('_keyMappings!.nodes[key] = entry'));
    });
  });

  group('the proposed mappings are still shown inline', () {
    test('highlighted rows remain — that is why you navigate here', () {
      expect(source, contains('proposalDecoration()'));
      expect(source, contains('ProposalBadge()'));
    });

    test('the list is bounded so a large batch cannot fill the page', () {
      expect(source, contains('maxHeight: 160'));
    });
  });

  group('a proposal merges onto the existing entry', () {
    // update_key_mapping used to build a fresh KeyMappingEntry and assign only
    // opcuaNode, so proposing a new node id silently discarded that key's
    // collect settings -- its retention and sample interval -- along with any
    // m2400/modbus/io binding. The 28 sensor fault mappings were written that
    // way. A proposal states what changes; the rest has to survive.
    test('starts from the entry already stored under the key', () {
      expect(source,
          contains('_keyMappings!.nodes[key] ?? KeyMappingEntry()'));
    });

    test('does not construct a bare entry and overwrite the slot', () {
      expect(source, isNot(contains('final entry = KeyMappingEntry();')));
    });

    test('applies a collect block when the proposal carries one', () {
      expect(source, contains('CollectEntry.fromJson(collect)'));
    });

    test('keys the collect entry to the mapping it belongs to', () {
      expect(source, contains('..key = key'));
    });

    test('an explicit null collect turns collection off', () {
      expect(source, contains("m.containsKey('collect')"));
      expect(source, contains('entry.collect = null'));
    });
  });

  group('a delete proposal removes the key', () {
    test('recognises the delete op', () {
      expect(source, contains("m['_op'] == 'delete'"));
    });

    test('removes through _removeKey so derived caches are dropped too', () {
      expect(source, contains('_removeKey(key)'));
    });

    test('a delete carries no fields to merge', () {
      final applyLoop = source.substring(source.indexOf('for (final m in _proposedMappings)'));
      final deleteAt = applyLoop.indexOf("m['_op'] == 'delete'");
      final mergeAt = applyLoop.indexOf('?? KeyMappingEntry()');
      expect(deleteAt, greaterThan(-1));
      expect(mergeAt, greaterThan(deleteAt),
          reason: 'the delete branch must return before any merge');
    });
  });

  // ================== behaviour: the 2026-08-21 incident ==================
  //
  // A batch of 16 mappings was accepted. Every mapping was written to
  // preferences, and not one proposal was marked accepted, so the whole batch
  // came back on the next load and could not be cleared. Rejecting failed
  // too. Nothing above this line would have caught any of it.
  //
  // What these tests reproduce, and what they do not. The banner publishes
  // commit/discard once and stays up while the operator navigates, and its
  // button holds the callback captured on the banner's last build -- so the
  // closure can be pressed after this page's subtree has gone. That is what
  // these do: take the published closure, take the page out of the tree, call
  // it.
  //
  // That yields a *disposed* state, not the deactivated-but-still-mounted one
  // the incident hit. Flutter unmounts inactive elements in finalizeTree at
  // the end of the frame that deactivated them, so no widget test can hold
  // that window open across an await. The two differ only in where the old
  // code died: deactivated, on the snackbar's ancestor lookup inside
  // _saveKeyMappings; disposed, one line later on
  // `ref.read(proposalStateProvider.notifier)` in _commitProposals. The
  // outcome asserted here -- mappings written, nothing accepted -- is the
  // same, and it is the outcome that cost the operator the batch.
  group('accept and reject survive the page going away', () {
    testWidgets('accept still saves the mappings and marks every proposal',
        (tester) async {
      final staged = await _stageBatch(tester);
      final commit = staged.commit;
      expect(commit, isNotNull,
          reason: 'the page must publish a commit callback to the banner');

      await _removePage(tester, staged.container);
      await commit!();
      await tester.pump();

      expect(staged.proposals.accepted, [_idOne, _idTwo],
          reason: 'every staged proposal must be marked accepted, or the '
              'batch comes back on the next load');
      final saved = _savedKeys(staged.store);
      expect(saved, containsAll([_keyOne, _keyTwo]),
          reason: 'the mappings must reach preferences');
    });

    testWidgets('reject still marks every proposal rejected', (tester) async {
      final staged = await _stageBatch(tester);
      final discard = staged.discard;
      expect(discard, isNotNull);

      await _removePage(tester, staged.container);
      await discard!();
      await tester.pump();

      expect(staged.proposals.rejected, [_idOne, _idTwo]);
      final saved = _savedKeys(staged.store);
      expect(saved, isNot(contains(_keyOne)),
          reason: 'reject must not touch the mappings');
    });
  });

  // preferencesProvider is invalidated under a staged batch -- a server-config
  // import does it, and so does the reconnect re-sync. A future resolved when
  // the proposal was staged still completes, with the instance that was
  // current then, whose database may already be closed. Reading the container
  // at press time is what keeps the write going to the live one.
  //
  // Since plan 02-06 the mappings go to the configuration store rather than to
  // preferences, and the store's identity is deliberately stable across every
  // rebuild of the things beneath it — so this is now the assertion that a
  // rebuild under a staged batch changes nothing about where the batch lands.
  // The read still happens at press time, and this test still fails if it
  // stops.
  group('a staged batch survives preferences being invalidated', () {
    testWidgets('accept writes through the container read at press time',
        (tester) async {
      final staged = await _stageBatch(tester);
      final commit = staged.commit!;
      final storeBefore = await staged.container.read(configStoreProvider.future);

      staged.container.invalidate(preferencesProvider);
      // Read it back, so the rebuild actually happens: the accept no longer
      // touches preferences at all, so an invalidation nobody reads is not a
      // rebuild and the premise below would pass vacuously.
      await staged.container.read(preferencesProvider.future);
      await tester.pump();

      await commit();
      await tester.pump();

      expect(staged.prefs, hasLength(2),
          reason: 'the premise: the preferences really were rebuilt');
      expect(identical(storeBefore,
          await staged.container.read(configStoreProvider.future)), isTrue,
          reason: 'the store keeps its identity across the rebuild — that is '
              'the contract lib/providers/config_store.dart is built on');
      expect(_savedKeys(staged.store), containsAll([_keyOne, _keyTwo]),
          reason: 'the batch must land in the live store');
      expect(staged.proposals.accepted, [_idOne, _idTwo]);
    });
  });

  group('a batch that did not fully land stays up', () {
    testWidgets('a failed save accepts nothing and keeps the batch',
        (tester) async {
      // A station whose shared database is unreachable. The store refuses
      // the write outright, which is what a save that does not land looks
      // like now that the mappings are rows.
      final staged = await _stageBatch(tester, failSave: true);

      await staged.commit!();
      await tester.pump();

      expect(staged.proposals.accepted, isEmpty,
          reason: 'a proposal whose mappings did not save must stay pending, '
              'or it is lost with nothing written');
      expect(staged.commit, isNotNull,
          reason: 'the banner must keep offering Accept');
      expect(find.textContaining('Not saved — the database is unreachable.'),
          findsOneWidget);
    });

    testWidgets('an accept that only half took keeps the batch and says so',
        (tester) async {
      final staged = await _stageBatch(tester, failAccept: {_idTwo});

      await staged.commit!();
      await tester.pump();

      expect(staged.proposals.accepted, [_idOne]);
      expect(_savedKeys(staged.store), containsAll([_keyOne, _keyTwo]),
          reason: 'the save itself succeeded');
      expect(staged.commit, isNotNull,
          reason: 'the database still says pending for one of them, so the '
              'operator must be able to press Accept again');
      // Queued behind the save's own success snackbar.
      await _drainSnackBars(tester);
      expect(find.textContaining('could not be marked accepted'),
          findsOneWidget);
    });

    testWidgets('a reject that only half took keeps the batch and says so',
        (tester) async {
      final staged = await _stageBatch(tester, failReject: {_idTwo});

      await staged.discard!();
      await tester.pump();

      expect(staged.proposals.rejected, [_idOne]);
      expect(staged.discard, isNotNull);
      expect(find.textContaining('could not be marked rejected'),
          findsOneWidget);
    });
  });

  // A mapping without a resolvable server alias reads null forever, so the
  // alias is the single field the operator most needs to see before pressing
  // Accept -- and the proposal card was the one place that did not show it.
  // On 2026-08-22 a card read "4:SPB01.multivac.hmi.p_stat_Run" while the
  // accepted row directly below it read "ns=4; id=... @ st101", which made a
  // proposal that did name a server indistinguishable from one that did not.
  group('the proposal card names the server the key will be routed to', () {
    testWidgets('shows the alias the proposal carries', (tester) async {
      await _stageBatch(tester, alias: 'st101');

      expect(find.textContaining('@ st101'), findsNWidgets(2),
          reason: 'both staged proposals name their server on the card');
    });

    testWidgets('says nothing extra when the proposal names no server',
        (tester) async {
      await _stageBatch(tester);

      expect(find.textContaining('@'), findsNothing,
          reason: 'an empty alias must not render a dangling separator');
    });
  });

  // The half of the 2026-08-22 report that was *not* broken, pinned so it
  // stays that way: the alias reaches preferences intact. StateMan re-reads
  // the save from preferences, so anything dropped on this path would be
  // dropped for the live system too.
  group('accepting a proposal keeps its server alias', () {
    testWidgets('server_alias lands inside opcua_node in preferences',
        (tester) async {
      final staged = await _stageBatch(tester, alias: 'st101');

      await staged.commit!();
      await tester.pump();

      final mappings = staged.store.inner.keyMappings;
      expect(mappings.lookupServerAlias(_keyOne), 'st101');
      expect(mappings.lookupServerAlias(_keyTwo), 'st101');
      // Through the stored payload, not through the model: the row is what
      // the next station reads, and the alias has to be nested under
      // `opcua_node` in it. A top-level `server_alias` round-trips through
      // the model and is invisible to StateMan.
      expect(
        (jsonDecode(jsonEncode(mappings.toJson())) as Map)['nodes'][_keyOne]
            ['opcua_node']['server_alias'],
        'st101',
        reason: 'the alias is nested under opcua_node, and StateMan looks '
            'for it there',
      );
    });
  });

  // dispose() retires the banner's slots a frame late, because navigating away
  // disposes this page from inside a build and writing to a provider there
  // trips riverpod's "tried to modify a provider while the widget tree was
  // building" (#238). The deferral is right, but it hands the clear a window:
  // between dispose() and the next frame the ProviderScope itself can go --
  // the app shutting down, or a widget test ending -- and the controllers the
  // clear kept a handle on go with it. Reading one then throws
  // "Bad state: Tried to use StateController<...> after `dispose` was called",
  // out of a post-frame callback where nothing catches it.
  //
  // #241 hit this for real doing the same work in the alarm and page editors.
  group('the deferred clear survives the ProviderScope going too', () {
    testWidgets('a slot disposed before the next frame is left alone',
        (tester) async {
      final proposals = _RecordingProposals();
      proposals.addProposal(_proposal(_idOne, _keyOne));

      // An owning ProviderScope, not the UncontrolledProviderScope the rest of
      // this file uses: the container has to die *with* the page, in the same
      // frame, which is what shutdown looks like and what a container kept
      // alive by addTearDown never reproduces.
      await tester.pumpWidget(ProviderScope(
        overrides: [
          preferencesProvider.overrideWith((ref) async =>
              createTestPreferences(keyMappings: KeyMappings(nodes: {}))),
          databaseProvider.overrideWith((ref) async => null),
          stateManProvider
              .overrideWith((ref) => throw StateError('No StateMan in tests')),
          proposalStateProvider.overrideWith((ref) => proposals),
        ],
        child: MaterialApp(home: Scaffold(body: KeyRepositoryContent())),
      ));
      await settle(tester);

      // The scope unmounts alongside the page, so the container is disposed in
      // the build phase of this frame and the deferred clear runs at the end
      // of it, against controllers that are already gone.
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'the deferred clear must check the slots are still alive '
              'before reading them; an uncaught error out of a post-frame '
              'callback takes the shutdown down with it');
    });
  });
}

// ============================ widget test rig ============================

const _idOne = 101;
const _idTwo = 102;
const _keyOne = 'PROPOSED.KEY.ONE';
const _keyTwo = 'PROPOSED.KEY.TWO';

/// A staged batch: the container the page is running in, the notifier its
/// decisions land on, and every [Preferences] the provider has built.
class _Staged {
  _Staged(this.container, this.proposals, this.prefs, this.store);

  final ProviderContainer container;
  final _RecordingProposals proposals;
  final List<Preferences> prefs;

  /// Where the key mappings actually land, since plan 02-06.
  final GuardedConfigStore store;

  /// Read fresh each time, exactly as the banner reads them: a resolved batch
  /// clears both slots, so a non-null callback means the batch is still up.
  Future<void> Function()? get commit =>
      container.read(proposalCommitProvider);
  Future<void> Function()? get discard =>
      container.read(proposalDiscardProvider);
}

/// Pumps the key repository with a two-proposal `key_mapping` batch pending,
/// and waits for it to publish its callbacks to the banner.
Future<_Staged> _stageBatch(
  WidgetTester tester, {
  Set<int> failAccept = const {},
  Set<int> failReject = const {},
  Future<Preferences> Function()? prefsBuilder,
  /// Stands the store up with no remote, so every save is refused.
  bool failSave = false,
  String? alias,
}) async {
  final proposals = _RecordingProposals(
    failAccept: failAccept,
    failReject: failReject,
  );
  proposals.addProposal(_proposal(_idOne, _keyOne, alias: alias));
  proposals.addProposal(_proposal(_idTwo, _keyTwo, alias: alias));

  final built = <Preferences>[];
  // The alias the proposals carry has to exist in the server config too. The
  // OPC UA section renders it in a DropdownButtonFormField, which asserts
  // unless exactly one menu item matches the selected value — an alias with
  // no configured server is zero items, and the page fails to build.
  final build = prefsBuilder ??
      () => createTestPreferences(
            keyMappings: KeyMappings(nodes: {}),
            stateManConfig: StateManConfig(opcua: [
              if (alias != null)
                OpcUAConfig()
                  ..endpoint = 'opc.tcp://localhost:4840'
                  ..serverAlias = alias,
            ]),
          );
  // The plant's wiring is `config_item` rows since v1.2 phase 2 plan 06, so
  // the accept writes through the configuration store. `withRemote: false` is
  // a station whose shared database is unreachable — the store refuses every
  // write, which is how this file reproduces a save that does not land.
  final store = await createTestConfigStore(
    session: kConfiguringTestSession,
    withRemote: !failSave,
  );
  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async {
      final prefs = await build();
      built.add(prefs);
      return prefs;
    }),
    configStoreProvider.overrideWith((ref) async => store),
    databaseProvider.overrideWith((ref) async => null),
    stateManProvider
        .overrideWith((ref) => throw StateError('No StateMan in tests')),
    proposalStateProvider.overrideWith((ref) => proposals),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Scaffold(body: KeyRepositoryContent())),
  ));
  await settle(tester);

  return _Staged(container, proposals, built, store);
}

/// Advances fake time far enough for a queued snackbar to replace the one in
/// front of it (the default 4 s, plus both animations).
Future<void> _drainSnackBars(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// Takes the page out of the tree, leaving the app (and its messenger) up.
///
/// The section's State is disposed by the end of this frame; the callbacks the
/// banner captured are not.
Future<void> _removePage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
  ));
  await tester.pump();
}

PendingProposal _proposal(int id, String key, {String? alias}) =>
    PendingProposal(
      id: id,
      proposalType: 'key_mapping',
      title: 'map $key',
      proposalJson: jsonEncode({
        '_proposal_type': 'key_mapping',
        // Built through the model rather than by hand, because where the
        // alias sits is the whole point: `server_alias` belongs *inside*
        // `opcua_node`, not at the top of the proposal. An audit that looks
        // at the top level reports a false negative.
        'key': key,
        'opcua_node': (OpcUANodeConfig(namespace: 2, identifier: key)
              ..serverAlias = alias)
            .toJson(),
      }),
      operatorId: 'ai',
      createdAt: DateTime(2026, 8, 21),
    );

Iterable<String> _savedKeys(GuardedConfigStore store) =>
    store.inner.keyMappings.nodes.keys;

/// Records what the page decided, and can make a chosen id throw instead.
///
/// The throwing is what the partial-failure counter needs: the page reports
/// how many of a batch went through, so a test has to be able to fail one
/// decision and let the rest succeed. Nothing here reaches a database --
/// accepting a proposal is an in-memory state change -- so the failure is
/// injected directly rather than by taking a connection away.
class _RecordingProposals extends ProposalStateNotifier {
  _RecordingProposals({
    this.failAccept = const {},
    this.failReject = const {},
  }) : super();

  final Set<int> failAccept;
  final Set<int> failReject;
  final List<int> accepted = [];
  final List<int> rejected = [];

  @override
  Future<void> acceptProposal(int id) async {
    if (failAccept.contains(id)) throw StateError('database is gone');
    accepted.add(id);
    await super.acceptProposal(id);
  }

  @override
  Future<void> rejectProposal(int id) async {
    if (failReject.contains(id)) throw StateError('database is gone');
    rejected.add(id);
    await super.rejectProposal(id);
  }
}


