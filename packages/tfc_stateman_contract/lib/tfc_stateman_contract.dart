/// The shared contract every `StateManApi` implementation is judged against.
///
/// One suite runs against `LocalStateMan` (server, over DeviceClients and
/// TimescaleDB, Phase 8) and `RemoteStateMan` (client, over the pipe, Phase 4),
/// and later against both through a fault-injection proxy. That is only
/// possible because this package imports **no implementation**: the sole
/// coupling to an implementation is the factory function
/// [runStateManContract] — and every sub-suite — takes as a parameter.
///
/// It is also a separate package on purpose. `package:test` is a real entry in
/// this package's `dependencies`, which would be unacceptable in
/// `tfc_relay_protocol` — that package is imported by the Flutter app, and
/// `test` pulls `analyzer` into the app's version solve.
///
/// ## Running it
///
/// ```dart
/// void main() => runStateManContract(MyStateMan.new, readOnlyKey: 'ST301...');
/// ```
///
/// That is the whole integration. The sub-suites stay individually exported so
/// an implementation can run a subset while it is being built — a source with
/// only the value path working can run [runSubscribeContract] alone on day one
/// — but the umbrella is what a finished implementation is measured by.
///
/// ## What a partial implementation does instead of forking
///
/// Some implementations legitimately cannot do some of this: a gateway with no
/// historian configured has no data services, a source whose keys come from a
/// config file has no address space to browse, and an M2400 weigher adapter
/// takes no writes at all (`M2400DeviceClientAdapter.write` throws
/// `UnsupportedError` today). Each of those declares itself through a
/// capability flag below, **once, where it registers the suite**. The
/// alternative — a second suite, or a check that quietly passes when it cannot
/// run — is how a capability becomes untested everywhere, and a skipped group
/// says so on the run report where a vacuous pass says nothing.
///
/// A flag the umbrella fails to forward is a capability that stops being
/// judged, silently, for every implementation. `test/suite_integrity_test.dart`
/// asserts by reflection that the named parameters here and the named
/// parameters of the eight `run…Contract` functions are the same set, so
/// dropping one is a test failure rather than a discovery three phases later.
///
/// ## Two things that are deliberately *not* parameters here
///
/// The freshness deadline is one: it is read from
/// [StateManHarness.staleAfter], because how long a value may go unheard-of is
/// a property of the source — a gateway polling a slow serial line and an
/// in-memory fake do not owe the operator the same number — and a suite-level
/// override would let a caller widen a deadline instead of meeting it.
///
/// The health/epoch keys are the other: `PIPE.*` keys are ordinary
/// subscribable keys (HLTH-01), so
/// [checkHealthKeysAreSubscribableLikeAnyTag] judges them through the same
/// value path as a temperature. There is nothing for a `hasUpstreamEpoch` flag
/// to switch off, and a flag that switches nothing off is a knob that looks
/// like a capability declaration and is not one.
///
/// The reference implementation is deliberately **not** exported from here.
/// The fakes live under their own import path in `lib`, one library each, so
/// nothing can acquire an implementation — or a deliberately broken one — by
/// depending on the contract. This library names none of them, which is a
/// dependency direction worth being able to grep for.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'src/access_contract.dart';
import 'src/browse_contract.dart';
import 'src/check.dart';
import 'src/data_services_contract.dart';
import 'src/freshness_contract.dart';
import 'src/hold_contract.dart';
import 'src/read_contract.dart';
import 'src/store_contract.dart';
import 'src/subscribe_contract.dart';
import 'src/write_contract.dart';

export 'src/access_contract.dart';
export 'src/browse_contract.dart';
export 'src/check.dart';
export 'src/data_services_contract.dart';
export 'src/freshness_contract.dart';
export 'src/harness.dart';
export 'src/hold_contract.dart';
export 'src/hold_harness.dart';
export 'src/meta.dart';
export 'src/read_contract.dart';
export 'src/store_contract.dart';
export 'src/subscribe_contract.dart';
export 'src/write_contract.dart';

/// Every sub-suite's registry, keyed by the group name the umbrella runs it
/// under.
///
/// The one place that knows how many parts the suite has. `allContractChecks`
/// merges it, the integrity tests iterate it, and a new sub-suite becomes
/// visible to both by being added here — which is the whole reason it exists
/// as data rather than as references scattered through this file.
///
/// `hold` is the eighth, added in Phase 5 with the deadman it judges
/// (05-RESEARCH §C.3 recommends a registry of its own rather than five more
/// entries in `write`: a source can take writes and still have nothing to
/// hold, and `supportsWrites` should not be the flag that switches a deadman
/// off).
///
/// `access` is the ninth, added in Phase 17: templates, roles-and-users, the
/// audit trail and the backend's config, judged on any leg through the session
/// lever `access_contract.dart` documents. Gated by `supportsAccessControl`,
/// which — unlike the other capability flags — defaults **false**, because most
/// implementations of this interface serve no access surface.
const contractRegistries = <String, Map<String, Check<StateManApi>>>{
  'subscribe': subscribeChecks,
  'store': storeChecks,
  'read': readChecks,
  'freshness': freshnessChecks,
  'write': writeChecks,
  'browse': browseChecks,
  'data services': dataServicesChecks,
  'hold': holdChecks,
  'access': accessChecks,
};

