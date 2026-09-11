/// `BrowseApi` over the plant's **live** address space, one level at a time.
///
/// ## Keys and browse answer different questions
///
/// `StateManApi.keys` is the keymapping list: cheap, always available, needing
/// no upstream call at all, and exactly what a picker bound to *configured*
/// tags wants. Browse is the live address space — what the page editor's browse
/// panel needs when the tag an engineer is looking for **has not been mapped
/// yet** and therefore cannot appear in a keymapping by construction. A gateway
/// that served only `keys` would make the panel useless for the one job it
/// exists to do.
///
/// ## One level per call, and never `browseTree`
///
/// `BrowseApi`'s shape is the specification: *"an eager tree of a real PLC
/// address space is not something to put on a slow link"* (`browse.dart`).
/// The pinned binding offers both — `ClientApi.browse` (one node's references,
/// continuation points already handled by BrowseNext) and `ClientApi.browseTree`
/// (a recursive walk to depth 100). This file uses the first and never the
/// second, and `browse_test.dart` asserts the call count per level so the
/// choice cannot quietly reverse.
///
/// **Assumption A4 (08-RESEARCH):** `ClientApi.browse` against a real PLC is
/// assumed fast enough to back [BrowseApi.fetchChildren] one level per call. If
/// it turns out not to be, the consequence is a *slow panel*, not a wrong
/// answer — the level still arrives, or it times out and reports that it did
/// (see [LocalBrowse.incidents]). That asymmetry is why the assumption is safe
/// to ship on: being wrong about it costs latency, and the alternative (an
/// eager tree, cached) would cost correctness the day a tag is renamed.
///
/// ## The roots are the links
///
/// One root per configured link that can browse. A link whose
/// [UpstreamLink.supportsBrowse] is false — the M2400 weigher, whose record
/// layout is fixed and has no tree — is not a root. That is not the same as
/// having no keys: its keys are in the keymapping like everybody else's.
///
/// ## A level that does not arrive is empty and recorded
///
/// Every upstream call in this gateway is bounded by a deadline and this one is
/// no exception. A link that accepted the browse and never answered yields an
/// **empty level with a recorded reason**, not a spinner the operator has to
/// close the panel to escape. `incidents` is what the reason lands in.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'opcua_upstream_link.dart' show translateOpcUaSample;
import 'upstream_link.dart';

/// One alias's live address space, expandable one level at a time.
///
/// Declared here rather than on [UpstreamLink] on purpose. Browsing is a
/// **capability**, not a duty: two of the three adapters this phase ships have
/// no tree to walk, and putting four more members on the interface every link
/// must implement would make each of them write four throwing stubs. A link
/// that can browse is registered with an address space; a link that cannot is
/// simply absent from the map, and [UpstreamLink.supportsBrowse] is the flag
/// that says which it is.
abstract interface class UpstreamAddressSpace {
  /// The direct children of [parent], or of the alias's own root when null.
  ///
  /// [parent] is the whole node and not just its id because the id is the
  /// *gateway's* spelling — a dotted `AREAnn.DEVnn.SUBnn` path — while reaching
  /// the node upstream needs the protocol's own address. That address rides in
  /// [BrowseNode.metadata], which is what makes the second call cheap and what
  /// keeps a NodeId out of the id a page saves.
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent);

  /// Description, current value and data type of [node], or null if unknown.
  Future<BrowseNodeDetail?> detailOf(BrowseNode node);
}

/// The metadata key an address space stores its own node address under.
///
/// `BrowseNode.metadata` is documented as free-form per-protocol annotation and
/// this is the gateway's one use of it. Spelled once here so a producer and a
/// consumer cannot drift.
const String browseNativeIdKey = 'nativeId';

/// The metadata key naming which link a node came from.
const String browseAliasKey = 'alias';

/// How deep [LocalBrowse.resolvePath] will descend before giving up.
///
/// A bound rather than a trust: `resolvePath` walks *downwards* following an id
/// prefix, so a cycle in a server's address space would otherwise be an
/// unbounded walk on the gateway's own event loop. Twelve is four times the
/// depth of the plant's own `AREAnn.DEVnn.SUBnn.member` convention.
const int maxBrowseDepth = 12;

/// `BrowseApi` over the configured links.
final class LocalBrowse implements BrowseApi {
  LocalBrowse({
    required List<UpstreamLink> links,
    required Map<String, UpstreamAddressSpace> spaces,
    this.deadline = const Duration(seconds: 5),
  })  : _links = List<UpstreamLink>.unmodifiable(links),
        _spaces = Map<String, UpstreamAddressSpace>.unmodifiable(spaces);

  final List<UpstreamLink> _links;
  final Map<String, UpstreamAddressSpace> _spaces;

  /// The bound on one level.
  ///
  /// Required at the seam by every other upstream signature in this package and
  /// defaulted here for the same reason [LocalStateMan]'s deadlines are: an
  /// omission must be impossible, and a deployment's choice must still be one
  /// constructor argument.
  final Duration deadline;

