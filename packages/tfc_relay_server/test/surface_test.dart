@TestOn('vm')
@Tags(['meta'])

/// The method table of the wire, written down.
///
/// This test exists to break the build on purpose. Every name below is a thing
/// a connected client may ask the gateway to do, so the set of names *is* the
/// access-control policy: capability is defined by surface. Registering a
/// handler on [RelaySession] without editing this file fails; editing this
/// file is the deliberate act that says "yes, the wire may now do this too".
///
/// The expected sets are hand-written literals, never derived from the class
/// they check. A set computed from the session — or spelled with the protocol
/// package's own name constants — would agree with any change and assert
/// nothing. The point is that a human reads a diff of these lines, so the
/// literals are bare strings and the wire spelling is repeated here on
/// purpose. (That is also why the constants class is not imported below: a
/// reference to it would make this file track the very thing it is pinning.)
///
/// Two properties are enforced here:
///
///  * **Closure, in both directions.** The session registers exactly these
///    forty-four names. One direction alone is half a check: a declared name
///    with no
///    handler answers METHOD_NOT_FOUND from a table claiming to carry it, and
///    a handler under a name nobody wrote down is surface nobody counted. The
///    argument is `suite_integrity_test.dart:22-33`, applied server-side.
///  * **Notifications are not handlers.** The six names the server *sends*
///    are listed in their own literal and asserted absent from the handler
///    table. A notification registered as a handler is a request a client
///    could make of the server — the wrong direction on a one-way name.
///
/// **Direction is the whole of the third literal.** A client→server
/// notification is a name the server *receives*, so it belongs in the handler
/// table's ledger — `json_rpc_2` dispatches a frame with no `id` through the
/// same `_methods[name]` table a request goes through — and it does **not**
/// belong in [expectedNotifications], which is the set of names the server
/// *sends*. The two are asserted disjoint, so a client notification put in the
/// wrong literal fails rather than quietly widening what a client may call.
/// [expectedClientNotifications] is that third set, and the closure checks
/// compare the ledger against the union.
///
/// One asymmetry a reader has to be told about (**D-P5-H**): every `_gated`
/// refusal in this server is visibly answered *except* a refused client
/// notification. A `'h'` frame arriving before `hello` is refused by the gate
/// and the refusal evaporates — the frame has no `id`, so `json_rpc_2` returns
/// before building a response and hands the exception to `onUnhandledError`
/// instead (measured, 05-RESEARCH §B.1 #2). Silence there is the gate working,
/// not the gate missing.
///
/// The session publishes its own ledger (`registeredMethods`), so no
/// reflection is needed: `dart:mirrors` would read the class where the ledger
/// already reads the registrations, and the registrations are what ship.
///
/// **Phase note.** Phase 4 pulled `write`, `writeStatus`, `read`, `readFresh`
/// and `readMany` forward from Phase 5: 04-RESEARCH Finding 4 ran the method
/// sweep against a live server and found all five answering `-32601`, which
/// put 28 of the contract suite's 44 checks out of reach over the real
/// gateway. Phase 5 still owns their *semantics* (three-state depth beyond the
/// plumbing, idempotency windows, hold-to-run) and Phase 10 adds the
/// data-service methods. Each of those is an edit to [expectedHandlerTable]
/// below, made by a human, in a diff.
///
/// **Phase 10 plan 02** made the first of those edits: the four `browse.*`
/// names. It is the shape every later data-service plan copies — the handler
/// bodies land, this literal grows in the same commit, and the contract legs'
/// gap lists shrink by the checks the handlers just made reachable. **Plan 03
/// made the second**, the four `timeseries.*` names; **plan 04 the third**, the
/// eleven `historyViews.*` names; and **plan 05 the last**, the fifteen
/// `preferences.*` ones. The table is now the whole of the thirty-four
/// data-service methods plus the nine that came before them, and both socket
/// legs name no gap at all.
library;

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
// Deliberately narrowed: the wire's name constants are *not* pulled in, so no
// expected set below can accidentally be spelled with the thing it pins.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ConflatingSendBuffer, protocolVersion;
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

