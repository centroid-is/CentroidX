/// `BackendBrowse`: the backend's address space, answered from the key
/// mappings main already holds.
///
/// **Nothing here reaches upstream, and that is the property under test.**
/// 13-CONTEXT: *"browse is answered from the key mappings main already holds,
/// not by reaching into a worker — a browse that stalls is the failure mode
/// this phase exists to prevent."* Two arms make that mechanical rather than
/// aspirational: one asserts the node objects handed out are the *same
/// objects* across calls (a tree rebuilt per disclosure triangle would hand
/// back new ones), and one scans the implementation's own source for `await`
/// and `async`, because a class that never awaits cannot stall no matter what
/// is happening on the plant.
///
/// The six shared browse-contract checks run at the bottom, against a
/// `StateManApi` whose only real collaborator is `BackendBrowse`. They are the
/// judge; the arms above them cover the two things the contract cannot see.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/relay/backend_browse.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show StateManApi;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show defaultBrowseFixture, runBrowseContract;

// ---------------------------------------------------------------- the fixture

/// The mapped key namespace, seeded to match `defaultBrowseFixture` exactly.
///
/// `ST101.CN02.PMP01.running` is not in the fixture and is here on purpose: a
/// second branch under the same root proves `fetchRoots` de-duplicates first
/// segments, and it is the one mapped key with no cached reading, which the
/// "no value, no data type" arm needs.
KeyMappings _mappings() => KeyMappings(nodes: {
      'ST101.CN01.MOT01.setpoint': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MOT01.setpoint')
          ..serverAlias = 'ST101',
        collect: CollectEntry(key: 'ST101.CN01.MOT01.setpoint'),
      ),
      'ST101.CN01.MOT01.running': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MOT01.running')
          ..serverAlias = 'ST101',
      ),
      'ST101.CN01.MOT01.reset': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MOT01.reset')
          ..serverAlias = 'ST101',
      ),
      'ST101.CN02.PMP01.running': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'PMP01.running')
          ..serverAlias = 'ST101',
        variableName: 'M_Pump.i_isRunning',
      ),
      'ST201.CN04.MOT01.setpoint': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'MOT01.setpoint')
          ..serverAlias = 'ST201',
      ),
      'ST201.CN04.MOT01.running': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'MOT01.running')
          ..serverAlias = 'ST201',
      ),
    });

/// What the pipe's cache would be holding. `ST101.CN02.PMP01.running` is
/// deliberately absent.
final Map<String, relay.DynamicValue> _cache = {
  'ST101.CN01.MOT01.setpoint': relay.DynamicValue(value: 42.5),
  'ST101.CN01.MOT01.running': relay.DynamicValue(value: true),
  'ST101.CN01.MOT01.reset': relay.DynamicValue(value: false),
  'ST201.CN04.MOT01.setpoint': relay.DynamicValue(value: 17.0),
  'ST201.CN04.MOT01.running': relay.DynamicValue(value: false),
};

/// The one key this deployment's harness declares to be a callable.
///
/// See the method-node finding: the key mapping format has no callable
/// concept, so a mapping-backed tree cannot type a node `method` on its own.
/// Production declares none; this set is what lets
/// `checkBrowseNodeTypesDistinguishFoldersFromVariables` run against a real
/// code path instead of being skipped.
const _methodKeys = <String>{'ST101.CN01.MOT01.reset'};

BackendBrowse _browse({Set<String> methodKeys = _methodKeys}) => BackendBrowse(
      keyMappings: _mappings(),
      readValue: (key) => _cache[key],
      methodKeys: methodKeys,
    );

/// A `StateManApi` whose only working member is `browse`.
///
/// The browse contract touches exactly two things outside `api.browse`:
/// `read(PipeKeys.connected)` through `linkUp`, and `dispose` through
/// `addTearDown`. Everything else throws rather than answering emptily — if a
/// browse case ever starts calling one, this fails loudly naming the member
/// instead of quietly passing on a fabricated answer.
final class _BrowseOnlyApi implements StateManApi {
  _BrowseOnlyApi() : browse = _browse();

