/// The contract suite with a fault proxy in the path.
///
/// **The named scenarios moved to `test/gate/` in Phase 7 (07-02).** F1/F8,
/// F4/F5, F7, F13 and F18 are now five files there, named by their catalogue
/// row so `test/gate/gate_manifest_test.dart` can count them against the
/// F1–F21 registry without anyone claiming a row by hand. Their bodies did not
/// change in the move.
///
/// What stayed is this file's other half, and the two answer different
/// questions. A scenario case asks whether one named fault behaves the way the
/// catalogue says it must — it injects, it waits, it judges one property. This
/// leg asks something the gate cannot: whether *the whole contract*, all 44
/// checks of it, still holds with two extra loopback hops and a lever in the
/// path. Its output is an accounting — `reachableThroughTheProxy`, the named
/// gap, and the cross-read against the WS leg — and that accounting is about
/// contract checks, not scenarios. Moving the scenarios out therefore changes
/// none of the numbers below; if it had, the move would have been the finding.
///
/// **The suite through the proxy** asks whether the properties survive two
/// extra loopback hops with a lever on them. The settings are benign — a few
/// milliseconds of latency and a rate no snapshot in this suite comes near —
/// because the claim is *the same 44 properties, judged the same way*, not
/// "the client copes with a bad link", which is the second half's job. The
/// counts are asserted exactly as the WS leg asserts them: a fault path that
/// quietly runs fewer checks is the same defect as a leg that lowered a
/// capability flag, and it is harder to spot because the report still says the
/// fault leg passed.
///
/// **Every timing assertion is a window.** STATE's Phase 2 handoff measured a
/// connect attempt completing on the far side of a proxy state transition —
/// `t=1204ms forwarding=false connect OK in 189ms` — so a flag read at
/// assertion time does not describe what the connection experienced. Nothing
/// here compares a duration for equality and nothing reads a proxy state at an
/// instant; the bands are the same ones the other two packages use, Linux
/// 20/100 and 75/150 elsewhere, because two packages that disagree about what
/// "on time" means would eventually disagree about whether the gateway is
/// healthy.
///
/// **Every case that depends on prior state carries an anti-vacuity arm.** A
/// fault case is the easiest kind of test to write vacuously: cut a link that
/// was never carrying anything and assert that nothing was lost.
///
/// **Every leg here is plaintext, and that is a decision rather than an
/// oversight.** `faultFixture` grew an opt-in TLS mode in 06-07 and nothing in
/// this file uses it, for two reasons that both cost something if a future
/// reader "upgrades" these legs to wss. First, a TLS fixture cannot install a
/// [FrameSeam]: the seam arrives through `dial:`, and a fixture that passes
/// `dial:` bypasses the panel's own pinned `HttpClient` — so `fixture.seam`
/// throws on a TLS leg, and the gate files' `inject` and `seam.dials` readings
/// would go with it. Second, and less visibly, byte-level truncation stops
/// meaning what it means here: `cutMidFrame(n)` counts wire bytes, so under TLS
/// the cut lands inside a TLS record, the record is discarded whole, and the
/// decoder receives *nothing* rather than a fragment (measured in
/// `tls_fault_test.dart`'s last group: 64 bytes across the wire, zero bytes to
/// the decoder). The frame-level truncations these legs and
/// `truncated_write_test.dart` depend on live one layer above the socket and
/// must stay there. The TLS failure paths have their own file; this one keeps
/// the decoder honest.
@TestOn('vm')
@Tags(['contract', 'faults'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// The reference implementation's sub-API fakes, for the factory signature: the
// contract barrel exports no implementation on purpose, so a harness that has
// to have something to serve names them from their own library.
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/client_harness.dart';

// ---------------------------------------------------------------------------
// The suite, through the proxy.
// ---------------------------------------------------------------------------

/// The designated read-only key, character-identical to the other legs.
///
/// Supplied so the read-only case *runs*: `runWriteContract` drops it when no
/// key is declared, and a dropped case is one fewer than
/// `allContractChecks.length` — which the accounting below would report as a
/// capability switched off. Correctly, because it would be one.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// One-way delay through the proxy for the suite leg.
///
/// Benign on purpose: a round trip crosses the proxy twice, so this is 6 ms on
/// top of a transport whose measured floor is already 50 ms (04-RESEARCH
/// Finding 8), and every `within()` budget inside the suite is 200 ms. A leg
/// that made the suite fail on timing would be reporting the proxy, not the
/// client.
const _benignLatency = Duration(milliseconds: 3);

/// Bytes per second the proxy will forward in each direction during the suite
/// leg.
///
/// 4 MB/s against a page whose largest single message — the 314-key snapshot —
/// is a few tens of kilobytes: the meter is armed and demonstrably in the path,
/// and no message in the suite waits on it for a measurable time.
const _benignThrottle = 4 * 1024 * 1024;

/// What this leg passes today, and it is the WS leg's number by construction.
///
/// The two legs judge the same implementation over the same gateway; the only
/// difference is two loopback hops. If this number and
/// `ws_contract_test.dart`'s ever disagree, one of the two legs is running a
/// different set of checks and the difference is the finding — which is why
/// the accounting case below reads that file rather than trusting this comment.
///
/// 31 until Phase 5, when the suite grew six checks — five hold-to-run
/// properties and one `writeStatus` property — all of them reachable, because
/// the gateway handler behind them landed in the same phase (05-05) rather
/// than being deferred. The WS leg's own comment carries the argument in full.
///
/// 37 until 10-02, when the four `browse.*` handlers landed and the six browse
/// checks moved out of the gap list below and into this number, in the same
/// commit on both legs. Same-commit is not tidiness here: the two legs
/// cross-check each other by text (the last case in this file), so a
/// half-flipped pair reports a leg disagreement — the loudest failure this
/// suite has — for a change that is actually correct on both sides.
///
/// 43 until 10-03, whose four `timeseries.*` handlers made it 46; 46 until
/// 10-04, whose eleven `historyViews.*` ones made it 48; and 48 until 10-05,
/// whose fifteen `preferences.*` ones make it **50** by taking the last two
/// entries out of the gap list below in the commit that registered them.
///
/// **And 50 until the 10-REVIEW fix cycle, whose CR-02 makes it 51** — by a
/// mechanism neither leg had seen before. Not a handler landing: a *check*
/// landing. `preferences.clear` had no judge on any leg, which is how the
/// widest method on the interface shipped behind the role that sets a theme;
/// `checkPreferenceClearCarriesItsAllowList` is the eighth data-services check
/// and it is reachable on the day it is written, because the handler behind it
/// landed back in 10-05.
///
/// **51 is the whole registry**, so this leg passes every check the in-memory
/// reference leg passes, through two loopback hops and a fault proxy. There is
/// nothing left for the gap list to name.
const int reachableThroughTheProxy = 51;

/// Every check this leg does not pass, by name. **It is empty as of 10-05**,
/// and it is identical to `ws_contract_test.dart`'s for the reason it was
/// always identical: a proxy in the path cannot add or remove a handler, so
/// any difference between the two lists is a leg that has drifted rather than
/// a transport that behaves differently.
///
/// The six `browse.*` entries were deleted in 10-02, in the same commit as the
/// WS leg's and as the handlers themselves; the three `timeseries.*` ones went
/// the same way in 10-03, the two `historyViews.*` ones in 10-04 and the last
/// two `preferences.*` ones in 10-05.
///
/// **The cross-read at the bottom of this file still bites with an empty
/// list**, and that is worth stating because it is exactly the kind of claim
/// that is assumed and wrong. What the empty list makes vacuous is the
/// *`missing`* comparison — nothing to look for, nothing missing — and the
/// anti-vacuity arm in front of it does not depend on the list at all: it
/// asserts the WS leg's file is where this one thinks it is, and it fails if
/// the working directory has moved. Both halves were run at empty.
const List<String> unreachableThroughTheProxy = <String>[];

/// The WS leg, read as text so the two gap lists cannot drift apart quietly.
///
/// A file read rather than an import: importing another test library to borrow
/// a constant couples the two legs' *names*, and the name is the part most
/// likely to change. The text is the claim.
const _wsLegPath = 'test/contract/ws_contract_test.dart';

/// One gateway-served client with the proxy in front of it, at benign settings.
///
/// The levers are armed inside `ready` rather than by the case, because the
/// proxy binds asynchronously (the whole reason the dial is a seam) and the
/// suite's factory has to return synchronously — 04-RESEARCH Finding 6, the
/// constraint this package keeps running into.
StateManApi _proxiedServedFake({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
}) {
  final fixture = relayFixture(
    staleAfter: staleAfter,
    readOnlyKeys: readOnlyKeys,
    writeLatency: writeLatency,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
    withProxy: true,
  );
  unawaited(fixture.ready.then((_) {
    fixture.proxy.latency = _benignLatency;
    fixture.proxy.throttleBytesPerSec = _benignThrottle;
  }).catchError((Object _) {}));
  return fixture.api;
}

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, through a fault proxy', () {
    setUp(() => ran++);
    runStateManContract(
      _proxiedServedFake,
      readOnlyKey: _readOnlyKey,
      browseFixture: defaultBrowseFixture,
      // The only override this leg takes, and it changes *when* the link is
      // cut, never what is asserted afterwards (`client_harness.dart`).
      dropLinkWithWritesInFlight: dropUpstreamUnderAWriteInFlight,
      expectUnreachable: unreachableThroughTheProxy.toSet(),
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    // The one named gap this leg carries: the access family 17-05 merged
    // into the kit roster (51 -> 78). RemoteStateMan serves no access surface
    // yet, so the umbrella's supportsAccessControl default (false) holds, and
    // the gap is pinned by NAME rather than absorbed into a lower count.
    // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
    final accessGap = accessChecks.keys.toSet();

    test('every check outside the named access gap was registered against '
        'the fault path, and the gap is pinned by name', () {
      final entitled = contractCases(readOnlyKey: _readOnlyKey);
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());
      expect(gap, accessGap,
          reason: 'this leg is short of the full roster by cases that are '
              'not the access family. That is a second capability switched '
              'off inside the first one\'s arithmetic, and the cases behind '
              'it are unjudged on the one path where a fault can reach them');
      expect(registered + gap.length, allContractChecks.length,
          reason: 'the umbrella registered $registered and the named access '
              'gap holds ${gap.length}; together they must reconcile to the '
              'roster of ${allContractChecks.length}, or a check exists that '
              'is neither run nor accounted for');
    });

    test('every registered check actually started', () {
      expect(ran + accessGap.length, allContractChecks.length,
          reason: '$ran of $registered registered cases actually ran, and '
              'the named access gap holds ${accessGap.length}. The '
              'difference is a case registered and then skipped, which the '
              'registration count cannot see: the report shows a skip reason, '
              'the suite stays green, and the property is as unjudged as it '
              'would have been with the capability off');
    });

    test('the reachable set and the named gaps account for every check', () {
      expect(
          reachableThroughTheProxy +
              unreachableThroughTheProxy.length +
              accessGap.length,
          allContractChecks.length,
          reason: 'this leg claims to pass $reachableThroughTheProxy checks, '
              'names ${unreachableThroughTheProxy.length} it does not, and '
              'carries the ${accessGap.length}-check access gap (17-06/17-08 '
              'opt this leg in; 17-14 empties it), which is '
              '${reachableThroughTheProxy + unreachableThroughTheProxy.length + accessGap.length} '
              'of ${allContractChecks.length}. The three must account for the '
              'whole suite or the gap is not a gap, it is a number somebody '
              'stopped maintaining');
    });

    test('the fault leg names the same gap as the WS leg', () {
      final ws = File(_wsLegPath);
      // Anti-vacuity: a sweep against a file that is not there passes by
      // having nothing to read, and the working directory `dart test` was
      // invoked from is exactly the sort of thing that changes silently.
      expect(ws.existsSync(), isTrue,
          reason: 'the WS leg was not found at $_wsLegPath, so this comparison '
              'has nothing to compare against and every name below is '
              'excused. Check the directory dart test was invoked from');

      final source = ws.readAsStringSync();
      final missing = unreachableThroughTheProxy
          .where((name) => !source.contains(name))
          .toList();
      expect(missing, isEmpty,
          reason: 'these checks are excused on the fault leg and are not '
              'excused on the WS leg: $missing. The two legs run the same '
              'client against the same gateway and differ only by two loopback '
              'hops, so a check that passes over one and is excused over the '
              'other is either a real fault-path defect wearing a known gap\'s '
              'clothes, or a gap list somebody closed in one place and forgot '
              'in the other');
    });
  });
}
