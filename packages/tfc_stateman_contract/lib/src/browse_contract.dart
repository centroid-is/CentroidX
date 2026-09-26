/// The browse half of the contract: how an engineer finds a tag, and how the
/// page editor gets back to one it has already bound.
///
/// Browse is the surface the page editor binds widgets through. Everything else
/// in this suite is about a value that is already bound; this is about choosing
/// which value that is, which means an error here is not a wrong number on a
/// screen — it is a button wired to the wrong machine, discovered later, by
/// someone pressing it.
///
/// Four methods, and the fourth is the one that would have been forgotten.
/// `fetchRoots` / `fetchChildren` / `fetchDetail` are the obvious three: expand
/// a level at a time, because an eager tree of a real PLC address space is not
/// something to put on a slow link. `resolvePath` is the one RESEARCH found
/// already in the repo (`browse_panel.dart:67-79`) and the one the CONTEXT
/// default did not anticipate: opening the browse panel on an already-bound
/// value needs the root → … → leaf chain to pre-select it. Without it the panel
/// opens unpositioned and the engineer re-navigates a thousand-node tree by
/// hand to find the tag they were already looking at. That is a UX regression
/// that would be discovered late — after the pipe is the only way to browse —
/// so it gets a contract case now.
///
/// The ordering guarantee is the implementation's, not the decoder's. A list of
/// nodes crossing the wire carries no evidence of which end is the root, so
/// "ordered root → … → leaf, target last" cannot be enforced at the boundary;
/// it has to be a property of the source, which is to say a property this file
/// asserts. [checkResolvePathReturnsRootToLeafChain] walks the chain against
/// `fetchChildren` and proves each entry is genuinely the parent of the next —
/// a chain that merely *ends* at the right node, having invented the middle, is
/// still a tree the panel cannot expand.
///
/// Shape follows `write_contract.dart`: no implementation is imported, every
/// case is a named top-level function so the sabotage suite can run it against
/// a damaged source, every await is wrapped in [within] so silence fails by
/// name instead of hanging, and the one thing a case cannot discover for itself
/// — which ids exist in this source's address space — arrives as an injected
/// [BrowseFixture].
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// The landmarks a browse case needs, in the address space of the source under
/// test.
///
/// Browse cases cannot be written against literal ids the way the read and
/// write cases can. `write_contract.dart` names a setpoint key and the harness
/// makes that key exist; nothing in the browse surface *creates* a node, so the
/// tree is whatever the source is looking at — an OPC UA server, a UMAS PLC, an
/// in-memory reference tree — and only the caller registering that source knows
/// what is in it. Hence a fixture rather than constants: one unmodified suite
/// judges a gateway browsing a real ST101 and a fake browsing a seeded tree,
/// and each declares its landmarks once, where it is registered.
///
/// The ids in [defaultBrowseFixture] are the plant-realistic ones the rest of
/// this package uses (`AREAnn.DEVnn.SUBnn`, the SVN tag convention), so a
/// source that seeds the conventional tree can take the default.
final class BrowseFixture {
  /// A node that must appear in `fetchRoots`.
  final String rootId;

  /// A folder whose children are known — the parent [folderChildIds] belong to.
  final String folderId;

  /// The ids `fetchChildren` must return for [folderId].
  final List<String> folderChildIds;

  /// A second folder, elsewhere in the tree, with children of its own.
  ///
  /// Exists so "these are the children of *this* folder" can be asserted as
  /// something other than "these are some nodes": a source that ignores its
  /// argument and returns the same list for every parent satisfies every check
  /// that only ever expands one folder.
  final String otherFolderId;

  /// A variable, nested at least one level below a root, whose current value
  /// the source can read.
  ///
  /// Nested on purpose: a chain of length one is trivially ordered, so a target
  /// directly under a root cannot demonstrate the root → leaf property.
  final String variableId;

  /// A method node — the one node kind that is not expandable.
  final String methodId;

  /// An id no node in this address space has.
  ///
  /// A stale binding is the ordinary case this stands for: a page saved last
  /// year against a tag since renamed in the PLC.
  final String unknownId;

