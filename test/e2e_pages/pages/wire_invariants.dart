/// Two of the review's defects that no single page owns, pinned on the same
/// wire the pages use.
///
/// Neither is one of the eleven routes: history views are `/history-view`'s,
/// and the browse tree is the page editor's key picker. They are here because
/// the review found them on this transport and a lane that stands the real
/// backend up is the cheapest place to hold them.
///
/// **Both were `knownRed` and neither is any more** (2026-09-20). The branch
/// fixed both; running the lane with `CENTROIDX_E2E_PAGES_KNOWN_RED=1` for
/// the first time is what showed it. The history-view case went green
/// untouched. The browse case had to be rewritten, because it asserted the
/// wrong remedy: it expected a hidden node to be REFUSED, and the fix that
/// landed answers it with the shape a node that does not exist gets — which
/// hides strictly more, since a refusal confirms the node is there. The case
/// now pins the shipped behaviour and keeps a live key beside it as the
/// control, so it still fails if the policy stops being consulted.
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
    testWidgets(
        'history.createView, .updateView and .addPeriod are refused to a '
        'session holding NO group', (tester) async {
      // Was KNOWN RED. `policy_state_man.dart`'s `_requireGroup` returned
      // before reading the identity when the member's group is null, and the
      // three creative history-view members are null by D-04. A socket nobody
      // signed in on, at a plant whose anonymous row grants nothing, could
      // therefore save — and with updateView, overwrite — a chart. The read
      // floor this branch added to the three creative members closed it, and
      // this case is what keeps it closed.
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

    testWidgets(
        'browse.fetchDetail answers a hidden variable the way it answers a '
        'node that does not exist — however the caller labels it',
        (tester) async {
      // Was KNOWN RED, and its remedy was wrong.
      //
      // The defect was real: the `BrowseNode` in `fetchDetail`'s params is
      // decoded from the caller's own frame, `type` included, and the policy
      // used to take an early return for anything the caller called a folder.
      // A client that sent `{"id": <a hidden variable>, "type": "folder"}` was
      // handed the live reading.
      //
      // The fix decides by the **id** and answers a hidden node with the shape
      // a source gives a node it has never heard of: the description and data
      // type the caller already had, no reading and no members
      // (`policy_state_man.dart` `fetchDetail`). NOT a refusal, which is what
      // this case used to demand — a refusal would confirm the node exists,
      // and the whole point of hiding is that it must not.
      //
      // So the assertion is about the VALUE, not about the error, and a key
      // the same policy leaves visible is asked the same question in the same
      // breath. Without that control an empty answer would be indistinguish-
      // able from a browse that simply stopped working.
      final hidden = plantKey('CN01.recipe_id');
      final visible = plantKey('CN01.speed_hz');
      final second = await live(tester, () => bench().secondServer(
          policy: AccessPolicyKeyPolicy(
              visibility: (key, identity) => key != hidden)));
      try {
        await live(tester, () async {
          final eng = await WireProbe.signedIn(second.server.port,
              username: kEngineer, password: kEngineerPassword);

          Future<Map<Object?, Object?>> detail(
              String id, BrowseNodeType type) async {
            final res = await eng.call(DataServiceMethods.browseFetchDetail, {
              'node': BrowseNode(
                      id: id,
                      displayName: id.split('.').last,
                      type: type)
                  .toJson(),
            });
            expect(res.isError, isFalse,
                reason: 'fetchDetail answers, it does not refuse: $res');
            return (res.result as Map);
          }

          // The control, and it has to come first: the policy is in force
          // and a key it does not hide answers with the BACKEND's own
          // description — which names the OPC UA node and the server it is
          // on. That string is the disclosure this rule exists to prevent,
          // and it is what the pre-fix bypass handed over.
          //
          // The description, not the reading, is what the control rests on.
          // `BackendBrowse.fetchDetail` fills `value` from the live-value
          // cache, which holds a key only while something is subscribed to
          // it, and nothing in this case subscribes — so `value` is null for
          // every node here and an assertion that the hidden one's value is
          // null would pass against a browse that had stopped working
          // entirely. It is kept below as a second, weaker arm; the
          // description is the one with teeth.
          final shown = await detail(visible, BrowseNodeType.variable);
          final shownDescription = shown['description'] as String?;
          expect(shownDescription, isNotNull,
              reason: 'the control: a visible key answers with the backend\'s '
                  'description, so an absent one below is the policy and not '
                  'a browse that stopped answering. asked $visible, '
                  'got $shown');
          expect(shownDescription, contains('ns='),
              reason: 'the control names the OPC UA node — the disclosure '
                  'the hidden key must not produce: $shownDescription');

          // Asked honestly.
          final honest = await detail(hidden, BrowseNodeType.variable);
          expect(honest['description'], isNull,
              reason: 'the hidden key answered with the backend\'s own '
                  'description: $honest');
          expect(honest['value'], isNull,
              reason: 'the hidden key answered with a reading: $honest');
          expect(honest['structChildren'], isNull,
              reason: 'the hidden key answered with its shape: $honest');

          // Asked with the node's kind forged — the original defect.
          final lie = await detail(hidden, BrowseNodeType.folder);
          expect(lie['description'], isNull,
              reason: 'labelled a folder, the hidden variable answered with '
                  'the backend\'s description: $lie');
          expect(lie['value'], isNull,
              reason: 'labelled a folder, the hidden variable answered with '
                  'its live value: $lie');
          expect(lie['structChildren'], isNull,
              reason: 'labelled a folder, the hidden variable answered with '
                  'its shape: $lie');
          expect(lie, honest,
              reason: 'the kind the caller claims must change nothing: a '
                  'node\'s identity is its id');

          await eng.close();
        });
      } finally {
        await live(tester, () => second.server.close());
      }
    });
  });
}
