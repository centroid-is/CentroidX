@TestOn('vm')

/// The relayed history-view surface: what it translates and what it must not.
///
/// The gateway already decides. `PolicyStateMan._PolicyHistoryViews` asks
/// `AccessPolicy.groupForHistoryView` — the one master policy, which
/// `packages/tfc_relay_server` reaches through `tfc_access` — writes the deny
/// row, and refuses with `forbidden`. Nothing in this file re-decides anything,
/// and `test/core/no_second_policy_test.dart` is what keeps that true.
///
/// What this file pins is the **one** thing the app-side adapter adds, and why
/// it had to be added at all: `RemoteStateMan._dataServiceCall` does not go
/// through the client's `withAccessErrors` — that wrapper is applied inside the
/// four *access* proxies only — so a `forbidden` on a history-view write
/// arrives as a bare `RpcException`. It falls straight through the five
/// `on AccessDenied` catches in `lib/pages/history_view.dart`, and the page
/// then carries on to `setState`, invalidate the picker and toast "Deleted"
/// for a delete that did not happen. A refusal the operator cannot see, and a
/// screen that says the opposite of the truth.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc/core/relayed_history_views.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

/// The gateway's refusal, in its own words and with the payload it really
/// sends — `substitutedRequest`, which carries the method and **no** itemKey
/// and **no** group, deliberately, because echoing a request that may hold a
/// non-finite number is what makes the error itself unencodable.
rpc.RpcException _forbidden(String method) => rpc.RpcException(
      -32005,
      'a permission is missing, so "$method" was refused. Deleting a saved '
      'view: nothing was changed, so this call definitively had no effect. '
      'Do not retry',
      data: <String, Object?>{'method': method, 'request': 'omitted'},
    );

/// A far end that refuses, or answers, on demand.
final class _ScriptedApi implements HistoryViewApi {
  Object? failure;
  int calls = 0;

  Future<T> _answer<T>(T value) async {
    calls++;
    final boom = failure;
    if (boom != null) throw boom;
    return value;
  }

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _answer(1);

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _answer(null);

  @override
  Future<void> deleteHistoryView(int id) => _answer(null);

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      _answer(2);

  @override
  Future<void> deleteHistoryViewPeriod(int id) => _answer(null);

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() =>
      _answer(const <HistoryViewRecord>[]);

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(int viewId) =>
      _answer(const <String, HistoryViewKeyRecord>{});

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(int viewId) =>
      _answer(const <int, HistoryViewGraphRecord>{});

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) =>
      _answer(const <String>[]);

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(int viewId) =>
      _answer(const <HistoryViewPeriodRecord>[]);

  @override
  Future<DateTime?> getGlobalRetentionHorizon() => _answer(null);
}

/// A file's source with comments stripped — the house rule
/// `no_second_policy_test.dart` states: a bare count on unfiltered text is
/// self-invalidating the moment somebody names the token in a doc comment,
/// and the file under test names two grades in its own prose.
String _uncommented(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final idx = line.indexOf('//');
      return idx == -1 ? line : line.substring(0, idx);
    })
    .join('\n');

