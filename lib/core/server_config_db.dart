import 'dart:convert';

import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';

/// A password-encrypted server configuration stored in the shared database.
///
/// The envelope itself is the [SecureEnvelope] JSON (PBKDF2 + AES-256-GCM),
/// so the database only ever sees ciphertext — the OPC-UA credentials inside
/// stay protected by the password the operator chose when storing it. The
/// metadata is deliberately plaintext: it lets the import dialog tell the
/// operator what they are about to overwrite their config with *before*
/// asking for the password.
class StoredServerConfig {
  final DateTime? savedAt;

  /// Hostname of the machine that stored the config.
  final String? savedBy;
  final Map<String, dynamic> envelope;

  StoredServerConfig({this.savedAt, this.savedBy, required this.envelope});

  factory StoredServerConfig.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'];
    return StoredServerConfig(
      savedAt: meta is Map && meta['saved_at'] is String
          ? DateTime.tryParse(meta['saved_at'] as String)
          : null,
      savedBy: meta is Map ? meta['saved_by'] as String? : null,
      envelope: (json['envelope'] as Map).cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'meta': {
          if (savedAt != null) 'saved_at': savedAt!.toIso8601String(),
          if (savedBy != null) 'saved_by': savedBy,
        },
        'envelope': envelope,
      };
}

/// Reads and writes the shared server-config envelope in the database.
///
/// The envelope lives as **one `config_item` row** — `kind='preference'`,
/// `id='server_config_envelope'`, `scope='shared'` — rather than in a table of
/// its own: that table is already replicated to every station, needs no schema
/// migration, and an operator can find (and delete) the row through the same
/// tooling as any other shared setting. Reads always go to the database, never
/// through a store's in-memory snapshot — that snapshot is filled at boot and
/// kept level by the sync engine, and the whole point of importing is picking
/// up a config another station stored *after* this one started.
///
/// ## Why the writes go through [PreferencesApi] and the read does not
///
/// The asymmetry is deliberate, and it is not an oversight waiting to be
/// tidied up. [publish] and [remove] replace the whole server configuration —
/// which Postgres this station talks to, which OPC UA servers it trusts — so
/// they must be gated on `administer` and land in the audit trail, and the
/// guarded [PreferencesApi] is the one path that does both. [fetch] must not
/// see a stale snapshot, for the reason in the paragraph above. Those are two
/// different requirements and they point at two different paths; making the
/// class symmetric would break whichever half it was made to match.
///
/// One consequence to know before reading [fetch] and worrying: [publish] does
/// populate the very cache [fetch] refuses to consult, because a shared
/// preference write updates the store's snapshot on its way to the row. That
/// does not make [fetch]'s direct select redundant — the snapshot holds only
/// what this station has written or has synchronised, and the config worth
/// importing is the one another station wrote a moment ago. The row remains
/// the only shared copy, and it remains the one [fetch] reads. It is proved
/// both ways in `server_config_db_test.dart`: a row another station wrote is
/// found with no reconcile here, and a row another station deleted reads as
/// absent even while this station's snapshot still holds the old value.
///
/// ## Superseded ciphertexts are not retained, on purpose
///
/// `server_config_envelope` is named by `kHistoryExemptPreferenceIds`, so
/// neither a [publish] nor a [remove] writes a `config_change` row. That is
/// the C-4 ruling from 04-01 and it is a *narrowing*, not a widening: the
/// payload is PBKDF2+AES-256-GCM ciphertext, `config_change` is never pruned,
/// and logging it would grant every superseded envelope retention-forever as
/// a side effect of a storage move. Today an overwritten envelope is simply
/// gone, and the exemption keeps its lifetime exactly that. The *fact* of the
/// write is still recorded: the `audit_entry` row says who replaced the
/// server configuration and when, naming neither side of the value.
class ServerConfigDb {
  ServerConfigDb._();

  static const String prefsKey = 'server_config_envelope';

  /// Stores [config] as the shared server config.
  ///
  /// [prefs] is the guarded store the caller already holds, so this write is
  /// checked and recorded like any other configuration write.
  static Future<void> publish(PreferencesApi prefs, StoredServerConfig config) {
    return prefs.setString(prefsKey, jsonEncode(config.toJson()));
  }

  /// Returns the stored config, or null when none has been stored yet.
  ///
  /// **Null is a normal return and the caller must keep treating it as one.**
  /// It means one thing and only one thing: there is no row. It cannot mean
  /// "not loaded yet", because [db] is the shared database itself and this
  /// select is issued against it every call — there is no snapshot in this
  /// path to be behind. The import dialog turns null into "No config stored in
  /// the database yet" and offers the operator a way forward; C-4 is what
  /// happens when that stops being distinguishable from a failure.
  ///
  /// Throws [FormatException] when the row exists but does not parse — either
  /// side of the encoding, the `{type,value}` preference payload or the
  /// envelope JSON inside it. A row that is there and unreadable is something
  /// the operator has to be told about, and it is emphatically not "nothing
  /// stored".
  static Future<StoredServerConfig?> fetch(AppDatabase db) async {
    final row = await (db.select(db.configItemTable)
          ..where((t) => t.kind.equals(ConfigKind.preference.wireName))
          ..where((t) => t.id.equals(prefsKey))
          ..where((t) => t.scope.equals(ConfigScope.shared.wireName)))
        .getSingleOrNull();
    if (row == null) return null;
    // `decodePreferencePayload` answers null for a payload this build cannot
    // read, which for an ordinary setting means "absent" and costs a default.
    // Here there is no default to fall back to and the row plainly exists, so
    // the same three cases are a corrupt row rather than an empty one.
    final raw = decodePreferencePayload(row.payload);
    if (raw is! String) {
      throw const FormatException(
          'The stored server config row does not hold a string');
    }
    if (raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['envelope'] is! Map) {
      throw const FormatException(
          'Stored server config is not a valid envelope');
    }
    return StoredServerConfig.fromJson(decoded);
  }

  /// Removes the shared server config. Gated and recorded like [publish].
  static Future<void> remove(PreferencesApi prefs) {
    return prefs.remove(prefsKey);
  }
}