/// Every method a connected client may call, as of Phase 10 plan 05.
///
/// Hand-written. Not derived. See the library doc for why — and note that the
/// four `browse.*` names below are bare strings for exactly that reason, even
/// though `DataServiceMethods` now declares them in the protocol package. A
/// literal spelled with the constants would agree with a rename of the wire
/// name and assert nothing about it.
const Set<String> expectedHandlerTable = {
  'hello',
  'ping',
  'subscribe',
  'unsubscribe',
  'write',
  'writeStatus',
  // Phase 14 plan 12. The first operator action on this wire that is not a
  // write, and it is gated by the same `KeyPolicy.canWrite` answer a write is
  // — so a `view` station cannot clear an alarm it may not have looked at.
  // Registered on every session whether or not the deployment supplied an
  // alarm engine, deliberately: a gateway with no engine answers a *named*
  // refusal rather than `-32601`, which is what keeps "serves no engine"
  // distinguishable from "too old to know the word".
  'ackAlarm',
  // Alarm history over the pipe. The second name on this wire that is not a
  // write and not a value read, and it is gated **differently from the ack one
  // line up**: an acknowledge takes `KeyPolicy.canWrite` because it clears
  // something off everybody's banner, and this takes only the visibility answer
  // `PolicyStateMan.keys` already carries, because it is a read. A `view`
  // station that may watch alarms happen may read what happened — gating it any
  // harder would blank the history page on the canteen wall display.
  //
  // Registered whether or not the deployment supplied a reader, for `ackAlarm`'s
  // reason and one more: a gateway with no reader answers a *named* refusal, so
  // "serves no alarm history" stays distinguishable from "too old to know the
  // word" AND from "this plant has never had an alarm" — which is the silent
  // answer a gateway-mode panel had been giving since `preferencesProvider`
  // stopped building it a database.
  'alarmHistory',
  'read',
  'readFresh',
  'readMany',
  // Phase 10 plan 02. The first four of the thirty-four data-service methods,
  // and the reason six contract checks stopped being proven-unreachable in
  // the commit that added them.
  'browse.fetchRoots',
  'browse.fetchChildren',
  'browse.fetchDetail',
  'browse.resolvePath',
  // Phase 10 plan 03. The timeseries three (four until the 2026-09-07 audit
  // cut the count method), and the reason three more contract checks stopped
  // being proven-unreachable in the commit that added them. These carry
  // strings the database interpolates into SQL, so the same commit that made
  // them callable put the allow-list in front of them — see
  // `hostile_params_test.dart`.
  'timeseries.queryTimeseriesData',
  'timeseries.queryTimeseriesDataMultiple',
  'timeseries.queryTimeseriesDataDownsampled',
  // Phase 10 plan 04. The history-view eleven — the largest family and the
  // only write-shaped one in this phase that is not a preference: four of
  // these mutate rows a chart reads. Two contract checks stopped being
  // proven-unreachable in the commit that added them, and one of the eleven
  // is covered by no contract check at all
  // (`historyViews.getGlobalRetentionHorizon`; `timeseries` used to have the
  // other one until the audit cut it) — its case lives in
  // `data_handlers_test.dart`, because `data_services_contract.dart:4-30`
  // forbids an eighth data-services case upstream.
  'historyViews.createHistoryView',
  'historyViews.updateHistoryView',
  'historyViews.deleteHistoryView',
  'historyViews.selectHistoryViews',
  'historyViews.getHistoryViewKeys',
  'historyViews.getHistoryViewGraphs',
  'historyViews.getHistoryViewKeyNames',
  'historyViews.addHistoryViewPeriod',
  'historyViews.deleteHistoryViewPeriod',
  'historyViews.listHistoryViewPeriods',
  'historyViews.getGlobalRetentionHorizon',
  // Phase 10 plan 05. The preferences fifteen, which close the table: the two
  // remaining contract checks stopped being proven-unreachable in the commit
  // that added them, and **seven of these fifteen are the only names on this
  // wire that a `view` station may not call** — `_PolicyPreferences` refuses
  // them with -32005, because `key_mappings` is the gateway's own routing
  // configuration and rewriting it re-points the plant's tag map.
  'preferences.getKeys',
  'preferences.getAll',
  'preferences.getBool',
  'preferences.getInt',
  'preferences.getDouble',
  'preferences.getString',
  'preferences.getStringList',
  'preferences.containsKey',
  'preferences.setBool',
  'preferences.setInt',
  'preferences.setDouble',
  'preferences.setString',
  'preferences.setStringList',
  'preferences.remove',
  'preferences.clear',
  // Phase 17 plan 09. The access twenty-eight — the four families 17-03
  // declared and this plan registers, the largest single addition to this
  // surface since Phase 10. Twenty-eight and not twenty-nine:
  // `accessTemplates.template` was cut by the access audit (no caller
  // anywhere, its own store included) and must never appear here. Every one
  // of these is gated server-side by the session's PolicyStateMan (17-07);
  // the registration through `_on` is what puts them all behind the
  // handshake gate, and `access_handlers_test.dart` sweeps exactly that.
  'accessTemplates.list',
  'accessTemplates.bindings',
  'accessTemplates.keysBoundTo',
  'accessTemplates.create',
  'accessTemplates.update',
  'accessTemplates.rename',
  'accessTemplates.delete',
  'accessTemplates.bind',
  'accessTemplates.unbind',
  'accessAdmin.roles',
  'accessAdmin.listUsers',
  'accessAdmin.createRole',
  'accessAdmin.updateRole',
  'accessAdmin.deleteRole',
  'accessAdmin.renameRole',
  'accessAdmin.createUser',
  'accessAdmin.deleteUser',
  'accessAdmin.setUserRole',
  'accessAdmin.setUserStationAccount',
  'accessAdmin.setUserPassword',
  'audit.entries',
  'audit.memberCountsByAction',
  'audit.distinctWho',
  'backendConfig.read',
  'backendConfig.validate',
  'backendConfig.write',
  'backendConfig.previous',
  'backendConfig.restorePrevious',
};

