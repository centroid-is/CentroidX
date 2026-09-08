@TestOn('vm')

/// **Acknowledge, on the gateway** — Phase 14 plan 12, ALRM-04.
///
/// Jón's Q-1 ruling of 2026-09-06: *"The acknowledge is not used anywhere yet.
/// So let's relay it."* Nothing depended on the old behaviour, so the ack is
/// built properly, and the whole of "properly" is in this file.
///
/// ## What breaks in the plant without these arms
///
/// A wall display in the canteen — a `view` station, bolted up there precisely
/// because nobody should be actuating a machine from it — clears the alarm
/// nobody has walked over and looked at yet. That is one missing comparison
/// away at all times, which is why arm 2 asserts *two* things: the refusal
/// code, and that the sink was never reached. A gate that throws after calling
/// the engine refuses just as visibly and has already done the damage.
///
/// The quieter failure is arm 6's. A hidden `AlarmKeys.active` answered
/// `forbidden` tells the asker the key exists, which is the enumeration
/// `key_policy.dart:16-26` exists to prevent. Existence is checked *above*
/// authorization here for that reason, exactly as `value_handlers.dart:416`
/// then `:444` order it on the write path.
///
/// ## Why the gate is `canWriteKey`, not a role comparison
///
/// `AlarmHandlers` is handed the session's own `PolicyStateMan.canWrite` — the
/// same expression `ValueHandlers` is handed at `relay_session.dart:832`, not a
/// copy of it — so the ack and the write cannot drift apart about what an
/// operator is. Under the shipped `AccessPolicyKeyPolicy` that is "the group
/// the master policy names for a tag write", `operate` at the floor; when the
/// policy changes it changes for both at once. Arm 7 pins that the question is
/// asked about `AlarmKeys.active` and not about whatever string the frame
/// carried.
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/alarm_ack_sink.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';

/// A panel next to a machine, and a display on a wall. `policy_test.dart`'s
/// two stations, in the same spelling, because they model the same two things.
/// `StationIdentity` on the user model (17-04b): the panel's session holds
/// `operate`, the display's holds nothing — the same two authorities the old
/// two-valued enum spelled, now in the master system's vocabulary.
const _panelUser = AuthenticatedUser(
    username: 'ST101-panel', roleName: 'Panel Operator', stationAccount: true);
const _displayUser = AuthenticatedUser(
    username: 'HALL-DISPLAY-panel',
    roleName: 'Hall Display',
    stationAccount: true);

const _panel = StationIdentity(
    user: _panelUser,
    station: 'ST101',
    session: AccessSession(user: _panelUser, groups: {AccessGroup.operate}));
const _display = StationIdentity(
    user: _displayUser,
    station: 'HALL-DISPLAY',
    session: AccessSession(user: _displayUser, groups: {}));

/// An alarm engine that writes down what it was asked to acknowledge.
///
/// The lever the pre-effect arms need. "The ack was refused" is cheap to assert
/// and easy to satisfy by accident, so what those arms actually assert is that
/// this list stayed empty.
final class _Recorder implements AlarmAckSink {
  _Recorder({this.failWith});

  /// What this engine throws instead of accepting. An engine that cannot find
  /// the open row is the case being modelled.
  final Object? failWith;

  final acks = <(String, int)>[];

  @override
  Future<void> acknowledge(String alarmUid, int ruleIndex) async {
    if (failWith != null) throw failWith!;
    acks.add((alarmUid, ruleIndex));
  }
}

/// The shipped policy, with a note of every key it was asked to authorize.
///
/// Hiding is a set membership test for `policy_test.dart`'s reason: 06-CONTEXT
/// forbids defining a pattern grammar, and a test policy that invented one
/// would be specifying policy language by the back door.
final class _SpyPolicy implements KeyPolicy {
  _SpyPolicy({this.hidden = const {}});

  final Set<String> hidden;

  /// Every key `canWrite` was asked about, in order.
  final asked = <String>[];

  @override
  bool canSee(String key, StationIdentity identity) => !hidden.contains(key);

  /// The shipped rule, **and** a refusal for anything hidden.
  ///
  /// The second half is what makes the ordering arm bite, and it was found by
  /// sabotage (c) rather than by reasoning: with a policy that hides a key and
  /// happily authorizes a write to it, swapping the existence and authorization
  /// checks changes no answer at all — the gate says yes either way and the
  /// existence check refuses second instead of first. The arm passed against a
  /// mutation it exists to catch.
  ///
  /// `policy_test.dart:_HidesTags` has the same shape and, on the write path,
  /// the same blind spot; it is survivable there because the *contrast* arm
  /// (hidden versus nonexistent) is what that file is really pinning. Here the
  /// subject **is** the ordering, so the policy has to be one where the two
  /// orders differ. Refusing a write to a key the station may not see is also
  /// the only honest answer: a station that may not know a tag exists cannot
  /// meaningfully be permitted to actuate it.
  @override
  bool canWrite(String key, StationIdentity identity) {
    asked.add(key);
    if (hidden.contains(key)) return false;
    return identity.session.can(AccessGroup.operate);
  }

