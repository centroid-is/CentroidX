/// The configuration write guard: a [Preferences] that checks and records the
/// seven write members and leaves every read alone.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';

import '../database.dart';
import '../preferences.dart';
import '../secure_storage/interface.dart';

/// The `who` of a row written with nobody signed in.
const String _anonymousWho = 'anonymous';

/// The `itemKey` of a `clear()` row. There is no key to name, and the whole
/// store is what was affected.
const String _wholeStoreItemKey = '*';

/// A hand-made write. Spec §2's default.
const String _operatorOrigin = 'operator';

/// A write the app made for itself, with nobody signed in.
const String _systemOrigin = 'system';

/// A [Preferences] that gates every write on the current session and writes one
/// audit row per write, denials included, and forwards every read untouched.
///
/// ## Why it wraps `Preferences` and not `PreferencesApi`
///
/// Spec §6 names `PreferencesApi`, but `preferencesProvider` returns a
/// `Preferences` and callers use members `PreferencesApi` does not have:
/// `setString(key, value, secret: true)` at `chat_widget.dart:361`,
/// `StateManConfig.toPrefs` writing with `secret: true, saveToDb: false`,
/// `onPreferencesChanged` driving the key-mappings watcher at
/// `state_man.dart:52`, and `isKeyInDatabase` in the preferences editor. A
/// decorator typed to the narrower interface would force every one of those
/// callers to change, which is exactly what "callers change nothing" forbids.
/// `Preferences` is a superset of `PreferencesApi`, so the spec's stated
/// contract holds too — `guarded_preferences_test.dart` asserts it.
///
/// ## Why reads are not gated
///
/// Spec §11 defers read permissions. A guarded read would break a station with
/// no session, which is every station at boot. Reads produce no audit row and
/// cannot be denied, for any key, at any session.
///
/// ## Why this surface fails closed
///
/// [AccessPolicy.groupForPref] is non-nullable and answers
/// [AccessGroup.administer] for anything it does not recognise. That is the
/// opposite of the tag surface, and the asymmetry is deliberate: a wrongly-open
/// setpoint is a nuisance, a wrongly-open config write is a broken plant
/// (spec §7).
///
/// ## The `database` escape, stated rather than hidden
///
/// `implements Preferences` obliges this class to expose a [database] getter,
/// so anything holding a `GuardedPreferences` can reach `prefs.database!.db`
/// and issue raw Drift that no guard sees. That is a real hole and it is not
/// closed here — see the getter. Section 3 of plan 03-03's write-path sweep is
/// what finds such a call site the first time it appears.
class GuardedPreferences implements Preferences {
  /// [session] is a callback rather than a value on purpose: a captured session
  /// would keep granting whatever was held when the provider was built, long
  /// after a logout or an inactivity timeout.
  ///
  /// [surface] is one string used for **both** the policy lookup and the
  /// `surface` column of every row this guard writes, so the group that was
  /// checked and the surface that was recorded cannot disagree. A surface the
  /// policy does not know answers [AccessGroup.administer], so a typo is a
  /// denial waiting to be noticed rather than a hole nobody sees.
  GuardedPreferences({
    required Preferences inner,
    required AccessPolicy policy,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    String surface = 'pref',
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _inner = inner,
        _policy = policy,
        _session = session,
        _audit = audit,
        _station = station,
        _surface = surface,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final Preferences _inner;
  final AccessPolicy _policy;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final String _surface;
  final void Function(AccessDenied denial)? _onDenied;
  final Logger _logger;

  // ---------------------------------------------------------------------------
  // The rule, in one place.
  // ---------------------------------------------------------------------------

  /// The group [key] requires on this guard's surface.
  ///
  /// [AccessPolicy.groupForWireSurface] answers a group for every surface
  /// since the 2026-09-02 operate-floor ruling — the nullable tag arm this
  /// method used to defend against with an `?? administer` is gone from the
  /// signature itself.
  AccessGroup _groupFor(String key) =>
      _policy.groupForWireSurface(_surface, key);

  /// The old-value reader for a write, or null when there must not be one.
  ///
  /// **A secret's old value is never read.** Reading it is the single edit that
  /// would copy a credential into a permanent, replicated table, and it would
  /// look like completeness while doing it.
  Future<String?> Function()? _oldValueOf(
          bool secret, Future<String?> Function() read) =>
      secret ? null : read;

  /// Check, record, then delegate — the one implementation of the rule, with
  /// seven thin members on top of it.
  ///
  /// On the deny path the row is written **before** the throw: a denial that
  /// leaves no row is the repudiation the trail exists to prevent. On the
  /// permitted path the row is written before the delegate, per spec §6 and to
  /// match `GuardedStateMan`.
  Future<void> _guard({
    required String key,
    required AccessGroup group,
    required String? newValue,
    required Future<String?> Function()? readOldValue,
    required Future<void> Function() write,
  }) async {
    final actionId = newActionId();
    final session = _session();

    if (!session.can(group)) {
      final denial = AccessDenied(key, group);
      await _record(_row(
        session: session,
        key: key,
        group: group,
        oldValue: null,
        newValue: newValue,
        allowed: false,
        actionId: actionId,
      ));
      _onDenied?.call(denial);
      throw denial;
    }

    await _commit(
      session: session,
      key: key,
      group: group,
      newValue: newValue,
      readOldValue: readOldValue,
      write: write,
      actionId: actionId,
      origin: _operatorOrigin,
    );
  }

  /// Read the old value, write the row, then delegate.
  ///
  /// Shared by the checked path and by [systemWrites], so the row a boot-time
  /// default produces is built by the same code as any other — the only
  /// difference is [origin], and the check that did not happen.
  Future<void> _commit({
    required AccessSession session,
    required String key,
    required AccessGroup group,
    required String? newValue,
    required Future<String?> Function()? readOldValue,
    required Future<void> Function() write,
    required String actionId,
    required String origin,
  }) async {
    String? oldValue;
    if (readOldValue != null) {
      try {
        oldValue = await readOldValue();
      } on Object catch (error) {
        // A store that cannot be read must not fail a write the session was
        // allowed to make. The row simply says nothing about what was there.
        _logger.w('audit old value unreadable for $_surface:$key: $error');
        oldValue = null;
      }
    }

    await _record(_row(
      session: session,
      key: key,
      group: group,
      oldValue: oldValue,
      newValue: newValue,
      allowed: true,
      actionId: actionId,
      origin: origin,
    ));
    await write();
  }

  /// The unchecked write [systemWrites] performs: no session check, one row,
  /// [_systemOrigin].
  ///
  /// [group] is still resolved and still recorded, so the trail shows what
  /// authority was skipped rather than showing none. `who` and `roleName` are
  /// whoever was standing at the panel — usually nobody, at boot — because
  /// that is the honest answer to "who was there when the machine did this".
  Future<void> _uncheckedWrite({
    required String key,
    required AccessGroup group,
    required String? newValue,
    required Future<String?> Function()? readOldValue,
    required Future<void> Function() write,
  }) =>
      _commit(
        session: _session(),
        key: key,
        group: group,
        newValue: newValue,
        readOldValue: readOldValue,
        write: write,
        actionId: newActionId(),
        origin: _systemOrigin,
      );

  AuditRecord _row({
    required AccessSession session,
    required String key,
    required AccessGroup group,
    required String? oldValue,
    required String? newValue,
    required bool allowed,
    required String actionId,
    String origin = _operatorOrigin,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleLabel,
        surface: _surface,
        itemKey: key,
        oldValue: oldValue,
        newValue: newValue,
        groupRequired: group.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
      );

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// `DriftAuditSink` already swallows its own failures, so this is
  /// belt-and-braces there — but [AuditSink] is an interface whose non-throwing
  /// contract lives in a doc comment and nothing enforces it, and the
  /// consequences of trusting it differ by path. On the permitted path an
  /// escaping sink exception would fail a write the session was allowed to
  /// make. On the deny path it would replace [AccessDenied] with something no
  /// caller catches, skip `onDenied`, and leave the operator with no prompt and
  /// no explanation for a control that did nothing.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stackTrace) {
      _logger.e('AUDIT ROW LOST for ${row.surface}:${row.itemKey}',
          error: error, stackTrace: stackTrace);
    }
  }

  _SystemPreferences? _systemWrites;

  /// The app's own boot-time defaults, written with nobody signed in.
  ///
  /// See [_SystemPreferences] for what this is, which call sites may use it,
  /// and what it costs. It is a separate object rather than a parameter on the
  /// members above, because a parameter would be one keystroke from being
  /// copied into an operator path.
  Preferences get systemWrites => _systemWrites ??= _SystemPreferences(this);

  // ---------------------------------------------------------------------------
  // Reads — straight through. No lookup, no row, no denial.
  // ---------------------------------------------------------------------------

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _inner.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _inner.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key, {bool secret = false}) =>
      _inner.getBool(key, secret: secret);