/// Every name the server *sends* as a notification, and therefore may never
/// register as a handler.
///
/// `u` is `update` on the wire — one character on purpose, because it is the
/// hot path. Spelling it as the wire spells it is the whole point of a literal.
/// **`preferences.changed` is the sixth, and it is the freeze most likely to
/// have been missed**: a notification is not a handler, so it appears in none
/// of the closure checks above and none of them would have failed if it had
/// shipped uncounted. It is here because the server sends it — one coalesced
/// frame per burst per session, carrying a **list** of keys — and because a
/// name the server emits that nobody wrote down is surface nobody reviewed,
/// exactly as a handler would be.
const Set<String> expectedNotifications = {
  'u',
  'tick',
  'resync',
  'status',
  'bye',
  'preferences.changed',
};

/// Names the client *sends* as notifications, registered as handlers so
/// `json_rpc_2` dispatches them, but never carrying an id and never answered.
///
/// `h` is the hold-to-run deadman tick — one character for the same reason `u`
/// is, because it is the hot path while a button is held. It is the first
/// name on this wire that travels client→server as a notification, and it is
/// in its own literal rather than in [expectedHandlerTable] because "the nine
/// names a client may *call*" is a true and useful sentence that `h` is not
/// part of: calling it as a request would hang the caller waiting for a
/// response the library never sends.
const Set<String> expectedClientNotifications = {
  'h',
};

/// Every name the session's ledger may contain: what a client may call, plus
/// what a client may announce.
Set<String> get everyRegisterableName =>
    {...expectedHandlerTable, ...expectedClientNotifications};

/// Names that are declared but that nothing answers.
///
/// A pure set operation, kept as a named function so the falsification cases
/// below can point it at a deliberately wrong input without constructing a
/// deliberately wrong session. `_on` is private and `_registered` has no
/// setter, which is correct: the way to prove this check bites is to feed the
/// comparison a bad set, not to open a seam in production code so a test can
/// misuse it.
Set<String> unhandled(Set<String> declared, Set<String> registered) =>
    declared.difference(registered);

