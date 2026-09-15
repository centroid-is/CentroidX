import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/proposal_state.dart';

/// Tests for the reactive proposal listeners in the three editors:
///   - AlarmEditorPage (alarm_editor.dart)
///   - PageEditor (page_editor.dart)
///   - KeyRepositoryEditor (key_repository.dart)
///
/// Each editor has a `ref.listen<ProposalState>(proposalStateProvider, ...)`
/// callback in its `build()` method that reactively picks up proposals as
/// they arrive via MCP, without requiring navigation.
///
/// Since these editors have heavy provider dependencies (AlarmMan, PageManager,
/// StateManConfig, etc.), we test:
///   1. Source-level assertions verifying the listener wiring exists and is
///      correct (same pattern as the other proposal tests).
///   2. Unit tests on ProposalStateNotifier verifying the filtering logic
///      that the listener callbacks depend on.
///
/// The shape they pin changed on 2026-08-19. Each listener used to stage the
/// *first* matching proposal and then guard itself with `if (_isProposal)
/// return`, so everything queued behind it was invisible until that one was
/// resolved. An MCP client fires create_alarm / create_key_mapping /
/// update_asset one call per item, so a set of 38 alarms arrived as 38
/// proposals and cost 38 reviews and 38 saves. Now every listener stages the
/// whole pending queue, re-entry is safe (ids already staged are skipped
/// instead of being blocked by a flag), and accept/reject happen once, in the
/// black banner, through the commit/discard callbacks each editor publishes.
void main() {
  late String alarmEditorSource;
  late String pageEditorSource;
  late String keyRepoSource;

  setUpAll(() {
    alarmEditorSource = File('lib/pages/alarm_editor.dart').readAsStringSync();
    pageEditorSource = File('lib/pages/page_editor.dart').readAsStringSync();
    keyRepoSource = File('lib/pages/key_repository.dart').readAsStringSync();
  });

  // ── Helper ──────────────────────────────────────────────────────────────

  PendingProposal makeProposal({
    int id = 1,
    String type = 'alarm',
    String title = 'Test',
    String json = '{"_proposal_type":"alarm"}',
    String operator = 'op1',
  }) =>
      PendingProposal(
        id: id,
        proposalType: type,
        title: title,
        proposalJson: json,
        operatorId: operator,
        createdAt: DateTime.now(),
      );

  /// The region of each editor that decides which proposal types it takes.
  ///
  /// The alarm editor and the key repository moved that decision out of the
  /// listener and into their staging methods; the page editor still filters in
  /// the listener because it routes three different proposal types to three
  /// different apply methods.
  String alarmStaging() =>
      _extractMethodBody(alarmEditorSource, 'int _stageAlarmProposals()')!;
  String keyStaging() =>
      _extractMethodBody(keyRepoSource, 'int _stageKeyMappingProposals()')!;
  String pageFilter() =>
      _extractListenerBody(pageEditorSource, 'ref.listen<ProposalState>')!;
  String pageBatch() => _extractMethodBody(
      pageEditorSource, 'int _applyAssetBatch(List<PendingProposal>')!;

  // ── Source-level: all three editors have ref.listen wiring ─────────────

  group('Reactive listener wiring exists in all three editors', () {
    test('AlarmEditorPage has ref.listen on proposalStateProvider', () {
      expect(alarmEditorSource,
          contains('ref.listen<ProposalState>(proposalStateProvider'));
    });

    test('PageEditor has ref.listen on proposalStateProvider', () {
      expect(pageEditorSource,
          contains('ref.listen<ProposalState>(proposalStateProvider'));
    });

    test('KeyRepositoryEditor has ref.listen on proposalStateProvider', () {
      expect(keyRepoSource,
          contains('ref.listen<ProposalState>(proposalStateProvider'));
    });
  });

  // ── Source-level: listener is inside build() (reactive on every rebuild) ─

  group('Listener is inside build() for reactivity', () {
    test('AlarmEditorPage listener is in build method', () {
      final buildBody = _extractMethodBody(alarmEditorSource, 'Widget build(');
      expect(buildBody, isNotNull,
          reason: 'AlarmEditorPage must have a build method');
      expect(buildBody, contains('ref.listen<ProposalState>'),
          reason: 'ref.listen must be inside build()');
    });

    test('PageEditor listener is in build method', () {
      final buildBody = _extractMethodBody(pageEditorSource, 'Widget build(');
      expect(buildBody, isNotNull,
          reason: 'PageEditor must have a build method');
      expect(buildBody, contains('ref.listen<ProposalState>'),
          reason: 'ref.listen must be inside build()');
    });

    test('KeyRepositoryEditor listener is in a build method', () {
      // KeyRepositoryPage delegates through nested widgets; find the build()
      // that actually contains the ref.listen call.
      var searchFrom = 0;
      bool found = false;
      while (true) {
        final idx = keyRepoSource.indexOf('Widget build(', searchFrom);
        if (idx == -1) break;
        final braceStart = keyRepoSource.indexOf('{', idx);
        final buildBody = _extractBraceBlock(keyRepoSource, braceStart);
        if (buildBody != null &&
            buildBody.contains('ref.listen<ProposalState>')) {
          found = true;
          break;
        }
        searchFrom = idx + 1;
      }
      expect(found, isTrue,
          reason: 'ref.listen<ProposalState> must be inside a build() method');
    });
  });

  // ── Source-level: a later proposal joins the batch, it is not blocked ───

  group('No "already showing one" guard blocks the rest of the queue', () {
    test('AlarmEditorPage does not bail out when a batch is staged', () {
      final listenerBody =
          _extractListenerBody(alarmEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull, reason: 'Must find the listener callback');
      expect(listenerBody, isNot(contains('if (_isProposal) return')),
          reason: 'that guard swallowed every proposal after the first');
    });

    test('KeyRepositoryEditor does not bail out when a batch is staged', () {
      final listenerBody =
          _extractListenerBody(keyRepoSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody, isNot(contains('if (_isProposal) return')));
    });

    test('PageEditor batches asset proposals before reaching its guard', () {
      // Only a `page` proposal replaces a whole page, so only that one is
      // still shown on its own. `asset` and `asset_update` both have to be
      // folded in first, or anything landing while one is staged is
      // swallowed -- seven new assets staged one and dropped six.
      final listenerBody =
          _extractListenerBody(pageEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      final batch = listenerBody!.indexOf('_applyAssetBatch(assetProposals)');
      final guard = listenerBody.indexOf('if (_isProposal) return');
      expect(batch, greaterThan(-1));
      expect(guard, greaterThan(-1));
      expect(batch, lessThan(guard),
          reason: 'the batch path must run before the single-proposal guard');
    });
  });

  // ── Source-level: double-apply is prevented by id, not by a flag ────────

  group('Re-entry is safe: ids already staged are skipped', () {
    test('AlarmEditorPage skips ids already in the batch', () {
      expect(alarmStaging(), contains('_proposalIds.contains(p.id)'));
    });

    test('KeyRepositoryEditor skips ids already in the batch', () {
      expect(keyStaging(), contains('_proposalIds.contains(p.id)'));
    });

    test('PageEditor skips ids already staged and ids already resolved', () {
      // acceptProposal/rejectProposal await a database write before dropping
      // the proposal from state, so their removals fire the listener after the
      // batch has been cleared. Without the consumed set the listener treats
      // the leftovers as a new batch and re-applies them -- which is how a
      // reject left the change on the page.
      expect(pageBatch(), contains('_proposalIds.contains(p.id)'));
      expect(pageBatch(), contains('_consumedProposalIds.contains(p.id)'));
    });
  });

  // ── Source-level: correct proposal type filtering per editor ────────────

  group('Type filtering: each editor filters for its own proposal types', () {
    test('AlarmEditorPage filters for alarm, alarm_create, alarm_update', () {
      final filter = alarmStaging();
      expect(filter, contains("'alarm'"));
      expect(filter, contains("'alarm_create'"));
      expect(filter, contains("'alarm_update'"));
      expect(filter.contains("'page'"), isFalse,
          reason: 'Alarm editor must not match page proposals');
      expect(filter.contains("'key_mapping'"), isFalse,
          reason: 'Alarm editor must not match key_mapping proposals');
    });

    test('PageEditor filters for page, asset and asset_update', () {
      final filter = pageFilter();
      expect(filter, contains("'page'"));
      expect(filter, contains("'asset'"));
      // asset_update arrives from the update_asset MCP tool. Without it the
      // proposal reaches ProposalState but the editor never picks it up, so
      // the operator sees nothing to save.
      expect(filter, contains("'asset_update'"));
      expect(filter.contains("'alarm'"), isFalse,
          reason: 'Page editor must not match alarm proposals');
      expect(filter.contains("'key_mapping'"), isFalse,
          reason: 'Page editor must not match key_mapping proposals');
    });

    test('KeyRepositoryEditor filters for key_mapping only', () {
      final filter = keyStaging();
      expect(filter, contains("'key_mapping'"));
      expect(filter.contains("'alarm'"), isFalse,
          reason: 'Key repo must not match alarm proposals');
      expect(filter.contains("'page'"), isFalse,
          reason: 'Key repo must not match page proposals');
      expect(filter.contains("'asset'"), isFalse,
          reason: 'Key repo must not match asset proposals');
    });
  });

  // ── Source-level: the whole queue is staged, not just the first ─────────

  group('Each editor stages the whole pending queue', () {
    test('AlarmEditorPage walks every pending proposal', () {
      expect(alarmStaging(), contains('for (final p in state.proposals)'));
      expect(alarmStaging(), isNot(contains('.first')),
          reason: 'staging one alarm meant one review and one save per alarm');
    });

    test('KeyRepositoryEditor walks every pending proposal', () {
      expect(keyStaging(), contains('for (final p in state.proposals)'));
      expect(keyStaging(), isNot(contains('.first')));
    });

    test('PageEditor hands the whole asset run to the batch', () {
      final listenerBody = pageFilter();
      // The whole matching run, never `.first`.
      expect(listenerBody, contains('.where((p) =>'));
      expect(listenerBody, contains("p.proposalType == 'asset' ||"));
      expect(listenerBody, contains("p.proposalType == 'asset_update'"));
      expect(listenerBody, contains('_applyAssetBatch(assetProposals)'));
      expect(pageBatch(), contains('for (final p in proposals)'));
    });

    test('PageEditor still takes page proposals one at a time', () {
      // A `page` proposal replaces or creates a whole page, so folding a run
      // of them together has no defined result. `asset` appends, which does,
      // so it moved to the batch -- it is the else branch that is left.
      //
      // `.first` is taken off the page-only list, not off the whole matching
      // run: once asset proposals are partitioned by page an off-page asset
      // can outlive the batch and sit at the head of the run, and applying
      // its json as a whole-page replacement would wipe the open page.
      final listener = pageFilter();
      expect(listener, contains('pageOnly.first.proposalJson'));
      expect(listener.indexOf('_applyAssetBatch(assetProposals)'),
          lessThan(listener.indexOf('pageOnly.first.proposalJson')));
    });
  });

  // ── Source-level: listener calls the correct stage/apply method ─────────

  group('Listener delegates to the correct stage/apply method', () {
    test('AlarmEditorPage calls _stageAlarmProposals', () {
      final listenerBody =
          _extractListenerBody(alarmEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody, contains('_stageAlarmProposals()'));
    });

    test('PageEditor calls _applyAssetBatch and _applyProposalData', () {
      final listenerBody =
          _extractListenerBody(pageEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody, contains('_applyAssetBatch'));
      expect(listenerBody, contains('_applyProposalData'));
    });

    test('KeyRepositoryEditor calls _stageKeyMappingProposals', () {
      final listenerBody =
          _extractListenerBody(keyRepoSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody, contains('_stageKeyMappingProposals()'));
    });
  });

  // ── Source-level: listener rebuilds only when something was staged ──────

  group('Listener calls setState only when something was newly staged', () {
    test('AlarmEditorPage rebuilds on a non-zero stage count', () {
      final listenerBody =
          _extractListenerBody(alarmEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody,
          contains('_stageAlarmProposals() + _dropDecidedElsewhere(next)'));
      expect(listenerBody, contains('if (changed > 0) setState(() {});'),
          reason: 'an unconditional setState rebuilds on every unrelated '
              'proposal state change');
    });

    test('PageEditor rebuilds after applying', () {
      final listenerBody =
          _extractListenerBody(pageEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody, contains('if (_isProposal) {'));
      expect(listenerBody, contains('setState(() {});'));
    });

    test('KeyRepositoryEditor rebuilds on a non-zero stage count', () {
      final listenerBody =
          _extractListenerBody(keyRepoSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      expect(listenerBody,
          contains('_stageKeyMappingProposals() + _dropDecidedElsewhere(next)'));
      expect(listenerBody, contains('if (changed > 0) setState(() {});'));
    });
  });

  // ── Source-level: nothing is dereferenced off an empty queue ────────────

  group('Listener returns early when no matching proposals exist', () {
    test('AlarmEditorPage stages zero and does nothing', () {
      // No .first to protect any more -- the loop simply adds nothing and the
      // return value is 0, which suppresses the rebuild.
      expect(alarmStaging(), contains('var added = 0;'));
      expect(alarmStaging(), contains('return added;'));
    });

    test('KeyRepositoryEditor stages zero and does nothing', () {
      expect(keyStaging(), contains('var added = 0;'));
      expect(keyStaging(), contains('return added;'));
    });

    test('PageEditor checks isEmpty before accessing .first', () {
      final listenerBody =
          _extractListenerBody(pageEditorSource, 'ref.listen<ProposalState>');
      expect(listenerBody, isNotNull);
      final isEmptyIdx = listenerBody!.indexOf('.isEmpty');
      final firstIdx = listenerBody.indexOf('.first');
      expect(isEmptyIdx, greaterThan(-1));
      expect(isEmptyIdx, lessThan(firstIdx),
          reason: 'isEmpty guard must come before .first access');
    });
  });

  // ── Source-level: staging reads proposalJson, not just the type ─────────

  group('Staging parses proposalJson', () {
    test('AlarmEditorPage decodes p.proposalJson', () {
      expect(alarmStaging(), contains('jsonDecode(p.proposalJson)'));
    });

    test('PageEditor decodes p.proposalJson in the batch', () {
      expect(pageBatch(), contains('jsonDecode(p.proposalJson)'));
    });

    test('KeyRepositoryEditor decodes p.proposalJson', () {
      expect(keyStaging(), contains('jsonDecode(p.proposalJson)'));
    });

    test('a malformed proposal does not take the batch with it', () {
      for (final entry in {
        'AlarmEditor': alarmStaging(),
        'PageEditor': pageBatch(),
        'KeyRepository': keyStaging(),
      }.entries) {
        expect(entry.value, contains('is! Map<String, dynamic>'),
            reason: '${entry.key} must skip a non-object proposal');
        // Per proposal, inside the loop -- the catch is what keeps one bad
        // decode from stranding the rest of the queue. The page editor now
        // names the error and reports it instead of swallowing it, so match
        // the construct rather than the exact bare spelling.
        expect(entry.value, matches(RegExp(r'\} catch \((_|e)\) \{')),
            reason: '${entry.key} must survive one bad decode');
      }
    });
  });

  // ── Source-level: no overlapping type filters across editors ────────────

  group('No overlapping type filters across editors (isolation)', () {
    test('alarm types are only handled by AlarmEditorPage', () {
      for (final alarmType in ['alarm', 'alarm_create', 'alarm_update']) {
        expect(pageFilter().contains("'$alarmType'"), isFalse,
            reason: 'PageEditor must not handle $alarmType');
        expect(keyStaging().contains("'$alarmType'"), isFalse,
            reason: 'KeyRepository must not handle $alarmType');
      }
    });

    test('page/asset types are only handled by PageEditor', () {
      for (final pageType in ['page', 'asset', 'asset_update']) {
        expect(alarmStaging().contains("'$pageType'"), isFalse,
            reason: 'AlarmEditor must not handle $pageType');
        expect(keyStaging().contains("'$pageType'"), isFalse,
            reason: 'KeyRepository must not handle $pageType');
      }
    });

    test('key_mapping type is only handled by KeyRepositoryEditor', () {
      expect(alarmStaging().contains("'key_mapping'"), isFalse,
          reason: 'AlarmEditor must not handle key_mapping');
      expect(pageFilter().contains("'key_mapping'"), isFalse,
          reason: 'PageEditor must not handle key_mapping');
    });
  });

  // ── Unit tests: ProposalState filtering matches listener logic ─────────

  group('ProposalState.ofType filtering matches listener type filters', () {
    test('alarm proposals are found by ofType for all alarm subtypes', () {
      final state = ProposalState(proposals: [
        makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'),
        makeProposal(id: 2, type: 'alarm_create', json: '{"uid":"ac1"}'),
        makeProposal(id: 3, type: 'alarm_update', json: '{"uid":"au1"}'),
        makeProposal(id: 4, type: 'page', json: '{"uid":"p1"}'),
        makeProposal(id: 5, type: 'key_mapping', json: '{"uid":"k1"}'),
      ]);

      // _stageAlarmProposals() skips anything that is not one of the three
      // alarm types. Simulate that filter:
      final alarmMatches = state.proposals.where((p) =>
          p.proposalType == 'alarm' ||
          p.proposalType == 'alarm_create' ||
          p.proposalType == 'alarm_update');
      expect(alarmMatches, hasLength(3));
      expect(alarmMatches.map((p) => p.id), containsAll([1, 2, 3]));
    });

    test('page proposals are found by ofType for page and asset', () {
      final state = ProposalState(proposals: [
        makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'),
        makeProposal(id: 2, type: 'page', json: '{"uid":"p1"}'),
        makeProposal(id: 3, type: 'asset', json: '{"uid":"as1"}'),
        makeProposal(id: 4, type: 'key_mapping', json: '{"uid":"k1"}'),
        makeProposal(id: 5, type: 'asset_update', json: '{"uid":"au1"}'),
      ]);

      final pageMatches = state.proposals.where((p) =>
          p.proposalType == 'page' ||
          p.proposalType == 'asset' ||
          p.proposalType == 'asset_update');
      expect(pageMatches, hasLength(3));
      expect(pageMatches.map((p) => p.id), containsAll([2, 3, 5]));
    });

    test('key_mapping proposals are found by ofType', () {
      final state = ProposalState(proposals: [
        makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'),
        makeProposal(id: 2, type: 'key_mapping', json: '{"uid":"k1"}'),
        makeProposal(id: 3, type: 'page', json: '{"uid":"p1"}'),
      ]);

      final keyMatches =
          state.proposals.where((p) => p.proposalType == 'key_mapping');
      expect(keyMatches, hasLength(1));
      expect(keyMatches.first.id, 2);
    });

    test('empty state yields no matches for any editor filter', () {
      const state = ProposalState();

      final alarmMatches = state.proposals.where((p) =>
          p.proposalType == 'alarm' ||
          p.proposalType == 'alarm_create' ||
          p.proposalType == 'alarm_update');
      expect(alarmMatches, isEmpty);

      final pageMatches = state.proposals
          .where((p) => p.proposalType == 'page' || p.proposalType == 'asset');
      expect(pageMatches, isEmpty);

      final keyMatches =
          state.proposals.where((p) => p.proposalType == 'key_mapping');
      expect(keyMatches, isEmpty);
    });

    test('the batch keeps queue order, oldest proposal first', () {
      final state = ProposalState(proposals: [
        makeProposal(
            id: 10, type: 'alarm', title: 'First alarm', json: '{"uid":"fa"}'),
        makeProposal(
            id: 20, type: 'alarm', title: 'Second alarm', json: '{"uid":"sa"}'),
        makeProposal(
            id: 30,
            type: 'alarm_create',
            title: 'Third alarm',
            json: '{"uid":"ta"}'),
      ]);

      final alarmMatches = state.proposals.where((p) =>
          p.proposalType == 'alarm' ||
          p.proposalType == 'alarm_create' ||
          p.proposalType == 'alarm_update');
      // The staged list is what the operator reads in the editor and what the
      // commit loop writes, so it has to follow the order they arrived in.
      expect(alarmMatches.map((p) => p.id).toList(), [10, 20, 30]);
      expect(alarmMatches.first.title, 'First alarm');
    });
  });

  // ── Unit tests: ProposalStateNotifier addProposal triggers listeners ───

  group('ProposalStateNotifier state changes trigger listener callbacks', () {
    test('addProposal changes state (would fire ref.listen)', () {
      final notifier = ProposalStateNotifier();
      final states = <ProposalState>[];

      notifier.addListener((state) {
        states.add(state);
      });

      notifier.addProposal(
          makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'));
      // StateNotifier fires listener for initial state + each change
      expect(states.last.proposals, hasLength(1));
    });

    test('a second proposal fires the listener again', () {
      // This is the case the old `if (_isProposal) return` guard threw away:
      // the state change arrives, but the editor refused to look at it.
      final notifier = ProposalStateNotifier();
      final states = <ProposalState>[];
      notifier.addListener(states.add);

      notifier.addProposal(
          makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'));
      final afterFirst = states.length;
      notifier.addProposal(
          makeProposal(id: 2, type: 'alarm', json: '{"uid":"a2"}'));
      expect(states.length, greaterThan(afterFirst));
      expect(states.last.proposals, hasLength(2));
    });

    test('addProposal of wrong type does not match another editors filter', () {
      final notifier = ProposalStateNotifier();
      notifier.addProposal(
          makeProposal(id: 1, type: 'key_mapping', json: '{"uid":"k1"}'));

      // Simulate alarm editor staging filter
      final alarmMatches = notifier.state.proposals.where((p) =>
          p.proposalType == 'alarm' ||
          p.proposalType == 'alarm_create' ||
          p.proposalType == 'alarm_update');
      expect(alarmMatches, isEmpty,
          reason: 'key_mapping proposal must not trigger alarm editor');
    });

    test('duplicate addProposal does not re-trigger state change', () {
      final notifier = ProposalStateNotifier();
      final states = <ProposalState>[];

      notifier.addListener((state) {
        states.add(state);
      });

      notifier.addProposal(makeProposal(id: 1, json: '{"uid":"dup"}'));
      final countAfterFirst = states.length;
      notifier.addProposal(makeProposal(id: 1, json: '{"uid":"dup"}'));
      // Second add is a duplicate — no additional state change
      expect(states.length, countAfterFirst,
          reason: 'Duplicate addProposal must not trigger state change');
    });

    test('acceptProposal removes from state (listener would see empty)',
        () async {
      final notifier = ProposalStateNotifier();
      notifier
          .addProposal(makeProposal(id: 1, type: 'alarm', json: '{"uid":"a1"}'));
      expect(notifier.state.proposals, hasLength(1));

      await notifier.acceptProposal(1);
      // After accept, the alarm editor listener would see empty alarm proposals
      final alarmMatches = notifier.state.proposals.where((p) =>
          p.proposalType == 'alarm' ||
          p.proposalType == 'alarm_create' ||
          p.proposalType == 'alarm_update');
      expect(alarmMatches, isEmpty);
    });

    test('accepting a batch drops the rows one at a time', () async {
      // Each removal is its own state change, so each one fires the listener
      // while the rest are still pending. That is why every editor tracks the
      // ids it has already resolved instead of trusting the flag.
      final notifier = ProposalStateNotifier();
      for (var id = 1; id <= 3; id++) {
        notifier.addProposal(
            makeProposal(id: id, type: 'alarm', json: '{"uid":"a$id"}'));
      }
      final seen = <int>[];
      notifier.addListener((s) => seen.add(s.proposals.length));

      await notifier.acceptProposal(1);
      await notifier.acceptProposal(2);
      await notifier.acceptProposal(3);
      expect(notifier.state.proposals, isEmpty);
      expect(seen, containsAllInOrder([3, 2, 1, 0]));
    });
  });

  // ── Source-level: consistency checks across all three editors ───────────

  group('Consistency: all editors follow the same reactive listener pattern',
      () {
    test('all editors use (prev, next) callback signature', () {
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        final listener =
            _extractListenerBody(entry.value, 'ref.listen<ProposalState>');
        expect(listener, isNotNull,
            reason: '${entry.key} must have a ProposalState listener');
      }
      // The callback signatures are inside the ref.listen call — we already
      // validated them by extracting the listener body successfully.
    });

    test('no editor makes a decision from the previous state', () {
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        final listener =
            _extractListenerBody(entry.value, 'ref.listen<ProposalState>');
        expect(listener!.contains('prev.'), isFalse,
            reason: '${entry.key} must act on the new state, not a diff');
      }
    });

    test('all editors read the current queue, not a single proposal', () {
      expect(alarmStaging(), contains('ref.read(proposalStateProvider)'));
      expect(keyStaging(), contains('ref.read(proposalStateProvider)'));
      expect(pageFilter(), contains('next.proposals'));
    });

    test('all editors keep a list of proposal ids', () {
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        expect(entry.value, contains('_proposalIds'),
            reason: '${entry.key} must track the whole batch');
        // Emptied whole, or one entry at a time now that a batch can be
        // decided one row at a time.
        expect(
            entry.value,
            anyOf(contains('_proposalIds.clear()'),
                contains('_proposalIds.removeAt(i)')),
            reason: '${entry.key} must drop resolved proposals from the batch');
      }
    });

    test('all editors expose _isProposal', () {
      // Two of them derive it from the staged batch so the flag cannot drift
      // out of step with what is actually on screen; the page editor still
      // holds it as a field because a `page` proposal stages pages rather
      // than a list of proposed items.
      expect(alarmEditorSource,
          contains('bool get _isProposal => _proposedAlarms.isNotEmpty'));
      expect(keyRepoSource,
          contains('bool get _isProposal => _proposedMappings.isNotEmpty'));
      expect(pageEditorSource, contains('bool _isProposal = false;'));
    });

    test('all editors publish commit/discard to the banner', () {
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        expect(entry.value, contains('proposalCommitProvider'),
            reason: '${entry.key} must hand the banner a commit');
        expect(entry.value, contains('proposalDiscardProvider'),
            reason: '${entry.key} must hand the banner a discard');
      }
    });

    test('all editors clear the callbacks on dispose', () {
      // The banner holds these closures over the State; left set they fire
      // into a disposed State after navigating away.
      //
      // Cleared through a captured StateController, not `ref`: Riverpod
      // throws "Cannot use ref after the widget was disposed" from inside
      // ConsumerState.dispose(), which took out 62 widget tests when this
      // was first written the obvious way.
      //
      // The slot and the write, not one exact line. KeyRepository defers the
      // write to a post-frame callback because navigating away disposes it
      // from inside a build, and writing to a provider there trips
      // "tried to modify a provider while the widget tree was building". The
      // other two clear inline and have the same hole; this accepts either
      // shape rather than pretending they already agree.
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        final dispose = _extractMethodBody(entry.value, 'void dispose() {');
        expect(dispose, isNotNull, reason: '${entry.key} must have dispose()');
        expect(dispose, contains('_commitSlot'),
            reason: '${entry.key} must drop its commit callback');
        expect(dispose, contains('_discardSlot'),
            reason: '${entry.key} must drop its discard callback');
        expect(dispose, contains('state = null'),
            reason: '${entry.key} must clear both slots');
        expect(dispose, isNot(contains('ref.read')),
            reason: '${entry.key} must not touch ref in dispose() -- Riverpod '
                'throws there; the controllers are captured on publish');
      }
    });

    test('no editor keeps an inline Accept/Reject control', () {
      // The black banner is the one place a proposal is acted on. Two
      // competing controls meant an operator could accept in one place while
      // the other still showed the change as pending.
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        expect(entry.value.contains("child: const Text('Accept')"), isFalse,
            reason: '${entry.key} must not offer an inline Accept');
        expect(entry.value.contains("child: const Text('Reject')"), isFalse,
            reason: '${entry.key} must not offer an inline Reject');
      }
    });

    test('all editors await acceptProposal instead of firing and forgetting',
        () {
      for (final entry in {
        'AlarmEditor': alarmEditorSource,
        'PageEditor': pageEditorSource,
        'KeyRepository': keyRepoSource,
      }.entries) {
        expect(entry.value, contains('await notifier.acceptProposal(id)'),
            reason: '${entry.key} must wait for the database write');
      }
    });
  });
}