  /// Same judgement as [canWrite], unrecorded: nothing in this file writes a
  /// preference, and the arm pinning [asked] is about the ack's one key.
  @override
  bool canWritePreference(String key, StationIdentity identity) =>
      !hidden.contains(key) && identity.session.can(AccessGroup.operate);
}

/// A validator that hands every session one fixed identity.
///
/// `policy_test.dart:_AlwaysStation`, for its reason: the subject here is the
/// policy, not the credential, and a second copy of `auth_test.dart`'s
/// temp-directory machinery would be a second place the token format is
/// written down.
final class _AlwaysStation implements TokenValidator {
  const _AlwaysStation(this.identity);

  final StationIdentity identity;

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}

/// One session over an in-memory channel, with a client peer on the far end.
///
/// `session_hello_test.dart:_link`, plus the three levers this file needs: an
/// identity, a policy, and a sink that may be absent. In memory rather than
/// over a socket because nothing here measures a millisecond — the subject is
/// an authorization decision, and a port would buy only wall-clock noise.
final class _Link {
  _Link(this.session, this.client, this.api);

  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'ack test over');
    await api.dispose();
  }

  Future<Object?> hello() => within(
      client.sendRequest(
          Methods.hello,
          HelloParams(
            protocol: protocolVersion,
            supported: const [protocolVersion],
            client: const PeerInfo('panel-under-test', '0.1.0'),
          ).toJson()),
      'the hello result');

  Future<Object?> ack({String uid = 'ALM-01', int ruleIndex = 0}) => within(
      client.sendRequest(Methods.ackAlarm,
          AckAlarmParams(alarmUid: uid, ruleIndex: ruleIndex).toJson()),
      'an ackAlarm response');

  /// Sends [params] raw, so a malformed frame can be put on the wire that the
  /// DTO would refuse to build.
  Future<Object?> ackRaw(Map<String, Object?> params) =>
      within(client.sendRequest(Methods.ackAlarm, params), 'an ackAlarm '
          'response to a raw frame');
}

_Link _link({
  StationIdentity identity = _panel,
  KeyPolicy? policy,
  AlarmAckSink? alarmAcks,
  bool seedActive = true,
}) {
  final pair = channelPair();
  final api = FakeStateMan();
  // The key has to have a *value* before `FakeStateMan.keys` will offer it —
  // the fake filters on arrival so a tag mistyped into a page config is not
  // laundered into a valid binding. On a real backend 14-03 put
  // `AlarmKeys.active` in `BackendLiveValues.keys`, which is what makes the
  // existence check pass in the plant.
  if (seedActive) api.setValue(AlarmKeys.active, const <Object?>[]);
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: _AlwaysStation(identity),
    // The shipped adapter since 17-07 deleted AllVisibleOperatorWrites: same
    // verdicts for this file's two stations — a tag write takes `operate`
    // (AccessPolicy.groupForTag's floor), which _panel holds and _display
    // does not.
    policy: policy ?? const AccessPolicyKeyPolicy(),
    alarmAcks: alarmAcks,
    serverSupported: const [protocolVersion],
    // Several arms provoke refusals on purpose, and a suite printing a stack
    // trace per provoked refusal trains everyone to scroll past them.
    onError: (_, __, ___) {},
  );
  final client = rpc.Client(pair.client);
  unawaited(client.listen());
  final link = _Link(session, client, api);
  addTearDown(link.dispose);
  return link;
}