/// Every registered check in the suite, keyed by the property it asserts.
///
/// Nothing is asserted here — `test/suite_integrity_test.dart` owns the
/// assertions. This is the enumeration those tests iterate: every check run
/// against an implementation that never responds (so none of them can hang),
/// and every check's name compared against the top-level `check…` functions
/// the library declares (so none of them is orphaned).
///
/// A merge, so a case name used twice in two registries would collapse two
/// checks into one. That is exactly the silent loss the integrity tests
/// forbid: they assert this map is as long as the registries are, together.
Map<String, Check<StateManApi>> get allContractChecks => {
      for (final registry in contractRegistries.values) ...registry,
    };

/// The cases [runStateManContract] will actually **run** under these
/// capabilities — the accounting behind "nothing was silently dropped".
///
/// Not what it registers: a declined capability is registered and skipped, so
/// it appears on the run report as a capability this implementation does not
/// have rather than as nothing at all. This map is the subset that will
/// execute, which is the number worth comparing against
/// [allContractChecks].
///
/// The hook parameters are absent on purpose: a hook rebinds a case, it never
/// adds or removes one, so it cannot change this count. [readOnlyKey] can, and
/// does — see below. So can [supportsHoldToRun], which takes all five
/// [holdChecks] out at once and is the flag most likely to be declined by a
/// real device adapter, so a leg that forgot to gate on it here would report a
/// count nobody could reconcile.
Map<String, Check<StateManApi>> contractCases({
  bool supportsWrites = true,
  String? readOnlyKey,
  bool supportsBrowse = true,
  bool supportsDataServices = true,
  bool supportsHoldToRun = true,
  bool supportsAccessControl = false,
}) =>
    {
      ...subscribeChecks,
      ...storeChecks,
      ...readChecks,
      ...freshnessChecks,
      if (supportsWrites)
        // Identity against the exported tear-off rather than against the case
        // name: `runWriteContract` drops this one case when nothing is
        // read-only, and repeating its sentence here would be a second copy of
        // a string that has to stay in step with the first.
        for (final entry in writeChecks.entries)
          if (readOnlyKey != null ||
              entry.value != checkReadOnlyKeyIsRejectedNotThrown)
            entry.key: entry.value,
      if (supportsBrowse) ...browseChecks,
      if (supportsDataServices) ...dataServicesChecks,
      if (supportsHoldToRun) ...holdChecks,
      // Defaults false, unlike its siblings: most StateManApi implementations
      // are not access-serving (the plant leg administers no roles), so the
      // umbrella opts them out and an access-serving leg opts in — the same
      // shape supportsDataServices takes for a source with no historian.
      if (supportsAccessControl) ...accessChecks,
    };

/// How many cases every [runStateManContract] call in this test file has
/// registered to run, cumulatively.
///
/// Read it before and after a call and the difference is what that call
/// contributes. A driver asserts on that difference — `expect(full,
/// allContractChecks.length)` is how "no capability flag was left false by
/// accident" is stated as a number, and it is a number no test-runner API
/// offers from inside the file being registered.
int get contractCasesRegistered => _casesRegistered;
var _casesRegistered = 0;

