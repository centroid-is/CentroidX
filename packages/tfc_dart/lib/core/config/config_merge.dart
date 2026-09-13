/// Reconciling what an editor is about to save with what the plant holds
/// **now** — for kinds whose items stand alone.
///
/// `ConfigStore.writeItems` replaces within kinds: every stored item of the
/// kind that is absent from the wanted list is deleted, and every present one
/// is written over. An editor hands over the set it loaded when it opened,
/// and it can have been open for an hour. Without this, a key another station
/// added in that hour was deleted — cleanly, because this station's snapshot
/// had already reconciled the row, so the compare-and-swap matched — and an
/// edit another station made to a key this operator never touched was
/// overwritten with the copy from an hour ago. The per-row CAS protects the
/// window since the last sync; it says nothing about the window since the
/// editor opened. This does.
///
/// The page editor has its own version of this rule (`page_codec.dart`'s
/// `mergeForSave`), decided per page because a page and its assets move
/// together and their ordering keys are relative to the page. Key mappings
/// have no such structure — each key is its own entity — so here the rule is
/// applied per item.
library;

import 'config_item.dart';
import 'config_store_errors.dart';

/// [wanted], with every item the editor was not shown reconciled against
/// what the store holds now.
///
/// [baseline] is what the editor loaded: the store's items of the kind at
/// that moment, revisions included. Per item:
///
///   * A stored item the baseline never held — added elsewhere since — is
///     **kept** as stored, unless the editor holds the same id: identical
///     content is nothing to write, different content is a [ConfigConflict].
///   * A stored item at a different revision from the baseline — changed
///     elsewhere since — is kept as stored when the editor left it exactly as
///     loaded, and is a [ConfigConflict] when the operator changed it too, or
///     deleted it.
///   * A baseline item the store no longer holds — deleted elsewhere since —
///     is dropped when the editor left it as loaded, and is a
///     [ConfigConflict] when the operator edited it.
///   * Everything else is the editor's to decide, as before.
///
/// A null [baseline] is an editor with nothing to compare against, and the
/// wanted list is returned as it is — today's behaviour, for a caller that
/// has not adopted the baseline yet.
///
/// Content is compared by payload and parent, never by `sortIndex`: an
/// editor's items carry ordinals where stored rows carry gapped keys, and the
/// kinds this serves have no order to speak of.
List<ConfigItem> mergeItemsForSave({
  required List<ConfigItem> wanted,
  required List<ConfigItem> stored,
  required List<ConfigItem>? baseline,
}) {
  if (baseline == null) return wanted;

  final wantedByKey = {for (final item in wanted) _key(item): item};
  final storedByKey = {for (final item in stored) _key(item): item};
  final baseByKey = {for (final item in baseline) _key(item): item};

  final result = Map<String, ConfigItem>.of(wantedByKey);

  for (final entry in storedByKey.entries) {
    final key = entry.key;
    final theirs = entry.value;
    final ours = wantedByKey[key];
    final base = baseByKey[key];

    if (base == null) {
      // Added elsewhere since this editor loaded.
      if (ours == null) {
        result[key] = theirs;
        continue;
      }
      if (_sameContent(ours, theirs)) continue;
      throw ConfigConflict.created(theirs.id);
    }

    if (theirs.rev != base.rev) {
      // Changed elsewhere since this editor loaded.
      if (ours == null) throw ConfigConflict(theirs.id, expectedRev: base.rev);
      if (_sameContent(ours, base)) {
        result[key] = theirs;
        continue;
      }
      throw ConfigConflict(theirs.id, expectedRev: base.rev);
    }
    // Unmoved: the editor decides, and already has.
  }

  for (final entry in baseByKey.entries) {
    final key = entry.key;
    if (storedByKey.containsKey(key)) continue;
    final ours = wantedByKey[key];
    if (ours == null) continue; // Deleted on both sides.
    if (_sameContent(ours, entry.value)) {
      // Deleted elsewhere, untouched here: their delete stands.
      result.remove(key);
      continue;
    }
    throw ConfigConflict(entry.value.id, expectedRev: entry.value.rev);
  }

  return result.values.toList();
}

String _key(ConfigItem item) => '${item.kind.wireName} ${item.id}';

bool _sameContent(ConfigItem a, ConfigItem b) =>
    a.parentId == b.parentId && samePayload(a.payload, b.payload);
