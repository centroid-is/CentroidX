/// Stored preferences, as the wire may see them.
///
/// This mirrors the *interface* `PreferencesApi`
/// (`packages/tfc_dart/lib/core/preferences.dart:14-85`) and never the
/// concrete `Preferences` class that implements it. The distinction is the
/// whole point of the file.
///
/// The concrete class adds a `{bool secret = false}` named parameter to its
/// getters, setters and `remove` (`preferences.dart:221,231,241,251,260,270,
/// 281,298,315,332,349,365`), which routes the call to secure storage instead
/// of the preferences database. That parameter is deliberately absent from
/// every member below: secret material must never traverse the pipe (SEC-01 —
/// keys are mounted files, not preference rows), and a mirrored `secret: true`
/// flag would turn one client-supplied boolean into remote retrieval of the
/// secure store. Absence is not enough on its own, because the obvious future
/// edit is to "helpfully" add it back, so
/// `packages/tfc_stateman_contract/test/api_surface_test.dart` asserts that no
/// member of this interface — or of any interface on the wire surface —
/// declares a parameter with that name.
///
/// One member is added rather than mirrored:
/// [PreferencesApi.onPreferencesChanged] exists today only on the concrete
/// class (`preferences.dart:382`). It is DB-03's change notification, and
/// without it a second client's edit is invisible until the page is
/// reopened — over a pipe with several clients on the same site, that is a
/// stale-settings bug, not a refresh nicety.
library;

/// Preferences as the pipe exposes them: read, write, enumerate, observe.
///
/// Every method is asynchronous because a remote implementation has a round
/// trip to make. The typed getters resolve to null when the key is absent,
/// and throw a `TypeError` when the stored value is of another type — the
/// behavior of the interface being mirrored, kept so ported call sites read
/// the same.
abstract interface class PreferencesApi {
  /// Returns all keys that match the provided parameters.
  ///
  /// If no [allowList] is provided, fetches all keys stored on the platform.
  ///
  /// Ignores any keys whose values are of types the preference store cannot
  /// represent.
  Future<Set<String>> getKeys({Set<String>? allowList});

  /// Returns all keys and values that match the provided parameters.
  ///
  /// If no [allowList] is provided, fetches all entries stored on the
  /// platform. Ignores any entries of incompatible types.
  Future<Map<String, Object?>> getAll({Set<String>? allowList});

  /// Reads a value, throwing a `TypeError` if the value is not a bool.
  Future<bool?> getBool(String key);

  /// Reads a value, throwing a `TypeError` if the value is not an int.
  Future<int?> getInt(String key);

  /// Reads a value, throwing a `TypeError` if the value is not a double.
  Future<double?> getDouble(String key);

  /// Reads a value, throwing a `TypeError` if the value is not a String.
  Future<String?> getString(String key);

  /// Reads a list of string values, throwing a `TypeError` if the value is
  /// not a `List<String>`.
  Future<List<String>?> getStringList(String key);

  /// Whether the store contains the given [key].
  Future<bool> containsKey(String key);

  /// Saves a boolean [value].
  Future<void> setBool(String key, bool value);

  /// Saves an integer [value].
  Future<void> setInt(String key, int value);

  /// Saves a double [value].
  ///
  /// On platforms that cannot store doubles, the value is stored as a float.
  Future<void> setDouble(String key, double value);

  /// Saves a string [value].
  Future<void> setString(String key, String value);

  /// Saves a list of strings [value].
  Future<void> setStringList(String key, List<String> value);

  /// Removes an entry.
  Future<void> remove(String key);

  /// Clears preferences.
  ///
  /// If no [allowList] is provided, and the store has no filter of its own,
  /// all preferences are removed — including values this application never
  /// set. It is highly recommended that an [allowList] be provided.
  Future<void> clear({Set<String>? allowList});

  /// Emits the name of each key whose value changed, including changes made
  /// by another client on the same site.
  ///
  /// DB-03: a settings page listens to this instead of re-reading on a timer,
  /// which is also what keeps two operators editing the same site from
  /// overwriting each other with stale form state.
  Stream<String> get onPreferencesChanged;
}