  const BrowseFixture({
    required this.rootId,
    required this.folderId,
    required this.folderChildIds,
    required this.otherFolderId,
    required this.variableId,
    required this.methodId,
    required this.unknownId,
  });
}

/// The conventional tree: one motor on the pre-freezer line, one on the
/// post-freezer line, and a method nobody should be able to expand.
///
/// The default so the bare entries in [browseChecks] can be run against a
/// source directly — which is what the sabotage suite does, and what makes a
/// damaged implementation judgeable by a single named check rather than only
/// through [runBrowseContract].
const defaultBrowseFixture = BrowseFixture(
  rootId: 'ST101',
  folderId: 'ST101.CN01.MOT01',
  folderChildIds: [
    'ST101.CN01.MOT01.setpoint',
    'ST101.CN01.MOT01.running',
    'ST101.CN01.MOT01.reset',
  ],
  otherFolderId: 'ST201.CN04.MOT01',
  variableId: 'ST101.CN01.MOT01.setpoint',
  methodId: 'ST101.CN01.MOT01.reset',
  unknownId: 'ST999.CN99.MOT99.setpoint',
);

/// Finds [id] by walking the tree from the roots, one level at a time.
///
/// Deliberately does not use `resolvePath`: three of the cases below need to
/// get hold of a node, and reaching it through the method whose correctness is
/// itself under test would make those cases fail for a reason they do not name.
/// This is also the walk the page editor performs when a user expands nodes by
/// hand, so a source that cannot be walked this way is broken for the panel
/// too.
///
/// Method nodes are not descended into (they are leaves) but are still matched,
/// which is how [checkBrowseNodeTypesDistinguishFoldersFromVariables] gets one.
Future<BrowseNode> _nodeAt(BrowseApi browse, String id) async {
  final queue = <BrowseNode>[
    ...await within(browse.fetchRoots(), 'the roots of the address space'),
  ];
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final node = queue.removeAt(0);
    if (node.id == id) return node;
    if (!node.isExpandable || !seen.add(node.id)) continue;
    queue.addAll(
        await within(browse.fetchChildren(node), 'the children of ${node.id}'));
  }
  fail('no node with id "$id" exists anywhere under the roots of this source, '
      'so the fixture describing it does not match the address space being '
      'browsed. Either the source is not serving the tree the caller of '
      'runBrowseContract declared, or fetchChildren is not returning a level '
      'the page editor could expand by hand either');
}

/// Awaits a path resolution and turns *any* throw into a named failure.
///
/// The promise being asserted is that an unresolvable target comes back as
/// null, and a check asserting "this does not throw" must not let the throw
/// escape raw — `expectContractViolation`'s third clause exists to forbid a
/// violation surfacing as a stack frame instead of the property that was lost.
Future<List<BrowseNode>?> _resolved(
    Future<List<BrowseNode>?> resolving, String what) async {
  try {
    return await within(resolving, what);
  } on TestFailure {
    rethrow;
  } catch (error) {
    fail('$what threw ${error.runtimeType} ($error) instead of resolving. A '
        'binding the source cannot resolve is the ordinary consequence of a '
        'tag being renamed in the PLC, and it must degrade to "no '
        'pre-selection" — a throw here takes down the whole browse panel on a '
        'page that has one stale widget on it');
  }
}

/// The address space has a top level, and every node in it is identifiable.
///
/// The first thing the page editor draws. A root without an id is a node the
/// panel cannot expand or bind; a root without a display name is a blank row in
/// the picker, which an engineer reads as "nothing here" and stops.
Future<void> checkFetchRootsReturnsTopLevelNodes(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final roots =
      await within(api.browse.fetchRoots(), 'the roots of the address space');

  expect(roots, isNotEmpty,
      reason: 'the source returned no roots at all, so the browse panel opens '
          'on an empty tree and there is no way to bind a widget to anything '
          'through it');
  for (final node in roots) {
    expect(node.id, isNotEmpty,
        reason: 'a root arrived with no id ("${node.displayName}"); the id is '
            'what a binding stores, so a node without one can be shown and '
            'never chosen');
    expect(node.displayName, isNotEmpty,
        reason: 'the root "${node.id}" arrived with no display name, so the '
            'picker renders a blank row where a station should be');
  }
  expect(roots.map((node) => node.id), contains(fixture.rootId),
      reason: 'the declared root "${fixture.rootId}" is not among the roots '
          'this source returned (${roots.map((n) => n.id).toList()})');
}

