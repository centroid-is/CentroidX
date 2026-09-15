/// The handler body for one session's alarm methods.
///
/// `data_handlers.dart:54`'s rule is kept verbatim: **nothing in this file
/// registers anything.** The registration table lives in one readable place,
/// `relay_session.dart`, and a handler that reached for the peer would be a
/// second place a name can enter the wire.
library;

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'alarm_ack_sink.dart';
import 'alarm_history_source.dart';
import 'error_codes.dart';

/// The bodies behind [Methods.ackAlarm] and [Methods.alarmHistory].
///
/// Built per session, exactly as `ValueHandlers` is, and holding no state of
/// its own: the engine it hands work to belongs to the gateway and outlives
/// every socket.
final class AlarmHandlers {
  AlarmHandlers({
    required this.api,
    this.sink,
    this.history,
    this.canWriteKey = _anyKeyWritable,
  });

  /// The default [canWriteKey]: every key is writable.
  ///
  /// `ValueHandlers._anyKeyWritable`'s posture and its reason — an object built
  /// directly by a unit kit must behave as it did before this argument existed.
  /// **Production never gets this**: `RelaySession` always passes the session's
  /// own predicate, and `alarm_ack_test.dart`'s view-station arm goes through
  /// the real session for exactly that reason.
  static bool _anyKeyWritable(String key) => true;

  /// The session's `PolicyStateMan` view of the source.
  ///
  /// Read for [StateManApi.keys] only. A key this station may not see is
  /// already filtered out of it, which is what makes the existence check below
  /// answer "nonexistent" for a hidden key without asking a second question.
  final StateManApi api;

  /// The alarm engine this gateway serves, or null on one that serves none.
  ///
  /// Null is a real deployment, not a misconfiguration: `tfc_relay_local`'s
  /// harness and every fixture in this package build a gateway with no engine,
  /// and the acknowledge is refused *by name* there rather than being absent
  /// from the wire — see the null branch in [acknowledge].
  final AlarmAckSink? sink;

  /// Where this gateway reads `alarm_history`, or null on one that reads none.
  ///
  /// Null is a real deployment for [sink]'s reason and refused by name for
  /// [sink]'s reason — see the null branch in [recent]. Separate from [sink]
  /// rather than folded into it because they are separate capabilities: a
  /// gateway can perfectly well have an alarm engine with no persistence
  /// (`AlarmEngine.persists` is false when it was built without a history
  /// writer), and one seam carrying both would make that deployment answer a
  /// sentence about acknowledging when what it cannot do is remember.
  final AlarmHistorySource? history;

  /// Whether the station this session speaks for may actuate a given key.
  ///
  /// The same predicate `ValueHandlers` is handed, from the same expression at
  /// the same call site (`relay_session.dart`), and **not** a second role
  /// comparison. Two comparisons can drift; one answer cannot. Read late on
  /// every call for `ownerOf`'s reason: these handlers are built during the
  /// session's `_start` and the identity is minted afterwards, by `_hello`.
  final bool Function(String key) canWriteKey;

