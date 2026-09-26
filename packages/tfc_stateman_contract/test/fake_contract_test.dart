/// The whole contract, in one call, against the reference implementation.
///
/// This is the phase gate: ROADMAP criteria 2 and 3 are that the suite "runs
/// against an arbitrary `StateManApi` instance passed in as a parameter" and
/// "passes against a fake/reference in-memory implementation", and both are
/// statements about the suite as a single artifact rather than about any
/// slice of it. The four per-slice drivers stay where they are — they are the
/// fast feedback while a slice is being worked on — but this file is what says
/// the contract is whole.
///
/// It registers the suite twice, and the second registration is not a
/// duplicate. The first declares every capability and is the accounting run:
/// the cases it runs must be exactly [allContractChecks], or something was
/// dropped. The second declares a source that takes no writes and has no
/// database behind it, browsing a different address space — the shape of a
/// panel talking to a gateway deployed without TimescaleDB — and it exists to
/// prove the capability flags are load-bearing rather than decorative. Three
/// separate ways they could be decorative are ruled out here:
///
///  * a boolean that changes nothing: the second run must execute strictly
///    fewer cases, and exactly as many fewer as the two declined registries
///    hold;
///  * a hook the umbrella declares and never forwards: every hook passed in
///    counts its own calls, and the last group asserts each was reached, so a
///    forwarding line deleted from the umbrella fails here rather than being
///    discovered when `RemoteStateMan` needs it in Phase 4;
///  * a fixture the umbrella defaults instead of forwarding: the second run's
///    source serves a tree the *default* fixture does not describe, so a
///    dropped `browseFixture` makes six browse cases fail rather than pass
///    against landmarks nobody chose.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// 100 ms rather than the fake's 300 ms default, for the same reason
/// `read_contract_test.dart` shortens it: the freshness cases are the only
/// ones in the suite that spend real time, and they are registered twice here.
const _staleAfter = Duration(milliseconds: 100);

/// An ordinary plant key, for the two cases below that poke at the fake
/// directly rather than through the contract.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// The whole file's wall-clock budget, asserted at the end rather than hoped
/// for.
///
/// A contract suite that costs a minute is a contract suite people stop
/// running before they push. The observed runtime is printed by the last case
/// so the margin is a number in the log rather than a belief.
const _budget = Duration(seconds: 60);

/// A sensor reading on the post-freezer line: the designated read-only key.
///
/// The same one `write_contract_test.dart` names, and a real one — read-only
/// devices are why the case exists (`M2400DeviceClientAdapter.write` throws
/// `UnsupportedError` today).
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// The one root of the second run's address space.
///
/// ST101 is deliberately absent. [defaultBrowseFixture] names `ST101` as its
/// root, so a run of the browse cases against this source with the default
/// fixture fails at the first case — which is what makes "the umbrella
/// forwarded the fixture it was given" an observable fact instead of a line of
/// code somebody read once.
const _alternateRoots = <BrowseNode>[
  BrowseNode(
      id: 'ST201',
      displayName: 'ST201 — pökkun (post-freezer)',
      type: BrowseNodeType.folder),
];

/// The default levels, plus a method under the post-freezer motor.
///
/// A fixture must name a method node — a method is the one node kind that must
/// not be expandable — and the conventional tree only has one, under ST101.
///
/// Not const: this level deliberately replaces the one the default tree has for
/// the same parent, and a const map may not be written with a key twice even to
/// override it.
final _alternateChildren = <String, List<BrowseNode>>{
  ...FakeBrowse.defaultChildren,
  'ST201.CN04.MOT01': [
    BrowseNode(
        id: 'ST201.CN04.MOT01.setpoint',
        displayName: 'setpoint',
        type: BrowseNodeType.variable,
        dataType: 'Float'),
    BrowseNode(
        id: 'ST201.CN04.MOT01.running',
        displayName: 'running',
        type: BrowseNodeType.variable,
        dataType: 'Boolean'),
    BrowseNode(
        id: 'ST201.CN04.MOT01.reset',
        displayName: 'reset()',
        type: BrowseNodeType.method),
  ],
};

