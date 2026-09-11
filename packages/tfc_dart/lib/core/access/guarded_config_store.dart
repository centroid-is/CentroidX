/// The write guard over [ConfigStore]: one access check, one bounded
/// `audit_entry` row, and the store's own exceptions passed through untouched.
///
/// [ConfigStore] performs no check and writes no audit row on purpose — it
/// sits below the layer that has a session. This is that layer, and it mirrors
/// `GuardedPreferences`' construction shape exactly (policy, session callback,
/// [AuditSink], station, `onDenied`) so `lib/providers` wires it the same way
/// `guard_wiring_test.dart` already pins for the other two guards.
library;

import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';

import '../config/config_diff.dart';
import '../config/config_item.dart';
import '../config/config_merge.dart';
import '../config/config_store.dart';
import '../config/config_store_errors.dart';
import '../config/key_mapping_codec.dart' as codec;
import '../state_man.dart' show KeyMappingEntry, KeyMappings, OpcUANodeConfig;

/// The `who` of a row written with nobody signed in. Matches
/// `GuardedPreferences`, because it is the same trail.
const String _anonymousWho = 'anonymous';

/// A hand-made write. Spec §2's default.
const String _operatorOrigin = 'operator';

/// A write the app made for itself, with nobody signed in.
const String _systemOrigin = 'system';

/// The surface every configuration write is checked and recorded on.
const String _configSurface = 'pref';

/// How many bytes of audit `new_value` a save may spend.
///
/// One kilobyte is generous for a list of key names and nowhere near the
/// megabyte a blob-shaped `audit_entry` row cost. See [auditSummaryOf].
const int kAuditSummaryLimitBytes = 1024;

/// The check key and the audit `item_key` for each kind this guard can write.
///
/// **One table, two uses, deliberately.** The string here is passed to
/// [AccessPolicy.groupForWireSurface] *and* written into the row's `item_key`
/// column, so the group that was checked and the surface that was recorded
/// cannot disagree — `access_policy.dart:308-317` says in as many words that
/// splitting them is how a guard ends up checking something it did not record.
///
/// Phase 3 adds `page` and `asset` entries here and nothing else changes: the
/// guarded surface is already item-shaped and kind-generic.
///
/// `asset` landed with milestone v1.2 plan 03-05, which moved the tech-doc
/// cleanup onto the store; `page` has none yet, so a `checkKind: page` still
/// throws — the page save (plan 03-06) is what adds it, and until then the
/// throw is what stops a page write routing around the check.
///
/// **Both name `page_editor_data`, and that is deliberate.** An asset is not
/// separately permissioned from the page it sits on: the policy answers
/// `configure` for that key (`access_policy.dart`'s exact rule), the same
/// answer it gave when the layout was one preference, so moving the layout
/// onto rows changed nothing about who may edit it. It is also the `item_key`
/// the trail already uses for a layout change, which is what lets a reader
/// follow the plant's layout across the cutover in one query.
const Map<ConfigKind, String> kConfigWriteKeys = <ConfigKind, String>{
  ConfigKind.keyMapping: codec.kKeyMappingsPrefKey,
  // The literal, not a shared constant: the page codec that owns this key
  // needs Flutter to parse a page and lives app-side, where this package
  // cannot import from.
  ConfigKind.asset: 'page_editor_data',
  // The page editor's own save, added when that save landed (03-06): one
  // gesture over `{page, asset}`, checked and recorded once under the key
  // above. Until this entry existed `write(checkKind: page)` threw, which is
  // what kept the save from routing around the check.
  ConfigKind.page: 'page_editor_data',
  // And the images those assets draw (04-09). The same key again, for the
  // third time and for the same reason: an image is not separately
  // permissioned from the mimic that shows it — somebody who may edit the
  // page may put a picture on it — and the group `page_editor_data` resolves
  // to, `configure`, is the group the old `page_editor_image:` preference
  // rule answered as well. So the swap moved the storage and changed nobody's
  // permissions. What the row does *not* share with the other two is history:
  // `kHistoryExemptKinds` holds this kind, so an upload writes a
  // `config_item` row and no `config_change` row. The audit row is still
  // written, and its `new_value` names the image ids that moved.
  ConfigKind.pageImage: 'page_editor_data',
};