/// Runs every sub-suite against implementations from [make].
///
/// [make] is called once per case and the instance disposed by `addTearDown`,
/// inside each sub-suite: a notification count, an attempt counter and a
/// minted-id list are only meaningful when nothing from a previous case has
/// touched them.
///
/// ### Capability flags
///
/// [supportsWrites] — `false` for a source that takes no writes at all. An
/// M2400 weigher speaks a read-only protocol; a diagnostics-only client is
/// given a read-only session. The write group is skipped with a reason rather
/// than passed.
///
/// [readOnlyKey] — a key of this source's that the *device* refuses writes to,
/// which is a property of the device and not of the pipe. Null drops the
/// read-only case alone: an implementation with nothing read-only about it has
/// no way to satisfy it honestly.
///
/// [supportsBrowse] — `false` for a source with no address space to navigate,
/// such as one serving a fixed key list out of a config file.
///
/// [browseFixture] — the landmarks the browse cases navigate to, in *this*
/// source's address space. Defaults to the conventional
/// [defaultBrowseFixture] tree that the reference implementation seeds; a
/// gateway browsing a real ST101 over OPC UA passes its own.
///
/// [supportsDataServices] — `false` for a source with no historian and no
/// preference store behind it: a gateway deployed without TimescaleDB, or a
/// panel talking to one.
///
/// [supportsHoldToRun] — `false` for a source with no deadman to offer: an
/// adapter over a read-only device protocol (the M2400 weigher speaks one) has
/// no tag to hold. A flag of its own rather than a corner of [supportsWrites],
/// because a source can take writes and still have nothing to hold.
///
/// [supportsAccessControl] — `true` for a source that serves the four access
/// families (templates, roles-and-users, audit, backend config) and implements
/// the test-only [StateManAccessHarness] session lever. Defaults **false**: the
/// plant leg administers no roles, so the access group is skipped for it with a
/// reason on the record, exactly as [supportsDataServices] skips the historian.
///
/// ### Harness hooks
///
/// Each of these overrides where one case gets its lever or its observable.
/// Left null, the case reads it off [StateManWriteHarness] /
/// [StateManDataHarness], which is what every in-memory implementation does.
/// They exist for a source whose plant-side machinery is not in the same
/// process as the test — `RemoteStateMan`'s upstream attempt count lives on
/// the server and arrives over a side channel, and its recorder is a database
/// on another host.
///
/// [upstreamWriteAttempts] — how many times `cmd` has been sent upstream.
/// [stallWrites] — hold writes open, so the in-flight window can be observed.
/// [dropLinkWithWritesInFlight] — cut the link under a write that is out.
/// [seedTimeseries] — record samples, as the gateway's recorder would.
///
/// ### Proving a gap instead of hiding it
///
/// [expectUnreachable] names checks whose *methods this peer does not have
/// yet*. Each named case still registers and still runs — so the counts a
/// driver asserts on stay whole — but it passes by failing with exactly
/// JSON-RPC -32601, and fails if it succeeds, fails with any other code, or
/// fails with no code at all. See [expectUnreachableMethod] for why that is
/// the only one of the four available options that does not rot.
///
/// This is **not** a way to excuse a red case. It is the opposite of lowering
/// [supportsBrowse] or [supportsDataServices]: those delete the cases and leave
/// the properties unjudged, while this one keeps them running and pins the
/// reason they cannot pass to a single wire code that stops being true the day
/// the handler lands.
///
/// Only browse and data-services checks may be named. The core groups —
/// subscribe, store, read, freshness, write — reach an implementation over
/// methods any peer serving this interface at all must have, so a
/// method-not-found there is a broken peer rather than an unbuilt one, and
/// excusing it would be exactly the rot this parameter exists to avoid.
void runStateManContract(
  StateManApi Function() make, {
  bool supportsWrites = true,
  String? readOnlyKey,
  int Function(StateManApi api, String cmd)? upstreamWriteAttempts,
  void Function(StateManApi api)? stallWrites,
  void Function(StateManApi api)? dropLinkWithWritesInFlight,
  bool supportsBrowse = true,
  BrowseFixture browseFixture = defaultBrowseFixture,
  bool supportsDataServices = true,
  void Function(StateManApi api, String tableName, List<TimeseriesData> points)?
      seedTimeseries,
  bool supportsHoldToRun = true,
  bool supportsAccessControl = false,
  Set<String> expectUnreachable = const {},
}) {
  // At registration, not inside a case: a name that matches nothing would
  // otherwise be silently ignored, the driver's arithmetic would still add up,
  // and the leg would report a gap it was no longer proving.
  final nameable = {...browseChecks.keys, ...dataServicesChecks.keys};
  final unnameable = expectUnreachable.difference(nameable);
  if (unnameable.isNotEmpty) {
    throw ArgumentError.value(
        unnameable.toList(),
        'expectUnreachable',
        'these are not browse or data-services checks. Only those two groups '
            'may be declared unreachable — every other check reaches the '
            'implementation over a method any peer serving StateManApi must '
            'already have, so -32601 there is a broken peer, not an unbuilt '
            'one. A name matching no check at all is the other possibility, '
            'and it means the gap list has gone stale');
  }

  group('StateManApi contract', () {
    runSubscribeContract(make);
    runStoreContract(make);
    runReadContract(make);
    runFreshnessContract(make);
    runWriteContract(
      make,
      supportsWrites: supportsWrites,
      readOnlyKey: readOnlyKey,
      upstreamWriteAttempts: upstreamWriteAttempts,
      stallWrites: stallWrites,
      dropLinkWithWritesInFlight: dropLinkWithWritesInFlight,
    );
    runBrowseContract(
      make,
      fixture: browseFixture,
      supportsBrowse: supportsBrowse,
      expectUnreachable: expectUnreachable,
    );
    runDataServicesContract(
      make,
      supportsDataServices: supportsDataServices,
      seedTimeseries: seedTimeseries,
      expectUnreachable: expectUnreachable,
    );
    runHoldContract(make, supportsHoldToRun: supportsHoldToRun);
    runAccessContract(make, supportsAccessControl: supportsAccessControl);
  });

  _casesRegistered += contractCases(
    supportsWrites: supportsWrites,
    readOnlyKey: readOnlyKey,
    supportsBrowse: supportsBrowse,
    supportsDataServices: supportsDataServices,
    supportsHoldToRun: supportsHoldToRun,
    supportsAccessControl: supportsAccessControl,
  ).length;
}
