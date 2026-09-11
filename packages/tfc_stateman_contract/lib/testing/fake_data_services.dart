/// In-memory reference implementations of the four data-service sub-APIs.
///
/// Each of these is a real implementation of its interface, not a mock: the
/// browse tree is walked, the window filter and the downsample are computed,
/// the view delete cascades, the change stream is a real broadcast controller.
/// They exist to prove the contract cases in `browse_contract.dart` and
/// `data_services_contract.dart` are satisfiable before any production code
/// exists, and to be the honest baseline the deliberately damaged variants in
/// `broken_browse.dart` are measured against.
///
/// **Phase 10 replaces every one of them with a database-backed
/// implementation** (DB-01..DB-04): the timeseries and history-view services
/// with TimescaleDB behind them, the preferences service with the site's
/// preference store and a change stream that carries another client's edits.
/// What must survive that replacement is the contract, not this code — so
/// nothing here should grow a behavior the contract does not ask for, because
/// a behavior nobody wrote a case for is one the database will silently fail to
/// reproduce.
///
/// They live under `lib/testing/` for the same reason `fake_state_man.dart`
/// does: the server and client packages import them, and a Phase 3 test that
/// needs a browsable tree should not have to build one.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

// ---------------------------------------------------------------- browse

/// A browsable address space, held as a seeded tree.
///
/// The important design decision is that [resolvePath] is **derived** by
/// walking the same tree the other three methods serve, rather than being a
/// second hand-written table of chains. A hand-written chain can disagree with
/// the tree — that is precisely the bug `ChainMissesTheTarget` imitates — so a
/// fake that hard-coded its answers could not honestly demonstrate that the two
/// agree. Here the chain is correct by construction: it is assembled from the
/// path the walk actually took, so root → … → leaf ordering and "each entry is
/// the parent of the next" hold for any tree it is given, including a tree a
/// later caller seeds itself.
///
/// The default tree is the plant-realistic one the contract's
/// `defaultBrowseFixture` names: two stations in the SVN tag convention
/// (`AREAnn.DEVnn.SUBnn`), one motor on each side of the freezer, and one
/// method node — the single node kind that must not offer a disclosure
/// triangle.
class FakeBrowse implements BrowseApi {
  FakeBrowse({
    List<BrowseNode>? roots,
    Map<String, List<BrowseNode>>? children,
    Map<String, BrowseNodeDetail>? details,
  })  : _roots = roots ?? defaultRoots,
        _children = children ?? defaultChildren,
        _details = details ?? defaultDetails;

  final List<BrowseNode> _roots;
  final Map<String, List<BrowseNode>> _children;
  final Map<String, BrowseNodeDetail> _details;

  /// The two stations at the top of the default address space.
  static const defaultRoots = <BrowseNode>[
    BrowseNode(
        id: 'ST101',
        displayName: 'ST101 — snyrtilína (pre-freezer)',
        type: BrowseNodeType.folder),
    BrowseNode(
        id: 'ST201',
        displayName: 'ST201 — pökkun (post-freezer)',
        type: BrowseNodeType.folder),
  ];

  /// One level per entry, exactly as the panel expands them.
  static const defaultChildren = <String, List<BrowseNode>>{
    'ST101': [
      BrowseNode(
          id: 'ST101.CN01',
          displayName: 'CN01 — færiband 1',
          type: BrowseNodeType.folder),
      BrowseNode(
          id: 'ST101.CN02',
          displayName: 'CN02 — færiband 2',
          type: BrowseNodeType.folder),
    ],
    'ST101.CN01': [
      BrowseNode(
          id: 'ST101.CN01.MOT01',
          displayName: 'MOT01 — mótor',
          type: BrowseNodeType.folder),
      BrowseNode(
          id: 'ST101.CN01.SEN01',
          displayName: 'SEN01 — nemi',
          type: BrowseNodeType.variable,
          dataType: 'Boolean'),
    ],
    'ST101.CN01.MOT01': [
      BrowseNode(
          id: 'ST101.CN01.MOT01.setpoint',
          displayName: 'setpoint',
          type: BrowseNodeType.variable,
          dataType: 'Float',
          description: 'Hraði færibands 1, mm/s'),
      BrowseNode(
          id: 'ST101.CN01.MOT01.running',
          displayName: 'running',
          type: BrowseNodeType.variable,
          dataType: 'Boolean'),
      // The one node that must not be expandable. A method is a callable on
      // the server with no children, and a disclosure triangle next to it
      // invites a click that can only ever open an empty level.
      BrowseNode(
          id: 'ST101.CN01.MOT01.reset',
          displayName: 'reset()',
          type: BrowseNodeType.method),
    ],
    'ST101.CN02': [
      BrowseNode(
          id: 'ST101.CN02.SEN01',
          displayName: 'SEN01 — nemi',
          type: BrowseNodeType.variable,
          dataType: 'Boolean'),
    ],
    'ST201': [
      BrowseNode(
          id: 'ST201.CN04',
          displayName: 'CN04 — færiband 4',
          type: BrowseNodeType.folder),
    ],
    'ST201.CN04': [
      BrowseNode(
          id: 'ST201.CN04.MOT01',
          displayName: 'MOT01 — mótor',
          type: BrowseNodeType.folder),
    ],
    // A second populated folder, elsewhere in the tree, whose children share no
    // id with the first one's. That disjointness is what lets a contract case
    // prove fetchChildren reads its argument instead of serving one canned
    // level for every parent.
    'ST201.CN04.MOT01': [
      BrowseNode(
          id: 'ST201.CN04.MOT01.setpoint',
          displayName: 'setpoint',
          type: BrowseNodeType.variable,
          dataType: 'Float'),
      BrowseNode(
          id: 'ST201.CN04.MOT01.running',
          displayName: 'running',
          type: BrowseNodeType.variable,
          dataType: 'Boolean'),
    ],
  };

