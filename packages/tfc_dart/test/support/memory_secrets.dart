/// An in-memory [MySecureStorage], and the one call that keeps a test off the
/// platform keychain.
///
/// **Why this exists as a shared file.** `SecureStorage.getInstance` falls back
/// to `AwsSecureStorage()` on Linux and macOS and *throws* on every other
/// platform (`secure_storage.dart:41-49`). Anything that reaches
/// `Preferences.create` without an instance set therefore passes on two of the
/// three CI platforms and fails on the third with `SecureStorage instance not
/// set for this platform` — a message that reads like a production defect and
/// is not one: the app sets its instance in `centroid-hmi/lib/main.dart:249`.
///
/// It stayed invisible for as long as the Windows lane was dying earlier, at
/// `pub get`. The first run that got past that reported eighteen failures
/// across seven files, every one of them this.
///
/// The fallback is also a reason to set it deliberately rather than to rely on
/// the default: `AwsSecureStorage` is a real client for a real service, and a
/// test that gets it by accident on macOS is one network hiccup from being
/// flaky for reasons that have nothing to do with what it asserts.
library;

import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

/// A [MySecureStorage] backed by a map. No keychain, no network, no files.
class MemorySecrets implements MySecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}

/// Installs a fresh [MemorySecrets] as the process-wide instance.
///
/// Call from `main()` before any case runs, or from `setUp` when a case needs
/// the store empty again. Returns the instance so a case that wants to inspect
/// what was written can hold on to it.
MemorySecrets useMemorySecrets() {
  final secrets = MemorySecrets();
  SecureStorage.setInstance(secrets);
  return secrets;
}
