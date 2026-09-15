/// The two ways a data-service implementation is wrong about something nobody
/// looks at twice.
///
/// `broken_write.dart` collects implementations that lie about what they did to
/// the plant. These are quieter. Neither loses a value, neither throws, neither
/// shows a wrong number: one hands the page editor a pre-selection that points
/// at the wrong node, and the other stores every preference correctly and
/// simply never mentions it. Both would pass a review, and both have shipped —
/// a browse source whose `resolvePath` was written against the parent chain
/// because that is what the tree walk naturally produces, and a preferences
/// backend whose change stream was declared, wired to nothing, and never
/// noticed because the page that reads it also writes it.
///
/// Each class replaces exactly one behavior of [FakeStateMan] and inherits the
/// rest, so `test/sabotage_browse_test.dart` can assert both halves of a
/// sabotage — the targeted check fails, and unrelated ones still pass. A
/// variant that failed everything would prove nothing about any individual
/// check.
///
/// Both break their sub-API by *wrapping* it rather than by replacing it. The
/// getters on [FakeStateMan] return interface types precisely so this is
/// possible: a variant delegates every honest method to the real
/// implementation and overrides the one it is here to damage, which is what
/// keeps "the sabotage is surgical" true rather than merely claimed.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// Resolves a binding to the chain of its *parent*, stopping one node short.
///
/// The most plausible browse bug there is, because it is what a tree walk
/// produces if you assemble the path on the way down and return before
/// appending the node you stopped at — an off-by-one in a recursion, not a
/// misunderstanding. Every other browse behavior is untouched: roots list,
/// folders expand, details describe, and a stale binding still degrades to
/// null. Only the pre-selection is wrong.
///
/// What it costs: the page editor opens the browse panel on a widget that is
/// already bound and highlights the folder containing the tag instead of the
/// tag. The engineer sees a selection that looks deliberate — something *is*
/// highlighted, in the right part of the tree — and binds it. The widget now
/// reads a folder, or the wrong sibling, and nothing about the screen says so
/// until somebody presses it.
///
/// This is T-09-01: a resolve chain pointing at the wrong node is a tampering
/// threat against what an engineer binds, and it is the reason
/// [checkResolvePathReturnsRootToLeafChain] asserts the last entry rather than
/// trusting the list to be a path.
class ChainMissesTheTarget extends FakeStateMan {
  ChainMissesTheTarget({super.staleAfter});

  _ParentChainBrowse? _truncating;

  @override
  BrowseApi get browse => _truncating ??= _ParentChainBrowse(super.browse);
}

/// Everything honest except the last entry of a resolved chain.
class _ParentChainBrowse implements BrowseApi {
  _ParentChainBrowse(this._honest);

  final BrowseApi _honest;

  @override
  Future<List<BrowseNode>> fetchRoots() => _honest.fetchRoots();

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) =>
      _honest.fetchChildren(parent);

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) =>
      _honest.fetchDetail(node);

  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    final chain = await _honest.resolvePath(targetId);
    // Null still means null: a stale binding degrades honestly, which is what
    // makes this variant surgical and what makes the bug survive review.
    if (chain == null || chain.length < 2) return chain;
    // The off-by-one. The chain is still a real path through the tree, still
    // ordered root-first, still expandable at every step — it just stops at
    // the parent, so the panel highlights the folder and not the tag.
    return chain.sublist(0, chain.length - 1);
  }
}

/// Stores every preference correctly and tells nobody.
///
/// A change stream that was declared and never wired. It is the easiest of all
/// these bugs to ship, because the page that writes a preference usually also
/// holds the value it wrote: the developer sees the setting take effect
/// immediately and concludes the notification works. It only fails with a
/// *second* listener — a second widget, a second page, or, over the pipe, a
/// second operator.
///
/// What it costs (DB-03): two operators have the same settings page open on one
/// site. One saves; the other's form never hears about it and goes on holding
/// values that are now stale. When the second one saves — a form they never
/// edited, from a page they left open — they overwrite the first one's change
/// with what the store held ten minutes ago.
///
/// The stream is **silent, not closed**, and the distinction is the whole point
/// of this variant. A closed stream ends, and a check awaiting its first event
/// gets an error it can name straight away. Silence is nothing at all: without
/// a deadline the check waits for the runner's 30-second timeout and reports a
/// file name instead of the property. This is T-09-05, and it is the case
/// [within] exists for — `test/sabotage_browse_test.dart` measures how long it
/// actually takes to fail and prints it, so the claim stays a number rather
/// than a belief.
class PrefsChangeNeverNotifies extends FakeStateMan {
  PrefsChangeNeverNotifies({super.staleAfter});

  _SilentPreferences? _silent;

  @override
  PreferencesApi get preferences =>
      _silent ??= _SilentPreferences(super.preferences);

  /// Closes the silent stream after the source is disposed.
  ///
  /// A broadcast controller nobody closes outlives the case that made it, and
  /// a leak here would surface as an inexplicable hang in a later test rather
  /// than as anything to do with this variant.
  @override
  Future<void> dispose() async {
    await super.dispose();
    await _silent?.dispose();
  }
}

/// Every preference operation, honestly performed, and never announced.
class _SilentPreferences implements PreferencesApi {
  _SilentPreferences(this._honest);

  final PreferencesApi _honest;

  /// A stream that is open and empty. Never closed while the source lives, so
  /// a listener waits rather than being told the news is over.
  final _silence = StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _silence.stream;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _honest.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _honest.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _honest.getBool(key);

  @override
  Future<int?> getInt(String key) => _honest.getInt(key);

  @override
  Future<double?> getDouble(String key) => _honest.getDouble(key);

  @override
  Future<String?> getString(String key) => _honest.getString(key);

  @override
  Future<List<String>?> getStringList(String key) =>
      _honest.getStringList(key);

  @override
  Future<bool> containsKey(String key) => _honest.containsKey(key);

  @override
  Future<void> setBool(String key, bool value) => _honest.setBool(key, value);

  @override
  Future<void> setInt(String key, int value) => _honest.setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _honest.setDouble(key, value);

  @override
  Future<void> setString(String key, String value) =>
      _honest.setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _honest.setStringList(key, value);

  @override
  Future<void> remove(String key) => _honest.remove(key);

  @override
  Future<void> clear({Set<String>? allowList}) =>
      _honest.clear(allowList: allowList);

  Future<void> dispose() async {
    if (_silence.isClosed) return;
    await _silence.close();
  }
}