void main() {
  late _ScriptedApi api;
  late List<AccessDenied> prompted;
  late RelayedHistoryViews views;

  setUp(() {
    api = _ScriptedApi();
    prompted = <AccessDenied>[];
    views = RelayedHistoryViews(api: api, onDenied: prompted.add);
  });

  group('a gateway refusal becomes the exception the page already catches', () {
    test('deleteHistoryView: forbidden arrives as AccessDenied', () async {
      api.failure = _forbidden('historyViews.deleteHistoryView');

      await expectLater(views.deleteHistoryView(4),
          throwsA(isA<AccessDenied>()));
    });

    test('every write translates it, not just the destructive two', () async {
      final calls = <String, Future<void> Function()>{
        'create': () => views.createHistoryView('v', const ['a']),
        'update': () => views.updateHistoryView(1, 'v', const ['a']),
        'delete': () => views.deleteHistoryView(1),
        'addPeriod': () => views.addHistoryViewPeriod(
            1, 'p', DateTime.utc(2026), DateTime.utc(2026, 1, 2)),
        'deletePeriod': () => views.deleteHistoryViewPeriod(1),
      };

      for (final entry in calls.entries) {
        api.failure = _forbidden('historyViews.${entry.key}');
        await expectLater(entry.value(), throwsA(isA<AccessDenied>()),
            reason: '"${entry.key}" is open on today\'s policy, so it is the '
                'arm that makes tightening AccessPolicy.groupForHistoryView a '
                'one-line change rather than a bug: the gateway would start '
                'refusing it and the panel would fall through the catch');
      }
    });

    test('the gateway\'s own sentence survives — it is not rebuilt from the '
        'itemKey and the group', () async {
      api.failure = _forbidden('historyViews.deleteHistoryView');

      final denial = await views
          .deleteHistoryView(4)
          .then<Object?>((_) => null)
          .onError<AccessDenied>((e, _) => e);

      expect('$denial', contains('definitively had no effect'),
          reason: 'the wording is the operator\'s half: it says the call had '
              'no effect and must not be retried, on exactly the transport '
              'where a retry is most tempting. A re-raise that rebuilt the '
              'sentence from itemKey + group alone would drop it');
    });

    test('the denial names the group the ONE policy states for that member',
        () async {
      const policy = AccessPolicy();
      api.failure = _forbidden('historyViews.deleteHistoryView');

      final denial = await views
          .deleteHistoryView(4)
          .then<AccessDenied?>((_) => null)
          .onError<AccessDenied>((e, _) => e);

      expect(denial!.required,
          policy.groupForHistoryView(AccessPolicy.historyViewDelete),
          reason: 'the verdict was the gateway\'s; only the label is local, '
              'and it is read out of the same AccessPolicy method the gateway '
              'asked. A group hard-coded here would be the second policy '
              'no_second_policy_test.dart exists to refuse — and it would put '
              'the wrong permission in front of the operator');
      expect(denial.itemKey, contains(AccessPolicy.historyViewDelete),
          reason: 'the wire carries no itemKey (substitutedRequest omits the '
              'request on purpose), so the member is what identifies what was '
              'refused');
    });

    test('onDenied fires BEFORE the throw, so the shared prompt appears even '
        'at a call site that swallows', () async {
      api.failure = _forbidden('historyViews.deleteHistoryView');

      // Exactly what the page does at all five writes: catch and return.
      try {
        await views.deleteHistoryView(4);
      } on AccessDenied {
        // swallowed, deliberately — the prompt is the operator's only notice
      }

      expect(prompted, hasLength(1),
          reason: 'every one of the page\'s five catches returns silently, '
              'because AccessDeniedListener is what names the missing '
              'permission. Without this callback a refused delete on a gateway '
              'panel is a button that did nothing, with no explanation '
              'anywhere');
      expect(prompted.single.required,
          const AccessPolicy()
              .groupForHistoryView(AccessPolicy.historyViewDelete));
    });
  });

  // ---------------------------------------------------------------------------
  // The one property no behavioural arm above can carry
  // ---------------------------------------------------------------------------

  group('the group is ASKED, never graded here', () {
    // Measured, 2026-09-09: replacing `_policy.groupForHistoryView(member) ??
    // AccessGroup.configure` with a bare `AccessGroup.configure` SURVIVES every
    // arm above, and it survives honestly — `groupForHistoryView` answers
    // `configure` for both destructive members and `null` (whose fallback is
    // `configure`) for the other three, so on today's policy table the two
    // spellings are observationally identical.
    //
    // They stop being identical the moment somebody changes that table, which
    // is the change the whole one-master-policy constitution exists to make
    // safe: the gateway would start refusing a member at a new grade and the
    // panel would put the OLD permission in front of the operator, who would
    // go and obtain the wrong thing. So the property is structural, and it is
    // asserted the way `no_second_policy_test.dart`'s arm 8 asserts the same
    // rule for `packages/tfc_relay_server`: this file may hold `AccessGroup`
    // as a type and may hold the one documented fallback, and it must reach
    // the answer by asking.
    final source = File('lib/core/relayed_history_views.dart').readAsStringSync();

    test('the adapter calls AccessPolicy.groupForHistoryView', () {
      expect(source, contains('_policy.groupForHistoryView(member)'),
          reason: 'run this suite from the repository root. A denial label '
              'computed from anything other than the one policy method is a '
              'second answer to "what does this member require", and it is '
              'the answer the operator reads');
    });

    test('and names exactly one AccessGroup grade — the documented fallback',
        () {
      final grades = RegExp(
              r'\bAccessGroup\.(operate|users|configure|administer|setpoints|view)\b')
          .allMatches(_uncommented(source))
          .map((m) => m.group(0))
          .toList();
      expect(grades, ['AccessGroup.configure'],
          reason: 'the single permitted literal is the `?? AccessGroup.'
              'configure` fallback for a member the gateway refused that this '
              'build\'s policy calls open — a backend graded stricter than the '
              'panel. A second grade in this file is this file deciding, which '
              'is the second policy the constitution forbids: $grades');
    });
  });

  group('what must NOT be translated', () {
    test('a handlerFailed propagates as itself — "cannot yet" is not "may not"',
        () async {
      api.failure = rpc.RpcException(-32011, 'the view table could not be read');

      await expectLater(
        views.deleteHistoryView(4),
        throwsA(isA<rpc.RpcException>()
            .having((e) => e.code, 'code', -32011)),
        reason: 'a backend that could not is a different fact from a session '
            'that may not, and only one of them is fixed by obtaining a '
            'permission. Flattening them would send an operator to the access '
            'screen for a database outage',
      );
      expect(prompted, isEmpty,
          reason: 'and the access-denied prompt must not appear for it');
    });

    test('the six reads are not wrapped and answer straight through', () async {
      expect(await views.selectHistoryViews(), isEmpty);
      expect(await views.getHistoryViewKeyNames(1), isEmpty);
      expect(await views.listHistoryViewPeriods(1), isEmpty);
      expect(await views.getGlobalRetentionHorizon(), isNull);
      expect(await views.getHistoryViewKeys(1), isEmpty);
      expect(await views.getHistoryViewGraphs(1), isEmpty);
      expect(api.calls, 6);
    });

    test('a failed read throws — the adapter never answers an empty list for '
        'one', () async {
      api.failure = rpc.RpcException(-32011, 'the view table could not be read');

      await expectLater(
          views.selectHistoryViews(), throwsA(isA<rpc.RpcException>()));
      await expectLater(views.listHistoryViewPeriods(1),
          throwsA(isA<rpc.RpcException>()));
      await expectLater(
          views.getHistoryViewKeyNames(1), throwsA(isA<rpc.RpcException>()));
    });
  });
}
