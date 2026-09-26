/// Browsing a live address space, one level at a time.
///
/// **Keys and browse answer different questions.** `StateManApi.keys` is the
/// keymapping list — cheap, always available, and what a picker bound to
/// *configured* tags wants. Browse is the **live** address space: what the page
/// editor's browse panel needs when the tag an engineer is looking for has not
/// been mapped yet, and therefore cannot appear in a keymapping at all. A
/// gateway that only served `keys` would make the panel useless for exactly the
/// job it exists to do — binding a widget to something new.
///
/// **The arm that matters is the two-folder one.** `browse_contract.dart:69-75`
/// says why the fixture carries a second folder: *"a source that ignores its
/// argument and returns the same list for every parent satisfies every check
/// that only ever expands one folder"*. That implementation looks like a
/// working tree right up until an engineer binds the pre-freezer motor under
/// the post-freezer station. Its sabotage is written out below.
///
/// **One `browse` call per level, and the count is asserted.** `browseTree` on
/// a real PLC address space is the mistake `BrowseApi`'s shape exists to
/// prevent — the binding's own doc calls it a recursive walk to depth 100, and
/// `browse.dart` answers that *"an eager tree of a real PLC address space is
/// not something to put on a slow link"*.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/opcua_server_fixture.dart';

void main() {
  group('the roots are the links', () {
    test('one root per browsable link, named by its alias', () async {
      final browse = LocalBrowse(
        links: [
          FakeUpstreamLink(alias: 'ST101'),
          FakeUpstreamLink(alias: 'ST201'),
        ],
        spaces: {'ST101': scriptedPlant('ST101'), 'ST201': scriptedPlant('ST201')},
      );

      final roots = await browse.fetchRoots();

      expect(roots.map((node) => node.id), ['ST101', 'ST201']);
      expect(roots.every((node) => node.type == BrowseNodeType.folder), isTrue);
      expect(roots.every((node) => node.displayName.isNotEmpty), isTrue);
    });

    test('a link that cannot browse is not a root', () async {
      final browse = LocalBrowse(
        links: [
          FakeUpstreamLink(alias: 'ST101'),
          // The M2400 weigher: a fixed record layout, no address space to
          // navigate. Its keys are still perfectly browsable through the
          // keymapping; its *live* tree is not there to be walked.
          FakeUpstreamLink(alias: 'weigher1v', supportsBrowse: false),
        ],
        spaces: {'ST101': scriptedPlant('ST101')},
      );

      expect((await browse.fetchRoots()).map((node) => node.id), ['ST101']);
    });
  });

  group('expanding a folder', () {
    test('two folders expand to different children — the arm a source that '
        'ignores its argument fails', () async {
      final space = scriptedPlant('ST101');
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': space},
      );

      final motor = await nodeAt(browse, 'ST101.CN01.MOT01');
      final other = await nodeAt(browse, 'ST101.CN04.MOT01');
      final children = await browse.fetchChildren(motor!);
      final others = await browse.fetchChildren(other!);

      expect(children.map((node) => node.id),
          containsAll(<String>[
            'ST101.CN01.MOT01.setpoint',
            'ST101.CN01.MOT01.running',
            'ST101.CN01.MOT01.reset',
          ]));
      expect(others, isNotEmpty);
      final otherIds = others.map((node) => node.id).toSet();
      expect(children.where((node) => otherIds.contains(node.id)), isEmpty,
          reason: 'expanding one folder returned nodes belonging to another, '
              'which is the canned-level failure the second fixture folder '
              'exists to catch');
    });

    test('SABOTAGE: a source that returns the same list for every parent fails '
        'exactly the two-folder arm', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': _CannedLevelSpace(scriptedPlant('ST101'))},
      );

      // The nodes are built rather than walked to: a canned-level source
      // cannot be walked at all, which is itself the point — the walk is the
      // page editor's, and the panel is already broken before the comparison
      // below gets its chance.
      const motor = BrowseNode(
          id: 'ST101.CN01.MOT01',
          displayName: 'MOT01',
          type: BrowseNodeType.folder,
          metadata: {'alias': 'ST101'});
      const other = BrowseNode(
          id: 'ST101.CN04.MOT01',
          displayName: 'MOT01',
          type: BrowseNodeType.folder,
          metadata: {'alias': 'ST101'});

      // Everything a single-folder check would look at still passes.
      expect((await browse.fetchChildren(motor)).map((node) => node.id),
          containsAll(<String>['ST101.CN01.MOT01.setpoint']));
      final children = await browse.fetchChildren(motor);
      final others = await browse.fetchChildren(other);
      final otherIds = others.map((node) => node.id).toSet();
      expect(children.where((node) => otherIds.contains(node.id)), isNotEmpty,
          reason: 'the sabotage must show up here and nowhere else');
    });
  });

  group('detail', () {
    test('a variable carries its reading and its data type', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': scriptedPlant('ST101')},
      );

      final variable = await nodeAt(browse, 'ST101.CN01.MOT01.setpoint');
      final detail = await browse.fetchDetail(variable!);

      expect(detail.dataType, isNotNull);
      expect(detail.dataType, isNotEmpty);
      expect(detail.value, isNotNull);
      expect(detail.value!.quality, Quality.good);
    });

    test('a method is not expandable and carries no reading', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': scriptedPlant('ST101')},
      );

      final method = await nodeAt(browse, 'ST101.CN01.MOT01.reset');

      expect(method!.type, BrowseNodeType.method);
      expect(method.isExpandable, isFalse);
      final detail = await browse.fetchDetail(method);
      expect(detail.value, isNull,
          reason: 'a method has no reading; a value here is an invented one');
      expect(detail.structChildren, isNull,
          reason: 'null means "not a struct" — an empty list would render as a '
              'struct with no members and put a disclosure triangle on a '
              'callable');
    });
  });

  group('resolvePath', () {
    test('an unknown id is null — not empty, not a throw', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': scriptedPlant('ST101')},
      );

      expect(await browse.resolvePath('ST999.CN99.MOT99.setpoint'), isNull);
      // An id on an alias this gateway does not serve at all is the same
      // ordinary case: a page imported from another plant.
      expect(await browse.resolvePath('ST404.CN01.MOT01.setpoint'), isNull);
    });

    test('the chain runs root to leaf, and costs one browse call per level',
        () async {
      final space = scriptedPlant('ST101');
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': space},
      );

      space.resetCalls();
      final chain = await browse.resolvePath('ST101.CN01.MOT01.setpoint');

      expect(chain, isNotNull);
      expect(chain!.map((node) => node.id), [
        'ST101',
        'ST101.CN01',
        'ST101.CN01.MOT01',
        'ST101.CN01.MOT01.setpoint',
      ]);
      // Three levels are descended into: the alias root, CN01 and MOT01. The
      // leaf is not expanded — it is the answer.
      // ignore: avoid_print
      print('resolvePath("ST101.CN01.MOT01.setpoint") cost '
          '${space.childrenCalls} browse calls for '
          '${chain.length - 1} levels descended');
      expect(space.childrenCalls, 3,
          reason: 'one call per level, and never a browseTree — the eager walk '
              'is the mistake this API shape exists to prevent');
    });

    test('an already-mapped folder resolves too, so the panel can preselect a '
        'station', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': scriptedPlant('ST101')},
      );

      final chain = await browse.resolvePath('ST101.CN01.MOT01');
      expect(chain!.last.id, 'ST101.CN01.MOT01');
      expect(chain.first.id, 'ST101');
    });
  });

  group('a link that stops answering', () {
    test('yields an empty level with a recorded reason, never a hung panel',
        () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': _SilentSpace()},
        deadline: const Duration(milliseconds: 50),
      );

      final root = (await browse.fetchRoots()).single;
      final children = await browse
          .fetchChildren(root)
          .timeout(const Duration(seconds: 2), onTimeout: () {
        fail('fetchChildren hung past its own deadline: the panel would spin');
      });

      expect(children, isEmpty);
      expect(browse.incidents, isNotEmpty);
      expect(browse.incidents.single, contains('ST101'));
      // ignore: avoid_print
      print('recorded incident: ${browse.incidents.single}');
    });

    test('an alias with no address space behind it is empty and recorded, not '
        'an exception', () async {
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: const {},
      );

      // supportsBrowse is true on the fake, so the alias IS a root; the space
      // being absent is a configuration gap, and a gap is not a crash.
      final root = (await browse.fetchRoots()).single;
      expect(await browse.fetchChildren(root), isEmpty);
      expect(browse.incidents, hasLength(1));
    });
  });

  group('over a live OPC UA address space', () {
    late OpcUaServerFixture fixture;
    late ua.Client client;
    late Timer clientCrank;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        treePaths: const [
          'ST101.CN01.MOT01.setpoint',
          'ST101.CN01.MOT01.running',
          'ST101.CN04.MOT01.setpoint',
        ],
        methodPaths: const ['ST101.CN01.MOT01.reset'],
      );
      client = ua.Client();
      clientCrank =
          Timer.periodic(const Duration(milliseconds: 10), (_) => client.runIterate(const Duration(milliseconds: 5)));
      await client.connect(fixture.endpoint);
      await client.awaitConnect();
      addTearDown(() async {
        clientCrank.cancel();
        await client.delete();
        await fixture.dispose();
      });
    });

    test('the real tree expands one level at a time, and each level is that '
        'node\'s own', () async {
      final space = OpcUaAddressSpace(alias: 'ST101', client: client);
      final browse = LocalBrowse(
        links: [FakeUpstreamLink(alias: 'ST101')],
        spaces: {'ST101': space},
        deadline: const Duration(seconds: 5),
      );

      final root = (await browse.fetchRoots()).single;
      expect(root.id, 'ST101');

      final conveyors = await browse.fetchChildren(root);
      expect(conveyors.map((node) => node.id),
          containsAll(<String>['ST101.CN01', 'ST101.CN04']));

      final motor = await nodeAt(browse, 'ST101.CN01.MOT01');
      expect(motor, isNotNull);
      final tags = await browse.fetchChildren(motor!);
      expect(tags.map((node) => node.id),
          containsAll(<String>[
            'ST101.CN01.MOT01.setpoint',
            'ST101.CN01.MOT01.running',
            'ST101.CN01.MOT01.reset',
          ]));

      // The two-folder arm, over the wire this time.
      final other = await nodeAt(browse, 'ST101.CN04.MOT01');
      final otherIds =
          (await browse.fetchChildren(other!)).map((node) => node.id).toSet();
      expect(tags.where((node) => otherIds.contains(node.id)), isEmpty);

      // Node kinds survive the translation: the method is the one node that
      // must not offer a disclosure triangle.
      final reset =
          tags.firstWhere((node) => node.id == 'ST101.CN01.MOT01.reset');
      expect(reset.type, BrowseNodeType.method);
      expect(reset.isExpandable, isFalse);

      // And a reading comes back with a quality on it.
      fixture.setValue('ST101.CN01.MOT01.setpoint', 42);
      final detail = await browse.fetchDetail(
          tags.firstWhere((node) => node.id == 'ST101.CN01.MOT01.setpoint'));
      expect(detail.value, isNotNull);
      expect(detail.value!.value, 42);
      expect(detail.dataType, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

// --------------------------------------------------------------- test doubles

/// A scripted address space in the plant's own `AREAnn.DEVnn.SUBnn` shape.
///
/// Deliberately hand-built rather than derived from a keymapping: the whole
/// point of browse is that it shows tags nobody has mapped yet.
ScriptedSpace scriptedPlant(String alias) =>
    ScriptedSpace(alias, <String?, List<String>>{
      null: ['$alias.CN01', '$alias.CN04'],
      '$alias.CN01': ['$alias.CN01.MOT01'],
      '$alias.CN04': ['$alias.CN04.MOT01'],
      '$alias.CN01.MOT01': [
        '$alias.CN01.MOT01.setpoint',
        '$alias.CN01.MOT01.running',
        '$alias.CN01.MOT01.reset',
      ],
      '$alias.CN04.MOT01': [
        '$alias.CN04.MOT01.setpoint',
        '$alias.CN04.MOT01.running',
      ],
    });

/// Walks the tree from the roots to [id], one level at a time.
///
/// Deliberately not `resolvePath`: three arms need to get hold of a node, and
/// reaching it through the method whose correctness is itself under test would
/// make those arms fail for a reason they do not name. `browse_contract.dart`'s
/// `_nodeAt` makes the same choice for the same reason.
Future<BrowseNode?> nodeAt(LocalBrowse browse, String id) async {
  var level = await browse.fetchRoots();
  while (level.isNotEmpty) {
    for (final node in level) {
      if (node.id == id) return node;
    }
    final next = level.where((node) => id.startsWith('${node.id}.')).toList();
    if (next.isEmpty) return null;
    level = await browse.fetchChildren(next.single);
  }
  return null;
}

final class ScriptedSpace implements UpstreamAddressSpace {
  ScriptedSpace(this.alias, this.levels);

  final String alias;
  final Map<String?, List<String>> levels;
  int childrenCalls = 0;

  void resetCalls() => childrenCalls = 0;

  @override
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent) async {
    childrenCalls++;
    final ids = levels[parent?.id] ?? const <String>[];
    return [for (final id in ids) _node(id)];
  }

  @override
  Future<BrowseNodeDetail?> detailOf(BrowseNode node) async =>
      node.type == BrowseNodeType.method
          ? const BrowseNodeDetail(description: 'a callable')
          : BrowseNodeDetail(
              description: node.id,
              dataType: 'Float',
              value: DynamicValue(value: 1.0, quality: Quality.good),
            );

  BrowseNode _node(String id) => BrowseNode(
        id: id,
        displayName: id.split('.').last,
        type: id.endsWith('.reset')
            ? BrowseNodeType.method
            : levels.containsKey(id)
                ? BrowseNodeType.folder
                : BrowseNodeType.variable,
        metadata: {'alias': alias},
      );
}

/// The failure the second fixture folder exists to catch: one canned level,
/// whatever you ask for.
final class _CannedLevelSpace implements UpstreamAddressSpace {
  _CannedLevelSpace(this.honest);

  final ScriptedSpace honest;

  @override
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent) =>
      honest.childrenOf(parent == null
          ? null
          : honest._node('${honest.alias}.CN01.MOT01'));

  @override
  Future<BrowseNodeDetail?> detailOf(BrowseNode node) => honest.detailOf(node);
}

/// A link that accepted the request and never answered — the half-open case.
final class _SilentSpace implements UpstreamAddressSpace {
  @override
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent) =>
      Completer<List<BrowseNode>>().future;

  @override
  Future<BrowseNodeDetail?> detailOf(BrowseNode node) =>
      Completer<BrowseNodeDetail?>().future;
}