  /// An operator acknowledging one active alarm.
  ///
  /// **Four steps, and the order is the decision.**
  ///
  /// 1. **Shape.** A frame that names no alarm is refused before anything else
  ///    happens, so `INVALID_PARAMS` here means what it means on the write
  ///    ladder: definitively no effect, nothing sent, nothing remembered.
  /// 2. **Existence**, from `api.keys`. A station that may not *see*
  ///    `AlarmKeys.active` has had it filtered out by the session's
  ///    `PolicyStateMan`, so it is refused here as a tag this source does not
  ///    serve — byte-identically to a tag that never existed.
  /// 3. **Authorization**, and it is below existence on purpose. Swap the two
  ///    and a hidden key is answered `forbidden`, which says it exists: ask
  ///    about a thousand names, keep the ones answered `forbidden` rather than
  ///    unserved, and the plant's alarm surface has been enumerated by a
  ///    station that may not read a byte of it (`key_policy.dart:16-26`).
  /// 4. **The engine.** Absent → a named refusal. Present → its answer is the
  ///    gateway's answer, including its failure.
  Future<Object?> acknowledge(rpc.Parameters params) async {
    // Every decode on the ingress path is sanitized first: `jsonDecode('1e999')`
    // yields Infinity silently, and `Infinity.toInt()` throws an
    // `UnsupportedError` that nothing at this boundary catches.
    final decoded = (sanitize(params.asMap).value as Map).cast<String, Object?>();

    final AckAlarmParams request;
    try {
      request = AckAlarmParams.fromJson(decoded);
    } on FormatException catch (error) {
      // The exception's own sentence, because it is the one that says which
      // field was wrong and why a missing one is not a zero.
      throw _refuse(Methods.ackAlarm,
          '${Methods.ackAlarm} params could not be read: ${error.message}');
    } on TypeError {
      throw _refuse(
          Methods.ackAlarm,
          '${Methods.ackAlarm} needs an "alarmUid" string and a whole, '
          'non-negative "ruleIndex": together they are the open alarm row, '
          'and neither one names it alone');
    }

    // **Existence first, and the placement is the property.** See step 2 above.
    // The sentence is the write path's, deliberately: one refusal a client
    // decodes one way, whichever surface produced it.
    if (!api.keys.contains(AlarmKeys.active)) {
      throw rpc.RpcException(
          rpc_errors.INVALID_PARAMS,
          'this gateway does not serve "${AlarmKeys.active}", so it has no '
          'active alarm set to acknowledge anything in',
          data: _substitute(Methods.ackAlarm));
    }

    // **The authorization gate.** `canWriteKey` alone, asked about
    // `AlarmKeys.active` — never about the frame's uid, which is a row id and
    // not a key any policy has an opinion about. Under the shipped
    // `AllVisibleOperatorWrites` this is `role == operate`, and it is that
    // answer through the one object every read surface is already served
    // through rather than a second role comparison that can drift from
    // `KeyPolicy`.
    //
    // **The message names the method and the rule and never the alarm.**
    // Echoing the uid back to a station that may not see the key is the
    // disclosure the ordering above exists to prevent, undone one line later.
    if (!canWriteKey(AlarmKeys.active)) {
      throw rpc.RpcException(
          ServerErrorCodes.forbidden,
          'this station may not acknowledge alarms: ${Methods.ackAlarm} is '
          'gated by the same permission a write is, and this session speaks '
          'for a station without the operate role. Nothing was acknowledged, '
          'so the alarm is still on the banner for whoever does have it. Do '
          'not retry — the session is fine and reading continues; what is '
          'missing is a permission, and permissions change in the gateway\'s '
          'token file rather than on the next attempt',
          data: _substitute(Methods.ackAlarm));
    }

    final engine = sink;
    if (engine == null) {
      // **Refused by name, and not `-32601`.** The name is registered on every
      // session whether or not a deployment supplied an engine, precisely so
      // that a client can tell this answer from the one an older gateway gives
      // — "too old to know the word" is a version problem and "serves no alarm
      // engine" is a composition problem, and they are fixed in different
      // places. Answering success instead would be an operator pressing
      // Acknowledge, being told it worked, and watching the alarm stay.
      //
      // **`handlerFailed` and not a constant of its own**, under
      // `error_codes.dart`'s stated rule — a code exists so the client can
      // behave *differently*, and there is no different behaviour available
      // here: nothing a panel can do about a gateway composed without an
      // engine. It is the honest code besides. The request was well formed,
      // this is not the client's fault, and nothing was applied, which is
      // three of `handlerFailed`'s four clauses exactly. The fourth —
      // "possibly transient: retrying is legitimate" — is a licence rather
      // than an instruction, and a retry here is one idempotent frame that is
      // refused again with the same sentence.
      throw rpc.RpcException(
          ServerErrorCodes.handlerFailed,
          'this gateway serves no alarm engine, so there is nothing to '
          'acknowledge into. ${Methods.ackAlarm} is registered on every '
          'session, so this is a composition problem rather than a version '
          'one: pass an AlarmAckSink to RelayServer(alarmAcks:) in whatever '
          'builds this gateway',
          data: _substitute(Methods.ackAlarm));
    }

    // The engine's answer is the gateway's answer. A throw here reaches
    // `RelaySession._answer` and becomes `handlerFailed`, which is right: the
    // engine failing to find the open row is the engine's fact to report, and
    // swallowing it would tell an operator the alarm was acknowledged when
    // nothing moved.
    await engine.acknowledge(request.alarmUid, request.ruleIndex);

    // Null, deliberately. The RPC's answer says the gateway accepted the
    // instruction; the operator's confirmation is the alarm leaving
    // `AlarmKeys.active`, and a result object here would be a second thing to
    // believe about the same event.
    return null;
  }

