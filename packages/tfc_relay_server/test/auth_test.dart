@TestOn('vm')

/// SEC-03: the credential the gateway checks, the identity it produces, and
/// the revocation that closes a live session.
///
/// Three properties, in the order they are built:
///
///  1. **The token file is read, and a bad file is refused at load** — a
///     duplicate `station`, an entry that still carries a `role` key
///     (whatever its value — the file names WHICH USER a station is and
///     grants nothing, D-06 as ruled), a token below the length floor, and a
///     file any other account on the plant machine can read. A load failure
///     fails `RelayServer.start()`; there is no permissive fallback, for the
///     same reason a misspelled PEM has none.
///  2. **A session knows which station it is**, and the credential appears in
///     nothing that leaves the process — not the `-32003` message, not the
///     close reason, not a `status` frame, not the error sink.
///  3. **Removing a station's token and reloading closes that station's live
///     session with 4001**, observed by a real client on its own socket, and
///     leaves every other station alone.
///
/// Without (1) any peer that can reach the port is a panel. Without (3) a
/// station whose token has been pulled keeps actuating the plant until it
/// chooses to reconnect, which is not revocation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/auth_config.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/error_reporter.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/ws_harness.dart';

/// Tokens long enough to clear [FileTokenValidator.minTokenLength], and
/// visibly not words anyone would type by accident.
const _stationOneToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';
const _stationTwoToken = 'ST201-9aXe5uHj1Lo4Nm7Bs2Tv8Qi6';

/// What an operator mints for ST101 after its token leaked: a new secret for
/// the same station with the same role, which is the remediation path the
/// whole of the revocation sweep exists to serve.
const _stationOneReplacement = 'ST101-4hYp8sWk2Cf6Nx1Dj9Ur5Lz7';

/// The `hello` a station sends, with or without its credential.
///
/// Local rather than `ws_harness.dart`'s `helloParams()`, which takes no
/// token: this is the only file in the package that needs one on the wire.
HelloParams _helloWith(String? token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    );

/// The accounts behind the usernames the token files below name — 17-04b's
/// `UserResolver` seam, filled from a switch the way 17-11 fills it from
/// `AccessRepository`. ST101 is the operating panel, ST201 the view-only
/// display: the same two authorities the old `operate`/`view` file values
/// spelled, now as group sets on database rows.
const _userOne = AuthenticatedUser(
    username: 'ST101-panel', roleName: 'Panel Operator', stationAccount: true);
const _userTwo = AuthenticatedUser(
    username: 'ST201-panel', roleName: 'Hall Display', stationAccount: true);
const _userLong = AuthenticatedUser(
    username: 'BAADER3E-panel',
    roleName: 'Panel Operator',
    stationAccount: true);

const _identityOne = StationIdentity(
    user: _userOne,
    station: 'ST101',
    session: AccessSession(user: _userOne, groups: {AccessGroup.operate}));
const _identityTwo = StationIdentity(
    user: _userTwo,
    station: 'ST201',
    session: AccessSession(user: _userTwo, groups: {}));

ResolvedUser? _accounts(String username) => switch (username) {
      'ST101-panel' =>
        const ResolvedUser(user: _userOne, groups: {AccessGroup.operate}),
      'ST201-panel' => const ResolvedUser(user: _userTwo, groups: {}),
      'BAADER3E-panel' =>
        const ResolvedUser(user: _userLong, groups: {AccessGroup.operate}),
      _ => null,
    };

/// A production fixture whose gateway checks [tokens], written to a temp file
/// this case owns.
///
/// `relayFixture` passes `const PermissiveTokenValidator()` for `validator:`,
/// which is the canonical default object `RelayServer` reads as "no validator
/// configured" — so a `ServerConfig.auth` beside it is not the two-sources-of-
/// truth configuration the constructor refuses.
RelayFixture _gatewayOn(Map<String, Object?> tokens, {RelayErrorHandler? onError}) =>
    _gatewayAt(_writeTokenFile(_tempDir(), tokens), onError: onError);

/// The same, on a token file the case already holds a path to — which is what
/// a revocation case needs, because it rewrites the file underneath the
/// running gateway.
RelayFixture _gatewayAt(String tokenFilePath, {RelayErrorHandler? onError}) =>
    relayFixture(
      config: ServerConfig(
        tick: ServerConfig.minTick,
        auth: AuthConfig(tokenFilePath: tokenFilePath),
      ),
      accounts: _accounts,
      onError: onError,
    );

