/// Where the gateway's certificate and private key are mounted — **paths,
/// never bytes**.
///
/// That restriction is the structural half of SEC-01, and it is the whole
/// reason this is a separate class instead of three fields on `ServerConfig`.
/// A config object that *can* hold key material eventually does: someone adds
/// a `List<int> keyBytes` for a container that mounts secrets as environment
/// variables, and from that moment the private key is inside every
/// configuration dump, every `toString`, and every support ticket that pastes
/// one. A config that cannot hold bytes cannot leak them, and
/// `tls_config_test.dart` asserts the field *types* so the property survives
/// the edit rather than only the review.
///
/// The same discipline is already load-bearing on the test side:
/// `test/support/certs.dart` hands back paths and PEM strings and never a
/// `SecurityContext`, so the sweep and the fixtures prove the same thing
/// (06-01-SUMMARY, "what later plans must know" §5).
///
/// **No I/O happens here.** `SecurityContext.useCertificateChain` reads a file,
/// and `server_config.dart`'s library doc pins "Pure data: no I/O, no clock",
/// so the context is built inside `RelayServer.start()` — which is also what
/// makes a misspelled path a loud failure at start rather than a surprise at
/// the first handshake.
///
/// Without this file the gateway has no way to be handed a leaf, and the plant
/// LAN carries every value and every write in cleartext.
library;

/// The three things a gateway needs to present a certificate, and nothing else.
final class TlsConfig {
  /// The PEM holding the gateway's leaf first, then any intermediates — the
  /// file `SecurityContext.useCertificateChain` reads. A private two-tier CA
  /// with no intermediate needs only the leaf.
  final String chainPath;

  /// The PEM holding the leaf's private key. On a plant machine this is the
  /// gateway's identity and `relay_certs` writes it `0600`; nothing in this
  /// process ever copies its contents anywhere else.
  final String keyPath;

  /// The passphrase protecting [keyPath], when there is one.
  ///
  /// Nullable and defaulting to null because the provisioning flow the phase
  /// ships writes unencrypted keys behind file permissions: a passphrase the
  /// gateway must know is a passphrase that lives in a config file next to the
  /// key, which protects nothing and adds a way to fail at start.
  final String? keyPassword;

  TlsConfig({
    required this.chainPath,
    required this.keyPath,
    this.keyPassword,
  }) {
    // Refused here rather than in `ServerConfig`'s block, so no `TlsConfig`
    // can exist in an unmountable state at all — in the style of that block's
    // `_positive`, but deliberately not `_positive` itself, whose message is
    // about ceilings (trap 7: the validators are not interchangeable).
    _mountable('chainPath', chainPath);
    _mountable('keyPath', keyPath);
  }

  /// The paths, and whether there is a passphrase — never the passphrase.
  ///
  /// **Declared rather than omitted.** The SEC-01 guard next door asserts that
  /// every field on this class is a `String`, on the reasoning that a config
  /// holding *bytes* is a config holding key material — and [keyPassword] is a
  /// `String`, so the one field here whose entire purpose is to hold a secret
  /// satisfies the test that exists to keep secrets out of the config. Until
  /// now the leak was prevented only by this class having no `toString()` at
  /// all, which renders `Instance of 'TlsConfig'` and is a property held by
  /// omission: 06-03's sabotage arm 4 shows how quickly a `toString()` appears
  /// once somebody wants a config dump. Writing one that redacts is what turns
  /// the guard from a rule about types into a rule about secrets.
  ///
  /// `none` and `<redacted>` read differently on purpose. A deployment
  /// debugging a start failure needs to know whether the gateway believes the
  /// key is encrypted; that is the useful half, and it is not the secret.
  @override
  String toString() => 'TlsConfig(chainPath: $chainPath, keyPath: $keyPath, '
      'keyPassword: ${keyPassword == null ? 'none' : '<redacted>'})';

  static void _mountable(String name, String value) {
    if (value.isEmpty) {
      throw ArgumentError('$name is empty: an empty path reaches '
          'SecurityContext as the process working directory, so the gateway '
          'fails to start with a message about a directory nobody configured '
          'instead of about the certificate somebody forgot to mount');
    }
  }
}
