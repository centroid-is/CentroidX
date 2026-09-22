import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

class OtherSecureStorage implements MySecureStorage {
  /// The macOS keychain options, exposed so a test can pin what reaches the
  /// platform — see `test/core/secure_storage_options_test.dart`.
  ///
  /// usesDataProtectionKeychain MUST stay false on macOS: the
  /// data-protection keychain (kSecUseDataProtectionKeychain) requires
  /// provisioned code signing (a real Apple Development identity with an
  /// application-identifier), and every keychain call fails with
  /// errSecMissingEntitlement (-34018) on ad-hoc/unprovisioned builds —
  /// which is what dev-machine and release builds are. The file-based
  /// login keychain works without provisioning (this is also why the
  /// amplify storage sets useDataProtection: false). Windows ignores
  /// mOptions entirely, so this is macOS-only in effect.
  @visibleForTesting
  static final MacOsOptions macOsOptions = MacOsOptions(
    accountName: 'CentroidX',
    // flutter_secure_storage 10 renamed this from
    // `useDataProtectionKeyChain` AND flipped its default to true, so it
    // must be spelled out: left to the default, every Mac build would move
    // to the data-protection keychain and fail with -34018. Keychain items
    // are still addressed exactly as 9.x addressed them — `accountName` is
    // the service, the key is the account, accessibility defaults to
    // `unlocked` — so items written by the old plugin stay readable.
    usesDataProtectionKeychain: false,
  );

  final _storage = FlutterSecureStorage(mOptions: macOsOptions);

  @override
  Future<void> write({required String key, required String value}) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) async {
    await _storage.delete(key: key);
  }

  @override
  Future<String?> read({required String key}) async {
    return await _storage.read(key: key);
  }
}
