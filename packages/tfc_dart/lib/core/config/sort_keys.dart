/// Gapped ordering keys: what a page's asset order is stored as, and why
/// dragging one asset is one row.
///
/// ## The wire format, decided here and nowhere else
///
/// - **Gap 1024**, first key 1024, keys **always positive**.
/// - Keys are **integers**. `config_item.sort_index` is `INTEGER` in the
///   Postgres DDL (`database_drift.dart`) — int4 — and [ConfigItem.sortIndex]
///   is `int?` all the way through the change-row wire format, so fractional
///   keys and LexoRank strings are foreclosed. The consequence worth stating:
///   there is no escape hatch when a gap runs out, so an exhausted gap
///   renumbers its parent **in the same call**, never later.
/// - A null key is legal and means "this kind is a set, not a list" — key
///   mappings and pages. Nulls sort last and are passed through untouched.
/// - Ties among equal input ordinals break on id, so two saves of the same
///   layout produce the same keys.
///
/// ## Ordinals in, keys out
///
/// The codecs emit `sortIndex` as a **rank**: 0..n-1 within a parent, rebuilt
/// from the asset list on every save, because that is what a `List<Asset>`
/// knows. This function reads those as rank only and rewrites them to stored
/// keys, changing as few as it can. That is the whole mechanism behind SC-1
/// and SC-2: an asset whose relative order did not change keeps the exact key
/// it had, so it is byte-identical to the snapshot, so
/// [ConfigItem.sameContentAs] says it did not change, so the diff never sees
/// it and the change log never mentions it.
///
/// With an empty `storedKeys` this degenerates to `(ordinal + 1) * kSortKeyGap`
/// — which is exactly what the blob→rows migration wants, so it calls this
/// with `{}` rather than copying the arithmetic.
library;

import 'config_item.dart';
import 'config_store.dart' show configSnapshotKey;

/// The distance between adjacent ordering keys.
///
/// Wide enough that a page of assets can be reordered for years without two
/// neighbours ever touching, small enough that 2^31 leaves room for two
/// million items under one parent.
const int kSortKeyGap = 1024;

/// [wanted]'s ordinals rewritten as stored ordering keys, changing as few as
/// possible.
///
/// [storedKeys] maps [configSnapshotKey] to the `sort_index` the store
/// currently holds — the store builds it from its own snapshot, so "as few as
/// possible" is measured against what is really in the database rather than
/// against what this process last wrote.
///
/// Items whose [ConfigItem.sortIndex] is null pass through untouched.
/// Grouping is per [ConfigItem.parentId]; groups never affect one another.
/// The returned list is in the caller's order — this assigns keys, it does not
/// sort.
///
/// Payloads are never rebuilt (C-6): a re-encoded payload would diff as an
/// edit on every save, which is precisely the noise this exists to remove.
List<ConfigItem> assignSortKeys(
  List<ConfigItem> wanted,
  Map<String, int> storedKeys,
) {
  // Position in `wanted` → the key that position ends up with. Filled per
  // group and applied once at the end, so the caller's order survives.
  final assigned = <int, int>{};

  final groups = <String?, List<int>>{};
  for (var i = 0; i < wanted.length; i++) {
    if (wanted[i].sortIndex == null) continue;
    groups.putIfAbsent(wanted[i].parentId, () => <int>[]).add(i);
  }

  for (final positions in groups.values) {
    // The wanted order: the ordinals are rank, and equal ranks break on id so
    // that the same layout saved twice produces the same keys.
    positions.sort((a, b) {
      final byOrdinal =
          wanted[a].sortIndex!.compareTo(wanted[b].sortIndex!);
      return byOrdinal != 0 ? byOrdinal : wanted[a].id.compareTo(wanted[b].id);
    });

    final current = [
      for (final position in positions)
        storedKeys[configSnapshotKey(wanted[position].kind,
            wanted[position].id)],
    ];

    // Which items may keep the key they already have: the longest run, in
    // wanted order, whose stored keys are already strictly increasing.
    //
    // The obvious cheaper rule — keep a key while it is bigger than the last
    // one kept — is wrong in the gesture the editor makes most: bringing the
    // last asset of a page to the front anchors on *its* key and then finds
    // every one of its 19 siblings too small, rewriting the whole page for one
    // drag. This picks the 19 instead, which is the difference between one
    // change row and twenty.
    final keep = _longestIncreasingRun(current);

    final keys = List<int?>.filled(positions.length, null);
    for (final index in keep) {
      keys[index] = current[index]!;
    }

    if (!_fillGaps(keys)) {
      // Somewhere there was no integer left between two neighbours, or nothing
      // left below the front. Renumber the whole group, now: the save in hand
      // is the one with nowhere to put its row, and deferring the rebalance
      // would mean refusing it.
      for (var i = 0; i < keys.length; i++) {
        keys[i] = (i + 1) * kSortKeyGap;
      }
    }

    for (var i = 0; i < positions.length; i++) {
      assigned[positions[i]] = keys[i]!;
    }
  }

  return [
    for (var i = 0; i < wanted.length; i++)
      if (assigned[i] case final key?)
        if (wanted[i].sortIndex == key) wanted[i] else _withKey(wanted[i], key)
      else
        wanted[i],
  ];
}