/// Expanding a folder yields that folder's children, not somebody else's.
///
/// The argument has to matter. A source that ignores [BrowseApi.fetchChildren]'s
/// parameter and returns one canned level satisfies every case that expands a
/// single folder, and produces a page editor where every station shows the same
/// six tags — which looks like a working tree right up until an engineer binds
/// one of them.
Future<void> checkFetchChildrenReturnsChildrenOfTheParent(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final browse = api.browse;
  final folder = await _nodeAt(browse, fixture.folderId);
  final other = await _nodeAt(browse, fixture.otherFolderId);

  final children = await within(
      browse.fetchChildren(folder), 'the children of ${fixture.folderId}');
  final others = await within(
      browse.fetchChildren(other), 'the children of ${fixture.otherFolderId}');

  expect(children.map((node) => node.id), containsAll(fixture.folderChildIds),
      reason: 'expanding ${fixture.folderId} returned '
          '${children.map((n) => n.id).toList()}, which does not include the '
          'children it was declared to have (${fixture.folderChildIds}); a tag '
          'that never appears in the picker cannot be bound to a widget at all');
  expect(others, isNotEmpty,
      reason: 'the second folder ${fixture.otherFolderId} expanded to nothing, '
          'so the comparison below would pass against a source that returns '
          'the same canned level for every parent');
  final otherIds = others.map((node) => node.id).toSet();
  expect(children.where((node) => otherIds.contains(node.id)), isEmpty,
      reason: 'expanding ${fixture.folderId} returned nodes that belong under '
          '${fixture.otherFolderId}; a source that serves one canned level for '
          'every parent shows an engineer the pre-freezer motor under the '
          'post-freezer station, and the binding they make there is silently '
          'the wrong machine');
}

/// A node's detail says what type it is, and what it currently reads.
///
/// The detail pane is what an engineer checks before binding: the data type
/// tells them whether the widget they are configuring can render it, and the
/// current value tells them they are looking at the tag they think they are.
/// The value arrives as the pipe's one value type, quality included, so a
/// reading nobody has heard about in an hour shows as stale here rather than as
/// a plausible number that settles the question wrongly.
Future<void> checkFetchDetailDescribesTheNode(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final browse = api.browse;
  final variable = await _nodeAt(browse, fixture.variableId);

  final detail = await within(
      browse.fetchDetail(variable), 'the detail of ${fixture.variableId}');

  expect(detail.dataType, isNotNull,
      reason: 'the detail of ${fixture.variableId} carries no data type, so '
          'nothing downstream can tell whether this tag is a number a gauge '
          'can draw or a string it cannot');
  expect(detail.dataType, isNotEmpty,
      reason: 'the detail of ${fixture.variableId} carries an empty data type, '
          'which renders as a blank field the engineer reads as "unknown"');
  expect(detail.value, isNotNull,
      reason: 'the detail of the variable ${fixture.variableId} carries no '
          'current value; the reading is how an engineer confirms they are '
          'looking at the tag they meant before they bind a button to it');
}