/// Runs [call] expecting a refusal, and hands the refusal back.
///
/// A call that is *answered* fails here rather than at a downstream matcher, so
/// the report names the property rather than the assertion that tripped over
/// it.
Future<rpc.RpcException> _refused(Future<Object?> call, String what) async {
  try {
    await call;
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

void main() {
  test('an operate station\'s ack reaches the alarm engine', () async {
    final sink = _Recorder();
    final link = _link(alarmAcks: sink);
    await link.hello();

    await link.ack(uid: 'ALM-7', ruleIndex: 2);

    expect(sink.acks, [('ALM-7', 2)],
        reason: 'exactly one pair, equal to what the frame carried');
  });

  test('a view station\'s ack is refused and the engine is never touched',
      () async {
    final sink = _Recorder();
    final link = _link(identity: _display, alarmAcks: sink);
    await link.hello();

    final refusal = await _refused(link.ack(), 'a view station\'s ack');

    expect(refusal.code, ServerErrorCodes.forbidden);
    // The second assertion is the one that matters. A gate that refuses
    // *after* calling the engine satisfies the first alone and has already
    // cleared the alarm.
    expect(sink.acks, isEmpty,
        reason: 'this is the arm that stops a canteen wall display clearing '
            'the alarm nobody has looked at yet');
  });

  test('the refusal names the method and does not name the alarm', () async {
    final link = _link(identity: _display, alarmAcks: _Recorder());
    await link.hello();

    final refusal =
        await _refused(link.ack(uid: 'SECRET-ALARM'), 'a view station\'s ack');

    expect(refusal.message, contains(Methods.ackAlarm));
    expect(refusal.message, contains('operate'));
    expect(refusal.message, isNot(contains('SECRET-ALARM')),
        reason: 'echoing the uid back to a station that may not see the key '
            'is the enumeration key_policy.dart:16-26 describes');
  });

  test('a gateway with no alarm engine refuses by name', () async {
    final link = _link();
    await link.hello();

    final refusal =
        await _refused(link.ack(), 'an ack on a gateway with no engine');

    expect(refusal.code, isNot(rpc_errors.METHOD_NOT_FOUND),
        reason: 'the name exists on every session. A client must be able to '
            'tell "this gateway serves no alarm engine" from "this gateway is '
            'too old to know the word" — 14-13 turns the second into an '
            'operator-grade sentence, and it can only do that if the two '
            'answers differ');
    expect(refusal.message, contains('AlarmAckSink'),
        reason: 'the missing collaborator, named, so the sentence says what '
            'to change');
  });

  test('a failing alarm engine is a handler failure, not a success', () async {
    final link = _link(
        alarmAcks: _Recorder(failWith: StateError('no open row for ALM-1/0')));
    await link.hello();

    final refusal = await _refused(link.ack(), 'an ack a failing engine got');

    expect(refusal.code, ServerErrorCodes.handlerFailed,
        reason: 'swallowing the engine\'s answer would tell an operator the '
            'alarm was acknowledged when nothing moved');
  });

  test('a hidden ALARM.active is refused as nonexistent, never as forbidden',
      () async {
    final sink = _Recorder();
    final link = _link(
        policy: _SpyPolicy(hidden: {AlarmKeys.active}), alarmAcks: sink);
    await link.hello();

    final refusal = await _refused(link.ack(), 'an ack for a hidden key');

    expect(refusal.code, isNot(ServerErrorCodes.forbidden),
        reason: 'answering forbidden says the key exists — the disclosure the '
            'hiding rule conceals');
    expect(refusal.code, rpc_errors.INVALID_PARAMS,
        reason: 'byte-identical to the unserved-tag path write takes');
    expect(sink.acks, isEmpty);
  });

  test('the gate is asked about ALARM.active, not about the frame\'s uid',
      () async {
    final policy = _SpyPolicy();
    final link = _link(policy: policy, alarmAcks: _Recorder());
    await link.hello();

    await link.ack(uid: 'ALM-9', ruleIndex: 1);

    expect(policy.asked, [AlarmKeys.active],
        reason: 'gating on the uid type-checks, reads sensibly, and under '
            'AccessPolicyKeyPolicy — whose tag floor ignores the key — '
            'passes every other arm in this file');
  });

  test('an ack before hello is refused and the engine is never touched',
      () async {
    final sink = _Recorder();
    final link = _link(alarmAcks: sink);

    final refusal = await _refused(link.ack(), 'a pre-hello ack');

    expect(refusal.code, ServerErrorCodes.helloRequired,
        reason: 'free from _on — and pinned here so a future '
            'hand-registration cannot lose it');
    expect(sink.acks, isEmpty);
  });

  test('malformed params are refused before the gate', () async {
    final sink = _Recorder();
    final link = _link(alarmAcks: sink);
    await link.hello();

    final refusal = await _refused(
        link.ackRaw(const {'ruleIndex': 1}), 'an ack naming no alarm');

    expect(refusal.code, rpc_errors.INVALID_PARAMS);
    expect(sink.acks, isEmpty);
  });

  test('ackAlarm is registered whether or not a sink was supplied', () async {
    // A wire surface that varies by deployment is a surface no literal can
    // freeze — and it is what would make `-32601` mean two different things.
    expect(_link(alarmAcks: null).session.registeredMethods,
        contains(Methods.ackAlarm));
    expect(_link(alarmAcks: _Recorder()).session.registeredMethods,
        contains(Methods.ackAlarm));
  });
}
