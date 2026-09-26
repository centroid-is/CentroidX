/// Two `hello` frames racing on one session, and the once-only identity they
/// break.
///
/// ## The mechanism
///
/// Named in full in `concurrent_engage_test.dart`, because the two files share
/// it: `json_rpc_2`'s `Server.listen` does not await the future its dispatch
/// returns (`server.dart:115`), and a **batch** — a JSON-RPC request that is a
/// JSON *array* rather than an object — is dispatched through
/// `Future.wait(request.map(_handleSingleRequest))` (`server.dart:175-181`),
/// which starts every member in the same turn. `Peer` routes an array whose
/// first member looks like a request straight to the server half
/// (`peer.dart:listen`), so a batch reaches the gateway's handlers intact.
///
/// **This is the first JSON-RPC array frame this repository has ever sent.**
/// Nothing in `json_rpc_2`'s client API builds one with ids a case chose, so
/// the frames here are `jsonEncode`d by hand onto `RelayFixture.client.sink`
/// and the answers are read back out of `RelayFixture.inbound` — the batch
/// response is itself one frame carrying an array of responses.
///
/// ## What is actually broken
///
/// `relay_session.dart:1210` guards on `_identity == null`, `:1211` awaits
/// `validator.validate(hello)`, and `:1228-1229` assigns. Two hellos both pass
/// the guard before either resumes.
///
///  * If the loser's token is **invalid**, it reaches `TokenRejected` and
///    calls `_requestClose(CloseCodes.authExpired, …)` at `:1213` — a 4001 that
///    tears down a session that authenticated correctly and has been serving
///    the plant. That is byte-for-byte the failure the comment at
///    `:1188-1209` says was fixed, resurrected through the batch path.
///  * If it is **valid but another station's**, `_identity` and
///    `_credentialDigest` are overwritten *after* the handshake was accepted.
///    No privilege escalation is constructible — the two fields are written
///    together and every authority check reads the identity late — but the
///    invariant, the attribution in the close ledger, and the subject the
///    revocation sweep judges by all break.
///
/// ## The two shapes, and the measurement behind running both
///
/// A batch races by construction. **Two separate frames do not**, as long as
/// the validator resolves in microtasks: two frames are two stream events, and
/// the microtask queue drains completely between them, so the first hello
/// finishes before the second is delivered. That was measured rather than
/// reasoned — this plan's RED run pointed the two-frame arms at `_TwoStations`
/// (which awaits nothing but its own microtask) and the anti-vacuity gate in
/// `_twoFrameRace` timed out after five seconds with `arrivals == 1`, twice.
/// So the two-frame shape *cannot* be driven by the shipped validator, and
/// saying so is more useful than an arm that passes for a reason nobody wrote
/// down.
///
/// The two-frame shape therefore runs against a validator that suspends on
/// something event-driven, which is not an invented hazard: it is exactly the
/// window `token_validator.dart:39-62` already writes down — "an
/// implementation that awaits real work — a directory lookup, a cache with a
/// refresh-on-miss, an HMAC service — reopens the window". That doc argues the
/// case for the *revocation sweep*; this file is the same await reopening the
/// same window for `_identity` itself. A fix that only re-checked in the batch
/// path would be a fix for the shipped validator and nothing else.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/token_validator.dart';

import 'support/ws_harness.dart';

const String _idA = 'hello-a';
const String _idB = 'hello-b';

/// A credential this gateway never issued. Distinctive enough that a substring
/// hit in a diagnostic could not be a coincidence, and long enough to clear
/// any loader floor, so the only reason it is refused is that it is unknown.
const String _unknownToken = 'NOT-A-CREDENTIAL-THIS-GATEWAY-EVER-ISSUED-4f2b';

// ---------------------------------------------------------------------------
// Validators.
// ---------------------------------------------------------------------------