  /// The body behind [Methods.alarmHistory].
  ///
  /// **Three steps, and the missing fourth is the decision.**
  ///
  /// 1. **Shape.** A window that could only ever answer empty — no `limit`, a
  ///    zero one, one over [AlarmHistoryParams.maxLimit], a `from` after its
  ///    `to` — is refused before anything is read. Every one of those would
  ///    otherwise come back as an empty list, which on screen is a factory that
  ///    has never had an alarm.
  /// 2. **Existence**, from `api.keys`, exactly as [acknowledge] does it and in
  ///    the same place for the same reason: a station that may not *see*
  ///    `AlarmKeys.active` has had it filtered out by the session's
  ///    `PolicyStateMan`, so it is refused as a tag this source does not serve,
  ///    byte-identically to a tag that never existed.
  /// 3. **The source.** Absent → a named refusal. Present → its answer is the
  ///    gateway's answer, **including its failure**.
  ///
  /// **There is no authorization step, and that is the decision.** [acknowledge]
  /// has one because an acknowledge is an operator action: it clears something
  /// off everybody's banner, so it is gated by the same `canWrite` answer a
  /// write is. This is a *read*, and step 2 already **is** its authorization —
  /// `PolicyStateMan.keys` is the hiding primitive every other read on this wire
  /// is gated by (`policy_state_man.dart:30-35`), and it is the same answer that
  /// decides whether the station is shown a banner at all. A station that may
  /// watch alarms happen may read what happened.
  ///
  /// Adding a `canWriteKey` gate here would not be a safe default. It would
  /// blank the history page on the canteen wall display and on every `view`
  /// station in the plant — the same silent empty page this method exists to
  /// remove, reached through a permission instead of through a missing
  /// database.
  ///
  /// **A failure is never an empty list.** The source's throw reaches
  /// `RelaySession._answer` and becomes `handlerFailed`, which is right:
  /// answering `{entries: []}` because the database was unreachable would
  /// report a fact about the gateway as a fact about the factory, and nothing
  /// on the operator's screen would distinguish the two.
  Future<Object?> recent(rpc.Parameters params) async {
    // Sanitized first, `acknowledge`'s reason: `jsonDecode('1e999')` yields
    // Infinity silently and `Infinity.toInt()` throws an `UnsupportedError`
    // nothing at this boundary catches.
    final decoded =
        (sanitize(params.asMap).value as Map).cast<String, Object?>();

    final AlarmHistoryParams request;
    try {
      request = AlarmHistoryParams.fromJson(decoded);
    } on FormatException catch (error) {
      // The exception's own sentence: it names which value was refused and why
      // an empty answer would have been worse than this refusal.
      throw _refuse(Methods.alarmHistory,
          '${Methods.alarmHistory} params could not be read: ${error.message}');
    } on TypeError {
      throw _refuse(
          Methods.alarmHistory,
          '${Methods.alarmHistory} needs a whole "limit" of at least 1 and at '
          'most ${AlarmHistoryParams.maxLimit}, and optional whole "fromMs" / '
          '"toMs" epoch milliseconds');
    }

    if (!api.keys.contains(AlarmKeys.active)) {
      throw rpc.RpcException(
          rpc_errors.INVALID_PARAMS,
          'this gateway does not serve "${AlarmKeys.active}", so it has no '
          'alarm history to read',
          data: _substitute(Methods.alarmHistory));
    }

    final source = history;
    if (source == null) {
      // Refused by name and not `-32601`, for `acknowledge`'s reason: the name
      // is registered on every session whether or not a deployment supplied a
      // reader, so a client can tell "serves no alarm history" from "too old to
      // know the word" — a composition problem and a version problem, fixed in
      // different places. Answering `{entries: []}` instead would be a panel
      // drawing an empty history page and calling it the plant's.
      throw rpc.RpcException(
          ServerErrorCodes.handlerFailed,
          'this gateway serves no alarm history, so there is nothing to read. '
          '${Methods.alarmHistory} is registered on every session, so this is '
          'a composition problem rather than a version one: pass an '
          'AlarmHistorySource to RelayServer(alarmHistory:) in whatever builds '
          'this gateway. Nothing was answered — this is NOT an empty history',
          data: _substitute(Methods.alarmHistory));
    }

    // The source's answer is the gateway's answer, and so is its throw. See the
    // doc above for why swallowing it would be the worst outcome available.
    final rows = await source.recentAlarms(
      limit: request.limit,
      from: request.from,
      to: request.to,
    );
    return AlarmHistoryEntry.encodeList(rows);
  }

  /// A shape refusal with the armor already on it.
  ///
  /// `value_handlers.dart:_refuse`'s argument, verbatim: `data['request']` is
  /// pre-substituted because `RpcException.serialize` copies the offending
  /// request into `error.data` when it is not — and one request carrying
  /// `1e999` then makes the *error* unencodable, at which point the peer drops
  /// it and every caller without a deadline waits forever.
  ///
  /// Takes the method name rather than assuming one: this class answers two
  /// names now, and a refusal that named the wrong one would send an engineer
  /// reading the wrong handler.
  static rpc.RpcException _refuse(String method, String why) =>
      rpc.RpcException(rpc_errors.INVALID_PARAMS, why,
          data: _substitute(method));

  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };
}
