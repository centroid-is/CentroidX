/// The second harness: the same client, over a real socket, through the proxy.
///
/// `channel_harness.dart` serves a `FakeStateMan` over a
/// `StreamChannelController`. This file serves the same fake over a loopback
/// TCP connection that runs through a [FaultProxy], and hands back the same
/// client type the channel harness hands back. There is no socket-specific
/// implementation anywhere below, and that absence is the point: the roadmap's
/// third criterion is that the same protocol assertions pass in both
/// harnesses, which is only a claim about the shipping client if one client is
/// judged through two transports.
///
/// **Why it belongs behind `faults.dart` and not `channel_harness.dart`.**
/// Everything here reaches for `dart:io` sockets. `faults.dart` argues at
/// length that an implementation importing the contract to be judged by it
/// must not thereby acquire the ability to bind ports; this is the harness
/// that binds them.
///
/// **Why the factory is synchronous when the wiring is not.** Every sub-suite
/// runner takes a `StateManApi Function()` and calls it inside the case, so a
/// factory returning a future would force all seven runners to be rewritten.
/// Binding a server socket, starting a proxy and connecting a client are all
/// asynchronous, so the two cannot be reconciled by waiting — they are
/// reconciled by buffering. [StreamChannelCompleter] hands the client a
/// channel immediately and holds everything written to it until the socket is
/// up, and every contract case awaits through `within()`, so a few
/// milliseconds of buffering is invisible to a case and visible to nothing
/// else. The parity sweep is what confirms that claim rather than asserting it
/// here.
///
/// **Teardown cascades from `dispose`.** A driver registers `api.dispose` and
/// nothing else, exactly as it does for the channel harness, so disposing the
/// returned client shuts the served peers, the proxy, the listening socket and
/// both ends of the connection, and disposes the fake. `socket_contract_test`
/// holds that to a delta of zero descriptors over twenty cycles.
library;

import 'dart:async';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../../testing/fake_data_services.dart';
import '../../testing/fake_state_man.dart';
import '../channel/channel_state_man.dart';
import '../channel/served_state_man.dart';
import 'fault_proxy.dart';
import 'line_channel.dart';

/// How long the served end is given to arrive after the client has connected.
///
/// Loopback, so this is a fraction of a millisecond in practice. The budget
/// exists to turn a proxy that accepted but never dialled upstream into a
/// named failure on the client's channel rather than a harness that never
/// becomes ready.
const _acceptBudget = Duration(seconds: 5);

/// Every end of one socket-served source, for a test that needs to reach past
/// the client — to pull a proxy lever, or to drive the served fake directly.
///
/// Ordinary drivers want [socketServedFake] and never see this.
final class SocketServedFake {
  SocketServedFake._(this.served, this._wiring, this.api, this.ready);

  /// The reference implementation, on the far side of the socket. Real, and
  /// driveable directly — which is what lets a bite-proof apply a fault the
  /// client cannot see the result of.
  final FakeStateMan served;

  final _SocketWiring _wiring;

  /// The implementation under test, on this side. The same type the channel
  /// harness returns, constructed the same way.
  final ChannelStateMan api;

  /// Completes when the listening socket is bound, the proxy is started and
  /// the client is connected — or when that sequence failed, in which case the
  /// failure has been delivered to the client's channel instead of thrown
  /// here, so it surfaces as a named contract failure rather than as an
  /// unhandled async error attributed to an unrelated test.
  ///
  /// Contract cases do not await it. A test that pulls a proxy lever must.
  final Future<void> ready;

  /// The proxy the client's traffic runs through, and the seam faults are
  /// injected at.
  ///
  /// Throws [StateError] before [ready] has completed, because the proxy is
  /// built against a port that does not exist until the server socket is
  /// bound. A test that forgot to await [ready] should be told that rather
  /// than shown a null-check failure in this file.
  FaultProxy get proxy {
    final proxy = _wiring.proxy;
    if (proxy == null) {
      throw StateError('the harness has no proxy until `ready` has completed; '
          'await it before pulling a lever');
    }
    return proxy;
  }
}