  final List<String> _incidents = <String>[];

  /// Why a level came back empty, in the order the emptiness happened.
  ///
  /// An empty level and an empty level *because the link stopped answering* are
  /// different facts, and a panel that cannot tell them apart shows an engineer
  /// "this station has no tags" when the truth is "this station did not reply".
  /// The list is the honest half of returning empty rather than throwing.
  List<String> get incidents => List<String>.unmodifiable(_incidents);

  @override
  Future<List<BrowseNode>> fetchRoots() async => <BrowseNode>[
        for (final link in _links)
          if (link.supportsBrowse)
            BrowseNode(
              id: link.alias,
              displayName: link.alias,
              type: BrowseNodeType.folder,
              description: 'upstream link ${link.alias} '
                  '(${link.state.wireName})',
              metadata: <String, String>{
                browseAliasKey: link.alias,
                'state': link.state.wireName,
              },
            ),
      ];

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async {
    final alias = _aliasOf(parent.id);
    final space = alias == null ? null : _spaces[alias];
    if (space == null) {
      _record(parent.id,
          'no live address space is configured for this alias, so the tree '
          'stops here; the keymapping still lists its keys');
      return const <BrowseNode>[];
    }
    // The alias's own root node is addressed as "the top", not as a node the
    // space has to recognise by id — the id at that level is the alias, which
    // is this gateway's name for the link and not anything the PLC knows.
    final asked = parent.id == alias ? null : parent;
    return _bounded<List<BrowseNode>>(
      () => space.childrenOf(asked),
      parent.id,
      const <BrowseNode>[],
    );
  }

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    // A method is a callable on the server. It has no reading, and inventing
    // one here would put a plausible number in the pane an engineer checks
    // *before* binding. `structChildren` stays null — "not a struct" — because
    // an empty list renders as a struct with no members, which is a disclosure
    // triangle on a node that can only ever expand to nothing.
    if (node.type == BrowseNodeType.method) {
      return BrowseNodeDetail(description: node.description ?? node.displayName);
    }
    final alias = _aliasOf(node.id);
    final space = alias == null ? null : _spaces[alias];
    if (space == null) {
      _record(node.id, 'no live address space is configured for this alias');
      return const BrowseNodeDetail();
    }
    final detail = await _bounded<BrowseNodeDetail?>(
      () => space.detailOf(node),
      node.id,
      null,
    );
    return detail ?? const BrowseNodeDetail();
  }

  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    // A page saved last year against a tag since renamed is the ORDINARY case,
    // not an error condition: null means "no pre-selection", which the panel
    // already knows how to render. Never an empty list (a chain the panel walks
    // to nowhere) and never a throw (one stale widget taking down the whole
    // panel).
    if (targetId.isEmpty) return null;
    final alias = _aliasOf(targetId);
    if (alias == null) return null;

    final roots = await fetchRoots();
    BrowseNode? current;
    for (final root in roots) {
      if (root.id == alias) current = root;
    }
    if (current == null) return null;

    final chain = <BrowseNode>[current];
    if (current.id == targetId) return chain;

    for (var depth = 0; depth < maxBrowseDepth; depth++) {
      // One level per step. This is the same walk the page editor performs when
      // an engineer expands nodes by hand, which is what makes a chain it
      // returns one the panel can actually follow.
      final children = await fetchChildren(chain.last);
      BrowseNode? next;
      for (final child in children) {
        if (child.id == targetId || targetId.startsWith('${child.id}.')) {
          next = child;
          break;
        }
      }
      if (next == null) return null;
      chain.add(next);
      if (next.id == targetId) return chain;
    }
    _record(targetId,
        'the walk hit the depth bound of $maxBrowseDepth without reaching the '
        'target');
    return null;
  }

  /// Which link's tree [id] belongs to, or null if no configured link claims it.
  String? _aliasOf(String id) {
    for (final link in _links) {
      if (id == link.alias || id.startsWith('${link.alias}.')) return link.alias;
    }
    return null;
  }

  /// Runs one upstream level under [deadline] and never lets it throw.
  ///
  /// Same rule as `UpstreamLink.read`: a failure is a *reported* absence, not
  /// an exception the caller has to decide what to render for.
  Future<T> _bounded<T>(
      Future<T> Function() call, String what, T onFailure) async {
    try {
      return await call().timeout(deadline);
    } on TimeoutException {
      _record(what,
          'the link did not answer within ${deadline.inMilliseconds} ms');
      return onFailure;
    } catch (error) {
      _record(what, 'the link failed the browse: $error');
      return onFailure;
    }
  }

  void _record(String what, String why) => _incidents.add('$what: $why');
}