  /// Details for the nodes a reading is known for.
  ///
  /// Not `const`, because [DynamicValue]'s public constructor is a sanitizing
  /// factory — the same one that keeps a non-finite reading away from
  /// `jsonEncode` — and a factory cannot be const.
  static final defaultDetails = <String, BrowseNodeDetail>{
    'ST101.CN01.MOT01.setpoint': BrowseNodeDetail(
      description: 'Hraði færibands 1, mm/s',
      dataType: 'Float',
      value: DynamicValue(value: 1450.0),
    ),
    'ST101.CN01.MOT01.running': BrowseNodeDetail(
      description: 'Keyrir mótorinn?',
      dataType: 'Boolean',
      value: DynamicValue(value: true),
    ),
  };

  @override
  Future<List<BrowseNode>> fetchRoots() async => List.of(_roots);

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async =>
      List.of(_children[parent.id] ?? const <BrowseNode>[]);

  /// The seeded detail, or one derived from the node itself.
  ///
  /// The fallback carries the node's own description and data type rather than
  /// an empty record: those two fields travel with every node in the tree
  /// already, and a detail pane that blanked them for want of a seeded entry
  /// would look like a source that knows nothing about a tag it just listed.
  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async =>
      _details[node.id] ??
      BrowseNodeDetail(
        description: node.description,
        dataType: node.dataType,
        structChildren: _children[node.id] == null || !node.isVariable
            ? null
            : List.of(_children[node.id]!),
      );

  /// The chain from a root to [targetId], or null when nothing matches.
  ///
  /// Null rather than an empty list, and never a throw: a page saved last year
  /// against a tag since renamed in the PLC is the ordinary case, and it must
  /// degrade to "no pre-selection" rather than take the panel down.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    for (final root in _roots) {
      final chain = _pathTo(root, targetId, <String>{});
      if (chain != null) return chain;
    }
    return null;
  }

  /// Depth-first, returning the path taken rather than just the node found.
  ///
  /// [seen] guards against a seeded tree that contains a cycle — a caller can
  /// pass any `children` map, including one that points back up. In a genuine
  /// tree it prunes nothing, because there is only ever one path to a node.
  List<BrowseNode>? _pathTo(BrowseNode node, String targetId, Set<String> seen) {
    if (node.id == targetId) return [node];
    if (!seen.add(node.id)) return null;
    for (final child in _children[node.id] ?? const <BrowseNode>[]) {
      final rest = _pathTo(child, targetId, seen);
      if (rest != null) return [node, ...rest];
    }
    return null;
  }
}

// ------------------------------------------------------------ timeseries

/// Recorded samples, held per table and kept in time order.
///
/// There is deliberately no way to record a sample through [TimeseriesApi] —
/// [seed] is the test-only lever, and its absence from the wire is a security
/// property, not an oversight: a client that could insert history could forge
/// it, and a chart is evidence.
class FakeTimeseries implements TimeseriesApi {
  final _tables = <String, List<TimeseriesData>>{};

  /// Records [points] against [tableName], as the gateway's recorder would.
  ///
  /// Sorted on the way in, so the ordering promise is a property of the store
  /// rather than of the order a test happened to seed in.
  void seed(String tableName, List<TimeseriesData> points) {
    (_tables[tableName] ??= <TimeseriesData>[])
      ..addAll(points)
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    final window = _window(tableName, from, to);
    return _descending(orderBy) ? window.reversed.toList() : window;
  }