/// A second real client on an already-running gateway.
///
/// `relayFixture` owns exactly one socket, and a sweep that closed every
/// session would pass every single-session test ever written. This is the
/// other station.
final class _Panel {
  _Panel._(this._ws, this.peer, this.inbound, this.done);

  final WebSocketChannel _ws;
  final rpc.Client peer;

  /// Every frame this panel received, in order.
  final List<String> inbound;

  /// Completes when this panel's socket has finished, however it finished.
  final Future<void> done;

  bool get isOpen => _ws.closeCode == null;

  static Future<_Panel> connect(RelayServer server) async {
    final ws = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}'));
    await ws.ready;
    final inbound = <String>[];
    final finished = Completer<void>();
    final base = wsChannel(ws);
    final tapped = base.stream
        .map((frame) {
          inbound.add(frame);
          return frame;
        })
        .transform(StreamTransformer<String, String>.fromHandlers(
          handleDone: (sink) {
            if (!finished.isCompleted) finished.complete();
            sink.close();
          },
        ));
    final peer = rpc.Client(StreamChannel<String>(tapped, base.sink));
    unawaited(peer.listen().catchError((Object _) => null));
    addTearDown(() async {
      await peer.close();
      await ws.sink.close().catchError((Object _) {});
    });
    return _Panel._(ws, peer, inbound, finished.future);
  }
}