/// Extracts the body of a method whose signature contains [methodSignature].
///
/// Returns the content from the first `{` after the signature to its matching
/// `}`. Returns null if not found.
String? _extractMethodBody(String source, String methodSignature) {
  final methodIndex = source.indexOf(methodSignature);
  if (methodIndex == -1) return null;

  final braceStart = source.indexOf('{', methodIndex);
  if (braceStart == -1) return null;

  var depth = 0;
  for (var i = braceStart; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) {
      return source.substring(braceStart, i + 1);
    }
  }
  return null;
}

/// Extracts a brace-delimited block starting at [braceStart].
String? _extractBraceBlock(String source, int braceStart) {
  if (braceStart < 0 || braceStart >= source.length) return null;
  var depth = 0;
  for (var i = braceStart; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) return source.substring(braceStart, i + 1);
  }
  return null;
}

/// Extracts the callback body of a `ref.listen<ProposalState>(...)` call.
///
/// Finds the listener invocation matching [listenerCall], then extracts the
/// lambda body `(prev, next) { ... }` — specifically, the content between the
/// first `{` inside that call and its matching `}`.
///
/// This is a heuristic parser that works for the simple single-lambda pattern
/// used in all three editors. Returns null if not found.
String? _extractListenerBody(String source, String listenerCall) {
  final callIndex = source.indexOf(listenerCall);
  if (callIndex == -1) return null;

  // Find the opening `{` of the callback lambda.
  // Skip the opening `(` of ref.listen to find the lambda body.
  final lambdaStart = source.indexOf('{', callIndex);
  if (lambdaStart == -1) return null;

  var depth = 0;
  for (var i = lambdaStart; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) {
      return source.substring(lambdaStart, i + 1);
    }
  }
  return null;
}