/// A `FakeStateMan` served over a loopback socket, behind a fault proxy.
///
/// Disposing [SocketServedFake.api] releases everything.
SocketServedFake serveFakeOverSocket({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
}) {
  final served = FakeStateMan(
    staleAfter: staleAfter,
    readOnlyKeys: readOnlyKeys,
    writeLatency: writeLatency,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );

  final completer = StreamChannelCompleter<String>();
  final wiring = _SocketWiring(served);
  final ready = wiring.connect(completer);

  final api = ChannelStateMan(
    channel: completer.channel,
    observables: served,
    closeServed: () => wiring.teardown(ready),
  );

  return SocketServedFake._(served, wiring, api, ready);
}

/// The driver-facing factory: one socket-served `StateManApi`, per case.
///
/// ```dart
/// void main() => runSubscribeContract(socketServedFake);
/// ```
///
/// The same shape and the same defaults as `channelServedFake`, because the
/// parity sweep runs one registry through both and a difference in defaults
/// would show up there as a difference between transports.
StateManApi socketServedFake({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
}) =>
    serveFakeOverSocket(
      staleAfter: staleAfter,
      readOnlyKeys: readOnlyKeys,
      writeLatency: writeLatency,
      browse: browse,
      timeseries: timeseries,
      historyViews: historyViews,
      preferences: preferences,
    ).api;

/// The descriptors one harness owns, and the order they have to be released
/// in.
final class _SocketWiring {
  _SocketWiring(this.served);

  final FakeStateMan served;

  /// The proxy in front of the served socket, once it has been built.
  FaultProxy? proxy;

  ServerSocket? _server;
  StreamSubscription<Socket>? _accepts;
  Socket? _client;
  final List<Socket> _accepted = <Socket>[];
  final List<ServedStateMan> _sessions = <ServedStateMan>[];
  bool _torn = false;

  /// Binds, serves, proxies and connects — then hands the client its channel.
  ///
  /// Never throws. A failure anywhere in the sequence is delivered to the
  /// channel instead, so the client's `Peer` sees a broken transport and every
  /// contract case fails on its own deadline naming its own property. Throwing
  /// out of here would surface as an unhandled error in whichever test the
  /// runner happened to be executing, which is the failure mode the whole
  /// phase is written against.
  ///
  /// Deliberately without early exits on teardown: a half-built harness is
  /// harder to release than a fully built one, so the sequence always runs to
  /// completion and [teardown] waits for it before closing anything. The cost
  /// is a few milliseconds on a harness that is disposed immediately; the
  /// alternative is a client whose channel is never set, whose `Peer.close()`
  /// therefore never completes, and whose `dispose` hangs.
  Future<void> connect(StreamChannelCompleter<String> completer) async {
    try {
      final bound = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = bound;

      // The served end arrives on its own schedule: the client's connect
      // completes when the *proxy* accepts, and the proxy only then opens the
      // upstream connection this listener answers. Without waiting for it,
      // `ready` can complete — and a case that disposes immediately can tear
      // the harness down — before the served socket and its peer exist, which
      // leaves them orphaned behind a proxy that is already gone: a descriptor
      // nothing closes and a peer writing into a socket whose far end was
      // destroyed. Waiting here is what makes the set of things `teardown`
      // has to release a closed one.
      final accepted = Completer<void>();
      _accepts = bound.listen((socket) {
        _accepted.add(socket);
        _sessions.add(serveStateMan(served, lineChannel(socket)));
        if (!accepted.isCompleted) accepted.complete();
      });

      final started = FaultProxy(targetPort: bound.port);
      proxy = started;
      await started.start();

      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        started.port,
      );
      _client = client;
      await accepted.future.timeout(_acceptBudget);
      completer.setChannel(lineChannel(client));
    } catch (error, stack) {
      completer.setError(error, stack);
    }
  }

  /// Releases every descriptor this harness opened, innermost first.
  ///
  /// Order matters. The served peers go first so their sockets are closed by
  /// the code that owns them; the proxy next, because shutting it down
  /// destroys both halves of every pair it is carrying; then the listener,
  /// which nothing can arrive on afterwards; then whatever sockets are left,
  /// destroyed rather than closed because by this point there is no peer to
  /// exchange a FIN with. The fake is disposed last, so its freshness watchdog
  /// outlives anything still draining.
  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;

    await ready;

    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();

    await proxy?.shutdown();

    await _accepts?.cancel();
    await _server?.close();

    for (final socket in _accepted) {
      socket.destroy();
    }
    _accepted.clear();
    _client?.destroy();

    await served.dispose();
  }
}