/// Two stations, two tokens, and no third answer.
///
/// Conforming to `TokenValidator`'s constraint: it awaits nothing external, so
/// its future resolves in a microtask. That is what makes it the right
/// validator for the batch shape — the race there comes from `Future.wait`,
/// not from a validator that misbehaves.
final class _TwoStations implements TokenValidator {
  const _TwoStations();

  static const String stationOneToken = 'ST101-TOKEN-8f3b1d64ac0e529716b4d8fa';
  static const String stationTwoToken = 'ST201-TOKEN-4d2a9e71bc0f38562a7c15eb';

  // StationIdentity fixtures on the user model (17-04b): the resolver-
  // verified account row, the station, and the session its role resolved
  // to. What the arms assert about them — value equality against the field
  // the winning hello set — is unchanged.
  static const AuthenticatedUser _userOne = AuthenticatedUser(
      username: 'ST101-panel',
      roleName: 'Panel Operator',
      stationAccount: true);
  static const AuthenticatedUser _userTwo = AuthenticatedUser(
      username: 'ST201-panel',
      roleName: 'Panel Operator',
      stationAccount: true);

  static const StationIdentity stationOne = StationIdentity(
      user: _userOne,
      station: 'ST101',
      session: AccessSession(user: _userOne, groups: {AccessGroup.operate}));
  static const StationIdentity stationTwo = StationIdentity(
      user: _userTwo,
      station: 'ST201',
      session: AccessSession(user: _userTwo, groups: {AccessGroup.operate}));

  /// Stand-in digests, and deliberately **not** derived from the tokens.
  ///
  /// What a case asserts about a digest is that it describes the same station
  /// the identity does — `TokenAccepted`'s doc calls the pair one fact — and a
  /// constant per station says that without a test file computing anything
  /// over a credential.
  static final Uint8List stationOneDigest = Uint8List.fromList(
      const [0x51, 0x01, 0x51, 0x01, 0x51, 0x01, 0x51, 0x01]);
  static final Uint8List stationTwoDigest = Uint8List.fromList(
      const [0x52, 0x01, 0x52, 0x01, 0x52, 0x01, 0x52, 0x01]);

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      switch (params.token) {
        stationOneToken =>
          TokenAccepted(stationOne, credentialDigest: stationOneDigest),
        stationTwoToken =>
          TokenAccepted(stationTwo, credentialDigest: stationTwoDigest),
        _ => const TokenRejected('this gateway issued no such credential'),
      };
}

/// [_TwoStations], suspended on something the case completes.
///
/// The validator `token_validator.dart:39-62` warns about, in the smallest
/// form that still has the property: a `validate` that does not resolve within
/// the turn it was called in. A directory lookup, an introspection endpoint or
/// a cache with a refresh-on-miss all have this shape.
final class _GatedStations implements TokenValidator {
  final _gate = Completer<void>();

  /// How many hellos have entered `validate` and suspended.
  int arrivals = 0;

  @override
  Future<TokenVerdict> validate(HelloParams params) async {
    arrivals++;
    await _gate.future;
    return const _TwoStations().validate(params);
  }

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }
}

// ---------------------------------------------------------------------------
// Frames, answers and the two shapes.
// ---------------------------------------------------------------------------

Map<String, Object?> _helloFrame(String id, String? token) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': Methods.hello,
      'params': HelloParams(
        protocol: protocolVersion,
        supported: const [protocolVersion],
        client: const PeerInfo('panel-under-test', '0.1.0'),
        token: token,
      ).toJson(),
    };

