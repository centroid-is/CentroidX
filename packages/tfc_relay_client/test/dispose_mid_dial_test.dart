@TestOn('vm')

/// A dial nobody is going to serve still closes the socket it opened.
///
/// Source: 16-07, finding S12. **No test covered dispose-mid-dial before this
/// file.**
///
/// `ConnectionSupervisor._attempt` takes a generation on the way in and, when
/// the dial finally answers, returns without serving if the client has been
/// disposed or the generation has moved on. That return dropped the
/// `ConnectAttempt` on the floor. The dial had already completed — the socket
/// is up, the WebSocket upgrade has happened — and nothing else in the file can
/// reach it: the only `sink` close is `_stopServing`'s `peer.close()`, and the
/// peer is built inside `_serve`, which this path never reaches.
///
/// **`_pinned?.close(force: true)` does not reap it**, which is the reason this
/// is not merely untidy. The upgrade detaches the socket from the `HttpClient`
/// connection pool, so closing the client leaves the socket open and the
/// gateway carries a session nobody is on until its own reaper fires. The
/// window is real and it is long: `connectTimeout` defaults to ten seconds, and
/// a gateway coming back from a reboot is exactly the condition that fills it —
/// a panel shutting down while the gateway is mid-restart leaks one session per
/// occurrence.
///
/// **Two doors, one condition.** The guard is `_disposed || gen != _generation`
/// and a fix that closed the socket on only the first would leave the second
/// open. The second door is not reachable through this class's public surface
/// today — `_generation` moves only in `dispose()`, in `_attempt` itself and in
/// `_down`/`_stop`, none of which can run while a dial is in flight, because
/// `_attempt` enters `connecting` before it awaits and `start()` refuses to
/// re-enter from there. That is a fact worth writing down rather than a reason
/// to leave the branch untested: the guard already names two doors, and the
/// second one becomes reachable the first time anything else learns to retire a
/// connection. So the dispose door is pinned end to end, on a real socket, and
/// the superseded door is pinned structurally — the close must sit under the
/// whole condition and not under a `_disposed`-only branch.
///
/// What breaks in the plant without this file: every panel restart that lands
/// during a gateway reboot leaves a zombie session behind, and the gateway's
/// connection ceiling is reached by machines that are not connected to it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_client/src/dial/pinned_dialer_io.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// The key the one registered page asks for.
///
/// One page rather than none, for `reconnect_test.dart:128-137`'s reason: with
/// an empty registry a resync completes without a call reaching the wire.
const String _seededKey = 'ST101.CN01.MOT01.setpoint';

/// How long an arm waits for something it expects.
const Duration _budget = Duration(seconds: 5);

/// How long an arm waits for the abandoned socket to close before calling it a
/// leak. Two orders of magnitude above a loopback close.
const Duration _closeBudget = Duration(seconds: 2);

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      snapshotDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
      connectTimeout: const Duration(seconds: 5),
    );

/// A gateway that accepts the upgrade and then says nothing at all.
///
/// Deliberately mute: it never answers `hello`, never closes, and never sends a
/// frame. So the only thing that can complete the client's `sink.done` is the
/// client closing its own socket, which is the whole assertion — and the
/// server-side `onDone` below is the same fact observed from the far end,
/// where a leak would actually be paid for.
final class _MuteGateway {
  _MuteGateway._(this._http);

  static Future<_MuteGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _MuteGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final List<WebSocket> _sockets = <WebSocket>[];

  /// How many sockets were upgraded. The anti-vacuity number: "the socket was
  /// closed" means nothing if no socket was ever opened.
  int accepted = 0;

  /// How many of them the far end saw go away.
  int closed = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      accepted++;
      _sockets.add(socket);
      socket.listen(
        (Object? _) {},
        onError: (Object _) => closed++,
        onDone: () => closed++,
        cancelOnError: true,
      );
    }
  }

  Future<void> shutdown() async {
    for (final socket in _sockets) {
      await socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

/// A dial that suspends until it is released, then dials for real.
///
/// It delegates to [connect] rather than fabricating an outcome, which is what
/// the `dial:` seam's own doc requires — "one attempt in, one `ConnectAttempt`
/// out, same as the real one". A fabricated success would be a socket this
/// client never opened, and the leak under test is about a socket it did.
final class _SuspendedDial {
  /// Completes the moment the supervisor has entered the dial. The arm's
  /// signal that the window is open.
  final Completer<void> entered = Completer<void>();

  /// Completed by the arm to let the dial finish.
  final Completer<void> release = Completer<void>();

  int calls = 0;

  /// What the dial handed back, once it has.
  ConnectAttempt? attempt;

  Future<ConnectAttempt> call(Uri uri) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    final result = await connect(uri, connectTimeout: const Duration(seconds: 5));
    attempt = result;
    return result;
  }
}

ConnectionSupervisor _supervisor(
  Uri uri,
  Future<ConnectAttempt> Function(Uri uri) dial,
) {
  final stores = <String, ValueStore>{};
  final supervisor = ConnectionSupervisor(
    uri: uri,
    config: _config(),
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(seconds: 2),
        random: Random(3)),
    barrier: ReadinessBarrier(),
    watchdog:
        FreshnessWatchdog(config: _config(), onViewFreshnessChanged: (_) {}),
    subscriptions: <String, SubscriptionState>{
      's1': SubscriptionState(subId: 's1', keys: const {_seededKey}),
    },
    storeFor: (id) => stores.putIfAbsent(id, () {
      final store = ValueStore();
      addTearDown(store.dispose);
      return store;
    }),
    dial: dial,
  );
  addTearDown(supervisor.dispose);
  return supervisor;
}

Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// ---------------------------------------------------------------------------
// The structural half. See the library doc for why the superseded door needs
// one.
// ---------------------------------------------------------------------------