  @override
  Future<int?> getInt(String key, {bool secret = false}) =>
      _inner.getInt(key, secret: secret);

  @override
  Future<double?> getDouble(String key, {bool secret = false}) =>
      _inner.getDouble(key, secret: secret);

  @override
  Future<String?> getString(String key, {bool secret = false}) =>
      _inner.getString(key, secret: secret);

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) =>
      _inner.getStringList(key, secret: secret);

  @override
  Future<bool> containsKey(String key, {bool secret = false}) =>
      _inner.containsKey(key, secret: secret);

  // ---------------------------------------------------------------------------
  // Writes — the seven members spec §6 names, and only these seven.
  // ---------------------------------------------------------------------------

  @override
  Future<void> setBool(String key, bool value,
          {bool saveToDb = true, bool secret = false}) =>
      _guard(
        key: key,
        group: _groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _oldValueOf(
            secret, () async => (await _inner.getBool(key))?.toString()),
        write: () =>
            _inner.setBool(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setInt(String key, int value,
          {bool saveToDb = true, bool secret = false}) =>
      _guard(
        key: key,
        group: _groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _oldValueOf(
            secret, () async => (await _inner.getInt(key))?.toString()),
        write: () =>
            _inner.setInt(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setDouble(String key, double value,
          {bool saveToDb = true, bool secret = false}) =>
      _guard(
        key: key,
        group: _groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _oldValueOf(
            secret, () async => (await _inner.getDouble(key))?.toString()),
        write: () =>
            _inner.setDouble(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setString(String key, String value,
          {bool saveToDb = true, bool secret = false}) =>
      _guard(
        key: key,
        group: _groupFor(key),
        newValue: secret ? null : value,
        readOldValue: _oldValueOf(secret, () => _inner.getString(key)),
        write: () =>
            _inner.setString(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setStringList(String key, List<String> value,
          {bool saveToDb = true, bool secret = false}) =>
      _guard(
        key: key,
        group: _groupFor(key),
        newValue: secret ? null : value.join(','),
        readOldValue: _oldValueOf(
            secret, () async => (await _inner.getStringList(key))?.join(',')),
        write: () => _inner.setStringList(key, value,
            saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> remove(String key, {bool secret = false}) => _guard(
        key: key,
        group: _groupFor(key),
        newValue: null,
        readOldValue: _oldValueOf(
            secret, () async => (await _inner.getAll())[key]?.toString()),
        write: () => _inner.remove(key, secret: secret),
      );

  /// Clears the store, or the part of it [allowList] names.
  ///
  /// There is no key for the policy to look up, so this member carries its own
  /// rule: **[AccessGroup.administer], always, whatever the allow list says.**
  /// It is the destructive whole-store operation, and an allow list is a
  /// parameter, not a smaller permission.
  @override
  Future<void> clear({Set<String>? allowList}) => _guard(
        key: _wholeStoreItemKey,
        group: AccessGroup.administer,
        newValue: null,
        readOldValue: null,
        write: () => _inner.clear(allowList: allowList),
      );

  // ---------------------------------------------------------------------------
  // Everything else — forwarded explicitly, one member at a time.
  // ---------------------------------------------------------------------------

  /// The wrapped store's database handle, and a hole this class cannot close.
  ///
  /// `implements Preferences` obliges this getter to exist, so anything holding
  /// a `GuardedPreferences` can reach `prefs.database!.db` and write
  /// `flutter_preferences` — or anything else — straight through Drift, past
  /// every check and every row above. Returning null instead would break the
  /// preferences editor and `ServerConfigDb`, which legitimately need it.
  ///
  /// **The residual risk is real and is not contained by this file.** What
  /// bounds it is plan 03-03's write-path sweep, which enumerates the direct
  /// Drift writers reachable from a widget and gets a verdict per site.
  @override
  Database? get database => _inner.database;

  @override
  KeyCache get keyCache => _inner.keyCache;

  @override
  MySecureStorage get secureStorage => _inner.secureStorage;

  @override
  PreferencesApi? get localCache => _inner.localCache;

  @override
  Stream<String> get onPreferencesChanged => _inner.onPreferencesChanged;

  @override
  Future<bool> isKeyInDatabase(String key) => _inner.isKeyInDatabase(key);

  // Forwarding a @visibleForTesting member is what "callers change nothing"
  // costs: the test that calls it holds a Preferences, and after plan 03-06
  // that Preferences is this one. The ignore covers the forward, not a missing
  // implementation.
  @override
  // ignore: invalid_use_of_visible_for_testing_member
  Future<void> syncToLocalCache() => _inner.syncToLocalCache();

  @override
  Future<void> loadFromPostgres() => _inner.loadFromPostgres();
}

/// The one write path that skips the session check — the app's own boot-time
/// defaults, and nothing else.
///
/// ## Why it exists
///
/// The app writes its own defaults at boot with nobody signed in. Under a
/// fail-closed config guard every one of these is an `administer` denial, and
/// the station does not come up:
///
/// - `lib/providers/state_man.dart:26` — default `key_mappings` on a fresh
///   station, inside `stateManProvider`.
/// - `packages/tfc_dart/lib/core/state_man.dart:443` — `StateManConfig`'s
///   default, written with `secret: true, saveToDb: false`. It takes a
///   `Preferences`, which is why this object is typed `Preferences` and not
///   `PreferencesApi`.
/// - `lib/page_creator/page.dart:247`, reached from
///   `lib/providers/page_manager.dart:29` — the default page layout. This one
///   is **unawaited**, so a denial there surfaces as an unhandled asynchronous
///   error: the station shows the hardcoded layout, never persists it, and
///   prompts whoever is standing there on every cold boot.
/// - `packages/tfc_dart/lib/core/alarm.dart:220`, reached from
///   `lib/providers/alarm.dart:13` — the default `alarm_man_config`.
/// - `lib/providers/collector.dart:27` — the default `collector_config`.
/// - `lib/providers/mcp_bridge.dart:112` — the MCP config migration's removes.
///
/// Plan 03-06 owns that list, routes each site through here and caps the set
/// with a test. It has already grown once, from three to six. **Anything else
/// using this is a defect**, not a shortcut.
///
/// ## Why a named object and not a flag
///
/// The alternative was to make those paths fail open by key pattern. That would
/// put permanently unguarded keys in the policy table, and the next person
/// adding a boot default would add another without anyone noticing. A named
/// object with counted call sites is the version that stays visible.
///
/// ## Why it still writes a row
///
/// Spec §2: `origin` defaults to hand-made on purpose, so an unmarked machine
/// caller lands *in* the trail loudly rather than escaping it silently — an
/// absent audit row is the one defect nobody ever notices. Every write through
/// here is recorded with `origin: 'system'`, `allowed: true` and the group that
/// would have been required.
///
/// ## Residual risk
///
/// Anything holding a `GuardedPreferences` can reach
/// [GuardedPreferences.systemWrites] and write any configuration key without a
/// check. The controls are plan 03-06's call-site test and the fact that this
/// is a named member somebody has to type on purpose. Phase 4 can narrow it
/// further by moving the boot defaults behind a first-run path. Nothing here
/// makes it unreachable.
class _SystemPreferences implements Preferences {
  _SystemPreferences(this._owner);

  final GuardedPreferences _owner;

  Preferences get _inner => _owner._inner;

  // ---------------------------------------------------------------------------
  // Writes — unchecked, still audited.
  // ---------------------------------------------------------------------------

  @override
  Future<void> setBool(String key, bool value,
          {bool saveToDb = true, bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _owner._oldValueOf(
            secret, () async => (await _inner.getBool(key))?.toString()),
        write: () =>
            _inner.setBool(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setInt(String key, int value,
          {bool saveToDb = true, bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _owner._oldValueOf(
            secret, () async => (await _inner.getInt(key))?.toString()),
        write: () =>
            _inner.setInt(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setDouble(String key, double value,
          {bool saveToDb = true, bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: secret ? null : '$value',
        readOldValue: _owner._oldValueOf(
            secret, () async => (await _inner.getDouble(key))?.toString()),
        write: () =>
            _inner.setDouble(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setString(String key, String value,
          {bool saveToDb = true, bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: secret ? null : value,
        readOldValue: _owner._oldValueOf(secret, () => _inner.getString(key)),
        write: () =>
            _inner.setString(key, value, saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> setStringList(String key, List<String> value,
          {bool saveToDb = true, bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: secret ? null : value.join(','),
        readOldValue: _owner._oldValueOf(
            secret, () async => (await _inner.getStringList(key))?.join(',')),
        write: () => _inner.setStringList(key, value,
            saveToDb: saveToDb, secret: secret),
      );

  @override
  Future<void> remove(String key, {bool secret = false}) =>
      _owner._uncheckedWrite(
        key: key,
        group: _owner._groupFor(key),
        newValue: null,
        readOldValue: _owner._oldValueOf(
            secret, () async => (await _inner.getAll())[key]?.toString()),
        write: () => _inner.remove(key, secret: secret),
      );

  @override
  Future<void> clear({Set<String>? allowList}) => _owner._uncheckedWrite(
        key: _wholeStoreItemKey,
        group: AccessGroup.administer,
        newValue: null,
        readOldValue: null,
        write: () => _inner.clear(allowList: allowList),
      );

  // ---------------------------------------------------------------------------
  // Everything else — the same store, forwarded, indistinguishable from the
  // guard's own reads.
  // ---------------------------------------------------------------------------

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _inner.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _inner.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key, {bool secret = false}) =>
      _inner.getBool(key, secret: secret);

  @override
  Future<int?> getInt(String key, {bool secret = false}) =>
      _inner.getInt(key, secret: secret);

  @override
  Future<double?> getDouble(String key, {bool secret = false}) =>
      _inner.getDouble(key, secret: secret);

  @override
  Future<String?> getString(String key, {bool secret = false}) =>
      _inner.getString(key, secret: secret);

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) =>
      _inner.getStringList(key, secret: secret);

  @override
  Future<bool> containsKey(String key, {bool secret = false}) =>
      _inner.containsKey(key, secret: secret);

  @override
  Database? get database => _inner.database;

  @override
  KeyCache get keyCache => _inner.keyCache;

  @override
  MySecureStorage get secureStorage => _inner.secureStorage;

  @override
  PreferencesApi? get localCache => _inner.localCache;

  @override
  Stream<String> get onPreferencesChanged => _inner.onPreferencesChanged;

  @override
  Future<bool> isKeyInDatabase(String key) => _inner.isKeyInDatabase(key);

  @override
  // ignore: invalid_use_of_visible_for_testing_member
  Future<void> syncToLocalCache() => _inner.syncToLocalCache();

  @override
  Future<void> loadFromPostgres() => _inner.loadFromPostgres();
}