  /// An entry for **every** requested table, including the ones with nothing
  /// recorded.
  ///
  /// The empty list is the point. A chart that iterates the names it asked for
  /// and finds no entry drops the series from its legend, which an operator
  /// reads as "this tag is flat" rather than as "nothing was recorded".
  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    final answers = <String, List<TimeseriesData>>{};
    for (final name in tableNames) {
      answers[name] =
          await queryTimeseriesData(name, to, orderBy: orderBy, from: from);
    }
    return answers;
  }

  /// Even selection across the window, both endpoints kept.
  ///
  /// Keeping the ends is what stops the bound being satisfied dishonestly:
  /// returning the first `maxPoints` samples respects the count and truncates
  /// the chart to the beginning of the window. The newest sample especially —
  /// an operator reads the right-hand end of a chart as "now".
  ///
  /// Which samples are chosen *between* the ends is Phase 10's question (a real
  /// downsampler averages or picks extrema per bucket, in the database, where
  /// the data is). Even selection is the simplest thing that satisfies the
  /// contract, and it is deliberately no cleverer than that.
  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    if (maxPoints <= 0) return const [];
    final window = _window(tableName, from, to);
    if (window.length <= maxPoints) return window;
    if (maxPoints == 1) return [window.last];
    final step = (window.length - 1) / (maxPoints - 1);
    return [
      for (var i = 0; i < maxPoints; i++) window[(i * step).round()],
    ];
  }

  /// Everything recorded in `[from, to]`, inclusive at both ends.
  List<TimeseriesData> _window(String tableName, DateTime? from, DateTime to) =>
      [
        for (final point in _tables[tableName] ?? const <TimeseriesData>[])
          if (!point.time.isAfter(to) &&
              (from == null || !point.time.isBefore(from)))
            point,
      ];

  /// The `orderBy` string is SQL-shaped because the signature is verbatim from
  /// the working code; only its direction is honoured here.
  static bool _descending(String? orderBy) =>
      orderBy != null && orderBy.toUpperCase().contains('DESC');
}

// --------------------------------------------------------- history views

/// Saved history views, their keys, graphs and time windows.
///
/// Ids increase and are never reused, which is what makes a stale id a miss
/// rather than a hit on somebody else's view.
class FakeHistoryViews implements HistoryViewApi {
  final _views = <int, HistoryViewRecord>{};
  final _keys = <int, Map<String, HistoryViewKeyRecord>>{};
  final _graphs = <int, Map<int, HistoryViewGraphRecord>>{};
  final _periods = <int, HistoryViewPeriodRecord>{};

  var _nextViewId = 1;
  var _nextPeriodId = 1;
  DateTime? _retentionHorizon;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) async {
    final id = _nextViewId++;
    _views[id] = HistoryViewRecord(id: id, name: name, createdAt: _now());
    _recordConfiguration(id, keys, keyConfigs, graphConfigs);
    return id;
  }

  /// Replaces name, keys and configuration; keeps `createdAt` and stamps
  /// `updatedAt`, which is the distinction the view picker sorts and labels by.
  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) async {
    final existing = _views[id];
    if (existing == null) return;
    _views[id] = HistoryViewRecord(
      id: id,
      name: name,
      createdAt: existing.createdAt,
      updatedAt: _now(),
    );
    _recordConfiguration(id, keys, keyConfigs, graphConfigs);
  }

  /// Deletes the view and everything recorded against it.
  ///
  /// The cascade is the behavior the database layer spells out by hand today
  /// rather than trusting to a foreign key, reproduced here because the
  /// contract asks for it. Rows that outlive their view are how a deleted view
  /// comes back as a partial one after the next restart.
  @override
  Future<void> deleteHistoryView(int id) async {
    _views.remove(id);
    _keys.remove(id);
    _graphs.remove(id);
    _periods.removeWhere((_, period) => period.viewId == id);
  }

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() async =>
      _views.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(
          int viewId) async =>
      {...?_keys[viewId]};

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(
          int viewId) async =>
      {...?_graphs[viewId]};

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async =>
      (_keys[viewId] ?? const <String, HistoryViewKeyRecord>{}).keys.toList();

  @override
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) async {
    final id = _nextPeriodId++;
    _periods[id] = HistoryViewPeriodRecord(
      id: id,
      viewId: viewId,
      name: name,
      startAt: _utc(start),
      endAt: _utc(end),
      createdAt: _now(),
    );
    return id;
  }

  @override
  Future<void> deleteHistoryViewPeriod(int id) async {
    _periods.remove(id);
  }

  /// Every saved window on [viewId], oldest first — by the window's own start,
  /// which is the order an operator scanning a shift list reads them in.
  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(
          int viewId) async =>
      [
        for (final period in _periods.values)
          if (period.viewId == viewId) period,
      ]..sort((a, b) {
          final byStart = a.startAt.compareTo(b.startAt);
          return byStart != 0 ? byStart : a.id.compareTo(b.id);
        });

  /// Null until something has actually been discarded.
  ///
  /// Null is the honest default for an in-memory store that never drops
  /// anything, and the distinction matters downstream: a chart scrolling past a
  /// known horizon is showing absence of data, while one scrolling past an
  /// unknown one knows nothing either way and must not claim otherwise.
  @override
  Future<DateTime?> getGlobalRetentionHorizon() async => _retentionHorizon;

  /// Test lever: the oldest instant any series is still retained for.
  void setRetentionHorizon(DateTime? horizon) =>
      _retentionHorizon = horizon == null ? null : _utc(horizon);

  void _recordConfiguration(
    int id,
    List<String> keys,
    Map<String, HistoryViewKeyRecord>? keyConfigs,
    Map<int, HistoryViewGraphRecord>? graphConfigs,
  ) {
    _keys[id] = {
      // A key with no configuration still gets a record, and the record's own
      // constructor defaults its alias to the key name — the `row.alias ??
      // row.key` the database layer does today, kept where the record is built
      // so no call site has to remember it.
      for (final key in keys) key: keyConfigs?[key] ?? HistoryViewKeyRecord(key: key),
    };
    _graphs[id] = {...?graphConfigs};
  }

  static DateTime _now() => _utc(DateTime.now());

  /// UTC at millisecond precision — the wire's one timestamp convention, so a
  /// record that has been through JSON is `==` to the one that went in.
  static DateTime _utc(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
      time.millisecondsSinceEpoch,
      isUtc: true);
}

