import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../client_config.dart';
import 'trust_capability.dart';
import '../ws_transport.dart';

/// A dialler that trusts the plant's private CA and nothing else.
///
/// **Owns the panel's one `HttpClient`.** Not one per attempt: a
/// `SecurityContext` parses the root PEM when it is built and an `HttpClient`
/// owns a connection pool, so a panel on a flapping link that built one per
/// dial would re-read the certificate and leak a pool per attempt — on the one
/// code path that only runs when something is already wrong.
final class PinnedDialer {
  PinnedDialer(ClientTlsConfig? tls, {Duration? connectionTimeout}) {
    if (tls == null) return;
    // With `withTrustedRoots: false` the machine's own store is never
    // consulted, so a rogue root installed on the station cannot vouch for
    // anything claiming to be the gateway — which is also why our own gateway
    // is refused by a client that skips this.
    //
    // The root arrives one of two ways — a mounted file, or the PEM text the
    // trust-acquisition flow pinned after the operator approved its
    // fingerprint — and both land on the same context: the pin does not know
    // or care how it was provisioned.
    final context = SecurityContext(withTrustedRoots: false);
    final pem = tls.rootCertPem;
    if (pem != null) {
      context.setTrustedCertificatesBytes(utf8.encode(pem));
    } else {
      context.setTrustedCertificates(tls.rootCertPath!);
    }
    _pinned = HttpClient(context: context)
      // The second bound under the abandoned dial.
      // `IOWebSocketChannel.connect` applies `connectTimeout` as a
      // `Future.timeout`, which abandons the connect rather than cancelling
      // it, leaving roughly three descriptors per attempt that nothing
      // reclaims. The backoff does not bound that — at the 30 s cap a panel
      // pointed at a gateway that swallows handshakes accumulates for the
      // whole fault — and `HttpClient.connectionTimeout` *cancels*.
      ..connectionTimeout = connectionTimeout;
  }

  HttpClient? _pinned;

  /// Whether this platform can pin a root at all. See [kCanPinTrustRoot].
  static const bool pins = kCanPinTrustRoot;

  Future<ConnectAttempt> dial(
    Uri uri, {
    Iterable<String>? protocols,
    Duration? connectTimeout,
  }) async {
    final ws = IOWebSocketChannel.connect(
      uri,
      protocols: protocols,
      customClient: _pinned,
      connectTimeout: connectTimeout,
    );
    return awaitReady(
      ws,
      certificateUntrusted: _certificateWasRefused,
    );
  }

  void close() {
    _pinned?.close(force: true);
    _pinned = null;
  }
}

/// Whether [error] is this panel refusing the gateway's certificate.
///
/// One level of unwrapping, because that is where the exception is:
/// `web_socket_channel` hands the failure over as a `WebSocketChannelException`
/// with the real one in `.inner`.
///
/// The type and nothing finer. *Which* certificate problem it was is
/// deliberately not read here — `ConnectionSupervisor._refusalReason` owns
/// that argument: openssl volunteers a reason on Linux and Windows and says
/// nothing on macOS, so a panel that named the fault would be silent on the
/// desktops and confident on the eLinux screens for the same broken leaf.
bool _certificateWasRefused(Object error) =>
    error is WebSocketChannelException && error.inner is HandshakeException;

/// One pinned dial, as a free function.
///
/// The shape the io-only tests already drive — `tls_client_test.dart`,
/// `tls_fault_test.dart` and `ws_transport_test.dart` build their own
/// `HttpClient` and hand it in. Production goes through [PinnedDialer], which
/// owns the client's lifetime; this exists so a test can dial with one it
/// controls without that ownership.
Future<ConnectAttempt> connect(
  Uri uri, {
  Iterable<String>? protocols,
  HttpClient? client,
  Duration? connectTimeout,
}) async {
  final ws = IOWebSocketChannel.connect(
    uri,
    protocols: protocols,
    customClient: client,
    connectTimeout: connectTimeout,
  );
  return awaitReady(ws, certificateUntrusted: _certificateWasRefused);
}