/// Assigns a key to every null slot in [keys], between the anchors around it.
///
/// Returns false when some run has no room — which is the caller's signal to
/// rebalance the group rather than to invent a key that is not strictly
/// between its neighbours.
bool _fillGaps(List<int?> keys) {
  var i = 0;
  while (i < keys.length) {
    if (keys[i] != null) {
      i++;
      continue;
    }
    var end = i;
    while (end < keys.length && keys[end] == null) {
      end++;
    }
    final count = end - i;
    final low = i == 0 ? null : keys[i - 1];
    final high = end == keys.length ? null : keys[end];

    if (low == null && high == null) {
      // Nothing anchored at all: the migration case, and a brand new parent.
      for (var j = 0; j < count; j++) {
        keys[i + j] = (j + 1) * kSortKeyGap;
      }
    } else if (low == null) {
      // Before the first anchor. Keys stay positive, so the room is `high - 1`
      // and there may not be enough of it.
      final step = _step(high! - 1, count);
      if (step == 0) return false;
      for (var j = 0; j < count; j++) {
        keys[i + j] = high - (count - j) * step;
      }
    } else if (high == null) {
      // After the last anchor: the append, and the only case with unbounded
      // room, so it always takes the full gap.
      for (var j = 0; j < count; j++) {
        keys[i + j] = low + (j + 1) * kSortKeyGap;
      }
    } else {
      final step = _step(high - low - 1, count);
      if (step == 0) return false;
      for (var j = 0; j < count; j++) {
        keys[i + j] = low + (j + 1) * step;
      }
    }
    i = end;
  }
  return true;
}

/// The spacing to use for [count] keys inside [room] integers: the full gap
/// when it fits, an even share when it does not, and zero when there is no
/// room at all.
int _step(int room, int count) {
  if (room < count) return 0;
  final even = room ~/ count;
  return even < kSortKeyGap ? even : kSortKeyGap;
}

/// The indices of a longest strictly-increasing subsequence of [values],
/// ignoring nulls (an item with no stored key can never be kept).
///
/// Patience sorting, O(n log n). The optimum matters here rather than being
/// gold-plating: every index this does *not* return is a row written and a
/// change row logged, so a cheaper heuristic is paid for in history noise on
/// every drag.
List<int> _longestIncreasingRun(List<int?> values) {
  // tails[k] = the index, in `values`, ending the best increasing run of
  // length k + 1 found so far.
  final tails = <int>[];
  final previous = List<int>.filled(values.length, -1);

  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value == null) continue;
    var lo = 0;
    var hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (values[tails[mid]]! < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    previous[i] = lo > 0 ? tails[lo - 1] : -1;
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }

  if (tails.isEmpty) return const [];
  final run = <int>[];
  for (var i = tails.last; i >= 0; i = previous[i]) {
    run.add(i);
  }
  return run.reversed.toList();
}

/// [item] with its ordering key replaced and everything else — payload
/// included, by reference — left alone.
ConfigItem _withKey(ConfigItem item, int key) => ConfigItem(
      kind: item.kind,
      id: item.id,
      payload: item.payload,
      scope: item.scope,
      parentId: item.parentId,
      sortIndex: key,
      rev: item.rev,
      updatedAt: item.updatedAt,
      updatedBy: item.updatedBy,
    );
