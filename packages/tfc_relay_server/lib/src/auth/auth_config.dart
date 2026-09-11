/// Where the gateway's token file is mounted — **a path, never a secret**.
///
/// The same rule `TlsConfig` carries, for the same reason and with the same
/// blast radius if it is broken: a config object that *can* hold the
/// credential set eventually does, and from that moment every configuration
/// dump, every `toString` and every support ticket that pastes one is
/// carrying the keys to the plant. A config that cannot hold secrets cannot
/// leak them.
///
/// Separate from `TlsConfig` rather than three more fields on it, because the
/// two rotate on different clocks — the leaf yearly, the tokens whenever a
/// station is added or a panel is retired — and because they fail in
/// different ways: a bad leaf stops every panel at once, a pulled token stops
/// exactly one.
///
/// **No I/O happens here.** `server_config.dart`'s library doc pins "Pure
/// data: no I/O, no clock", so the file is read inside `RelayServer.start()`,
/// which is also what makes a misspelled path a loud failure at start rather
/// than a gateway that quietly admits everybody.
///
/// Without this file a deployment has no way to say where its credentials
/// live, and the only validator the gateway can be given is the permissive
/// one.
library;

/// The one thing a gateway needs in order to check credentials.
final class AuthConfig {
  /// The JSON file mapping each station's token to its identity, in the shape
  /// `{"tokens": {"<token>": {"stationId": "...", "role": "view"|"operate"}}}`.
  ///
  /// On a plant machine it is mounted `0600` and owned by the gateway's
  /// account; `FileTokenValidator` refuses to load one any other account can
  /// read.
  final String tokenFilePath;

  AuthConfig({required this.tokenFilePath}) {
    // Refused here rather than in `ServerConfig`'s block, so no `AuthConfig`
    // can exist in an unmountable state at all — `tls_config.dart:54-60`'s
    // argument, and deliberately not `ServerConfig._positive`, whose message
    // is about ceilings (trap 7: the validators are not interchangeable).
    if (tokenFilePath.isEmpty) {
      throw ArgumentError('tokenFilePath is empty: an empty path reaches '
          'dart:io as the process working directory, so the gateway fails to '
          'start with a message about a directory nobody configured instead '
          'of about the token file somebody forgot to mount');
    }
  }
}
