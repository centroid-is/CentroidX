/// The one place the no-history rule lives, and the payload the rule forces
/// the sync transport to carry.
///
/// Everything else in this library stores the complete entity on both sides of
/// every change (`config_change.dart`), because a history that reduced on
/// write could only ever answer the questions its author thought of. This file
/// is the one deliberate bend in that rule, and it bends in the safe
/// direction: for an exempt entity **nothing is stored at all**, rather than a
/// change row with its sides redacted. No row ever lies about what it holds;
/// there is simply no row.
///
/// ## The two rulings, and why
///
/// **1. Page images carry no history.** A page image's id *is* the sha256
/// prefix of its bytes, so the bytes never change under an id: an "update" is
/// a different id, and "the history of one image" is not a question anybody
/// can ask. What the exemption avoids is C-3 — a base64 payload of up to about
/// 6.7 MB written twice into a table that is never pruned (once as the insert's
/// `new_value`, once again as the garbage collector's delete `old_value`), for
/// every image, forever. Nothing an engineer reads is lost: the *asset* change
/// rows still record which image an asset referenced at each revision, so the
/// trail still says when a mimic's picture was swapped and by whom. Only the
/// bytes of blobs that have since been collected are gone.
///
/// **2. `server_config_envelope` carries no history.** It is
/// PBKDF2+AES-256-GCM ciphertext (`lib/core/server_config_db.dart:74`), and
/// secrets are out of scope this milestone. Logging it would grant every
/// superseded ciphertext retention-forever as a side effect of a storage move
/// — C-4 — which is strictly worse than today, where a superseded envelope is
/// simply overwritten. The exemption keeps its lifetime exactly what it is now.
///
/// ## Where the rule is asked
///
/// Inside the change-row writers themselves, never at their call sites:
/// `ConfigStore._appendChange`, `SqlitePreferences._log` and
/// `blob_migration._insertChange` are the three places in this package that
/// insert into `config_change`, and each one asks before it inserts.
/// `config_history_policy_test.dart` scans `lib/` and fails if a fourth
/// appears that does not — because a ciphertext written into a never-pruned
/// table cannot be taken back, so the guard has to be structural rather than
/// remembered.
///
/// ## What the rule costs, and the nudge that pays it
///
/// Both of the ways a station learns that another station wrote something are
/// driven entirely by change rows: the NOTIFY trigger is `AFTER INSERT ON
/// config_change` (`database_drift.dart:731-733`), and the fast path is a
/// `config_change.id` watermark (`config_sync.dart:12-13`). A kind that writes
/// no change rows is therefore invisible to both, and would reach the other
/// stations only on the five-minute rev sweep — station A uploads an image and
/// saves a page, station B has the asset in seconds and a broken image on the
/// mimic until the sweep. That is a regression against today's keyed
/// `flutter_preferences` trigger, which propagates promptly.
///
/// So a commit that touched an exempt item sends its own notification on the
/// same `config_change` channel, after the commit, naming the kinds to
/// reconcile — see [encodeReconcileNudge]. Two properties of that payload are
/// load-bearing:
///
///   * it names **kinds and never entities**, so `pg_notify`'s 8000-byte cap —
///     which is enforced by erroring the statement that fired it, i.e. by
///     failing the save — is unreachable by construction rather than by luck;
///   * it is sent **after** the commit as its own statement, so a rolled-back
///     write never sends one, and a nudge that arrives for a write that did
///     not happen merely triggers an idempotent reconcile against committed
///     state.
///
/// A connection that dies between the commit and the notify sends nothing, and
/// nothing retries it: exempt-kind propagation then degrades to sweep latency
/// (up to [kConfigSweepInterval]) for that one write. That is the failure this
/// design accepts, and it is the same one an ordinary write already has when a
/// notification is lost with its connection.
library;

import 'config_item.dart';

/// Kinds no entity of which is ever written to the change log.
///
/// See the library doc for the argument. Widening this is a decision — an
/// exempt kind has no history at all, so nothing in the history view or in
/// undo can act on one — and `config_history_policy_test.dart` fails until the
/// decision is written down beside the code.
const Set<ConfigKind> kHistoryExemptKinds = {ConfigKind.pageImage};

/// Ids exempt within [ConfigKind.preference], which as a kind carries history
/// like any other.
const Set<String> kHistoryExemptPreferenceIds = {'server_config_envelope'};

/// Preference id **prefixes** whose rows carry no history.
///
/// `chat.` is the chat assistant's own state — the conversation index, the
/// active conversation and one `chat.conversation.<id>` row per thread, each
/// rewritten in full on every message. Logging those would append both the
/// old and the new transcript to `config_change` per turn: an N-turn
/// conversation costs O(N²) bytes in a table nothing prunes, replicated into
/// every station's mirror — the C-3 storage bomb rebuilt for chat. A
/// conversation is not plant configuration and nobody undoes one, so the
/// log is silent about it, the way it is about a page image.
const Set<String> kHistoryExemptPreferenceIdPrefixes = {'chat.'};

/// Whether writes to `(kind, id)` are kept out of `config_change` entirely.
///
/// Asked by every change-row writer immediately before it would insert. The
/// `config_item` write itself, and the compare-and-swap guarding it, are
/// untouched by this: an exempt entity is stored, versioned and synchronised
/// exactly like any other. Only its history is not kept.
bool historyExempt(ConfigKind kind, String id) =>
    kHistoryExemptKinds.contains(kind) ||
    (kind == ConfigKind.preference &&
        (kHistoryExemptPreferenceIds.contains(id) ||
            kHistoryExemptPreferenceIdPrefixes
                .any((prefix) => id.startsWith(prefix))));

/// The marker that tells a reconcile nudge from the trigger's own empty
/// payload.
const String kReconcileNudgePrefix = 'reconcile:';

/// The notification payload that asks the other stations to reconcile [kinds].
///
/// Wire names, comma-separated, behind [kReconcileNudgePrefix] — a few dozen
/// bytes whatever was written, which is the whole point. See the library doc.
String encodeReconcileNudge(Iterable<ConfigKind> kinds) =>
    '$kReconcileNudgePrefix${[for (final kind in kinds) kind.wireName].join(',')}';

/// The kinds [payload] asks for, or null when it is not a nudge at all.
///
/// Null is the trigger's empty payload and anything else unrecognised, and it
/// means "consume the change log" — the ordinary fast path, which must keep
/// working exactly as it did. A wire name this build has never heard of is
/// dropped rather than fatal, for the reason [ConfigKind.byWireName] is
/// nullable: a newer station writing kinds an older one does not know must not
/// stop the older one acting on the kinds it does.
Set<ConfigKind>? decodeReconcileNudge(String payload) {
  if (!payload.startsWith(kReconcileNudgePrefix)) return null;
  final names = payload.substring(kReconcileNudgePrefix.length).split(',');
  return {
    for (final name in names)
      if (ConfigKind.byWireName(name) case final kind?) kind,
  };
}