/// The resolve chain runs root → … → leaf, and every step is a real edge.
///
/// This is the pre-selection case. The page editor opens the browse panel on a
/// widget that is already bound and hands the stored id to `resolvePath`; the
/// chain that comes back is what the panel expands and highlights. The ordering
/// is asserted three ways, because there are three separate ways to get it
/// wrong and each looks fine from one of the others:
///
///  * the **last** entry must be the target — a chain that stops at the parent
///    leaves the panel selecting a folder, and the engineer, seeing a selection
///    that looks deliberate, binds the wrong node;
///  * the **first** entry must be a root — a chain that starts in the middle is
///    a subtree the panel cannot expand from where it is;
///  * every **intermediate** entry must be the genuine parent of the next,
///    checked against `fetchChildren` — a source that returns the right two
///    ends with invented nodes between them produces a tree that expands into
///    nothing.
Future<void> checkResolvePathReturnsRootToLeafChain(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final browse = api.browse;

  final chain = await _resolved(browse.resolvePath(fixture.variableId),
      'the chain from a root to ${fixture.variableId}');

  expect(chain, isNotNull,
      reason: 'the source could not resolve ${fixture.variableId}, a target '
          'the caller declared exists; the panel then opens unpositioned and '
          'the engineer re-navigates the tree by hand to reach the tag they '
          'were already looking at');
  final path = chain!;
  expect(path, isNotEmpty,
      reason: 'the chain to ${fixture.variableId} came back empty rather than '
          'null; an empty list is a chain the panel walks to nowhere, where '
          'null at least means "no pre-selection" honestly');
  expect(path.last.id, fixture.variableId,
      reason: 'the chain ends at "${path.last.id}" instead of the target '
          '${fixture.variableId}. The panel selects whatever the chain ends '
          'at, so this is a pre-selection pointing at the wrong node — and a '
          'selection that looks deliberate is one an engineer binds without '
          'checking');
  expect(path.length, greaterThan(1),
      reason: 'the chain to a nested target is one entry long, so it cannot '
          'be demonstrating any ordering at all; the fixture declares '
          '${fixture.variableId} as nested below a root');

  final roots =
      await within(browse.fetchRoots(), 'the roots of the address space');
  expect(roots.map((node) => node.id), contains(path.first.id),
      reason: 'the chain starts at "${path.first.id}", which is not one of '
          'this source\'s roots; the panel expands from the top down, so a '
          'chain beginning in the middle of the tree cannot be followed');

  for (var i = 0; i < path.length - 1; i++) {
    final children = await within(browse.fetchChildren(path[i]),
        'the children of ${path[i].id} while walking the chain');
    expect(children.map((node) => node.id), contains(path[i + 1].id),
        reason: '"${path[i + 1].id}" is the next entry in the chain but is not '
            'a child of "${path[i].id}", so the chain is not a path through '
            'this tree. The panel expands each entry in turn and finds the '
            'next one missing, which leaves it stopped partway with no '
            'selection and no error');
  }
}

/// A target that does not exist resolves to null — not empty, not a throw.
///
/// The stale-binding case, and it is the common one: a page saved last year
/// against a tag since renamed in the PLC. Three outcomes are possible and only
/// one is usable. Null means "no pre-selection", which the panel already knows
/// how to render — it opens at the roots. An empty list is indistinguishable
/// from a resolved chain of nothing. A throw takes the whole browse panel down
/// because one widget on the page is stale.
Future<void> checkResolvePathReturnsNullForUnknownTarget(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final chain = await _resolved(api.browse.resolvePath(fixture.unknownId),
      'an unresolvable target coming back');

  expect(chain, isNull,
      reason: 'resolving the unknown id ${fixture.unknownId} returned '
          '${chain?.map((n) => n.id).toList()} instead of null. A stale '
          'binding must degrade to "no pre-selection"; anything else either '
          'pre-selects a node the binding does not name, or hands the panel a '
          'chain it cannot tell from a real one');
}

/// Folders and variables expand; methods do not.
///
/// `isExpandable` is what puts a disclosure triangle on a row. A variable
/// counts as expandable because a structured tag has members and an engineer
/// binds one of them. A method does not: it is a callable on the server, it has
/// no children, and a triangle next to it invites a click that can only ever
/// produce an empty level.
Future<void> checkBrowseNodeTypesDistinguishFoldersFromVariables(
  StateManApi api, {
  BrowseFixture fixture = defaultBrowseFixture,
}) async {
  final browse = api.browse;
  final folder = await _nodeAt(browse, fixture.folderId);
  final variable = await _nodeAt(browse, fixture.variableId);
  final method = await _nodeAt(browse, fixture.methodId);

  expect(folder.type, BrowseNodeType.folder,
      reason: '${fixture.folderId} came back as ${folder.type.name} where the '
          'fixture declares a folder');
  expect(variable.type, BrowseNodeType.variable,
      reason: '${fixture.variableId} came back as ${variable.type.name} where '
          'the fixture declares a variable; only a variable can be bound to a '
          'widget, so a tag typed as anything else disappears from the picker');
  expect(method.type, BrowseNodeType.method,
      reason: '${fixture.methodId} came back as ${method.type.name} where the '
          'fixture declares a method');

  expect(folder.isExpandable, isTrue,
      reason: 'a folder that is not expandable is a station the engineer '
          'cannot open, which hides every tag underneath it');
  expect(variable.isExpandable, isTrue,
      reason: 'a variable that is not expandable hides the members of a '
          'structured tag, and a member is a perfectly ordinary thing to bind');
  expect(method.isExpandable, isFalse,
      reason: 'a method claims to be expandable, so the panel offers a '
          'disclosure triangle on a node that can only ever expand to nothing');
}

