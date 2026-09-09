import 'dart:io';

import 'interface.dart';
import 'linux.dart';

export 'interface.dart';

class SecureStorage {
  static MySecureStorage? _instance;
  static int _generation = 0;

  /// Which backing store the secrets currently in memory came from.
  ///
  /// Swapping the instance invalidates everything cached from the old one.
  /// Production sets the instance once at startup (a no-op); tests swap in a
  /// fresh fake per test and must not see a previous test's secrets served
  /// from the process-wide caches.
  ///
  /// This used to be an eager push: [setInstance] called
  /// `Preferences.clearSecretCache()` and `DatabaseConfig.clearPrefsCache()`
  /// directly. That made the *store* import its own callers — and through
  /// `preferences.dart` it dragged the drift-backed preferences store, and so
  /// `dart:ffi`, into the import closure of anything that merely wanted to read
  /// a password. A Server Config page in a browser could not compile because of
  /// these two lines. See `core/database_config.dart`.
  ///
  /// So the pull replaces the push: a cache records the generation it was
  /// filled under and treats a mismatch as a miss. Nothing is dropped eagerly,
  /// which is why this is a counter and not a registration list — a list would
  /// only invalidate caches that had already registered, so whether a stale
  /// secret survived would depend on which libraries had been touched first.
  /// A counter has no such hole: a cache that never registered also never
  /// existed, and one that exists always sees the bump.
  static int get generation => _generation;

  static void setInstance(MySecureStorage instance) {
    _instance = instance;
    _generation++;
  }

  static MySecureStorage getInstance() {
    if (_instance != null) {
      return _instance!;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      return AwsSecureStorage();
    }
    throw Exception('SecureStorage instance not set for this platform');
  }
}
