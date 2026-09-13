import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../client_config.dart';
import 'trust_capability.dart';
import '../ws_transport.dart';

/// The browser's dial. It opens a real socket; what it cannot do is pin.
///
/// **There is no browser API to add a trust root, to pin one, or to inspect
/// the peer certificate.** A page gets the machine's trust store and nothing
/// else. So the plant's private CA has to be trusted by the browser — either
/// because the gateway carries a publicly-trusted certificate, or because the
/// root was provisioned into the OS/browser store — and this class refuses to
/// pretend otherwise: a `ClientTlsConfig` handed to it is a refusal, not a
/// silently ignored field. A configuration that *reads* as pinned while
/// nothing pins is worse than one that says it cannot.
///
/// **`wss` only.** Plaintext is refused here rather than left to the browser's
/// mixed-content rules, because those depend on how the page was served: an
/// `https://` page already refuses `ws://`, but a page opened over `http://`
/// would happily put a station credential and every plant write on the wire in
/// the clear. `ClientConfig.checkDialable` carries the same rule, and this is
/// the backstop for a dial that reached here another way.
///
/// **The dial IS bounded, and by this class rather than by the browser.** The
/// WebSocket API has no connect timeout and exposes no hook for one, which is
/// where the claim that nothing could be done came from — but that is a fact
/// about the browser API, not about the Dart code above it. `awaitReady` races
/// `ws.ready` against the deadline and closes the socket when the deadline
/// wins, and closing during CONNECTING is exactly what cancels an attempt. It
/// matters here more than anywhere: the supervisor's backoff cannot bound a
/// single attempt, and an unbounded one against a black-holed gateway parks
/// this client on the operating system's TCP timeout — about 75 s — while the
/// schedule the operator can see says 30.
///
/// **A failed handshake is opaque, and that is a browser limit.** A refused
/// certificate fires a bare `error` event and closes with 1006 and an empty
/// reason — indistinguishable from a gateway that did not answer. So
/// [ConnectFailed.certificateUntrusted] is always false here, and the health
/// line says less on web than it does on a panel. Reporting "certificate
/// untrusted" on a guess would send an engineer to the wrong end of the wire.
final class PinnedDialer {
  PinnedDialer(ClientTlsConfig? tls, {Duration? connectionTimeout})
      : _connectionTimeout = connectionTimeout,
        _refusal = tls == null
            ? null
            : 'a root certificate was configured for a browser client, and a '
                'browser cannot use one: there is no API to add a trust root, '
                'to pin, or to read the peer certificate. Trust the gateway in '
                'the machine\'s own store instead, and clear this field so the '
                'configuration stops claiming a pin that does not exist';

  /// Set when the configuration cannot be honoured here, so every dial fails
  /// the same way with the same sentence instead of connecting unpinned.
  final String? _refusal;

  /// The dial bound this dialer was built with, used when [dial] is given
  /// none of its own.
  ///
  /// Kept rather than dropped for the reason this whole class exists: it was
  /// accepted and ignored, which is the "reads as honoured while nothing
  /// honours it" fault the header argues against one field over, at the trust
  /// root. io has the same two levels — the `HttpClient` bound still applies
  /// when the dial parameter is null — so this mirrors it.
  final Duration? _connectionTimeout;

  /// Whether this platform can pin a root at all. See [kCanPinTrustRoot].
  static const bool pins = kCanPinTrustRoot;

  Future<ConnectAttempt> dial(
    Uri uri, {
    Iterable<String>? protocols,
    Duration? connectTimeout,
  }) async {
    final refusal = _refusal;
    if (refusal != null) {
      return ConnectFailed.refused(uri, refusal);
    }
    if (uri.scheme != 'wss') {
      return ConnectFailed.refused(
          uri,
          'a browser client dials wss:// only, and this is "${uri.scheme}". '
          'Plaintext would put the station credential and every write on the '
          'wire in the clear, and whether the browser stops it depends on how '
          'the page was served rather than on anything configured here');
    }
    // Per-dial bound first, then the one this dialer was built with. Both were
    // accepted and ignored before; either being present is a caller asking for
    // a bound, and null on both is "the platform decides", which on a browser
    // means the OS TCP timeout. `ClientConfig.connectTimeout` is non-nullable
    // and defaults to 10 s, so a production panel always arrives here with a
    // value — null is the hand-built-harness case.
    final ws = WebSocketChannel.connect(uri, protocols: protocols);
    return awaitReady(
      ws,
      certificateUntrusted: _opaque,
      timeout: connectTimeout ?? _connectionTimeout,
    );
  }

  void close() {}
}

/// A browser cannot tell a refused certificate from an absent gateway, so this
/// never claims it can. See the class doc.
bool _opaque(Object error) => false;
