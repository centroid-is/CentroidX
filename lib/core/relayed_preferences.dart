/// The shared configuration store, served by the gateway over the socket.
///
/// **Why this exists.** A panel has two stores and the difference matters:
/// `localPreferencesProvider` holds what is true of *this machine* — the
/// gateway address, the startup page, the database IP — and must never sync,
/// because stations disagree about all three. `preferencesProvider` holds what
/// is true of *the plant* — key mappings, alarm rules, page layouts — and every
/// station must see the same thing.
///
/// The second one used to mean "this station's Postgres connection". In
/// gateway mode that is the wrong answer twice over: it is a second thing for
/// the panel to be able to reach when the whole point of the transport is that
/// there is one, and it is a thing a browser does not have at all.
///
/// So in gateway mode the shared store is the gateway's, read and written over
/// the same socket the values come down. The two `PreferencesApi`s — this
/// app's and the protocol's — are member-for-member identical, which is not a
/// coincidence: the protocol's was written to mirror it. This class is the
/// twenty lines of delegation between them.
///
/// **Nothing is guarded here, on purpose.** `GuardedPreferences` puts a check
/// and an audit row in front of every write on a direct station because that
/// station is talking to its own database and nothing else would. Over the
/// relay the gateway does it — `PolicyStateMan` refuses on the far side and
/// writes the audit row against the station's verified account — and a second
/// check on this side would be a client asking itself for permission, which is
/// the posture the milestone exists to replace.
library;

import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// This app's [PreferencesApi], backed by the gateway's.
final class RelayedPreferences implements PreferencesApi {
  const RelayedPreferences(this._api);

  final rp.PreferencesApi _api;

  /// Every change the gateway announced, so a settings page and a chart legend
  /// hear the same edit. Not on [PreferencesApi] — the app reads it through
  /// `preferenceChangesProvider`, which is the one place that knows which
  /// transport is in force.
  Stream<String> get onPreferencesChanged => _api.onPreferencesChanged;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _api.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _api.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _api.getBool(key);

  @override
  Future<int?> getInt(String key) => _api.getInt(key);

  @override
  Future<double?> getDouble(String key) => _api.getDouble(key);

  @override
  Future<String?> getString(String key) => _api.getString(key);

  @override
  Future<List<String>?> getStringList(String key) => _api.getStringList(key);

  @override
  Future<bool> containsKey(String key) => _api.containsKey(key);

  @override
  Future<void> setBool(String key, bool value) => _api.setBool(key, value);

  @override
  Future<void> setInt(String key, int value) => _api.setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _api.setDouble(key, value);

  @override
  Future<void> setString(String key, String value) =>
      _api.setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _api.setStringList(key, value);

  @override
  Future<void> remove(String key) => _api.remove(key);

  @override
  Future<void> clear({Set<String>? allowList}) =>
      _api.clear(allowList: allowList);
}