/// An [UpstreamAddressSpace] over the pinned binding's `ClientApi.browse`.
///
/// `browse` and not `browseTree`: the first is one node's references with
/// continuation points already handled by the binding (BrowseNext), which is
/// exactly [UpstreamAddressSpace.childrenOf]'s shape. The second is the eager
/// walk this API exists to avoid.
///
/// **Ids are the gateway's, not the server's.** A node's [BrowseNode.id] is the
/// string NodeId as the PLC spells it, which at this plant is the
/// `AREAnn.DEVnn.SUBnn` tag path itself; the NodeId proper rides in
/// [BrowseNode.metadata] under [browseNativeIdKey] so the next level costs no
/// re-derivation. A numeric NodeId has no such spelling and falls back to its
/// canonical `ns=…;i=…` form, which is still a stable thing for a page to save.
final class OpcUaAddressSpace implements UpstreamAddressSpace {
  OpcUaAddressSpace({
    required this.alias,
    required ua.ClientApi client,
    ua.NodeId? root,
    this.namespace = 1,
    this.deadline = const Duration(seconds: 5),
  })  : _client = client,
        _root = root ?? ua.NodeId.fromString(1, alias);

  /// The link this address space belongs to.
  final String alias;

  /// The namespace new node ids are read back in. Namespace 0 is the server's
  /// own and is never this gateway's tree.
  final int namespace;

  /// The bound on one browse or one detail read.
  ///
  /// Required at every other upstream await in this package and required here
  /// too: `LocalBrowse` already bounds the level it asked for, but a bound
  /// applied only by the caller leaves the binding's own future pending against
  /// a disconnected PLC — which is `state_man.dart:1868`'s
  /// `await client.awaitConnect()` inherited rather than prevented (T-08-10),
  /// and it is the exact shape `freeze_test.dart`'s upstream-await sweep is
  /// pointed at. The sweep caught this one; the deadline is its answer.
  final Duration deadline;

  final ua.ClientApi _client;
  final ua.NodeId _root;

  @override
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent) async {
    final references = await _client.browse(
      parent == null ? _root : _nodeIdOf(parent),
      // Hierarchical references only, subtypes included: Organizes,
      // HasComponent and HasProperty are the edges a tree is made of.
      // HasTypeDefinition is not hierarchical and is therefore already
      // excluded, which is why a folder does not expand into its own type.
      referenceTypeId: ua.NodeId.hierarchicalReferences,
      includeSubtypes: true,
    ).timeout(deadline);
    return <BrowseNode>[
      for (final reference in references)
        if (reference.isForward) _nodeFor(reference),
    ];
  }

  @override
  Future<BrowseNodeDetail?> detailOf(BrowseNode node) async {
    // `ClientApi.read` reads value, display name, description and data type in
    // one service call — the four things the detail pane shows.
    final sample = await _client.read(_nodeIdOf(node)).timeout(deadline);
    final arrivedAt = DateTime.now();
    final value = translateOpcUaSample(
      sample,
      arrivedAt: arrivedAt,
      // A missing source timestamp on a browse detail is not worth a counter:
      // this is a one-shot read for a pane an engineer is looking at, not a
      // monitored sample feeding a screen. The fallback still happens; nothing
      // is silently degraded by it.
      onSourceTimeFallback: () {},
    );
    return BrowseNodeDetail(
      description: sample.description?.value ?? node.description,
      value: value,
      dataType: sample.typeId?.toString() ?? node.dataType,
    );
  }

  ua.NodeId _nodeIdOf(BrowseNode node) {
    final native = node.metadata[browseNativeIdKey];
    if (native != null && native.isNotEmpty) {
      return ua.NodeId.fromString(namespace, native);
    }
    return ua.NodeId.fromString(namespace, node.id);
  }

  BrowseNode _nodeFor(ua.BrowseResultItem reference) {
    final id = reference.nodeId.isString()
        ? reference.nodeId.string
        : reference.nodeId.toString();
    return BrowseNode(
      id: id,
      displayName: reference.displayName.isNotEmpty
          ? reference.displayName
          : (reference.browseName.isNotEmpty ? reference.browseName : id),
      type: _typeFor(reference.nodeClass),
      metadata: <String, String>{
        browseAliasKey: alias,
        browseNativeIdKey: id,
      },
    );
  }

  static BrowseNodeType _typeFor(ua.NodeClass nodeClass) =>
      switch (nodeClass) {
        ua.NodeClass.UA_NODECLASS_OBJECT => BrowseNodeType.folder,
        ua.NodeClass.UA_NODECLASS_VIEW => BrowseNodeType.folder,
        ua.NodeClass.UA_NODECLASS_VARIABLE => BrowseNodeType.variable,
        ua.NodeClass.UA_NODECLASS_METHOD => BrowseNodeType.method,
        // A node kind this gateway has never heard of degrades to `other`
        // rather than blanking the level — the same forward-compatibility rule
        // `BrowseNode.fromJson` applies on the wire.
        _ => BrowseNodeType.other,
      };
}