/// Names that are answered but that nobody declared.
Set<String> undeclared(Set<String> registered, Set<String> declared) =>
    registered.difference(declared);

/// A session over an in-memory channel, with no client on the far end.
///
/// Nothing is called on it — only its ledger is read — so the far end stays
/// empty on purpose.
RelaySession _session() {
  final pair = channelPair();
  final api = FakeStateMan();
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: const PermissiveTokenValidator(),
    serverSupported: const [protocolVersion],
  );
  addTearDown(() async {
    await session.close(1000, 'surface test over');
    await api.dispose();
  });
  return session;
}

void main() {
  group('the handler table is closed', () {
    test('every declared name has a handler', () {
      final registered = _session().registeredMethods;

      expect(unhandled(expectedHandlerTable, registered), isEmpty,
          reason: 'a name in expectedHandlerTable that the session never '
              'registered is a method the table claims to carry and the peer '
              'answers METHOD_NOT_FOUND for. Either register it or delete the '
              'line.');
    });

    test('every handler has a declared name', () {
      final registered = _session().registeredMethods;

      expect(undeclared(registered, everyRegisterableName), isEmpty,
          reason: 'the session registered a method nobody wrote down. The set '
              'of names is the access-control policy, so this is an '
              'authorization change that reached the wire without a diff. Add '
              'it to expectedHandlerTable deliberately, or remove the '
              'registration.');
    });

    test('the table is exactly the seventy-three names a client may call today',
        () {
      // The sentence is unchanged in shape and still true: seventy-three names
      // a client may *call* — forty-four through Phase 14, 17-09's
      // twenty-eight access methods, and `alarmHistory`. `h` is not one of them — it is
      // announced, never called — so it is taken out of the ledger by name
      // here rather than being added to the literal, which would say a
      // client may ask the gateway to tick.
      expect(
          _session().registeredMethods.difference(expectedClientNotifications),
          expectedHandlerTable,
          reason: 'both directions at once, stated as one equality so the '
              'failure prints the whole table rather than a difference');
    });

    test('the registered table is the seventy-three callable names plus the '
        'client notifications', () {
      expect(_session().registeredMethods, everyRegisterableName,
          reason: 'the ledger is the union, because json_rpc_2 dispatches a '
              'notification through the same table a request goes through. A '
              'name here that is in neither literal is surface nobody counted');
    });

    test('neither side of the comparison is empty', () {
      // Anti-vacuity: two empty sets satisfy both directions above and prove
      // nothing. If either of these fails, the checks above are asserting
      // that nothing is missing from nothing.
      expect(expectedHandlerTable, isNotEmpty,
          reason: 'an empty literal makes every direction-one check vacuous');
      expect(_session().registeredMethods, isNotEmpty,
          reason: 'a session that registered nothing makes every '
              'direction-two check vacuous — the ledger is not being read');
    });
  });

  group('the closure check bites', () {
    test('an extra registration is caught by name', () {
      final registered = _session().registeredMethods;
      final widened = {...registered, 'dropDatabase'};

      // Against the union, exactly as the real closure check above compares:
      // a falsification arm has to feed the comparison a deliberately wrong
      // *input* while keeping the baseline right, or it stops falsifying the
      // check that ships and starts falsifying a different one.
      final found = undeclared(widened, everyRegisterableName);

      expect(found, {'dropDatabase'},
          reason: 'direction two must name the offending method, because the '
              'failure a reviewer reads is the method that appeared');
      expect(found.single, 'dropDatabase');
    });

    test('a declared name with no handler is caught by name', () {
      final registered = _session().registeredMethods;
      final overclaimed = {...expectedHandlerTable, 'ghostMethod'};

      final found = unhandled(overclaimed, registered);

      expect(found, {'ghostMethod'},
          reason: 'direction one must name the method the table claims to '
              'carry but nothing answers');
    });

    test('the comparison reports the offender in its failure text', () {
      // The reason strings above are only worth having if the matcher's own
      // output carries the name. Provoke the real failure and read it.
      late final Object caught;
      try {
        expect(undeclared({...expectedHandlerTable, 'dropDatabase'},
            expectedHandlerTable), isEmpty);
        fail('the closure check passed a widened table');
      } on TestFailure catch (error) {
        caught = error;
      }

      expect('$caught', contains('dropDatabase'),
          reason: 'a failure that does not name the method makes the reviewer '
              'diff the session by hand');
    });
  });

  // The sweep 04-RESEARCH Finding 4 ran against a live gateway, kept as a
  // case. The literal above is a statement about a ledger; this is the same
  // statement made where a client stands, over a real socket, and the two can
  // only disagree if `_on` has stopped being the way a method reaches the
  // table.
  group('every declared name answers over a real socket', () {
    test('no name in the table comes back -32601', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue('CN01.MOT01.speed', 1200);

      // Params good enough to be *dispatched*; a refusal on the contents is a
      // pass here, because the property is that the method exists at all.
      const params = <String, Object?>{
        'sub': 'surface-probe',
        'keys': ['CN01.MOT01.speed'],
        'key': 'CN01.MOT01.speed',
        'cmd': '01JZZZZZZZZZZZZZZZZZZZZZZZ',
        'value': 1200,
        'cmds': ['01JZZZZZZZZZZZZZZZZZZZZZZZ'],
        // The browse trio (Phase 10 plan 02). Written out as literal maps
        // rather than built from `BrowseNode.toJson()`, for the same reason
        // the expected sets above are bare strings: a bag spelled with the
        // encoder would agree with a change to the encoder, and this bag's
        // only job is to be *dispatchable* — a refusal on the contents is a
        // pass here, because the property is that the method exists at all.
        'parent': <String, Object?>{
          'id': 'ST101.CN01',
          'displayName': 'CN01',
          'type': 'folder',
        },
        'node': <String, Object?>{
          'id': 'ST101.CN01.MOT01.setpoint',
          'displayName': 'setpoint',
          'type': 'variable',
        },
        'targetId': 'ST101.CN01.MOT01.setpoint',
        // The timeseries seven (Phase 10 plan 03). `to` and `from` are epoch
        // **milliseconds**, not ISO strings — that is the wire's instant
        // encoding (`client_sub_apis.dart` sends `msOf`), and a string here
        // would be refused on its contents rather than dispatched, which
        // still passes this sweep but for the wrong reason. `from` is before
        // `to` and the three integers are inside their ceilings, so the
        // dispatch is a real one on every one of the four names.
        'table': 'st101_cn01_mot01_setpoint',
        'tables': ['st101_cn01_mot01_setpoint'],
        'from': 1_786_600_800_000, // 2026-08-13T06:00:00Z
        'to': 1_786_604_400_000, //   2026-08-13T07:00:00Z
        'maxPoints': 1000,
        'intervalMs': 60_000,
        'howMany': 10,
        // The history-view five (Phase 10 plan 04). `keys` above is reused —
        // it is a list of plant keys in both places, which is what a view
        // plots — and `name` is the view's own label. `viewId` and `id` are
        // both 1 because the sweep runs the eleven names in the order they
        // are declared above: `createHistoryView` runs first and
        // `FakeHistoryViews` hands out ids from 1, so every later name in the
        // family addresses a view that really was created a moment earlier.
        // That matters more here than it looks: an id addressing nothing
        // still *dispatches*, so the sweep would pass either way — but a
        // dispatch that reaches a real row is the one that would catch a
        // handler wired to the wrong source.
        'viewId': 1,
        'id': 1,
        'name': 'Vaktir',
        // Epoch **milliseconds**, like `from` and `to` and for the same
        // reason: a saved window is two instants and this wire has exactly
        // one instant encoding. `start` is before `end`.
        'start': 1_786_600_800_000, // 2026-08-13T06:00:00Z
        'end': 1_786_604_400_000, //   2026-08-13T07:00:00Z
        // The preferences one (Phase 10 plan 05). `key` and `value` above are
        // reused — a preference key is a string and `value` is whatever type
        // the setter takes, so the typed setters are *refused on their
        // contents* here and dispatched, which is a pass for this sweep. Only
        // `allowList` is new, and it is spelled out rather than left absent so
        // `getKeys`, `getAll` and `clear` are dispatched with the argument a
        // settings page actually sends. It names the one key this fixture
        // seeded, so the `clear` at the end of the sweep empties one row
        // rather than the store.
        'allowList': ['CN01.MOT01.speed'],
      };

      final methodNotFound = <String>[];
      // The skip is named in the `where`, not achieved by leaving a name out
      // of a literal: `h` is a *notification*, and sending it as a request
      // would hang this case forever waiting for a response json_rpc_2 never
      // sends (it returns before building one when the frame has no id —
      // measured, 05-RESEARCH §B.1 #1). The sweep is over the union so that a
      // future client notification is skipped deliberately too.
      for (final method in everyRegisterableName
          .where((name) => !expectedClientNotifications.contains(name))) {
        if (method == 'hello') continue; // one hello per session, spent above.
        try {
          await fixture.request(method, params: params, what: 'a $method answer');
        } on rpc.RpcException catch (error) {
          if (error.code == rpc_errors.METHOD_NOT_FOUND) {
            methodNotFound.add(method);
          }
        }
      }

      expect(methodNotFound, isEmpty,
          reason: 'a name in the frozen table that the wire answers '
              '"unknown method" for is a client staring at a control it can '
              'never use: $methodNotFound');
    }, tags: 'ws');
  });

  group('notifications are not handlers', () {
    test('no notification name is registered as a method', () {
      final registered = _session().registeredMethods;

      final overlap = registered.intersection(expectedNotifications);

      expect(overlap, isEmpty,
          reason: 'a notification registered as a handler is a one-way name '
              'the client can now call: $overlap');
    });

    test('the two literals are disjoint', () {
      expect(expectedHandlerTable.intersection(expectedNotifications), isEmpty,
          reason: 'a name cannot be both something the client asks for and '
              'something the server announces');
    });

    test('the notification literal is not empty', () {
      // Anti-vacuity: an empty notification set makes the disjointness and
      // intersection checks above true for free.
      expect(expectedNotifications, isNotEmpty,
          reason: 'an empty literal makes both notification checks vacuous');
      expect(expectedNotifications, hasLength(6),
          reason: 'update/tick/resync/status/bye — five names as of Phase 3, '
              'and preferences.changed as of 10-05, which is six. A '
              'notification is not a handler and appears in none of the '
              'closure checks above, so this count is the only arm that would '
              'have caught a sixth server-to-client name shipping uncounted; '
              'changing it is a deliberate edit');
    });
  });

  group('a client notification is a handler, and only that', () {
    test('the client-notification literal is not empty', () {
      // Anti-vacuity, the same argument as the arm above: an empty third
      // literal would make the union equal the handler table and every check
      // that mentions it true for free.
      expect(expectedClientNotifications, isNotEmpty,
          reason: 'an empty literal makes the union check and both '
              'disjointness arms below vacuous');
      expect(expectedClientNotifications, hasLength(1),
          reason: 'h — one name as of Phase 5, and the first frame on this '
              'wire that travels client to server; changing this count is a '
              'deliberate edit, because each one is an un-idded, unanswered '
              'frame that can move a plant tag');
    });

    test('no client notification is also a callable name', () {
      expect(
          expectedClientNotifications.intersection(expectedHandlerTable),
          isEmpty,
          reason: 'a name in both literals is a tick a client could also send '
              'as a request — and a request for it hangs the caller, because '
              'json_rpc_2 answers a notification with nothing');
    });

    test('no client notification is a name the server sends', () {
      expect(
          expectedClientNotifications.intersection(expectedNotifications),
          isEmpty,
          reason: 'direction is the whole distinction: a name in both would '
              'be the server announcing something it also accepts, and the '
              'session would register a name it emits');
    });

    test('every client notification is registered as a handler', () {
      final registered = _session().registeredMethods;

      expect(unhandled(expectedClientNotifications, registered), isEmpty,
          reason: 'a declared client notification with no handler is a frame '
              'the fallback answers -32601 for — into onUnhandledError, where '
              'nobody sees it — while a panel holds a button and the machine '
              'never moves');
    });
  });
}