/// The file under inspection, found relative to this package rather than to the
/// working directory, so the arm reads the branch it was written against.
File _supervisorSource() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = File('${dir.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}src'
        '${Platform.pathSeparator}connection_supervisor.dart');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('walked from ${Directory.current.absolute.path} to the filesystem '
          'root without finding lib/src/connection_supervisor.dart. Every '
          'assertion below would otherwise pass by reading nothing, which is '
          'the failure the anti-vacuity arm exists to prevent');
    }
    dir = parent;
  }
}

/// Whether [line] is a comment. `no_bad_certificate_test.dart:171-185`'s rule,
/// copied for the same reason: this file's own prose names the guard.
bool _isComment(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('///') || trimmed.startsWith('//');
}

void main() {
  group('a dial abandoned by dispose closes the socket it went on to open', () {
    test('the socket is closed, at both ends', () async {
      final gateway = await _MuteGateway.start();
      final dial = _SuspendedDial();
      final supervisor = _supervisor(gateway.uri, dial.call);

      supervisor.start();
      await dial.entered.future;

      // The panel is going away while the dial is still out. Ten seconds of
      // window in production; here it is exact.
      await supervisor.dispose();
      dial.release.complete();

      await _until('the abandoned dial to answer', () => dial.attempt != null);
      final attempt = dial.attempt!;
      expect(attempt, isA<ConnectSucceeded>(),
          reason: 'the dial has to have succeeded for there to be anything to '
              'leak. A refused dial produces no socket and this arm would be '
              'about nothing');
      expect(gateway.accepted, 1,
          reason: 'anti-vacuity: the far end saw ${gateway.accepted} sockets, '
              'so "the socket was closed" is a statement about a socket that '
              'was never opened');

      final channel = (attempt as ConnectSucceeded).channel;
      final closedHere = await channel.sink.done
          .then((_) => true)
          .catchError((Object _) => true)
          .timeout(_closeBudget, onTimeout: () => false);

      expect(closedHere, isTrue,
          reason: 'the dial completed into a supervisor that had already been '
              'disposed, and nothing closed the socket it had just opened. '
              'Nothing else can reach it: the only sink close in the file is '
              '`_stopServing`\'s `peer.close()`, and the peer is built inside '
              '`_serve`, which this path never enters. Closing the pinned '
              '`HttpClient` does not reap it either — the WebSocket upgrade '
              'detaches the socket from the connection pool — so the gateway '
              'carries a session nobody is on until its own reaper fires');

      await _until('the far end to see the socket go away',
          () => gateway.closed == 1);
      expect(gateway.closed, 1,
          reason: 'the close has to be visible at the end that pays for the '
              'leak. A client-side future that completed without the gateway '
              'seeing anything would be bookkeeping, not a closed socket');
    });
  });

  group('a superseded dial leaks nothing either', () {
    test('the close sits under the whole guard, not under a disposed-only '
        'branch', () {
      final source = _supervisorSource();
      final lines = source.readAsLinesSync();

      expect(lines.length, greaterThan(400),
          reason: 'anti-vacuity: ${source.path} holds only ${lines.length} '
              'lines, which is not the supervisor. A structural arm that read '
              'the wrong file, or an empty one, passes forever');

      final calls = <int>[];
      for (var i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        if (lines[i].contains('_closeAbandonedDial(')) calls.add(i);
      }
      expect(calls, hasLength(2),
          reason: 'expected exactly two non-comment mentions of '
              '`_closeAbandonedDial` — its declaration and its one call site — '
              'and found ${calls.length}. Two call sites would mean the '
              'cleanup has two homes and only one of them is pinned here');

      // The call, not the declaration: the declaration is the later of the two
      // only by convention, so take the one that is indented inside `_attempt`
      // and reads as a statement.
      final callSite = calls.firstWhere(
          (i) => lines[i].contains('await _closeAbandonedDial('),
          orElse: () => fail('no awaited call to `_closeAbandonedDial` was '
              'found. The cleanup exists but nothing on the abandoned-dial '
              'path reaches it'));

      // The nearest enclosing `if` above the call, skipping comments and
      // blank lines. This is what a `_disposed`-only branch would change.
      String? guard;
      for (var i = callSite - 1; i >= 0; i--) {
        final line = lines[i];
        if (_isComment(line) || line.trim().isEmpty) continue;
        if (line.trim().startsWith('if (')) {
          guard = line.trim();
          break;
        }
        fail('the line above the abandoned-dial cleanup is not the guard it '
            'belongs to; it reads "${line.trim()}". This arm can only speak '
            'about a cleanup that sits directly inside its own `if`');
      }

      expect(guard, isNotNull,
          reason: 'no enclosing `if` was found above the cleanup, so nothing '
              'here can say which doors it covers');
      expect(guard, contains('_disposed'),
          reason: 'the guard is "$guard" and does not mention `_disposed`, so '
              'the dispose door — the one that is reachable today and the one '
              'the arm above drives — is not the one this cleanup is under');
      expect(guard, contains('gen != _generation'),
          reason: 'the guard is "$guard". The abandoned-dial cleanup has to '
              'sit under the *whole* condition. A cleanup moved under a '
              '`_disposed`-only branch closes the socket for the door that is '
              'reachable today and leaves the superseded one open — and that '
              'door becomes reachable the first time anything other than '
              '`_attempt` and `dispose` learns to retire a connection');
    });
  });
}
