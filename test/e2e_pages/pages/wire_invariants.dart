/// Two of the review's known defects that no single page owns, pinned on the
/// same wire the pages use.
///
/// Neither is one of the eleven routes: history views are `/history-view`'s,
/// and the browse tree is the page editor's key picker. They are here because
/// the review found them on this transport and a lane that stands the real
/// backend up is the cheapest place to keep them red until they are fixed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BrowseNode, BrowseNodeType, DataServiceMethods;
import 'package:tfc_relay_server/tfc_relay_server.dart'
    show AccessPolicyKeyPolicy;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

void wireInvariantCases(BackendBench Function() bench) {
  group('wire invariants the pages depend on', () {
    knownRed(
        'KNOWN RED: history.createView, .updateView and .addPeriod are '
        'refused to a session holding NO group', (tester) async {
      // `policy_state_man.dart`'s `_requireGroup` returns before reading the
      // identity when the member's group is null, and the three creative
      // history-view members are null by D-04. A socket nobody signed in
      // on, at a plant whose anonymous row grants nothing, could therefore
      // save — and with updateView, overwrite — a chart.
      final port = bench().port;
      await live(tester, () async {
        await bench().revokeAnonymous();
        try {
          final nothing = await WireProbe.anonymous(port);
          final create = await nothing.call(
              DataServiceMethods.historyCreateView, {
            'name': 'nobody\'s chart',
            'keys': [plantKey('CN01.speed_hz')],
            'keyConfigs': null,
            'graphConfigs': null,
          });
          expect(create.errorCode, WireErrors.forbidden,
              reason: 'a session holding no group saved a view: $create');
          final update = await nothing.call(
              DataServiceMethods.historyUpdateView, {
            'id': 1,
            'name': 'wiped',
            'keys': <String>[],
            'keyConfigs': null,
            'graphConfigs': null,
          });
          expect(update.errorCode, WireErrors.forbidden,
              reason: 'a session holding no group overwrote a view: $update');
          await nothing.close();
        } finally {
          await bench().restoreAnonymous();
        }
      });
    });

    knownRed(
        'KNOWN RED: browse.fetchDetail does not hand a hidden variable\'s '
        'live value to a caller that labels the node a folder',
        (tester) async {
      // The `BrowseNode` in `fetchDetail`'s params is decoded from the
      // caller's own frame, `type` included. A policy that hides a key must
      // decide by the id, never by the kind the caller claims. The shipped
      // policy hides nothing, so this runs against a second server over the
      // same plant whose policy hides one key.
      final hidden = plantKey('CN01.recipe_id');
      final second = await live(tester, () => bench().secondServer(
          policy: AccessPolicyKeyPolicy(
              visibility: (key, identity) => key != hidden)));
      try {
        await live(tester, () async {
          final eng = await WireProbe.signedIn(second.server.port,
              username: kEngineer, password: kEngineerPassword);
          final honest = await eng.call(DataServiceMethods.browseFetchDetail, {
            'node': const BrowseNode(
                    id: 'HALL1.CN01.recipe_id',
                    displayName: 'recipe_id',
                    type: BrowseNodeType.variable)
                .toJson(),
          });
          expect(honest.isError, isTrue,
              reason: 'the control: asked as a variable, the hidden key is '
                  'refused; got $honest');
          final lie = await eng.call(DataServiceMethods.browseFetchDetail, {
            'node': const BrowseNode(
                    id: 'HALL1.CN01.recipe_id',
                    displayName: 'recipe_id',
                    type: BrowseNodeType.folder)
                .toJson(),
          });
          final leaked = !lie.isError &&
              (lie.result is Map) &&
              (lie.result as Map)['value'] != null;
          expect(leaked, isFalse,
              reason: 'labelled a folder, the hidden variable answered with '
                  'its live value: $lie');
          await eng.close();
        });
      } finally {
        await live(tester, () => second.server.close());
      }
    });
  });
}
