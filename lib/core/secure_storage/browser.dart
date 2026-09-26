import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

/// The browser's keychain: none, on purpose.
///
/// The gateway keeps the secrets (`docs/web-client-scope.md`). The wire has no
/// `secret:` parameter, `state_man_config` reaches a gateway client redacted,
/// and a browser is never handed a plant credential. What still crosses the
/// secret path on a web boot is exactly one thing: the default
/// `state_man_config` that `stateManProvider` writes for a client that has
/// never been configured — a gateway client carries that document and never
/// dials with it. Holding it in memory is honest; persisting it would be a
/// "secure" store on a laptop that guards nothing, and the hook the next
/// secret would quietly hang off.
///
/// **Why an instance has to be set at all.** `SecureStorage.getInstance()`
/// answers a platform default when nothing was set, and that default asks
/// `dart:io`'s `Platform` — which a browser cannot answer, so the first
/// preference store built on the boot path threw and the panel came up blank.
///
/// **Why not `flutter_secure_storage`'s web arm.** It encrypts through
/// `crypto.subtle`, which a browser exposes only on a secure context. A page
/// opened over plain `http://` on a LAN address — a bench, or a laptop pointed
/// at a station — would throw out of the first secret read, which is the same
/// blank screen this class exists to end, arriving from a different direction.
class BrowserSecureStorage implements MySecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}