// ---------------------------------------------------------- preferences

/// Stored preferences with a real change stream.
///
/// Broadcast, not single-subscription, and that is a contract property rather
/// than a convenience: a settings page and a chart legend both listen, and over
/// a pipe with several clients on one site the change stream is how the second
/// operator's edit reaches the first one's open form (DB-03). A single
/// subscriber would hand the second listener an exception instead of the news.
///
/// **No secret material passes through here** (SEC-01, T-09-02). The interface
/// mirrored has no `secret:` parameter — `api_surface_test.dart` fails if one
/// ever appears — so there is no route from this store to the secure store, and
/// nothing seeded in this file is a credential.
class FakePreferences implements PreferencesApi {
  final _values = <String, Object?>{};
  final _changes = StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async => {
        for (final key in _values.keys)
          if (allowList == null || allowList.contains(key)) key,
      };

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async => {
        for (final entry in _values.entries)
          if (allowList == null || allowList.contains(entry.key))
            entry.key: entry.value,
      };

  // The typed getters cast rather than test-and-return-null, which is the
  // documented behavior of the interface being mirrored: a key holding another
  // type is a programming error worth a TypeError, not a silent null that
  // renders as a default and hides the mismatch.

  @override
  Future<bool?> getBool(String key) async => _values[key] as bool?;

  @override
  Future<int?> getInt(String key) async => _values[key] as int?;

  @override
  Future<double?> getDouble(String key) async => _values[key] as double?;

  @override
  Future<String?> getString(String key) async => _values[key] as String?;

  @override
  Future<List<String>?> getStringList(String key) async {
    final stored = _values[key] as List<String>?;
    // A copy on the way out as well as in: a caller that mutates what it read
    // must not be editing the store through the back door.
    return stored == null ? null : List<String>.of(stored);
  }

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<void> setBool(String key, bool value) async => _set(key, value);

  @override
  Future<void> setInt(String key, int value) async => _set(key, value);

  @override
  Future<void> setDouble(String key, double value) async => _set(key, value);

  @override
  Future<void> setString(String key, String value) async => _set(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      _set(key, List<String>.of(value));

  @override
  Future<void> remove(String key) async {
    if (!_values.containsKey(key)) return;
    _values.remove(key);
    _announce(key);
  }

  /// Clears everything, or everything in [allowList].
  ///
  /// One announcement per key removed, not one for the clear: a listener
  /// filtering for the key it cares about would miss a bare "something
  /// changed", and that listener is a settings page holding a form.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    final removed = [
      for (final key in _values.keys)
        if (allowList == null || allowList.contains(key)) key,
    ];
    for (final key in removed) {
      _values.remove(key);
      _announce(key);
    }
  }

  /// Closes the change stream. Idempotent, and safe to call twice.
  Future<void> dispose() async {
    if (_changes.isClosed) return;
    await _changes.close();
  }

  void _set(String key, Object? value) {
    _values[key] = value;
    _announce(key);
  }

  /// Emits on every write, including one that stores the value already there.
  ///
  /// Deliberately not conditional on the value having changed. A preference
  /// write is a person pressing save, it happens at human frequency, and a
  /// listener that redraws once too often costs nothing — where a listener that
  /// misses an edit because two clients converged on the same value shows a
  /// form the operator has to reopen to trust.
  void _announce(String key) {
    if (_changes.isClosed) return;
    _changes.add(key);
  }
}
