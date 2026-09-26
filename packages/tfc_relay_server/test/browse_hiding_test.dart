@TestOn('vm')

/// A hidden tag stays hidden however the caller describes it.
///
/// `_PolicyBrowse._visible` decided kind-first: `if (!node.isVariable) return
/// true`. On `fetchDetail` the [BrowseNode] is decoded from the CALLER's own
/// frame (`browse.dart:70-78`), so `isVariable` is a field the caller fills
/// in — and a client that claimed `type: "folder"` for a hidden variable took
/// the early return and was handed its live reading.
///
/// The rule the hiding design rests on (wire API §9, last section) is that a
/// key the policy will not show is spelled as **absent**, so a caller cannot
/// probe for the existence of keys it may not see. A field the prober controls
/// cannot be part of that decision.
library;

import 'package:tfc_access/tfc_access.dart' show AccessGroup;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

/// The tag the policy hides. `PermissiveSeriesResolver` maps a node id to
/// itself, so this id IS the plant key `canSee` is asked about.
const _hidden = 'ST101.CN02.MOT01.speed';

/// One the station may see, so the arms prove hiding rather than a dead browse.
const _shown = 'ST101.CN01.MOT01.speed';

void main() {
  late PolicyStateMan policy;

  setUp(() {
    final plant = FakeStateMan(
      browse: FakeBrowse(
        children: const {
          _hidden: [
            BrowseNode(
                id: '$_hidden.member',
                displayName: 'member',
                type: BrowseNodeType.variable),
          ],
          _shown: [
            BrowseNode(
                id: '$_shown.member',
                displayName: 'member',
                type: BrowseNodeType.variable),
          ],
        },
        details: {
          _hidden: BrowseNodeDetail(
              description: 'THE HIDDEN TAG',
              value: DynamicValue(value: 1234.5)),
          _shown: BrowseNodeDetail(
              description: 'an ordinary tag', value: DynamicValue(value: 7.0)),
        },
      ),
    );
    addTearDown(plant.dispose);
    policy = PolicyStateMan(
      source: plant,
      policy: ScriptedPolicy.hiding(const {_hidden}),
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => stationHolding(const {AccessGroup.operate}),
    );
  });

  BrowseNode node(String id, {required bool variable}) => BrowseNode(
        id: id,
        displayName: id,
        type: variable ? BrowseNodeType.variable : BrowseNodeType.folder,
      );

  test('a hidden variable, declared honestly, gets the nonexistent shape',
      () async {
    final detail =
        await policy.browse.fetchDetail(node(_hidden, variable: true));
    expect(detail.value, isNull, reason: 'the baseline the fix must preserve');
  });

  test('CLAIMING it is a folder does not reveal it', () async {
    final detail =
        await policy.browse.fetchDetail(node(_hidden, variable: false));
    expect(detail.value, isNull,
        reason: 'the caller chose the word "folder" and the policy believed '
            'it. A node\'s identity is its id; its type is a rendering hint, '
            'and the prober controls it');
  });

  test('a visible tag is still served, whatever kind it claims', () async {
    for (final variable in const [true, false]) {
      final detail =
          await policy.browse.fetchDetail(node(_shown, variable: variable));
      expect(detail.value, isNotNull,
          reason: 'hiding must not become a browse that shows nothing');
    }
  });

  test('the children of a hidden node are not listed', () async {
    final children =
        await policy.browse.fetchChildren(node(_hidden, variable: true));
    expect(children, isEmpty,
        reason: 'struct members map to no key of their own, so each child '
            'passed the per-node check on its own account and the shape of a '
            'hidden tag was disclosed by asking about it directly');
  });

  test('the children of a visible node still are', () async {
    final children =
        await policy.browse.fetchChildren(node(_shown, variable: true));
    expect(children, isNotEmpty);
  });
}