/// Waits on wall-clock rather than on turns of the microtask queue.
///
/// The fixture's answers sit in the send buffer until the tick drains them, so
/// a waiter that only pumped microtasks would never see one. A deadline turned
/// into a `fail`, in `ws_malformed_test.dart:703`'s shape: silence is the
/// failure mode here and a matcher cannot express it.
Future<void> _until(bool Function() done, String what,
    {Duration budget = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('waited ${budget.inSeconds} s for $what, and it never happened');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Every JSON-RPC response the client has received, by id.
///
/// Reads `inbound` rather than awaiting the fixture's own peer: these frames
/// are written straight onto the socket, so the peer has no pending entry for
/// their ids and discards the answers (`client.dart:232`).
Map<String, Map<String, Object?>> _received(RelayFixture fixture) {
  final answers = <String, Map<String, Object?>>{};
  for (final frame in fixture.inbound) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      continue;
    }
    for (final entry in decoded is List ? decoded : [decoded]) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is String) answers[id] = entry.cast<String, Object?>();
    }
  }
  return answers;
}

Future<Map<String, Map<String, Object?>>> _answers(
    RelayFixture fixture, List<String> ids) async {
  await _until(() {
    final answers = _received(fixture);
    return ids.every(answers.containsKey);
  }, 'answers for $ids');
  return _received(fixture);
}

/// One raced handshake, and the session it happened on.
final class _Race {
  _Race(this.fixture, this.session, this.answers);

  final RelayFixture fixture;

  /// Held from before the race, because a session that gets torn down leaves
  /// the registry — and "did it get torn down" is exactly what arm 1 asks.
  final RelaySession session;

  final Map<String, Map<String, Object?>> answers;

  Map<String, Object?> get a => answers[_idA]!;
  Map<String, Object?> get b => answers[_idB]!;

  bool isResult(Map<String, Object?> answer) => answer.containsKey('result');
  bool isRefusal(Map<String, Object?> answer) => answer.containsKey('error');
}

typedef _RaceRunner = Future<_Race> Function(String tokenA, String? tokenB);

/// Both hellos in one array frame. Races by construction.
Future<_Race> _batchRace(String tokenA, String? tokenB) async {
  final fixture = relayFixture(validator: const _TwoStations());
  await fixture.ready;
  final session = fixture.server.sessions.sessions.single;

  fixture.client.sink.add(jsonEncode([
    _helloFrame(_idA, tokenA),
    _helloFrame(_idB, tokenB),
  ]));

  return _Race(fixture, session, await _answers(fixture, [_idA, _idB]));
}

/// Two frames, one turn, against a validator that suspends on an event.
Future<_Race> _twoFrameRace(String tokenA, String? tokenB) async {
  final gate = _GatedStations();
  final fixture = relayFixture(validator: gate);
  await fixture.ready;
  final session = fixture.server.sessions.sessions.single;

  fixture.client.sink.add(jsonEncode(_helloFrame(_idA, tokenA)));
  fixture.client.sink.add(jsonEncode(_helloFrame(_idB, tokenB)));

  // The anti-vacuity gate: if only one hello ever reaches the validator these
  // frames were sequential, and every assertion below would be about a
  // sequence rather than a race.
  await _until(() => gate.arrivals == 2,
      'both hellos to be suspended inside validator.validate at once');
  gate.open();

  return _Race(fixture, session, await _answers(fixture, [_idA, _idB]));
}

const Map<String, _RaceRunner> _shapes = {
  'as one batch frame': _batchRace,
  'as two frames in one turn': _twoFrameRace,
};