/// The case names, declared once so [runBrowseContract] can override a case by
/// name without the string appearing twice.
const _rootsCase = 'the address space has a top level, and every root is '
    'identifiable';
const _childrenCase = 'expanding a folder yields that folder\'s children, not '
    'another\'s';
const _detailCase = 'a node\'s detail carries its data type, and a variable\'s '
    'carries a reading';
const _chainCase = 'a resolved path runs root to leaf, and every step is a '
    'real edge';
const _unresolvableCase =
    'a target that does not exist resolves to null, not empty and not a throw';
const _typesCase = 'folders and variables expand; methods do not';

/// Every browse property, keyed by the sentence it asserts.
///
/// The key is the test name, so a failure in CI reads as the promise that was
/// broken rather than as a function identifier. Each entry runs against
/// [defaultBrowseFixture]; [runBrowseContract] rebinds them all to the fixture
/// the caller declares.
const browseChecks = <String, Check<StateManApi>>{
  _rootsCase: checkFetchRootsReturnsTopLevelNodes,
  _childrenCase: checkFetchChildrenReturnsChildrenOfTheParent,
  _detailCase: checkFetchDetailDescribesTheNode,
  _chainCase: checkResolvePathReturnsRootToLeafChain,
  _unresolvableCase: checkResolvePathReturnsNullForUnknownTarget,
  _typesCase: checkBrowseNodeTypesDistinguishFoldersFromVariables,
};

/// Registers the browse contract against implementations from [make].
///
/// [fixture] is required rather than defaulted, following the capability-flag
/// precedent in `write_contract.dart`: an implementation that differs declares
/// how, once, at the point where it is registered. A defaulted fixture would
/// let a source with an entirely different address space be registered by
/// accident and then fail six cases with messages about ids nobody chose.
///
/// [supportsBrowse] `false` skips the group with a reason on the record rather
/// than passing it vacuously, so a source with no address space to browse is
/// visible in the run report instead of absent from it.
///
/// One fresh instance per case, disposed by `addTearDown`.
void runBrowseContract(
  StateManApi Function() make, {
  required BrowseFixture fixture,
  bool supportsBrowse = true,
  Set<String> expectUnreachable = const {},
}) {
  final cases = <String, Check<StateManApi>>{
    _rootsCase: (api) =>
        checkFetchRootsReturnsTopLevelNodes(api, fixture: fixture),
    _childrenCase: (api) =>
        checkFetchChildrenReturnsChildrenOfTheParent(api, fixture: fixture),
    _detailCase: (api) => checkFetchDetailDescribesTheNode(api, fixture: fixture),
    _chainCase: (api) =>
        checkResolvePathReturnsRootToLeafChain(api, fixture: fixture),
    _unresolvableCase: (api) =>
        checkResolvePathReturnsNullForUnknownTarget(api, fixture: fixture),
    _typesCase: (api) =>
        checkBrowseNodeTypesDistinguishFoldersFromVariables(api,
            fixture: fixture),
  };

  group('browse', () {
    cases.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        // The link, before the property. On an in-process source this is a
        // synchronous read and nothing more; behind a socket it is where the
        // connect, the handshake and the first subscribe come due, and leaving
        // them inside the case's own budget made the first check in this suite
        // a measurement of the transport (`harness.dart`'s [linkUp]).
        await linkUp(api);
        if (expectUnreachable.contains(property)) {
          await expectUnreachableMethod(property, () => check(api));
          return;
        }
        await check(api);
      });
    });
  },
      skip: supportsBrowse
          ? null
          : 'this implementation declares no browse support; the browse '
              'contract is skipped rather than passed, so the capability is '
              'visible in the run report instead of absent from it');
}
