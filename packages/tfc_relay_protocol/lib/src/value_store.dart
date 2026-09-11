/// The per-key value cache behind `StateManApi.listen(key)` — CONTEXT D-01's
/// primary read path.
///
/// Shaped by one measured scenario: 1500 keys on one page over a slow
/// connection. The alternative — 1500 broadcast `StreamController`s — pays an
/// allocation, a subscription and an event per key per update, and every
/// arriving batch wakes every widget whether its value moved or not. Here
/// there is one map, one wire subscription feeding it, and a batch applied
/// synchronously in a single loop: keys whose value did not change cost
/// nothing at all, so *k* changed keys mean *k* rebuilds, never *n* (CLI-06).
///
/// [ValueStore.applyBatch] exists as the entry point (rather than a per-key
/// setter) for two reasons: sequence bookkeeping and the gap check happen once
/// per batch instead of once per key, and a listener that does real work —
/// an alarm re-evaluation, a chart recompute — makes the per-key cost of a
/// 1500-key batch very visible, so the notification count is a property worth
/// testing (`test/value_store_test.dart`).
///
/// Pure state machine: no I/O, no clock. The sequence number is a parameter,
/// exactly as `ConflatingSendBuffer.poll(int nowMs)` takes its timestamp, so
/// every behavior is deterministic under test.
library;

import 'dynamic_value.dart';
import 'quality.dart';
import 'value_listenable.dart';

/// What a key reads as before any value has arrived, and again after a
/// [ValueStore.clear].
///
/// [Quality.uncertainNotYetKnown], not a good-quality zero — which renders as
/// a plausible reading for a tag that may not exist at all — and not
/// [Quality.errorConfig], which asserts the tag is *gone* and that waiting
/// will not help. On the slow link this store was shaped for, every key on a
/// page is in this state for the first round trip; labelling that a
/// configuration error would tell the operator to go fix a page that is fine,
/// and would teach them that the one non-transient error code heals on its
/// own. A key the source has affirmatively been told is gone is a different
/// fact, and carries [Quality.errorConfig].
final DynamicValue notYetKnown =
    DynamicValue(value: null, quality: Quality.uncertainNotYetKnown);

/// One key's cached value and its listeners.
///
/// Handed to widgets as a [ValueListenable]; Phase 4's builder listens to it
/// directly, with no adapter object per key.
final class ValueStoreNode implements ValueListenable<DynamicValue> {
  /// The key this node caches, carried for diagnostics and log lines.
  final String key;

  DynamicValue? _value;
  final _listeners = <VoidCallback>[];

  ValueStoreNode(this.key);

  /// The cached value, or [notYetKnown] when none has arrived. Never throws:
  /// reading is what a widget does during a build.
  @override
  DynamicValue get value => _value ?? notYetKnown;

  /// Null until a value has actually arrived — distinguishing "not known" from
  /// "known to be bad", which [value] cannot express on its own.
  DynamicValue? get cached => _value;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Removes one registration. Removing a listener that was never added is a
  /// no-op, so teardown paths need no bookkeeping.
  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// Assigns and notifies only on a genuine change.
  ///
  /// The [identical] check first: a re-sent object graph must not pay for a
  /// deep structural compare. Then `==`, which is why [DynamicValue] is
  /// immutable with structural equality — that guard is the whole k-of-n
  /// property.
  void _set(DynamicValue next) {
    final current = _value;
    if (identical(current, next)) return;
    if (current != null && current == next) return;
    _value = next;
    _notify();
  }

  /// Forgets the cached value. Notifying only when there was one keeps
  /// `clear()` on an untouched page free.
  void _forget() {
    if (_value == null) return;
    _value = null;
    _notify();
  }

  /// Iterates a copy: a listener is allowed to remove itself (a widget
  /// disposing during a rebuild), and that must not make the run skip the
  /// next listener.
  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// How many listeners are attached right now.
  ///
  /// An **observation surface for teardown assertions**, and it exists because
  /// the alternative is worse. "The session detached everything it attached"
  /// is a property of the *source*, not of the session's own bookkeeping — a
  /// session that emptied its own listener map while leaving the callbacks on
  /// the node would satisfy every count it kept about itself and still hold a
  /// dead panel's values flowing into a buffer nobody will drain. The relay's
  /// kill-cycle test (`teardown_test.dart`) reads this, because this is the
  /// only place the truth lives.
  ///
  /// Read-only by construction: exposing the list would let an inspection
  /// become a mutation, and a teardown test that could detach the listeners it
  /// is counting is not a test.
  int get listenerCount => _listeners.length;

  void _dropListeners() => _listeners.clear();