void main() {
  _shapes.forEach((shape, race) {
    group('two hellos racing $shape', () {
      test('a bad second credential does not close the session the first one '
          'opened', () async {
        final raced = await race(
            _TwoStations.stationOneToken, _unknownToken);

        expect(raced.isResult(raced.a), isTrue,
            reason: 'the hello carrying a credential this gateway issued must '
                'be answered with a handshake');
        expect(raced.isRefusal(raced.b), isTrue,
            reason: 'the second hello must be refused — with a response. Its '
                'code is the fix\'s choice and is deliberately not pinned '
                'here');

        expect(raced.session.sentCloseCode, isNull,
            reason: 'the session was closed with '
                '${raced.session.sentCloseCode} while it was serving the '
                'plant, because the loser of the race reached TokenRejected '
                'and called _requestClose(CloseCodes.authExpired) at '
                'relay_session.dart:1213. A client with a state bug must not '
                'be able to disconnect a handshake that succeeded, and '
                'CloseCodes.authExpired is ${CloseCodes.authExpired}');
        expect(raced.session.identity, _TwoStations.stationOne,
            reason: 'the identity must be the one the accepted handshake set');

        // The 4001 is scheduled for the next turn (`_requestClose` uses
        // `Timer.run`), so a session that is going to die has died by now.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(raced.fixture.server.sessions.sessionCount, 1,
            reason: 'the socket is gone: a bad credential in a racing frame '
                'cost the panel its session');
      }, tags: 'ws');

      test('another station\'s valid credential cannot take the identity over',
          () async {
        final raced = await race(
            _TwoStations.stationOneToken, _TwoStations.stationTwoToken);

        expect(raced.isResult(raced.a), isTrue);
        expect(raced.isRefusal(raced.b), isTrue,
            reason: 'exactly one handshake may be accepted on one session');

        expect(raced.session.identity, _TwoStations.stationOne,
            reason: 'the identity is '
                '${raced.session.identity} — the losing hello overwrote it '
                '*after* the winning handshake had been accepted. Identity is '
                'the subject the revocation sweep judges by and the subject '
                'every close-ledger attribution names, so a session answering '
                'for a station it never authenticated as breaks both, even '
                'where no privilege was gained');
        expect(raced.session.credentialDigest, _TwoStations.stationOneDigest,
            reason: 'the identity and the digest are one fact and are written '
                'together (relay_session.dart:1224-1229). A session carrying '
                'one hello\'s identity and another\'s digest is a session the '
                'revocation sweep would judge on a credential it is not using');

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(raced.session.sentCloseCode, isNull,
            reason: 'the loser is refused with a response, never a close');
        expect(raced.fixture.server.sessions.sessionCount, 1);
      }, tags: 'ws');
    });
  });

  group('a hello that is not racing anything still behaves', () {
    // `session_hello_test.dart:165` and `auth_test.dart:502/:524`, restated
    // over this file's validator so that the fix for the arms above cannot be
    // bought by changing the settled sequential answer. Both shapes, because
    // the second frame's *envelope* is the only thing that differs once the
    // first hello has been answered — and the batch envelope must reach the
    // same answer as the bare one.
    for (final batched in [false, true]) {
      test('a second hello sent after the first was answered is refused '
          'without closing the session '
          '${batched ? '(in a batch frame)' : '(as a bare frame)'}',
          () async {
        final fixture = relayFixture(validator: const _TwoStations());
        await fixture.ready;
        final session = fixture.server.sessions.sessions.single;

        fixture.client.sink
            .add(jsonEncode(_helloFrame(_idA, _TwoStations.stationOneToken)));
        final first = (await _answers(fixture, [_idA]))[_idA]!;
        expect(first.containsKey('result'), isTrue,
            reason: 'the first hello did not take, so the second one is not '
                'the second anything');

        final second = _helloFrame(_idB, _TwoStations.stationTwoToken);
        fixture.client.sink
            .add(jsonEncode(batched ? [second] : second));
        final answer = (await _answers(fixture, [_idB]))[_idB]!;

        expect(answer.containsKey('error'), isTrue,
            reason: 'a second hello on a session that already has an identity '
                'is refused; that is settled behaviour and this arm is here '
                'to keep it settled');
        expect(session.identity, _TwoStations.stationOne);
        expect(session.credentialDigest, _TwoStations.stationOneDigest);

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(session.sentCloseCode, isNull,
            reason: 'a renegotiation attempt is a client bug, not a hostile '
                'act: the session it already has keeps working');
        expect(fixture.server.sessions.sessionCount, 1);
      }, tags: 'ws');
    }
  });
}