/// A reading for the variable the alternate fixture points the detail case at.
final _alternateDetails = <String, BrowseNodeDetail>{
  ...FakeBrowse.defaultDetails,
  'ST201.CN04.MOT01.setpoint': BrowseNodeDetail(
    description: 'Hraði færibands 4, mm/s',
    dataType: 'Float',
    value: DynamicValue(value: 900.0),
  ),
};

/// The landmarks of that address space — every one of them different from the
/// default fixture's.
const _alternateFixture = BrowseFixture(
  rootId: 'ST201',
  folderId: 'ST201.CN04.MOT01',
  folderChildIds: [
    'ST201.CN04.MOT01.setpoint',
    'ST201.CN04.MOT01.running',
    'ST201.CN04.MOT01.reset',
  ],
  otherFolderId: 'ST201.CN04',
  variableId: 'ST201.CN04.MOT01.setpoint',
  methodId: 'ST201.CN04.MOT01.reset',
  unknownId: 'ST999.CN99.MOT99.setpoint',
);

void main() {
  final wall = Stopwatch()..start();

  // Every hook counts its own calls. Nothing here changes what the case does —
  // each one delegates to the lever the case would have reached on its own —
  // so the counts measure forwarding and nothing else.
  var attemptsAsked = 0;
  var stalls = 0;
  var linkDrops = 0;
  var seeds = 0;

  FakeStateMan make() => FakeStateMan(staleAfter: _staleAfter);

  FakeStateMan makeAlternate() => FakeStateMan(
        staleAfter: _staleAfter,
        browse: FakeBrowse(
          roots: _alternateRoots,
          children: _alternateChildren,
          details: _alternateDetails,
        ),
      );

  // What actually ran, as opposed to what the accounting says ran. A `setUp`
  // declared in the group fires once per case the umbrella registers into it
  // and never for a skipped one, which makes it the only number in this file
  // that comes from the test runner rather than from the code being measured.
  var ranFull = 0;
  var ranReduced = 0;

  final beforeFull = contractCasesRegistered;
  group('the reference implementation, every capability declared', () {
    setUp(() => ranFull++);
    runStateManContract(
      make,
      readOnlyKey: _readOnlyKey,
      upstreamWriteAttempts: (api, cmd) {
        attemptsAsked++;
        return (api as FakeStateMan).upstreamWriteAttempts(cmd);
      },
      stallWrites: (api) {
        stalls++;
        (api as FakeStateMan).stallWrites();
      },
      dropLinkWithWritesInFlight: (api) {
        linkDrops++;
        (api as FakeStateMan).disconnectUpstream();
      },
      browseFixture: defaultBrowseFixture,
      seedTimeseries: (api, tableName, points) {
        seeds++;
        (api as FakeStateMan).seedTimeseries(tableName, points);
      },
      // FakeStateMan serves the four access families (FakeAccessServices) and
      // implements the session lever, so the fully-capable run judges them too
      // — 17-05. Without this the roster would grow but this "runs everything"
      // arm would stop being true.
      supportsAccessControl: true,
    );
  });
  final full = contractCasesRegistered - beforeFull;

  final beforeReduced = contractCasesRegistered;
  group('a source with no writes, no database and a tree of its own', () {
    setUp(() => ranReduced++);
    runStateManContract(
      makeAlternate,
      supportsWrites: false,
      supportsDataServices: false,
      browseFixture: _alternateFixture,
      // Still an access-serving FakeStateMan, so this run declines exactly
      // writes and data services and nothing else — which is what the
      // arithmetic arm below asserts.
      supportsAccessControl: true,
    );
  });
  final reduced = contractCasesRegistered - beforeReduced;

  group('the run itself', () {
    test('the fully-capable run executes every check the suite has', () {
      expect(full, allContractChecks.length,
          reason: 'the umbrella ran $full of ${allContractChecks.length} '
              'checks against an implementation that declared every '
              'capability. The difference is cases nobody is running: either a '
              'flag defaults to false, or a sub-suite the umbrella no longer '
              'delegates to, and either way the property those cases assert is '
              'unjudged for every implementation that uses this entry point');
    });

    test('declining a capability runs strictly fewer cases, not the same ones',
        () {
      expect(reduced, lessThan(full),
          reason: 'a run declaring no writes and no data services executed as '
              'many cases as one declaring both, so the flags change nothing — '
              'either they are ignored, or the declined cases are passing '
              'vacuously, which is worse than skipping them because the report '
              'then claims a capability the source does not have');
      expect(reduced, full - writeChecks.length - dataServicesChecks.length,
          reason: 'declining writes and data services should remove exactly '
              'the ${writeChecks.length} write and '
              '${dataServicesChecks.length} data-service cases and nothing '
              'else; it removed ${full - reduced}, so a flag is reaching '
              'further than the capability it names');
    });

    test('a cancelled subscription stops being held for closing', () async {
      // WR-08. Nothing ever removed a closer, including on cancel, so a
      // long-lived source — and Phase 3/4 tests will hold one across many
      // cases — accumulated a controller per subscribe call, and dispose then
      // awaited close() on every controller ever created. This is shipped
      // lib/ code, not a test file.
      final source = FakeStateMan(staleAfter: _staleAfter);
      addTearDown(source.dispose);
      expect(source.openHandedOutStreams, 0);

      for (var i = 0; i < 50; i++) {
        final subscription = source.subscribe(_speedKey).listen((_) {});
        await subscription.cancel();
      }

      expect(source.openHandedOutStreams, 0,
          reason: 'fifty subscribe/cancel cycles left '
              '${source.openHandedOutStreams} controllers registered; the '
              'registry tracks streams that still need closing, not every '
              'stream ever handed out');
    });

    test('a live subscription is still held, and closed by dispose', () async {
      final source = FakeStateMan(staleAfter: _staleAfter);
      var done = false;
      source.subscribe(_speedKey).listen((_) {}, onDone: () => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(source.openHandedOutStreams, 1,
          reason: 'deregistering on cancel must not deregister a stream '
              'nobody cancelled');

      await source.dispose();
      expect(done, isTrue,
          reason: 'a consumer that never cancelled must still be told the '
              'source is gone');
      expect(source.openHandedOutStreams, 0);
    });

    test('feeding a hold costs no upstream write attempts', () async {
      // Trap 3. Ten ticks a second through `write` would mint ten cmds a
      // second into the strict `_mintedCmds` set and inflate the attempt
      // counter WRT-03's whole contract rests on. A hold costs exactly two
      // writes — the engage and the release — however long it is held.
      final source = FakeStateMan(staleAfter: _staleAfter);
      addTearDown(source.dispose);

      final hold = await source.holdToRun(_speedKey);
      expect(hold.isHeld, isTrue);
      final engage = source.mintedCmds.single;

      for (var i = 0; i < 10; i++) {
        hold.tick();
      }

      expect(source.mintedCmds, [engage],
          reason: 'ten ticks minted ${source.mintedCmds.length - 1} extra '
              'command ids; a tick is not an operator action and must not '
              'take one');
      expect(source.upstreamWriteAttempts(engage), 1);

      await hold.release();
      expect(source.mintedCmds, hasLength(2),
          reason: 'a whole hold is two writes: the engage and the release');
      for (final cmd in source.mintedCmds) {
        expect(source.upstreamWriteAttempts(cmd), 1);
      }
    });

    test('a hold engages, advances the tag, and writes zero on release',
        () async {
      // D-P5-D: one key, and it is the key passed in — the tag *is* the
      // deadman counter, so what the PLC sees is what this test reads.
      final source = FakeStateMan(staleAfter: _staleAfter);
      addTearDown(source.dispose);

      final hold = await source.holdToRun(_speedKey);
      expect(source.read(_speedKey)?.asInt, 1,
          reason: 'the engage write puts 1 on the tag');

      hold.tick();
      hold.tick();
      expect(source.read(_speedKey)?.asInt, 3);

      await hold.release();
      expect(source.read(_speedKey)?.asInt, 0,
          reason: '0 is reserved for released');
      expect(await hold.onReleased, HoldEnded.operatorLetGo);
    });

    test(
        'writeStatus answers not_received only for a datable cmd minted after '
        'this source started', () async {
      // The gateway's three-piece positive-evidence rule
      // (`value_handlers.dart:357-398`), mirrored rather than loosened: a
      // reference implementation that says not_received more freely than the
      // gateway does is one the contract cannot use, because not_received is
      // the only answer that invites an operator to move a machine again.
      final source = FakeStateMan(staleAfter: _staleAfter);
      addTearDown(source.dispose);

      final applied = await source.write(_speedKey, 12);
      final now = DateTime.now().millisecondsSinceEpoch;
      final fresh = newUlid();
      final ancient = newUlid(nowMs: now - const Duration(days: 1).inMilliseconds);
      final ahead = newUlid(nowMs: now + const Duration(hours: 1).inMilliseconds);
      const gibberish = 'not-a-ulid';

      final answers = await source
          .writeStatus([applied.cmd, fresh, ancient, ahead, gibberish]);

      expect(answers.map((a) => a.cmd).toList(),
          [applied.cmd, fresh, ancient, ahead, gibberish],
          reason: 'the answer is positionally aligned with the question');
      expect(answers[0], isA<WriteApplied>(),
          reason: 'a recorded outcome is the answer, always');
      expect(answers[1], isA<WriteNotReceived>());
      expect(answers[1].isSafeToResend, isTrue);
      expect(answers[2], isA<WriteUnknown>(),
          reason: 'minted before this source existed: forgetting is not '
              'evidence of never happening');
      expect(answers[3], isA<WriteUnknown>(),
          reason: 'minted in a future this source has not reached — a panel '
              'whose clock runs ahead must not buy itself a re-send window');
      expect(answers[4], isA<WriteUnknown>());
      expect((answers[4] as WriteUnknown).reason.kind, 'unrecognized_cmd');
    });

    test('disposing the source releases every live hold', () async {
      // A disposed source that leaves a counter advancing is a machine nobody
      // is holding.
      final source = FakeStateMan(staleAfter: _staleAfter);
      final hold = await source.holdToRun(_speedKey);
      expect(hold.isHeld, isTrue);

      await source.dispose();

      expect(await hold.onReleased, HoldEnded.disposed);
      expect(hold.isHeld, isFalse);
      expect(hold.tick, returnsNormally,
          reason: 'a tick after the source is gone must be a no-op, not a '
              'throw out of a timer nobody is awaiting');
    });

    test('what ran is what the umbrella accounts for', () {
      expect(ranFull, full,
          reason: 'the fully-capable run executed $ranFull cases while '
              'contractCases accounts for $full. The two are computed '
              'independently — one by the test runner, one by the umbrella — '
              'and a difference means a flag the umbrella forwards to a '
              'sub-suite is not the flag it counts with, so the count above '
              'is measuring something other than the run');
      expect(ranReduced, reduced,
          reason: 'the reduced-capability run executed $ranReduced cases while '
              'contractCases accounts for $reduced; the accounting and the '
              'delegation disagree about what a declined capability costs');
    });

    test('every harness hook the umbrella takes reached the case that uses it',
        () {
      expect(attemptsAsked, greaterThan(0),
          reason: 'the upstreamWriteAttempts hook was never called, so the '
              'no-auto-retry case read the count off the harness instead. A '
              'remote implementation, whose attempt count lives on the server, '
              'would be judged against a counter that is not the one the plant '
              'sees');
      expect(stalls, greaterThan(0),
          reason: 'the stallWrites hook was never called, so the in-flight '
              'window was opened by the harness instead of by the lever the '
              'caller supplied');
      expect(linkDrops, greaterThan(0),
          reason: 'the dropLinkWithWritesInFlight hook was never called, so '
              'the write-unknown case cut the link its own way; an '
              'implementation whose link is cut by something else is not being '
              'judged on the ending it will actually meet');
      expect(seeds, greaterThan(0),
          reason: 'the seedTimeseries hook was never called, so the three '
              'timeseries cases seeded through the harness. A source whose '
              'recorder is not in this process would be judged against data it '
              'never received');
    });

    test('the whole contract costs less than its declared budget', () {
      // Printed rather than merely asserted: the margin is what tells the next
      // person whether a case they are about to add is affordable.
      print('the full contract ran in ${wall.elapsed.inMilliseconds} ms '
          '(budget ${_budget.inSeconds} s)');
      expect(wall.elapsed, lessThan(_budget),
          reason: 'the contract took ${wall.elapsed.inSeconds} s. A suite that '
              'costs this much is one people stop running before they push, '
              'and a contract nobody runs is not a contract');
    });
  });
}
