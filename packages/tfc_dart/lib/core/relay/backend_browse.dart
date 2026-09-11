/// `BrowseApi` over the key mappings the backend already holds.
///
/// ## Why the mappings and not the plant
///
/// 13-CONTEXT settles this: browse *"is answered from the key mappings main
/// already holds, not by reaching into a worker — a browse that stalls is the
/// failure mode this phase exists to prevent"*. Every answer below is a lookup
/// in a map built once in the constructor and handed back inside an
/// already-completed Future. No method here awaits anything, arms anything, or
/// speaks to a link. A PLC that has stopped answering cannot make the key
/// picker spin, because the key picker never asks it.
///
/// The alternative 13-CONTEXT permits — a genuine upstream browse sent down the
/// pipe with a deadline, the way a write goes — was rejected. See the
/// method-node note below for what it would have bought and what it costs.
///
/// ## The address space is the dotted key namespace
///
/// `ST101.CN01.MOT01.setpoint` is a station, a conveyor, a motor and a tag, and
/// the SVN tag convention (`AREAnn.DEVnn.SUBnn`) means that is true of every
/// key in the plant. So the tree is the prefix tree of the mapped keys:
///
///  * a segment path that is **itself a mapped key** is a variable — the thing
///    an engineer binds. It stays a variable even when other keys nest below
///    it, because a struct an engineer binds whole is still bindable and typing
///    it as a folder would take the tag out of the picker entirely;
///  * a segment path that is **only a prefix** is a folder;
///  * a mapped key named in [BackendBrowse.methodKeys] is a method.
///
/// Folders and variables expand (a structured tag has members and an engineer
/// binds one). Methods do not.
///
/// ## The method-node decision
///
/// **A key mapping declares no callables.** `KeyMappingEntry` carries an OPC UA
/// node, an M2400 record, a Modbus register, a collect entry, a bit mask and a
/// UMAS variable name — and nothing anywhere in the format says "this is a
/// method you can call". A mapping-backed tree therefore *cannot* produce a
/// `BrowseNodeType.method` from the mapping alone, however it is written.
///
/// So the callables are **declared**, at the composition root, through
/// [methodKeys]. Production passes none today, which is a true statement about
/// SVN's address space (no panel calls an OPC UA method) and is visible in
/// `bin/main.dart` rather than hidden in a defaulted branch here. A deployment
/// that grows one adds a key to a set at the place a human reviews.
///
/// The rejected alternative was an upstream browse down the pipe with a
/// deadline, which would learn node classes from the server itself. It buys
/// method nodes and unmapped tags; it costs a browse call that can time out,
/// on the one surface where a stall is worst — the panel is modal and the
/// engineer cannot do anything else while it spins. The trigger that would
/// change the answer is a deployment that needs to *call* an OPC UA method from
/// a panel: at that point a declared set is no longer enough, because the panel
/// needs the method's arguments too, and those only exist upstream.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../collector.dart' show collectTableName;
import '../state_man.dart' show KeyMappingEntry, KeyMappings;

/// The metadata key a node's owning server alias is stored under.
///
/// Two stations carry identically named motors, so "which PLC is this" is the
/// one annotation worth the bytes on every node in a level.
const String browseServerKey = 'server';

/// One node of the prefix tree, with its level already built.
///
/// Both the [BrowseNode] and the children list are built once and handed out
/// by reference. That is not a micro-optimisation: `fetchChildren` is called
/// once per disclosure triangle, and rebuilding the level would make every
/// triangle an O(mapped keys) walk over the whole plant.
final class _Node {
  _Node(this.id, this.parentId);

  final String id;
  final String? parentId;
  final List<_Node> childNodes = <_Node>[];

  /// Set once, after the whole tree is known: a node's type depends on whether
  /// it is a mapped key, which is known immediately, but its children are not.
  late final relay.BrowseNode node;
  late final List<relay.BrowseNode> children;
}

/// `BrowseApi` answered from [KeyMappings], synchronously, forever.
final class BackendBrowse implements relay.BrowseApi {
  /// Builds the whole address space now, so no call later has to.
  ///
  /// [readValue] is a plain function rather than a `BackendValueSource` on
  /// purpose: this file must not depend on 13-03's, so the two can land in the
  /// same wave. The composition root passes `values.read`.
  ///
  /// [methodKeys] is the declared callable set — see the method-node decision
  /// in this library's doc. Empty is the honest production answer, and it is
  /// the default so that a caller who has not thought about it gets the
  /// truthful tree rather than a guess.
  BackendBrowse({
    required KeyMappings keyMappings,
    relay.DynamicValue? Function(String key)? readValue,
    Set<String> methodKeys = const <String>{},
  })  : _entries = Map<String, KeyMappingEntry>.unmodifiable(keyMappings.nodes),
        _readValue = readValue,
        _methodKeys = Set<String>.unmodifiable(methodKeys) {
    _build();
  }