  @override
  String toString() => 'ValueStoreNode($key: ${_value ?? 'not yet known'})';
}

/// The outcome of applying one batch. Sealed so a new verdict breaks every
/// switch that handles them.
sealed class BatchVerdict {
  const BatchVerdict();
}

/// Applied, and the sequence is intact.
final class BatchOk extends BatchVerdict {
  const BatchOk();
}

/// A batch was lost: the cache may no longer match the server, so the client
/// resyncs with a snapshot rather than trusting a delta chain (CLI-03).
/// Reported once for the whole batch; the values in hand are still applied,
/// because they are newer than what was cached.
///
/// A batch arriving *behind* the sequence is [BatchReplay], not this — its
/// values are older than what is cached and are not applied at all.
final class BatchSeqGap extends BatchVerdict {
  /// The sequence number this batch should have carried.
  final int expected;

  /// The sequence number it actually carried.
  final int received;

  const BatchSeqGap({required this.expected, required this.received});

  @override
  String toString() => 'BatchSeqGap(expected: $expected, received: $received)';
}

/// A re-delivery: this batch's sequence is one already applied. Its values are
/// older than what is cached, so they are **discarded** — applying them would
/// put a reading from two batches ago on the mimic under good quality, which
/// is the F18 old-epoch/old-seq rule.
///
/// Still a verdict rather than silence: a duplicate on the wire means the
/// stream is not behaving, and the client resyncs on it exactly as it does on
/// [BatchSeqGap].
final class BatchReplay extends BatchVerdict {
  /// The highest sequence number already applied.
  final int lastApplied;

  /// The sequence number this batch carried.
  final int received;

  const BatchReplay({required this.lastApplied, required this.received});

  @override
  String toString() =>
      'BatchReplay(lastApplied: $lastApplied, received: $received)';
}

/// Keys to nodes, plus the sequence bookkeeping for the stream feeding them.
final class ValueStore {
  final _nodes = <String, ValueStoreNode>{};
  int? _lastSeq;

  /// The node for [key], created on first use. Always the same instance for
  /// the same key — a widget holds the node it was handed.
  ValueStoreNode node(String key) =>
      _nodes.putIfAbsent(key, () => ValueStoreNode(key));

  /// The cached value for [key], or null when nothing has arrived for it.
  DynamicValue? peek(String key) => _nodes[key]?.cached;

  /// Every key the store holds a node for, whether or not a value has arrived
  /// for it, in first-touch order.
  List<String> get keys => _nodes.keys.toList(growable: false);

  /// Evaluates the sequence, then applies [changes] in one synchronous loop.
  ///
  /// The sequence is judged *first* because a batch that is not newer than
  /// what has already been applied must not be applied at all: its values are
  /// stale, and writing them would put an old reading on screen under good
  /// quality with only a verdict — which the caller may or may not act on — to
  /// say so.
  ///
  /// Only keys whose value genuinely changed notify. Pass [seq] when the batch
  /// is part of a numbered stream; omit it for out-of-band applications
  /// (a snapshot, a local write echo), which never disturb the bookkeeping.
  BatchVerdict applyBatch(Map<String, DynamicValue> changes, {int? seq}) {
    final last = _lastSeq;
    if (seq != null && last != null && seq <= last) {
      // A re-delivery. Never rewind _lastSeq either: doing so would turn the
      // next legitimate batch into a second, false gap.
      return BatchReplay(lastApplied: last, received: seq);
    }

    for (final entry in changes.entries) {
      node(entry.key)._set(entry.value);
    }

    if (seq == null) return const BatchOk();

    // First numbered batch of the stream sets the baseline; it is not a gap.
    final expected = last == null ? seq : last + 1;
    _lastSeq = seq;
    return seq == expected
        ? const BatchOk()
        : BatchSeqGap(expected: expected, received: seq);
  }

  /// Discards the cache — the resync path, since recovery is always a
  /// snapshot and never a delta replay.
  ///
  /// Nodes survive: orphaning them would take every listening widget dark for
  /// the rest of the session. Keys that held a value notify, because a screen
  /// showing a number must learn that the number is no longer known. Sequence
  /// bookkeeping resets, so a server numbering from scratch is not a gap.
  void clear() {
    for (final node in _nodes.values) {
      node._forget();
    }
    _lastSeq = null;
  }

  /// Teardown: every listener is dropped, so nothing can be notified again.
  /// Nodes and cached values remain readable — a widget mid-dispose may still
  /// read a value it already holds.
  void dispose() {
    for (final node in _nodes.values) {
      node._dropListeners();
    }
  }
}
