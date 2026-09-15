import 'dart:convert';

import 'package:test/test.dart';
// The browse shapes now reach consumers through the barrel (plan 01-05), so
// the direct src/ import they needed before is gone: a test that reaches past
// the barrel is a test that can pass while the public surface is broken.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Every browse shape must survive encode → jsonEncode → jsonDecode → decode,
/// and decoders must ignore unknown fields (forward compatibility).
void main() {
  Map<String, Object?> viaJson(Map<String, Object?> json,
          {Map<String, Object?> extra = const {'futureField': 123}}) =>
      jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

  test('BrowseNode round-trips and tolerates unknown fields', () {
    const node = BrowseNode(
      id: 'ns=2;s=ST101.CN01.MTR01.Speed',
      displayName: 'Speed',
      type: BrowseNodeType.variable,
      dataType: 'Float',
      description: 'Hraði færibands',
      metadata: {'server': 'ST101', 'unit': 'm/s'},
    );

    final decoded = BrowseNode.fromJson(viaJson(node.toJson()));

    expect(decoded, node,
        reason: 'a node the page editor is bound to must survive the pipe '
            'unchanged, or the binding silently points at nothing');
    expect(decoded.metadata, {'server': 'ST101', 'unit': 'm/s'});
    expect(decoded.dataType, 'Float');
    expect(decoded.description, 'Hraði færibands');
  });

  test('an unrecognized node type decodes to other, never a throw', () {
    final decoded = BrowseNode.fromJson(const {
      'id': 'x',
      'displayName': 'x',
      'type': 'quantum_folder',
    });

    expect(decoded.type, BrowseNodeType.other,
        reason: 'a newer server adding a node kind must not blank the browse '
            'tree on a deployed panel');
    expect(decoded.isExpandable, isFalse);
  });

  test('a missing node type decodes to other', () {
    final decoded =
        BrowseNode.fromJson(const {'id': 'x', 'displayName': 'x'});
    expect(decoded.type, BrowseNodeType.other);
  });

  test('isExpandable is true for folder and variable only', () {
    BrowseNode of(BrowseNodeType type) =>
        BrowseNode(id: 'i', displayName: 'd', type: type);

    expect(of(BrowseNodeType.folder).isExpandable, isTrue);
    expect(of(BrowseNodeType.variable).isExpandable, isTrue);
    expect(of(BrowseNodeType.method).isExpandable, isFalse);
    expect(of(BrowseNodeType.other).isExpandable, isFalse);

    expect(of(BrowseNodeType.folder).isFolder, isTrue);
    expect(of(BrowseNodeType.variable).isVariable, isTrue);
  });

  test('metadata defaults to empty and is omitted from JSON when empty', () {
    const node = BrowseNode(
        id: 'i', displayName: 'd', type: BrowseNodeType.folder);

    expect(node.metadata, isEmpty);
    expect(node.toJson().containsKey('metadata'), isFalse,
        reason: 'browse results fan out per keystroke; empty maps are bytes '
            'paid for on every node');
    expect(node.toJson().containsKey('dataType'), isFalse);
    expect(node.toJson().containsKey('description'), isFalse);
    expect(BrowseNode.fromJson(viaJson(node.toJson())), node);
  });

  test('an all-absent BrowseNodeDetail encodes to {} and decodes back equal',
      () {
    const detail = BrowseNodeDetail();

    expect(detail.toJson(), isEmpty);
    expect(BrowseNodeDetail.fromJson(viaJson(detail.toJson())), detail);
  });

  test('BrowseNodeDetail round-trips a bad-quality DynamicValue', () {
    final detail = BrowseNodeDetail(
      description: 'Motor speed',
      dataType: 'Float',
      value: DynamicValue(
        value: 42.5,
        quality: Quality.badCommFault,
        typeId: ValueType.double,
        sourceTypeId: 'ns=2;s=Float',
        sourceTime: DateTime.utc(2026, 8, 13, 9, 30, 15, 250),
      ),
    );

    final decoded = BrowseNodeDetail.fromJson(viaJson(detail.toJson()));

    expect(decoded, detail);
    expect(decoded.value!.quality, Quality.badCommFault,
        reason: 'the detail pane must show a stale value as stale, not as a '
            'plausible-looking number');
    expect(decoded.value!.typeId, ValueType.double);
    expect(decoded.value!.sourceTypeId, 'ns=2;s=Float');
    expect(decoded.value!.asDouble, 42.5);
  });

  test('BrowseNodeDetail round-trips struct children', () {
    const detail = BrowseNodeDetail(
      dataType: 'ST_Weigher',
      structChildren: [
        BrowseNode(
            id: 'ns=2;s=W.Weight',
            displayName: 'Weight',
            type: BrowseNodeType.variable),
        BrowseNode(
            id: 'ns=2;s=W.Reset',
            displayName: 'Reset',
            type: BrowseNodeType.method),
      ],
    );

    final decoded = BrowseNodeDetail.fromJson(viaJson(detail.toJson()));

    expect(decoded, detail);
    expect(decoded.structChildren, hasLength(2));
    expect(decoded.structChildren![1].type, BrowseNodeType.method);
  });

  test('an empty struct child list is distinct from no struct children', () {
    const empty = BrowseNodeDetail(structChildren: []);

    expect(empty.toJson()['structChildren'], isEmpty,
        reason: '"a struct with no members" and "not a struct" are different '
            'answers and the pane renders them differently');
    expect(BrowseNodeDetail.fromJson(viaJson(empty.toJson())), empty);
    expect(BrowseNodeDetail.fromJson(viaJson(empty.toJson())).structChildren,
        isNotNull);
  });

  test('a resolved path is an ordered root → leaf chain of BrowseNodes', () {
    const chain = [
      BrowseNode(id: 'ns=2;s=ST101', displayName: 'ST101', type: BrowseNodeType.folder),
      BrowseNode(id: 'ns=2;s=ST101.CN01', displayName: 'CN01', type: BrowseNodeType.folder),
      BrowseNode(
          id: 'ns=2;s=ST101.CN01.Speed',
          displayName: 'Speed',
          type: BrowseNodeType.variable),
    ];

    final encoded = jsonEncode([for (final n in chain) n.toJson()]);
    final decoded = [
      for (final n in jsonDecode(encoded) as List)
        BrowseNode.fromJson((n as Map).cast<String, Object?>())
    ];

    expect(decoded, chain,
        reason: 'opening the browse panel on an already-bound value '
            'pre-selects it by walking this chain root → leaf');
    expect(decoded.last.id, 'ns=2;s=ST101.CN01.Speed',
        reason: 'the last entry is the target node itself');
  });
}