/// The example mapping a fresh plant is seeded with.
///
/// The same two-field entry `lib/providers/state_man.dart` used to write into
/// the blob at boot, moved here so the seed has one definition and lands
/// through the guarded system path rather than through a preference write.
final KeyMappings kExampleKeyMappings = KeyMappings(nodes: {
  'exampleKey': KeyMappingEntry(
    opcuaNode: OpcUANodeConfig(namespace: 42, identifier: 'identifier'),
  ),
});

/// A save's `audit_entry.new_value`: which keys moved, never what they hold.
///
/// `{"added":[…],"changed":[…],"removed":[…]}` of **key names only**, capped
/// at [limitBytes] with a `"truncated"` count of the names that did not fit.
///
/// This is SC-2's "the megabyte audit row is gone", made structural rather
/// than promised. A `key_mappings` save used to land the before- and
/// after-image of a 530 kB blob in one row, out of which nobody could tell
/// which key changed. The names are what a person reading the trail needs;
/// the values are in the `config_change` rows underneath, one per key, joined
/// by `action_id`.
///
/// A pure function, so the truncation contract is testable without a database.
String auditSummaryOf(ConfigDiff diff,
    {int limitBytes = kAuditSummaryLimitBytes}) {
  final added = [for (final item in diff.added) item.id];
  final changed = [for (final item in diff.changed) item.id];
  final removed = [for (final item in diff.removed) item.id];
  final total = added.length + changed.length + removed.length;

  String encode(int keep) {
    var budget = keep;
    List<String> take(List<String> from) {
      final n = budget < from.length ? budget : from.length;
      budget -= n;
      return from.sublist(0, n);
    }

    final map = <String, Object>{
      'added': take(added),
      'changed': take(changed),
      'removed': take(removed),
    };
    // Present only when something was dropped, so the ordinary save's row
    // reads as a complete list rather than as a list with a zero beside it.
    if (keep < total) map['truncated'] = total - keep;
    return jsonEncode(map);
  }

  final full = encode(total);
  if (utf8.encode(full).length <= limitBytes) return full;

  // The largest number of names that fits. A linear walk would be 3000 JSON
  // encodings on the import this exists for; a bisection is a dozen.
  var low = 0;
  var high = total;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    if (utf8.encode(encode(mid)).length <= limitBytes) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return encode(low);
}