  @override
  final relay.BrowseApi browse;

  Never _notPartOfThisFixture(String member) => throw UnsupportedError(
      'the browse fixture composed no $member; a browse contract case reached '
      'outside api.browse, which this fixture cannot answer honestly');

  // The four access families (17-03), on this fixture's own rule: everything
  // outside `api.browse` fails loudly naming the member rather than quietly
  // passing on a fabricated answer.
  @override
  relay.AccessTemplateApi get accessTemplates =>
      _notPartOfThisFixture('access template store');

  @override
  relay.AccessAdminApi get accessAdmin =>
      _notPartOfThisFixture('access admin store');

  @override
  relay.AuditApi get audit => _notPartOfThisFixture('audit trail store');

  @override
  relay.BackendConfigApi get backendConfig =>
      _notPartOfThisFixture('backend config document');

  /// `PipeKeys.connected` is true because a mapping-backed browse has no link
  /// to bring up: the address space is a map in this process's memory and is
  /// serving from the instant the constructor returns.
  @override
  relay.DynamicValue? read(String key) => key == relay.PipeKeys.connected
      ? relay.DynamicValue(value: true)
      : _cache[key];

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _notPartOfThisFixture('value source');

  @override
  Stream<relay.DynamicValue> subscribe(String key) =>
      _notPartOfThisFixture('value source');

  @override
  Future<relay.DynamicValue> readFresh(String key) async =>
      _notPartOfThisFixture('value source');

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) async =>
      _notPartOfThisFixture('value source');

  @override
  List<String> get keys => _notPartOfThisFixture('value source');

  @override
  Future<relay.WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) async =>
      _notPartOfThisFixture('write source');

  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) async =>
      _notPartOfThisFixture('write source');

  @override
  Future<relay.HoldHandle> holdToRun(String key) async =>
      _notPartOfThisFixture('write source');

  @override
  relay.TimeseriesApi get timeseries => _notPartOfThisFixture('TimeseriesApi');

  @override
  relay.HistoryViewApi get historyViews =>
      _notPartOfThisFixture('HistoryViewApi');

  @override
  relay.PreferencesApi get preferences =>
      _notPartOfThisFixture('PreferencesApi');

  @override
  Future<void> dispose() async {}
}

/// [source] with Dart line comments removed.
String _stripComments(String source) => source
    .split('\n')
    .map((line) {
      final slashes = line.indexOf('//');
      return slashes < 0 ? line : line.substring(0, slashes);
    })
    .join('\n');

