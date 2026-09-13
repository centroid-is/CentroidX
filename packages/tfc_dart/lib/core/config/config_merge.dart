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

/// The baseline an editor should hold **after** a save that went through
/// [mergeItemsForSave] (or `mergeForSave`), given what it wrote and what the
/// store holds now.
///
/// It is the editor's *view*, not the store's state. For every item the
/// editor holds: when the stored row now matches the editor's content, the
/// editor's version landed (or was already there) and the baseline takes the
/// stored row, new revision included; when it does not, the merge adopted
/// another station's version and the editor is still showing its own, so
/// the baseline keeps the entry it had — at the old revision, so the next
/// save sees "moved elsewhere, untouched here" and adopts theirs again
/// rather than "unmoved, the editor decides" and writing the old content
/// back over their edit. An item the editor holds that the store no longer
/// does is left off, and so is every stored row the editor does not hold:
/// those are the rows the merge kept from other stations, and a baseline
/// that named them would have the next save read their absence from the
/// editor as a deletion.
///
/// Refreshing the baseline from the store alone — every stored row at its
/// new revision — was what the first version did, and it was strictly worse
/// than not refreshing: the second save deleted what the first had kept.
List<ConfigItem> refreshedBaseline({
  required List<ConfigItem>? oldBaseline,
  required List<ConfigItem> editorWanted,
  required List<ConfigItem> storedNow,
}) {
  final old = {for (final item in oldBaseline ?? const <ConfigItem>[]) _key(item): item};
  final now = {for (final item in storedNow) _key(item): item};
  final result = <ConfigItem>[];
  for (final item in editorWanted) {
    final key = _key(item);
    final current = now[key];
    if (current == null) continue;
    if (_sameContent(item, current)) {
      result.add(current);
      continue;
    }
    final previous = old[key];
    if (previous != null) result.add(previous);
  }
  return result;
}

String _key(ConfigItem item) => '${item.kind.wireName} ${item.id}';

bool _sameContent(ConfigItem a, ConfigItem b) =>
    a.parentId == b.parentId && samePayload(a.payload, b.payload);