/// A [ConfigStore] whose writes are checked against the session and recorded.
///
/// ## The check key and the audit key are the same string (C-8)
///
/// Both come from [kConfigWriteKeys], and for key mappings both are
/// `'key_mappings'` on surface `'pref'` — the key the policy already classes
/// as `configure` and the same one the blob write was checked as. **Do not
/// introduce a new surface, and do not make the `item_key` per mapping key.**
/// [AccessPolicy.groupForWireSurface] answers `administer` for a surface it
/// does not know and [AccessPolicy.groupForPref] answers `administer` for a
/// key no rule matches, so either change would silently lock every operator
/// and shift leader out of the key repository, and the failure would look
/// like a permissions bug rather than like a typo.
///
/// SC-2 asks the trail to name the key that changed, and it does — through the
/// **trail**, not through one column. One `audit_entry` whose `new_value`
/// summarises the diff by name, and N `config_change` rows sharing its
/// `action_id`, each carrying one key and both full sides of it.
///
/// ## Item-shaped and kind-generic, before Phase 3 needs it (A3)
///
/// [save] is the write path and it takes `List<ConfigItem>` plus a
/// [ConfigKind]. Phase 3 writes pages and assets through this same method:
/// `ConfigStore` can never take a page model — this package has no Flutter
/// dependency and `page_codec.dart` does — so an item list is the only shape
/// that works for all three, and widening a guarded write after it has shipped
/// is the review nobody wants. [saveKeyMappings] is one line on top of it so
/// domain call sites read as domain code.
///
/// ## Ordering: check, write, then record
///
/// A denial is recorded immediately, before the throw — a refusal that leaves
/// no row is the repudiation the trail exists to prevent. A permitted write is
/// recorded **after** the store returns, which is the opposite of
/// `GuardedPreferences`' ordering and is deliberate: this store can refuse a
/// write outright (no remote, unsafe pool, another station won the row), and a
/// row written first would claim a save that never happened.
///
/// The accepted cost, stated here because whoever reads the trail must find it
/// written down rather than discover it: a crash between the store's `COMMIT`
/// and the audit insert leaves `config_change` rows on an `action_id` with no
/// `audit_entry`. Orphan history is recoverable — the rows say what changed
/// and who — where an audit row claiming a write that never landed is not.
class GuardedConfigStore {
  /// [session] is a callback rather than a value on purpose: a captured
  /// session would keep granting whatever was held when the provider was
  /// built, long after a logout or an inactivity timeout.
  GuardedConfigStore({
    required ConfigStore inner,
    required AccessPolicy policy,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _inner = inner,
        _policy = policy,
        _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final ConfigStore _inner;
  final AccessPolicy _policy;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;
  final Logger _logger;

  /// The store itself. **Reads pass through it, not through this object**: a
  /// read produces no row and cannot be denied (spec §11 defers read
  /// permissions, and a guarded read would break every station at boot), so
  /// wrapping the snapshot, the mappings and the change stream would add a
  /// forwarding layer with nothing in it.
  ConfigStore get inner => _inner;

  /// Replaces the stored rows of [kind] with [wanted] — the write path.
  ///
  /// Throws [ArgumentError] for a kind [kConfigWriteKeys] does not name. That
  /// is a developer error and it must die in a test rather than fall through
  /// to the policy's `administer` default, where it would read as a
  /// permissions problem at an operator's panel.
  ///
  /// Throws [AccessDenied] when the session may not, having written the row
  /// and fired `onDenied` first. Everything the store throws —
  /// `ConfigStoreOfflineException`, `ConfigStoreUnsafePoolException`,
  /// `ConfigConflict` — propagates **unwrapped**, because the editor's three
  /// catch arms are those three types.
  Future<ConfigWriteResult> save(List<ConfigItem> wanted,
          {required ConfigKind kind, String? reason}) =>
      write(wanted, kinds: {kind}, checkKind: kind, reason: reason);

  /// Replaces the stored rows of [kinds] with [wanted], checked and recorded
  /// as [checkKind] — the write path, of which [save] is the one-kind case.
  ///
  /// ## Why two kind arguments
  ///
  /// A page save is one gesture over two kinds: the page row and its assets
  /// move together, and both have to be in the replace set or an asset the
  /// operator deleted would be inserted and never removed. But it is **one**
  /// thing an operator did, so it is one check and one audit row. [kinds]
  /// bounds what the store may rewrite; [checkKind] names the row in
  /// [kConfigWriteKeys] that decides who may do it and what the trail calls
  /// it. Making them one argument would force either a check per kind — two
  /// audit rows for one Save — or a check key invented at the call site, and
  /// [AccessPolicy.groupForWireSurface] answers `administer` for a surface it
  /// does not know, so an invented key locks the operator out and looks like a
  /// permissions bug.
  ///
  /// Throws [ArgumentError] for a [checkKind] that [kConfigWriteKeys] does not
  /// name, and for any kind in [kinds] outside [kSharedConfigKinds] — both are
  /// developer errors and must die in a test rather than fall through to the
  /// policy's `administer` default, where they would read as a permissions
  /// problem at an operator's panel.
  ///
  /// `preference` is now a shared kind (04-05) but still has no entry in
  /// [kConfigWriteKeys], so a preference write through here dies on the first
  /// throw rather than the second. That is deliberate and it is the whole
  /// point of [writePreference]: every other kind is checked once per *kind*,
  /// and a preference is checked per *key* — `alarm_man_config` is `configure`
  /// where `collector_config` is `administer`. A single entry in that table
  /// would flatten eight key families onto one group.
  ///
  /// Throws [AccessDenied] when the session may not, having written the row
  /// and fired `onDenied` first. Everything the store throws —
  /// `ConfigStoreOfflineException`, `ConfigStoreUnsafePoolException`,
  /// `ConfigConflict` — propagates **unwrapped**, because the editor's three
  /// catch arms are those three types.
  Future<ConfigWriteResult> write(
    List<ConfigItem> wanted, {
    required Set<ConfigKind> kinds,
    required ConfigKind checkKind,
    String? reason,
  }) async {
    // Before the check, and before any row: a kind that may not be written
    // here at all is not a denial to record, it is a call that should not
    // compile and could not be stopped at compile time.
    //
    // `preference` is under sync since 04-05, so the shared-set loop below no
    // longer catches it — and without this it would be checkable under
    // *another* kind's key: `kinds: {preference}, checkKind: keyMapping`
    // would replace every shared preference in the plant on a `configure`
    // check, which is T-04-05a exactly. The per-key arm is the only way in.
    if (kinds.contains(ConfigKind.preference)) {
      throw ArgumentError.value(
          kinds,
          'kinds',
          'holds `preference`, which is checked per key and not per kind — '
              '`alarm_man_config` is configure where `collector_config` is '
              'administer. Use writePreference(prefKey: …), whose one string '
              'is both the group looked up and the item_key recorded.');
    }
    for (final kind in kinds) {
      if (!kSharedConfigKinds.contains(kind)) {
        throw ArgumentError.value(
            kind,
            'kinds',
            'is not one of the shared configuration kinds this surface may '
                'replace ($kSharedConfigKinds). A `preference` row belongs to '
                'one station and writing it here would share it with all of '
                'them.');
      }
    }
    final itemKey = _keyFor(checkKind);
    final group = _policy.groupForWireSurface(_configSurface, itemKey);
    final session = _session();
    final actionId = newActionId();

    if (!session.can(group)) {
      await _record(_row(
        session: session,
        itemKey: itemKey,
        group: group,
        newValue: null,
        allowed: false,
        actionId: actionId,
        reason: reason,
      ));
      final denial = AccessDenied(itemKey, group);
      _onDenied?.call(denial);
      throw denial;
    }

    return _writeAndRecord(
      wanted,
      kinds: kinds,
      itemKey: itemKey,
      group: group,
      session: session,
      actionId: actionId,
      origin: _operatorOrigin,
      reason: reason,
    );
  }

  /// Replaces the shared preference rows with [wanted], checked and recorded
  /// as the preference key [prefKey] — the write path `SharedRowPreferences`
  /// uses, and the only one that resolves a group per key.
  ///
  /// ## Why a second entry point and not an entry in [kConfigWriteKeys]
  ///
  /// Every other kind is one permissioned thing: a key mapping is `configure`
  /// because the key repository is, an asset is `configure` because the page
  /// it sits on is. Preferences are eight key families with three different
  /// groups between them — `alarm_man_config` is `configure`,
  /// `<bucket>.recipes` is `setpoints`, `state_man_config`,
  /// `collector_config`, `update_channel` and `server_config_envelope` are
  /// `administer` — and one table entry would flatten them onto whichever one
  /// was written down. So the *key* is passed in, and it is the same string
  /// twice over, exactly as [kConfigWriteKeys] is for the other kinds: the
  /// group checked and the `item_key` recorded cannot disagree, and a key no
  /// rule names answers `administer` rather than falling open.
  ///
  /// ## Why the whole set and not the one key
  ///
  /// [ConfigStore.writeItems] replaces within kinds: [wanted] is every shared
  /// preference that must exist after this write, not the one that changed. A
  /// caller passing one item would delete every sibling. `SharedRowPreferences`
  /// is what assembles it from the snapshot, and
  /// `shared_preferences_rows_test.dart` pins the rule with three seeded keys.
  ///
  /// Throws exactly what [write] throws, for the same reasons.
  Future<ConfigWriteResult> writePreference(
    List<ConfigItem> wanted, {
    required String prefKey,
    String? reason,
  }) async {
    final group = _policy.groupForWireSurface(_configSurface, prefKey);
    final session = _session();
    final actionId = newActionId();

    if (!session.can(group)) {
      await _record(_row(
        session: session,
        itemKey: prefKey,
        group: group,
        newValue: null,
        allowed: false,
        actionId: actionId,
        reason: reason,
      ));
      final denial = AccessDenied(prefKey, group);
      _onDenied?.call(denial);
      throw denial;
    }

    return _writeAndRecord(
      wanted,
      kinds: const {ConfigKind.preference},
      itemKey: prefKey,
      group: group,
      session: session,
      actionId: actionId,
      origin: _operatorOrigin,
      reason: reason,
    );
  }

  /// [writePreference] with no check, `origin: 'system'` and one audit row —
  /// the [ConfigStore] side of `GuardedPreferences.systemWrites`.
  ///
  /// **This is not "writes we want to allow".** It is "writes the app makes on
  /// its own behalf when nobody has acted": the empty `alarm_man_config`
  /// `AlarmMan.create` writes at boot, the default `collector_config`, the
  /// empty recipe list written on an asset's *read* path. A Save button never
  /// qualifies; the fix for a legitimate operator write being refused is a
  /// rule in `kPrefAccessRules`. The set of files that may reach this is
  /// capped by `kSystemWriteCallSites` and by a test that compares that
  /// constant against the source in both directions.
  ///
  /// The group is resolved and recorded even though it was not enforced, so
  /// the trail shows what authority was skipped rather than showing none —
  /// the same shape [seedDefaultIfEmpty] uses.
  ///
  /// ## Offline is not empty, and a default must never take a panel down
  ///
  /// Unlike [writePreference], this **does not throw when the shared store is
  /// unreachable**: it logs and returns an empty result. Two reasons, and they
  /// are the same two [seedDefaultIfEmpty] states at length.
  ///
  /// A default is written *because storage held nothing*, and a station that
  /// cannot reach Postgres has not learned that storage held nothing — it has
  /// learned nothing at all. Writing on that basis is inventing configuration;
  /// refusing loudly is worse still, because every one of these call sites is
  /// inside a provider that a mimic hangs off (`alarm.dart:26-29` is the
  /// clearest: the exception comes out of `alarmMan` and takes the alarm page
  /// with it). The station is already coming up on its mirror with defaults in
  /// hand; the shared row is written by whichever station is online when the
  /// value is next set.
  ///
  /// A [ConfigConflict] is swallowed for the third reason [seedDefaultIfEmpty]
  /// gives: it means another station wrote the same default first, which is
  /// the outcome this wanted anyway.
  ///
  /// **An operator's write is not covered by any of this.** [writePreference]
  /// still refuses, loudly, every time — a Save button that quietly wrote
  /// nothing is the green snackbar this milestone exists to end.
  Future<ConfigWriteResult> writePreferenceAsSystem(
    List<ConfigItem> wanted, {
    required String prefKey,
    String? reason,
  }) async {
    if (!_inner.hasRemote) {
      _logger.i('the system default for $prefKey was not written: the shared '
          'store is unreachable, so "storage is empty" is not something this '
          'station knows. It boots on the default in hand.');
      return ConfigWriteResult(diff: ConfigDiff.none, actionId: newActionId());
    }
    try {
      return await _writeAndRecord(
        wanted,
        kinds: const {ConfigKind.preference},
        itemKey: prefKey,
        group: _policy.groupForWireSurface(_configSurface, prefKey),
        session: _session(),
        actionId: newActionId(),
        origin: _systemOrigin,
        reason: reason,
      );
    } on ConfigStoreOfflineException catch (error) {
      _logger.w('the system default for $prefKey did not land; the shared '
          'database went away between the attach and the write: $error');
    } on ConfigConflict catch (error) {
      _logger.i('the system default for $prefKey was not needed; another '
          'station wrote it first: $error');
    }
    return ConfigWriteResult(diff: ConfigDiff.none, actionId: newActionId());
  }

  /// Checks and records a preference write that lands in the OS keychain
  /// rather than in a row, then performs it.
  ///
  /// ## Why a write with no row is still this class's business
  ///
  /// A secret is a preference: `server_config_envelope` and
  /// `state_man_config` are set through the same `setString(…, secret: true)`
  /// every other setting uses, and `GuardedPreferences` checked and recorded
  /// all seven of its write members without caring where the value ended up.
  /// Losing that in the move to rows would take "somebody set the plant's
  /// database credentials" out of the trail — the one write where the trail
  /// matters most — and would leave the *only* unchecked configuration write
  /// in the app being the one that stores a credential.
  ///
  /// **Neither side of the value is ever recorded.** [AuditRecord.oldValue]
  /// and `newValue` are both null here, which is the rule
  /// `GuardedPreferences._oldValueOf` states: reading the old value is the
  /// single edit that would copy a credential into a permanent, replicated
  /// table, and it would look like completeness while doing it.
  ///
  /// The row is written **before** [write], matching `GuardedPreferences`:
  /// there is no store underneath that can refuse, so there is no window in
  /// which the row would claim a write that did not happen.
  Future<void> writeSecret({
    required String prefKey,
    required Future<void> Function() write,
    String? reason,
  }) async {
    final group = _policy.groupForWireSurface(_configSurface, prefKey);
    final session = _session();
    final actionId = newActionId();

    if (!session.can(group)) {
      await _record(_row(
        session: session,
        itemKey: prefKey,
        group: group,
        newValue: null,
        allowed: false,
        actionId: actionId,
        reason: reason,
      ));
      final denial = AccessDenied(prefKey, group);
      _onDenied?.call(denial);
      throw denial;
    }

    await _record(_row(
      session: session,
      itemKey: prefKey,
      group: group,
      newValue: null,
      allowed: true,
      actionId: actionId,
      origin: _operatorOrigin,
      reason: reason,
    ));
    await write();
  }

  /// [writeSecret] with no check and `origin: 'system'` — the secret half of
  /// [writePreferenceAsSystem].
  ///
  /// The boot default `state_man_config` is written this way: with nobody
  /// signed in, through `systemPreferences`, into the keychain. Unlike its row
  /// counterpart this does **not** no-op when Postgres is unreachable, because
  /// the keychain is local: there is no "storage is empty" this station could
  /// be wrong about, and a station that cannot store its own default
  /// connection settings would re-derive them on every boot.
  Future<void> writeSecretAsSystem({
    required String prefKey,
    required Future<void> Function() write,
    String? reason,
  }) async {
    await _record(_row(
      session: _session(),
      itemKey: prefKey,
      group: _policy.groupForWireSurface(_configSurface, prefKey),
      newValue: null,
      allowed: true,
      actionId: newActionId(),
      origin: _systemOrigin,
      reason: reason,
    ));
    await write();
  }

  /// [save] for key mappings.
  ///
  /// Exists so 02-06's call sites read as domain code. With [baseline] — the
  /// store's key mapping items as the editor loaded them — the wanted set is
  /// first reconciled against what the store holds now through
  /// `mergeItemsForSave`, so a key another station added, changed or removed
  /// while the repository was open is kept, adopted or refused rather than
  /// silently replaced with the editor's hour-old copy. Without it the save is
  /// `save(keyMappingItems(wanted), kind: keyMapping)` and nothing more, which
  /// `guarded_config_store_test.dart` holds it to.
  Future<ConfigWriteResult> saveKeyMappings(KeyMappings wanted,
      {String? reason, List<ConfigItem>? baseline}) {
    var items = codec.keyMappingItems(wanted);
    if (baseline != null) {
      items = mergeItemsForSave(
        wanted: items,
        stored: _inner.keyMappingItems,
        baseline: baseline,
      );
    }
    return save(items, kind: ConfigKind.keyMapping, reason: reason);
  }

  /// Writes the example mapping when the plant has none — the systemWrites
  /// analogue, with no check, `origin: 'system'` and one audit row.
  ///
  /// A no-op unless a remote is attached *and* the shared store is empty once
  /// the first reconcile has landed. Both halves matter:
  ///
  /// - **Offline is not empty.** A station that never reached Postgres has no
  ///   shared configuration to speak for; seeding one would be this station
  ///   inventing plant wiring, and the store refuses shared writes offline
  ///   anyway. It boots on whatever its mirror holds, which may be nothing.
  /// - **Empty is only knowable after the reconcile.** The snapshot is filled
  ///   from the local mirror, so a fresh station attached to a fully
  ///   configured plant has an empty snapshot for as long as the first sweep
  ///   takes. Seeding on that would add a junk key to a live plant.
  ///
  /// A station that loses the race — another one seeded the same key between
  /// the reconcile and this write — gets a unique violation out of the store's
  /// transaction. That is logged and swallowed: a boot default must never take
  /// a panel down, and the loser picks the row up at the next reconcile.
  Future<void> seedDefaultIfEmpty() async {
    if (!_inner.hasRemote) return;
    await _inner.syncSettled;
    if (_inner.keyMappingItems.isNotEmpty) return;

    final itemKey = _keyFor(ConfigKind.keyMapping);
    try {
      await _writeAndRecord(
        codec.keyMappingItems(kExampleKeyMappings),
        kinds: const {ConfigKind.keyMapping},
        itemKey: itemKey,
        // Resolved and recorded even though it was not enforced, so the trail
        // shows what authority was skipped rather than showing none.
        group: _policy.groupForWireSurface(_configSurface, itemKey),
        session: _session(),
        actionId: newActionId(),
        origin: _systemOrigin,
        reason: 'boot default: the shared store held no key mappings',
      );
    } on Object catch (error) {
      _logger.w('key_mappings boot seed did not land; another station has '
          'very likely seeded the same key, and the next reconcile brings it '
          'here: $error');
    }
  }

  // ---------------------------------------------------------------------
  // The one implementation of write-then-record.
  // ---------------------------------------------------------------------

  Future<ConfigWriteResult> _writeAndRecord(
    List<ConfigItem> wanted, {
    required Set<ConfigKind> kinds,
    required String itemKey,
    required AccessGroup group,
    required AccessSession session,
    required String actionId,
    required String origin,
    String? reason,
  }) async {
    final result = await _write(
      wanted,
      kinds: kinds,
      actionId: actionId,
      session: session,
      reason: reason,
    );

    // Save pressed twice wrote no row, no change entry and no event; it does
    // not get an audit row either. The same rule the store applies underneath.
    if (result.diff.isEmpty) return result;

    await _record(_row(
      session: session,
      itemKey: itemKey,
      group: group,
      // Never the old side. The before-image of every key that moved is in the
      // `config_change` rows this action wrote, in full, one per key — putting
      // it here too is how the megabyte row happened in the first place.
      newValue: auditSummaryOf(result.diff),
      allowed: true,
      actionId: actionId,
      origin: origin,
      reason: reason,
    ));
    return result;
  }

  /// The delegation to the store — one call for every kind, which is what
  /// 02-05 said this body would become.
  ///
  /// There is no per-kind arm left and deliberately so: a second write path is
  /// how a save escapes the check (T-03-03), and the switch that used to be
  /// here could only grow one. What guards the surface is the pair of tables
  /// above — [kConfigWriteKeys] decides who may write a kind and what the
  /// trail calls it, [kSharedConfigKinds] decides which kinds this surface may
  /// replace at all — and both are refused in [write] before anything is
  /// written or recorded.
  Future<ConfigWriteResult> _write(
    List<ConfigItem> wanted, {
    required Set<ConfigKind> kinds,
    required String actionId,
    required AccessSession session,
    String? reason,
  }) =>
      _inner.writeItems(
        kinds: kinds,
        wanted: wanted,
        actionId: actionId,
        who: session.user?.username ?? _anonymousWho,
        roleName: session.roleName,
        reason: reason,
      );

  /// The check and audit key for [kind].
  String _keyFor(ConfigKind kind) {
    final itemKey = kConfigWriteKeys[kind];
    if (itemKey == null) {
      throw ArgumentError.value(
          kind,
          'kind',
          'has no entry in kConfigWriteKeys, so there is no key to check it '
              'as and none to record it under. Add one (guarded_config_store'
              '.dart) rather than letting it fall through to the policy\'s '
              'administer default.');
    }
    return itemKey;
  }

  AuditRecord _row({
    required AccessSession session,
    required String itemKey,
    required AccessGroup group,
    required String? newValue,
    required bool allowed,
    required String actionId,
    String origin = _operatorOrigin,
    String? reason,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleName,
        surface: _configSurface,
        itemKey: itemKey,
        oldValue: null,
        newValue: newValue,
        groupRequired: group.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// On the permitted path the write has already committed, so an escaping
  /// sink exception would report a successful save as failed and have the
  /// operator do it twice. On the deny path it would replace [AccessDenied]
  /// with something no caller catches, skip `onDenied`, and leave the operator
  /// with no prompt and no explanation for a control that did nothing.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stackTrace) {
      _logger.e('AUDIT ROW LOST for ${row.surface}:${row.itemKey}',
          error: error, stackTrace: stackTrace);
    }
  }
}