void main() {
  group('the mapping-backed address space', () {
    test('the roots are the distinct first segments, sorted, and expandable',
        () async {
      final browse = _browse();
      final roots = await browse.fetchRoots();

      expect(roots.map((node) => node.id).toList(), ['ST101', 'ST201'],
          reason: 'six mapped keys across two stations are two roots in '
              'station order; a root per key would put the same station in '
              'the picker four times');
      for (final root in roots) {
        expect(root.type, relay.BrowseNodeType.folder);
        expect(root.displayName, root.id);
        expect(root.isExpandable, isTrue);
      }
    });

    test('expanding a folder returns one level, not the subtree', () async {
      final browse = _browse();
      final level = await browse
          .fetchChildren(const relay.BrowseNode(
              id: 'ST101',
              displayName: 'ST101',
              type: relay.BrowseNodeType.folder))
          .then((nodes) => nodes.map((node) => node.id).toList());

      expect(level, ['ST101.CN01', 'ST101.CN02'],
          reason: 'one level per call is the whole shape of BrowseApi; a '
              'level that carried its grandchildren would be an eager tree of '
              'the plant address space delivered on every disclosure triangle');
    });

    test('the tree is built once, and the nodes handed out are the same objects',
        () async {
      final browse = _browse();
      expect(browse.treeBuilds, 1,
          reason: 'the index is built in the constructor');

      final parent = const relay.BrowseNode(
          id: 'ST101.CN01.MOT01',
          displayName: 'MOT01',
          type: relay.BrowseNodeType.folder);
      final first = await browse.fetchChildren(parent);
      for (var i = 0; i < 9; i++) {
        await browse.fetchChildren(parent);
        await browse.fetchRoots();
        await browse.resolvePath('ST101.CN01.MOT01.setpoint');
      }
      final tenth = await browse.fetchChildren(parent);

      expect(browse.treeBuilds, 1,
          reason: 'a tree rebuilt per call turns one disclosure triangle into '
              'an O(keys) walk over the whole plant mapping');
      expect(identical(first, tenth), isTrue,
          reason: 'the same level came back as a different list object, so '
              'something rebuilt it; the counter can be forgotten but object '
              'identity cannot be faked by an implementation that rebuilds');
      expect(identical(first.first, tenth.first), isTrue,
          reason: 'the child nodes are rebuilt per call');
    });

    test('a mapped key that is also a folder stays bindable', () async {
      final browse = BackendBrowse(
        keyMappings: KeyMappings(nodes: {
          'ST301.CN01.SENS01': KeyMappingEntry(),
          'ST301.CN01.SENS01.p_stat_xOutput': KeyMappingEntry(),
        }),
      );
      final chain = await browse.resolvePath('ST301.CN01.SENS01');

      expect(chain, isNotNull);
      expect(chain!.last.type, relay.BrowseNodeType.variable,
          reason: 'the struct itself is a mapped key an engineer binds; '
              'typing it as a folder because it happens to have members takes '
              'the whole tag out of the picker');
      expect(chain.last.isExpandable, isTrue);
    });

    test('a node id no key has expands to an empty level, and never a canned one',
        () async {
      final browse = _browse();
      final children = await browse.fetchChildren(const relay.BrowseNode(
          id: 'ST999.CN99',
          displayName: 'CN99',
          type: relay.BrowseNodeType.folder));

      expect(children, isEmpty,
          reason: 'a stale row in the panel must expand to nothing rather '
              'than to some other station\'s tags, and it must not throw: one '
              'renamed tag cannot take down the whole browse panel');
    });

    test('the detail of a node no key has says so, rather than describing '
        'another node', () async {
      final browse = _browse();
      final detail = await browse.fetchDetail(const relay.BrowseNode(
          id: 'ST999.CN99.MOT99.setpoint',
          displayName: 'setpoint',
          type: relay.BrowseNodeType.variable));

      expect(detail.value, isNull);
      expect(detail.dataType, isNull);
      expect(detail.structChildren, isNull);
      expect(detail.description, contains('ST999.CN99.MOT99.setpoint'),
          reason: 'the refusal names the node the caller asked about; a '
              'blank detail pane reads as "nothing to say about this tag" '
              'when the fact is "this backend has never heard of it"');
    });

    test('the detail of a folder carries its children as struct members',
        () async {
      final browse = _browse();
      final detail = await browse.fetchDetail(const relay.BrowseNode(
          id: 'ST101.CN01.MOT01',
          displayName: 'MOT01',
          type: relay.BrowseNodeType.folder));

      expect(detail.structChildren, isNotNull);
      expect(detail.structChildren!.map((node) => node.id), [
        'ST101.CN01.MOT01.reset',
        'ST101.CN01.MOT01.running',
        'ST101.CN01.MOT01.setpoint',
      ]);
    });

    test('the detail of a mapped key comes from the mapping, and the reading '
        'from the cache', () async {
      final browse = _browse();
      final detail = await browse.fetchDetail(const relay.BrowseNode(
          id: 'ST101.CN01.MOT01.setpoint',
          displayName: 'setpoint',
          type: relay.BrowseNodeType.variable));

      expect(detail.value?.value, 42.5);
      expect(detail.dataType, 'double');
      expect(detail.description, contains('ST101'),
          reason: 'the server alias is the one fact that tells an engineer '
              'which PLC this tag lives on, and two stations carry '
              'identically named motors');
      expect(detail.description, contains('ns=2;s=MOT01.setpoint'));
      expect(detail.structChildren, isNull,
          reason: 'null means "not a struct"; an empty list would render as a '
              'struct with no members, which is a different fact');
    });

    test('a mapped key with nothing in the cache reports no data type', () async {
      final browse = _browse();
      final detail = await browse.fetchDetail(const relay.BrowseNode(
          id: 'ST101.CN02.PMP01.running',
          displayName: 'running',
          type: relay.BrowseNodeType.variable));

      expect(detail.value, isNull);
      expect(detail.dataType, isNull,
          reason: 'the data type is derived from the reading, so a key with '
              'no reading has none to report; inventing one would tell the '
              'engineer a gauge can draw a tag nobody has heard from');
      expect(detail.description, contains('M_Pump.i_isRunning'),
          reason: 'the mapping still describes the key even with no reading');
    });

    test('a resolved chain stops at the folder when the folder is the target',
        () async {
      final browse = _browse();
      final chain = await browse.resolvePath('ST101.CN01');

      expect(chain?.map((node) => node.id).toList(), ['ST101', 'ST101.CN01']);
    });

    test('a stale binding resolves to null, not to a plausible chain', () async {
      final browse = _browse();

      expect(await browse.resolvePath('ST999.CN99.MOT99.setpoint'), isNull);
      expect(await browse.resolvePath('ST101.CN01.MOT01.speed'), isNull,
          reason: 'a target whose ancestors all exist is the exact shape a '
              'renamed member takes; resolving it to the parent chain would '
              'pre-select the motor and let the engineer bind a tag that is '
              'not there');
      expect(await browse.resolvePath(''), isNull);
    });
  });

  group('the method-node decision', () {
    test('a declared method key is a method, and does not expand', () async {
      final browse = _browse();
      final chain = await browse.resolvePath('ST101.CN01.MOT01.reset');

      expect(chain!.last.type, relay.BrowseNodeType.method);
      expect(chain.last.isExpandable, isFalse);
    });

    test('production declares none, so the same key is an ordinary variable',
        () async {
      final browse = _browse(methodKeys: const {});
      final chain = await browse.resolvePath('ST101.CN01.MOT01.reset');

      expect(chain!.last.type, relay.BrowseNodeType.variable,
          reason: 'the key mapping format has no callable concept, so a '
              'mapping-backed tree can only know a node is a method because '
              'the deployment said so at the composition root. Nothing about '
              'the mapping itself may produce one');
    });

    test('a declared key that is not mapped anywhere invents no node',
        () async {
      final browse = _browse(methodKeys: const {'ST404.CN01.MOT01.reset'});

      expect(await browse.resolvePath('ST404.CN01.MOT01.reset'), isNull,
          reason: 'the declared set annotates the address space the mappings '
              'describe; letting it add nodes would make the composition root '
              'a second, unreviewed source of tags');
    });
  });

  group('nothing in this class can stall', () {
    test('the implementation awaits nothing and declares no async member', () {
      final source = _stripComments(
          File('lib/core/relay/backend_browse.dart').readAsStringSync());

      expect(source, isNot(contains('await ')),
          reason: 'T-13-04-c: every browse answer is a synchronous map lookup '
              'wrapped in an already-completed Future. An await here is a '
              'browse call that can park, which is the failure mode this '
              'whole phase exists to prevent');
      expect(source, isNot(contains('async')),
          reason: 'an async body is where an await goes next');
      expect(source, isNot(contains('Future.delayed')));
      expect(source, isNot(contains('Timer')));
    });

    test('it names neither the local gateway nor the value source', () {
      final source =
          File('lib/core/relay/backend_browse.dart').readAsStringSync();

      expect(source, isNot(contains('package:tfc_relay_local')),
          reason: 'that edge is the dependency cycle Phase 13 exists to avoid');
      expect(source, isNot(contains('backend_live_values.dart')),
          reason: '13-03 runs in the same wave; readValue is a function so '
              'the two files can land independently');
    });
  });

  // The judge. Six checks, against a StateManApi whose only real collaborator
  // is BackendBrowse.
  runBrowseContract(_BrowseOnlyApi.new, fixture: defaultBrowseFixture);
}