  final Map<String, KeyMappingEntry> _entries;
  final relay.DynamicValue? Function(String key)? _readValue;
  final Set<String> _methodKeys;

  final Map<String, _Node> _index = <String, _Node>{};
  late final List<relay.BrowseNode> _roots;

  int _treeBuilds = 0;

  /// How many times the node index has been built.
  ///
  /// One, always, for the life of the object. Exposed because "the tree is
  /// built once" is a promise about a count, and a count nothing can read is
  /// not a promise — the same reasoning `BackendValueSource.roundTrips` is
  /// declared under.
  int get treeBuilds => _treeBuilds;

  /// How many nodes the address space has, folders included.
  int get nodeCount => _index.length;

  /// The declared callables, as this instance was constructed with them.
  Set<String> get methodKeys => _methodKeys;

  // ------------------------------------------------------------------ the tree

  void _build() {
    _treeBuilds++;
    final rootIds = <String>[];

    // Sorted first, so every level below comes out in key order without a
    // second sort per node. A picker whose rows move between expansions is a
    // picker an engineer misclicks.
    final keys = _entries.keys.toList()..sort();
    for (final key in keys) {
      if (key.isEmpty) continue;
      final segments = key.split('.');
      var path = '';
      String? parentId;
      for (final segment in segments) {
        path = parentId == null ? segment : '$parentId.$segment';
        var node = _index[path];
        if (node == null) {
          node = _Node(path, parentId);
          _index[path] = node;
          if (parentId == null) {
            rootIds.add(path);
          } else {
            _index[parentId]!.childNodes.add(node);
          }
        }
        parentId = path;
      }
    }

    for (final node in _index.values) {
      node.node = _describe(node);
    }
    for (final node in _index.values) {
      node.children = List<relay.BrowseNode>.unmodifiable(
          <relay.BrowseNode>[for (final child in node.childNodes) child.node]);
    }
    _roots = List<relay.BrowseNode>.unmodifiable(
        <relay.BrowseNode>[for (final id in rootIds) _index[id]!.node]);
  }

  /// The [relay.BrowseNode] for one index entry.
  ///
  /// A mapped key is a variable (or a declared method); anything else is a
  /// folder. The alternative — "has children, therefore a folder" — would type
  /// a mapped struct as a folder and drop it out of the picker, and a struct is
  /// exactly what the plant's `FB_Sensor` keys are.
  relay.BrowseNode _describe(_Node node) {
    final entry = _entries[node.id];
    final type = entry == null
        ? relay.BrowseNodeType.folder
        : _methodKeys.contains(node.id)
            ? relay.BrowseNodeType.method
            : relay.BrowseNodeType.variable;
    final server = entry?.server;
    final segments = node.id.split('.');
    return relay.BrowseNode(
      id: node.id,
      displayName: segments.last,
      type: type,
      dataType: entry == null ? null : _dataTypeOf(_read(node.id)),
      description: _descriptionOf(node, entry),
      metadata: server == null
          ? const <String, String>{}
          : <String, String>{browseServerKey: server},
    );
  }

  /// What this node is, said in the mapping's own terms.
  ///
  /// A folder is described by what is under it, because there is no mapping
  /// entry to describe it with.
  String _descriptionOf(_Node node, KeyMappingEntry? entry) {
    if (entry == null) {
      final count = node.childNodes.length;
      return '${node.id} — $count ${count == 1 ? 'child' : 'children'}';
    }
    final parts = <String>[];
    final opcua = entry.opcuaNode;
    if (opcua != null) {
      parts.add('ns=${opcua.namespace};s=${opcua.identifier}');
    }
    final variable = entry.variableName;
    if (variable != null) parts.add('variable $variable');
    if (entry.m2400Node != null) parts.add('M2400 record');
    if (entry.modbusNode != null) parts.add('Modbus register');
    if (entry.io == true) parts.add('I/O unit');
    final collect = entry.collect;
    // The same derivation the collector inserts through and the series
    // resolver reads back, so the detail pane cannot name a table nothing
    // writes.
    if (collect != null) parts.add('collected as ${collectTableName(collect)}');
    final server = entry.server;
    if (server != null) parts.add('on $server');
    if (parts.isEmpty) return node.id;
    return '${node.id} — ${parts.join(', ')}';
  }