/// Waits for [done] to become true, or fails naming [what].
///
/// A poll rather than an event, because what these cases wait for — a socket
/// the server closed, a frame that arrived — has no seam to listen on from
/// this side. Bounded, so a property that never happens fails by name instead
/// of hanging the lane.
Future<void> _until(bool Function() done, String what,
    {Duration budget = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A temp directory released with the case.
Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('relay-auth-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Writes a token file and locks it to the owner, which is the only mode the
/// loader accepts on POSIX.
String _writeTokenFile(Directory dir, Object? contents, {String mode = '600'}) {
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(contents is String ? contents : _json(contents));
  if (!Platform.isWindows) {
    Process.runSync('chmod', [mode, file.path]);
  }
  return file.path;
}

String _json(Object? value) => jsonEncode(value);

/// The one-station file every accept-path case starts from. The entry names
/// WHICH USER the station is and grants nothing (D-06 as ruled): the groups
/// live on the account row, behind [_accounts].
Map<String, Object?> _oneStation() => {
      'tokens': {
        _stationOneToken: {'username': 'ST101-panel', 'station': 'ST101'},
      },
    };

Map<String, Object?> _twoStations() => {
      'tokens': {
        _stationOneToken: {'username': 'ST101-panel', 'station': 'ST101'},
        _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
      },
    };

void main() {
  group('the token file is read, and a bad one is refused at load', () {
    test('a token file with two stations sharing an id is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {'username': 'ST101-panel', 'station': 'ST101'},
          _stationTwoToken: {'username': 'ST101-other', 'station': 'ST101'},
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _accounts),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', allOf(contains('ST101'), contains(path)))),
          reason: 'two tokens answering to one station makes a revocation '
              'ambiguous: pulling one of them leaves the other still valid for '
              'the identity that was supposed to lose access, and the sweep '
              'cannot tell which live session to close');
    });

    test('a token shorter than the floor is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          'short-token': {'username': 'ST101-panel', 'station': 'ST101'},
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _accounts),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('ST101'), contains('${FileTokenValidator.minTokenLength}'), contains(path)))),
          reason: 'a short credential is a guessable one, and the message must '
              'name the station rather than the token so a support ticket that '
              'pastes it does not paste a credential');
    });

    test('an entry that still carries a role key is refused, whatever the '
        'value', () async {
      // The judgement the old "unknown role string" arm carried, sharpened
      // by D-06 as ruled: the offence is the file having somewhere to put an
      // answer to "and therefore may do X", so the KEY is refused — a role
      // nobody implements, a legacy grant and 17-04's interim role name all
      // alike — and never silently translated or dropped.
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': 'supervisor',
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _accounts),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('supervisor'), contains('"role"'),
                  contains('ST101'), contains(path)))),
          reason: 'the message names the offending value and the station, so '
              'the operator who wrote it is told the grant they believe in '
              'was refused rather than narrowed — and told where the role '
              'now lives (on the account row)');
    });

    test('a group- or world-readable token file is refused', () async {
      final path = _writeTokenFile(_tempDir(), _oneStation(), mode: '644');

      await expectLater(
          FileTokenValidator.load(path, accounts: _accounts),
          throwsA(isA<FileSystemException>()
              .having((e) => e.message, 'message', contains('readable'))),
          reason: 'the credential set is the plant\'s keys; a file every '
              'account on the machine can read is a credential set every '
              'account on the machine has');
    }, skip: Platform.isWindows ? 'POSIX file modes' : null);

    test('a token file the gateway cannot read at all fails the load', () async {
      final dir = _tempDir();

      await expectLater(
          FileTokenValidator.load('${dir.path}/absent.json',
              accounts: _accounts),
          throwsA(isA<FileSystemException>()),
          reason: 'there is no permissive fallback: a gateway that accepted '
              'every panel because somebody misspelled a path would look '
              'perfectly healthy');
    });
  });

  group('a good file produces identities', () {
    test('a valid token maps to its station identity', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _twoStations()),
          accounts: _accounts);

      final accepted = await validator.validate(_helloWith(_stationTwoToken));

      expect(
          accepted,
          isA<TokenAccepted>()
              .having((a) => a.identity, 'identity', _identityTwo),
          reason: 'the resolved row, whole — username, station, and the '
              'group set the account\'s role holds — never the file\'s '
              'claim (ACCESS-06)');
    });

    test('an unknown or absent credential is refused, and the refusal never '
        'repeats it', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: _accounts);

      const impostor = 'IMPOSTOR-4d2f8e1c6b9a3057fe4d2c8b';
      final unknown = await validator.validate(_helloWith(impostor));
      final absent = await validator.validate(_helloWith(null));

      expect(unknown, isA<TokenRejected>());
      expect(absent, isA<TokenRejected>());
      expect((unknown as TokenRejected).reason, isNot(contains(impostor)),
          reason: 'the reason reaches the client inside a -32003 message; a '
              'gateway that echoes the credential back has published it to '
              'every log that catches the refusal');
      expect((absent as TokenRejected).reason, isNotEmpty);
    });

    test('stillValid follows the file, not the session', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final validator =
          await FileTokenValidator.load(path, accounts: _accounts);

      // Through `validate`, because that is how a live session comes by the
      // pair the sweep asks about: an identity and the digest of the
      // credential that bought it.
      final one = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      final two = await validator.validate(_helloWith(_stationTwoToken))
          as TokenAccepted;
      expect(validator.stillValid(one.identity, one.credentialDigest), isTrue);
      expect(validator.stillValid(two.identity, two.credentialDigest), isTrue);

      _writeTokenFile(dir, _oneStation());
      expect(validator.stillValid(two.identity, two.credentialDigest), isTrue,
          reason: 'nothing has been reloaded yet — a validator that answered '
              'from the disk on every call would be doing file I/O on the '
              'hello path');

      await validator.reload();
      expect(validator.stillValid(one.identity, one.credentialDigest), isTrue);
      expect(validator.stillValid(two.identity, two.credentialDigest), isFalse,
          reason: 'ST201\'s token is gone from the file, so its live session '
              'is the one the sweep must close');
    });

    test('a station whose role was narrowed is no longer the identity it '
        'holds', () async {
      // Database-driven since 17-04b: the file cannot say anything about a
      // role any more, so the demotion is an edit to the account source —
      // and the digest, the file, and reload() are all untouched. The
      // resolver is consulted live on every stillValid call.
      final accounts = <String, ResolvedUser>{
        'ST101-panel':
            const ResolvedUser(user: _userOne, groups: {AccessGroup.operate}),
      };
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: (username) => accounts[username]);

      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(operating.identity.session.can(AccessGroup.operate), isTrue);
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue);

      // Same token, same file, narrower groups behind the account's role.
      accounts['ST101-panel'] =
          const ResolvedUser(user: _userOne, groups: {});

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'a session minted before the demotion is still carrying '
              'operate. Leaving it live is the demotion not taking effect '
              'until the panel happens to reconnect — and after Phase 17 the '
              'role also decides configure and administer');
    });

    test('a replaced token is no longer the credential the session holds',
        () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final validator =
          await FileTokenValidator.load(path, accounts: _accounts);

      final accepted = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isTrue);

      // The remediation a leaked credential actually gets: mint a new secret,
      // same station, same account, edit the file, push it to the panel.
      _writeTokenFile(dir, {
        'tokens': {
          _stationOneReplacement: {
            'username': 'ST101-panel',
            'station': 'ST101'
          },
        },
      });
      await validator.reload();

      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isFalse,
          reason: 'the session is holding the leaked credential. Nothing '
              'about its Identity changed — same station, same role — which '
              'is exactly why comparing identities could not see this, and '
              'why the digest of the accepted credential travels beside it');
      expect(validator.stillValid(accepted.identity, null), isTrue,
          reason: 'stated rather than hidden: with no digest to compare, the '
              'answer falls back to the station lookup and cannot tell a '
              'replacement from a re-save. Every session this gateway '
              'authenticates carries one; a null here means the validator '
              'that accepted the session was not this one');
      expect(
          (await validator.validate(_helloWith(_stationOneReplacement))
                  as TokenAccepted)
              .credentialDigest,
          isNot(accepted.credentialDigest),
          reason: 'the new credential resolves to the same identity through a '
              'different digest — which is the whole mechanism');
    });

    test('reloadIfChanged re-reads only when the file changed', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final validator =
          await FileTokenValidator.load(path, accounts: _accounts);

      expect(await validator.reloadIfChanged(), isFalse,
          reason: 'the digest is unchanged, so a config-watch loop that fires '
              'on every notification must cost nothing — re-parsing here is '
              'how a re-save of an identical file churns every live session');

      _writeTokenFile(dir, _oneStation());
      expect(await validator.reloadIfChanged(), isTrue);
      expect(validator.stillValid(_identityTwo, null), isFalse);
    });
  });

  group('the permissive default is honestly labelled', () {
    test('the permissive validator grants every group, and names itself',
        () async {
      final verdict =
          await const PermissiveTokenValidator().validate(_helloWith(null));

      expect(
          verdict,
          isA<TokenAccepted>().having((a) => a.identity.session.groups,
              'groups', AccessGroup.values.toSet()),
          reason: 'its semantics today are "everyone may do everything"; the '
              'full group set is that written down — a larger claim than the '
              'old Role.operate made, and the honest one — and a deployment '
              'still running one stays legible in a config diff');
      expect((verdict as TokenAccepted).identity.station,
          PermissiveTokenValidator.stationId);
      expect(PermissiveTokenValidator.stationId, contains('permissive'),
          reason: 'the station id a permissive gateway hands out must say what '
              'it is wherever it is printed');
    });

    test('an identity carries no credential and cannot be made to', () {
      expect(_identityOne.toString(), contains('ST101'));
      expect(_identityOne.toString(), isNot(contains(_stationOneToken)));
      expect(_identityOne.toString(), isNot(contains('operate')),
          reason: 'and no group set either: a close reason that enumerated '
              'what a station may do would publish the plant\'s grading to '
              'whoever is watching the socket');
    });
  });

  group('AuthConfig holds a path and nothing else', () {
    test('an empty token path is refused at construction', () {
      expect(() => AuthConfig(tokenFilePath: ''), throwsArgumentError);
    });
  });

  group('a session knows which station it is', () {
    test('a valid token gives the session its station identity', () async {
      final fixture = _gatewayOn(_twoStations());
      await fixture.ready;

      final raw = await fixture.request(Methods.hello,
          params: _helloWith(_stationTwoToken).toJson(),
          what: 'the hello result over a real socket');

      expect(HelloResult.fromJson((raw as Map).cast<String, Object?>()).protocol,
          protocolVersion);
      expect(fixture.server.sessions.sessions.single.identity, _identityTwo,
          reason: 'every surface downstream of the handshake asks the session '
              'which station it is; a session that carries a protocol and no '
              'identity is one the policy seam cannot answer about');
    }, tags: 'ws');

    test('a hello with no credential is refused when the gateway has a token '
        'file', () async {
      final fixture = _gatewayOn(_oneStation());
      await fixture.ready;
      final session = fixture.server.sessions.sessions.single;

      final refusal = await fixture.refusal(Methods.hello,
          params: _helloWith(null).toJson(),
          what: 'a tokenless hello against a gateway with a token file');

      expect(refusal.code, ServerErrorCodes.unauthorized);
      expect(session.identity, isNull);
      expect(session.sentCloseCode, CloseCodes.authExpired,
          reason: 'the refusal answers first and the close is scheduled for '
              'the next turn (relay_session.dart:846-849), so a panel learns '
              'why before it learns that');
    }, tags: 'ws');

    test('a permissive gateway still accepts a hello with no credential',
        () async {
      // The control. Without it, the case above passes against a gateway that
      // refuses every hello for any reason at all.
      final fixture = relayFixture();
      await fixture.ready;

      final result = await fixture.hello();

      expect(result.protocol, protocolVersion);
      expect(
          fixture.server.sessions.sessions.single.identity?.session.groups,
          AccessGroup.values.toSet(),
          reason: 'the permissive identity, full group set — see "honestly '
              'labelled" above');
    }, tags: 'ws');

    test('a second hello cannot change the session\'s identity', () async {
      final fixture = _gatewayOn(_twoStations());
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'the first hello');
      final session = fixture.server.sessions.sessions.single;

      final second = await fixture.refusal(Methods.hello,
          params: _helloWith(_stationTwoToken).toJson(),
          what: 'a second hello on a session that already has one');

      expect(second.code, ServerErrorCodes.alreadyHelloed);
      expect(session.identity?.station, 'ST101',
          reason: 'the credential is checked before the gate, so a second '
              'hello carrying another station\'s token reaches the validator. '
              'If it could overwrite the identity, a view station could talk '
              'its way into an operate one on a handshake the gate then '
              'refuses — the refusal being irrelevant, because the damage is '
              'the field, not the answer');
    }, tags: 'ws');

    test('a second hello with a bad credential does not close a session that '
        'authenticated correctly', () async {
      final fixture = _gatewayOn(_oneStation());
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'the first hello');
      final session = fixture.server.sessions.sessions.single;

      final second = await fixture.refusal(Methods.hello,
          params: _helloWith('NOT-A-CREDENTIAL-THIS-GATEWAY-KNOWS').toJson(),
          what: 'a second hello carrying a credential the gateway never '
              'issued');

      expect(second.code, ServerErrorCodes.alreadyHelloed,
          reason: 'the same frame with a *good* token already gets this '
              'answer. Reaching the validator first meant a bad one produced '
              'a 4001 instead, tearing down a session that authenticated '
              'correctly and has been serving the plant — a self-inflicted '
              'disconnect by a client with a state bug, and the credential '
              'check has nothing left to decide on a session that already '
              'has an identity');
      expect(session.identity?.station, 'ST101');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'a 4001 would have been scheduled by now; the socket is '
              'still here');
    }, tags: 'ws');

    test('the credential appears in no message, close reason, status frame or '
        'log', () async {
      // Distinctive enough that a substring hit cannot be a coincidence, and
      // long enough to clear the loader's floor so the only reason it is
      // refused is that it is not in the file.
      const presented = 'LEAKCANARY-8f3b1d64ac0e529716b4d8fa3c';
      final reported = <String>[];
      final fixture = _gatewayOn(_oneStation(),
          onError: (error, stack, what) =>
              reported.add('$what: $error\n$stack'));
      await fixture.ready;

      final refusal = await fixture.refusal(Methods.hello,
          params: _helloWith(presented).toJson(),
          what: 'a hello carrying a credential this gateway never issued');
      final close = await fixture.awaitClose('the refused session closing');

      // One rule, four surfaces, because a credential published on any of
      // them is published (T-06-26).
      expect(refusal.toString(), isNot(contains(presented)),
          reason: 'the -32003 message and its data reach the panel and every '
              'log that catches the refusal');
      expect(close.closeReason, isNotNull,
          reason: 'a null reason would satisfy every absence assertion below '
              'while proving nothing (06-02-SUMMARY deviation 3)');
      expect(close.closeReason, isNot(contains(presented)),
          reason: 'the close reason is displayed to an operator');
      expect(fixture.inbound.where((f) => f.contains(presented)), isEmpty,
          reason: 'every frame the client received, which is where a '
              'StatusParams.error would arrive');
      expect(reported.where((r) => r.contains(presented)), isEmpty,
          reason: 'the gateway\'s error sink — its log on a plant machine');
    }, tags: 'ws');
  });

  group('revocation closes the revoked station\'s session', () {
    test('revoking a station\'s token closes its live session with 4001',
        () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final fixture = _gatewayAt(path);
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'ST101\'s hello');
      expect(fixture.server.sessions.sessions.single.identity?.station,
          'ST101');

      // The apply is in-process and the case drives it directly: no timer, no
      // sleep, no watcher. Production hangs this off whatever already watches
      // the file (see `reloadTokens`' doc), and a test that waited for one
      // would be measuring a poll interval.
      _writeTokenFile(dir, {
        'tokens': {
          _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
        },
      });
      await fixture.server.reloadTokens();

      final close = await fixture.awaitClose('the revoked station\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'the client has to *observe* 4001 on its own socket. The '
              'server recording an intention is what the handler-table sweep '
              'spent this phase refusing to count');
      expect(close.closeReason, contains('ST101'),
          reason: 'a panel that goes dark at shift change needs the reason to '
              'name the station whose credential was pulled');
    }, tags: 'ws');

    test('replacing a station\'s token closes the session holding the old one',
        () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final fixture = _gatewayAt(path);
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'ST101\'s hello');

      final survivor = await _Panel.connect(fixture.server);
      await survivor.peer.sendRequest(
          Methods.hello, _helloWith(_stationTwoToken).toJson());
      expect(fixture.server.sessions.sessionCount, 2);

      // ST101's token leaked. The operator does the obvious thing: a new
      // secret for the same station with the same role. ST101's Identity is
      // untouched by that edit, which is what made this the one revocation
      // path the sweep could not see.
      _writeTokenFile(dir, {
        'tokens': {
          _stationOneReplacement: {'username': 'ST101-panel', 'station': 'ST101'},
          _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
        },
      });
      await fixture.server.reloadTokens();

      final close = await fixture.awaitClose(
          'the session still holding the leaked credential',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'a leaked credential is remediated by replacing it, not by '
              'deleting the station. A session that keeps its operate role '
              'for as long as its heartbeat holds is the primary incident '
              'surviving its own primary remediation');
      expect(close.closeReason, contains('ST101'));
      expect(survivor.isOpen, isTrue,
          reason: 'ST201\'s entry is byte-identical across the edit; a sweep '
              'that closed it would be reacting to the file changing rather '
              'than to the credential changing');
      expect(await survivor.peer.sendRequest(Methods.ping), isA<Map>());
    }, tags: 'ws');

    test('revoking one station leaves the other\'s session alone', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final fixture = _gatewayAt(path);
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'ST101\'s hello');

      final survivor = await _Panel.connect(fixture.server);
      await survivor.peer.sendRequest(
          Methods.hello, _helloWith(_stationTwoToken).toJson());
      const key = 'CN01.MOT01.speed';
      fixture.served.setValue(key, 1);
      await survivor.peer.sendRequest(Methods.subscribe,
          const SubscribeParams(sub: 'page-1', keys: [key]).toJson());
      expect(fixture.server.sessions.sessionCount, 2);

      _writeTokenFile(dir, {
        'tokens': {
          _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
        },
      });
      await fixture.server.reloadTokens();
      await fixture.awaitClose('the revoked station\'s socket',
          budget: const Duration(seconds: 3));

      expect(survivor.isOpen, isTrue,
          reason: 'a sweep that closed every session would pass a '
              'single-session case, which is why there are two here');
      expect(await survivor.peer.sendRequest(Methods.ping), isA<Map>(),
          reason: 'still answering, not merely still connected');
      fixture.served.setValue(key, 2);
      await _until(
          () => survivor.inbound.any((f) => f.contains('"method":"u"')),
          'ST201 still receiving plant updates after ST101 was revoked');
    }, tags: 'ws');

    test('a session that has not said hello is left alone by the sweep',
        () async {
      final dir = _tempDir();
      final fixture = _gatewayAt(_writeTokenFile(dir, _twoStations()));
      await fixture.ready;
      expect(fixture.server.sessions.sessions.single.identity, isNull);

      _writeTokenFile(dir, _oneStation());
      await fixture.server.reloadTokens();

      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'a pre-hello session has no identity to revoke. The gate '
              'already holds it to one method and the heartbeat reaper '
              'already reaps it, so it is not the revocation\'s business — '
              'and a sweep that closed it would be closing sockets for a '
              'credential nobody had presented yet');
    }, tags: 'ws');

    test('reloadTokensIfChanged reads the file once, and a no-op call closes '
        'nobody', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final fixture = _gatewayAt(path);
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_stationOneToken).toJson(),
          what: 'ST101\'s hello');

      expect(await fixture.server.reloadTokensIfChanged(), isFalse,
          reason: 'the documented sequence was reloadIfChanged() then '
              'reloadTokens(), which parses the file twice per change and '
              'lets the two reads disagree — a file edited between them, or '
              'half-written by an editor that does not write atomically, '
              'leaves the sweep running against a set the caller never saw');
      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'the sweep RUNS on every call since 17-09 — the digest '
              'guards the parse, not the credential, because most user-model '
              'revocations never touch the file — and a sweep over unchanged '
              'credentials closes nothing');

      _writeTokenFile(dir, {
        'tokens': {
          _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
        },
      });

      expect(await fixture.server.reloadTokensIfChanged(), isTrue);
      final close = await fixture.awaitClose('the revoked station\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'one call, one read, and the sweep still happens — this is '
              'the call an embedder\'s poll makes');
    }, tags: 'ws');

    test('a station with a long name is still closed, not silently kept',
        () async {
      // Found by the review fix, not by the review. RFC 6455 caps a close
      // reason at 123 bytes and `package:web_socket` throws above it; the
      // throw lands in `_Connection.closeSocket`'s catch, which reads it as
      // "the far end is already gone", and the socket is then **never
      // closed**. The gateway believes it revoked the station and the panel
      // keeps its credential. The old reason was 116 bytes with `ST101` in
      // it, so a thirteen-character station id was enough.
      const long = 'BAADER-FILLETING-LINE-3-PANEL-EAST';
      const token = 'BAADER3E-7pQ2xL9mR4vK1nT6wS3yB8dF';
      final dir = _tempDir();
      final path = _writeTokenFile(dir, {
        'tokens': {
          token: {'username': 'BAADER3E-panel', 'station': long},
        },
      });
      final fixture = _gatewayAt(path);
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(token).toJson(), what: 'the long station\'s hello');

      _writeTokenFile(dir, {
        'tokens': {
          _stationTwoToken: {'username': 'ST201-panel', 'station': 'ST201'},
        },
      });
      await fixture.server.reloadTokens();

      final close = await fixture.awaitClose('the revoked station\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'a revocation that depends on how long the station is '
              'called is not a revocation');
      expect(close.closeReason, contains(long));
    }, tags: 'ws');

    test('reloadTokens refuses to pretend on a gateway with no token file',
        () async {
      final fixture = relayFixture();
      await fixture.ready;

      await expectLater(
          fixture.server.reloadTokens(),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('PermissiveTokenValidator'))),
          reason: 'a silent no-op would let a deployment believe rotation '
              'works: the operator edits the file, nothing happens, and '
              'nothing says so');
    }, tags: 'ws');
  });

  // A security property no behavioural case can see. The sabotage arm proved
  // it: replacing the accumulator with an early-exit compare — the exact
  // "simplification" a later reader makes — leaves every other case in this
  // file green, because early exit is *correct*, it is only not constant
  // time. A timing assertion would be a flake on a shared CI runner, so the
  // pin is structural instead, and it is stated plainly rather than implied
  // by a comment nobody has to keep true.
  group('the credential comparison does not exit early', () {
    final source =
        File('lib/src/auth/file_token_validator.dart').readAsStringSync();

    test('the source the pin reads is the real one', () {
      // Anti-vacuity: every assertion below passes against an empty string.
      expect(source, contains('class FileTokenValidator'),
          reason: 'the pin is reading the wrong file, and everything it '
              'reports is noise');
    });

    test('the lookup confirms the digest through the constant-time helper', () {
      expect(source, contains('_constantTimeEquals(entry.digest, presented)'),
          reason: 'the map lookup is a hash lookup over digests; the actual '
              'credential comparison is the line after it, and if that line '
              'stops calling the helper the property is gone');
    });

    test('the helper accumulates instead of returning at the first difference',
        () {
      final body = _functionBody(source, 'bool _constantTimeEquals(');
      final loop = body.indexOf('for (');
      expect(loop, greaterThanOrEqualTo(0),
          reason: 'the helper has no loop left in it: something replaced the '
              'byte-wise comparison with a whole-object one, which for two '
              'Uint8Lists is reference equality');

      final afterLoop = body.substring(loop);
      expect('return'.allMatches(afterLoop), hasLength(1),
          reason: 'there is more than one exit from the comparison loop, so '
              'how long the comparison takes depends on where the two digests '
              'first differ — which is the side channel the helper exists to '
              'close (T-06-28). Found:\n$afterLoop');
      expect(afterLoop, contains('^'));
      expect(afterLoop, contains('|='));
    });

    test('nothing in the file compares a token with ==', () {
      final offenders = <String>[];
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('//') || line.startsWith('///')) continue;
        if (!line.contains('==')) continue;
        // `token == null` is a presence check on the reference, not a
        // comparison of the secret against anything.
        if (line.contains('token ==') && !line.contains('token == null')) {
          offenders.add('${i + 1}: $line');
        }
        if (line.contains('== token')) offenders.add('${i + 1}: $line');
      }
      expect(offenders, isEmpty,
          reason: 'a Dart String `==` short circuits on the first differing '
              'code unit. Found: $offenders');
    });
  });

  // The other property no behavioural case can see, and this one is a
  // *timing* property of the event loop rather than of a comparison.
  //
  // `RelayServer.reloadTokens` awaits the reload and then sweeps the sessions
  // that already carry an identity. A hello whose identity landed *during*
  // that await would be visited while its identity was still null, skipped,
  // and then handed a credential set no sweep checked — keeping its access
  // for the life of its socket. It cannot happen here, and the reason is that
  // `validate` contains no `await`: its future is already complete, so the
  // assignment happens in a microtask, and microtasks drain before
  // `readAsBytes`'s I/O completion can be delivered.
  //
  // That is a property of *this* implementation, not of the interface, and
  // the interleaving is not forcible from outside — which is exactly why it
  // needs a pin rather than a case. The constraint is written on
  // `TokenValidator.validate` for anyone writing a second implementation.
  group('the credential check resolves without waiting on the world', () {
    final source =
        File('lib/src/auth/file_token_validator.dart').readAsStringSync();

    test('validate awaits nothing', () {
      final body =
          _methodBody(source, 'Future<TokenVerdict> validate(HelloParams');
      expect(body, contains('_set.lookup(token)'),
          reason: 'anti-vacuity: the pin is reading the wrong span and the '
              'assertion below is about nothing');
      // Word-boundary, not a substring scan — `unawaited(…)` contains the
      // letters `await` and means the opposite (2026-09-06).
      expect(body, isNot(matches(RegExp(r'\bawait\b'))),
          reason: 'an `await` here makes the hello path event-asynchronous, '
              'and the revocation sweep in `relay_server.dart` then has a '
              'window a session can be authenticated in and never swept. If '
              'this validator genuinely has to wait on something, do the '
              'waiting in `reload` — where the sweep is already ordered '
              'behind it — and keep this a lookup. Found:\n$body');
    });

    test('the sweep itself awaits nothing', () {
      final server = File('lib/src/relay_server.dart').readAsStringSync();
      final sweep =
          _methodBody(server, 'void _sweepRevoked(RevocableTokenValidator');
      expect(sweep, contains('_sessions.sessions'),
          reason: 'anti-vacuity: the pin is reading the wrong span');
      // Word-bounded: `unawaited(` contains the string and is the opposite of
      // what this is counting.
      expect(RegExp(r'\bawait\b').allMatches(sweep), isEmpty,
          reason: 'an await inside the loop would let the next iteration '
              'observe a registry the previous close had not finished leaving '
              '— the property `unawaited(session.close(...))` depends on, '
              'which is only safe because the registry removal is the '
              'synchronous half of the teardown. Found:\n$sweep');

      for (final entry in {
        'reloadTokens': _methodBody(server, 'Future<void> reloadTokens()'),
        'reloadTokensIfChanged':
            _methodBody(server, 'Future<bool> reloadTokensIfChanged()'),
      }.entries) {
        expect(RegExp(r'\bawait\b').allMatches(entry.value), hasLength(1),
            reason: '${entry.key} has more than the one await its reload '
                'needs, and the sweep is ordered behind whatever the second '
                'one waits for. Found:\n${entry.value}');
      }
    });
  });
}

/// The body of the *method* whose declaration starts with [signature].
///
/// [_functionBody]'s sibling, and separate because the closing brace of a
/// method is at two spaces rather than at column zero — reading to the first
/// `\n}` would swallow the rest of the class.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) fail('$signature is not in the source any more');
  final open = source.indexOf('{', start);
  final close = source.indexOf('\n  }', open);
  if (close < 0) fail('$signature has no closing brace at two spaces');
  return source.substring(open, close);
}

/// The body of the top-level function whose declaration starts with
/// [signature], braces included.
///
/// The `ws_malformed_test.dart` precedent for `_defuse`: a structural pin has
/// to read the one function rather than the whole file, or a `return` anywhere
/// else in the file satisfies it.
String _functionBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) fail('$signature is not in the source any more');
  final open = source.indexOf('{', start);
  // Top-level function, so the closing brace is the first one at column zero.
  final close = source.indexOf('\n}', open);
  if (close < 0) fail('$signature has no closing brace at column zero');
  return source.substring(open, close);
}