  relay.DynamicValue? _read(String key) {
    final reader = _readValue;
    return reader == null ? null : reader(key);
  }

  /// The data type a reading declares, or null when there is no reading.
  ///
  /// Null rather than `'unknown'`: the detail pane renders the type so an
  /// engineer can tell whether the widget they are configuring can draw this
  /// tag, and a fabricated type answers that question wrongly. A key nobody has
  /// heard from has no type to report yet, and saying so is the honest answer.
  static String? _dataTypeOf(relay.DynamicValue? value) {
    if (value == null) return null;
    final sourceType = value.sourceTypeId;
    if (sourceType != null && sourceType.isNotEmpty) return sourceType;
    final declared = value.typeId;
    if (declared != null && declared != relay.ValueType.unknown) {
      return declared.name;
    }
    if (value.isBoolean) return relay.ValueType.boolean.name;
    if (value.isInteger) return relay.ValueType.integer.name;
    if (value.isDouble) return relay.ValueType.double.name;
    if (value.isString) return relay.ValueType.string.name;
    if (value.isArray) return relay.ValueType.array.name;
    if (value.isObject) return relay.ValueType.object.name;
    return null;
  }

  // ------------------------------------------------------------- the surface

  @override
  Future<List<relay.BrowseNode>> fetchRoots() =>
      Future<List<relay.BrowseNode>>.value(_roots);

  /// The direct children of [parent], and never anybody else's.
  ///
  /// The argument is looked up by id, so an implementation-level slip that
  /// ignored it would fail the contract's `otherFolderId` arm. A parent this
  /// address space does not have expands to an empty level rather than
  /// throwing: a page saved last year against a since-renamed tag is the
  /// ordinary case, and one stale row must not take the panel down.
  @override
  Future<List<relay.BrowseNode>> fetchChildren(relay.BrowseNode parent) =>
      Future<List<relay.BrowseNode>>.value(
          _index[parent.id]?.children ?? const <relay.BrowseNode>[]);

  /// Description, reading, type and members of [node].
  ///
  /// A node this address space does not have gets a detail that **says so**,
  /// naming the id the caller asked about. A blank pane reads as "nothing to
  /// say about this tag" where the fact is "this backend has never heard of
  /// it", and those are different things for an engineer holding a binding.
  @override
  Future<relay.BrowseNodeDetail> fetchDetail(relay.BrowseNode node) {
    final indexed = _index[node.id];
    if (indexed == null) {
      return Future<relay.BrowseNodeDetail>.value(relay.BrowseNodeDetail(
          description: '${node.id} is not in this backend\'s address space: no '
              'key mapping names it, so there is nothing to read and nothing '
              'to expand. A tag renamed in the PLC looks exactly like this'));
    }
    final entry = _entries[node.id];
    final value = entry == null ? null : _read(node.id);
    return Future<relay.BrowseNodeDetail>.value(relay.BrowseNodeDetail(
      description: indexed.node.description,
      value: value,
      dataType: _dataTypeOf(value),
      // null means "not a struct" and an empty list means "a struct with no
      // members"; the pane renders those differently, so a leaf must not
      // report an empty list.
      structChildren: indexed.children.isEmpty ? null : indexed.children,
    ));
  }

  /// The chain root → … → [targetId], target last, or null.
  ///
  /// Built by walking the target's own ancestors out of the index, so every
  /// entry is a node that exists and every step is a real edge — a chain with
  /// the right two ends and invented nodes between them is a tree the panel
  /// expands into nothing.
  ///
  /// Null is the whole fail-closed rule on this method: a target no node has is
  /// a stale binding, which must degrade to "no pre-selection". A one-element
  /// chain, or the parent's chain, would pre-select a node the binding does not
  /// name — and a selection that looks deliberate is one an engineer binds
  /// without checking.
  @override
  Future<List<relay.BrowseNode>?> resolvePath(String targetId) {
    var node = _index[targetId];
    if (node == null) return Future<List<relay.BrowseNode>?>.value(null);
    final chain = <relay.BrowseNode>[];
    while (node != null) {
      chain.insert(0, node.node);
      final parentId = node.parentId;
      node = parentId == null ? null : _index[parentId];
    }
    return Future<List<relay.BrowseNode>?>.value(
        List<relay.BrowseNode>.unmodifiable(chain));
  }
}
