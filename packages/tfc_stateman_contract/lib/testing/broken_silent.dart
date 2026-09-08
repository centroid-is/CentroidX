/// The implementation that imitates a link which is up but dead.
///
/// Every other variant under `lib/testing/` breaks one behaviour and inherits
/// the rest, so a sabotage suite can assert that the targeted check fails and
/// its neighbours still pass. This one is the opposite by design: it breaks
/// *everything*, and it is not there to be caught by a particular check. It is
/// there to be pointed at **every** check at once.
///
/// What it stands for is the worst thing a transport can do, which is nothing.
/// A socket whose TCP connection is still open while the process behind it is
/// wedged; an OPC UA session that acknowledges a subscription and never
/// publishes; a database that accepts a query and never answers. Nothing errors,
/// nothing closes, nothing arrives.
///
/// Against a source like this, a check that awaits without a deadline does not
/// fail — it **hangs**, for the full 30-second `package:test` timeout, on every
/// CI run for as long as the case exists, and then reports the name of a test
/// file instead of the property an operator lost. That is the cost
/// [within] exists to prevent, and `test/suite_integrity_test.dart` runs every
/// registered check against this class to prove no check in the suite can incur
/// it.
///
/// Note the one thing it does *not* do: it never throws. A variant that threw
/// would be caught by any check that awaits anything, which would make the
/// sweep pass without saying anything about deadlines. Silence is the only
/// sabotage that distinguishes a check with a budget from a check without one.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// A source that accepts everything and resolves nothing.
///
/// Futures never complete, listeners are never notified, streams never emit,
/// and the store never fills — so `read` answers "nothing known" forever and
/// `keys` stays empty. The levers still exist and still accept calls, because a
/// check must be able to *try* to make a value arrive; nothing comes of it.
///
/// The deadline it declares is deliberately tiny. Every freshness case budgets
/// itself at three times [staleAfter], so a source declaring 300 ms would make
/// the integrity sweep pay nearly a second per freshness case to establish
/// something that has nothing to do with how long the deadline is.
class NeverResponds extends FakeStateMan {
  NeverResponds({super.staleAfter = const Duration(milliseconds: 20)});

  _DeadServices? _dead;

  /// Nothing arrives, ever.
  ///
  /// One override for the whole value path: [FakeStateMan] routes every lever —
  /// `setValue`, `setValues`, `setQuality`, `dropKey`, the link snapshot —
  /// through this single seam, so swallowing it here is what makes the store
  /// stay empty and every node stay silent. Overriding the individual levers
  /// instead would leave the source honest through whichever one was forgotten.
  @override
  void applyChanges(Map<String, DynamicValue> changes) {}

  @override
  Future<DynamicValue> readFresh(String key) => _never();

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) => _never();

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _never();

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) => _never();

  /// The engage never answers, so no handle is ever handed out.
  ///
  /// Overridden rather than inherited even though the inherited version would
  /// hang too — it awaits [write], which is already silent here. Overriding
  /// says so at the surface, and it is what keeps this class's promise
  /// checkable by reading it: every member either swallows or never answers,
  /// and none of them throws. An `UnimplementedError` would surface as
  /// `meta.dart:80-85`'s third forbidden failure mode and make every hold
  /// check in the integrity sweep fail for the wrong reason.
  @override
  Future<HoldHandle> holdToRun(String key) => _never();

  /// Even shutting down never finishes.
  ///
  /// A source whose `dispose` hangs is an ordinary and nasty bug — a socket
  /// close waiting on a peer that is gone — and it belongs in this class for
  /// the same reason everything else here does: the case that asserts a
  /// disposed source notifies nobody would otherwise pass against a source that
  /// notifies nobody about anything, and prove nothing about its own property.
  /// [halt] is how a test disposes of one of these.
  @override
  Future<void> dispose() => _never();

  @override
  BrowseApi get browse => _dead ??= _DeadServices();

  @override
  TimeseriesApi get timeseries => _dead ??= _DeadServices();

  @override
  HistoryViewApi get historyViews => _dead ??= _DeadServices();

  @override
  PreferencesApi get preferences => _dead ??= _DeadServices();

  // The four access families are dead too. NeverResponds extends FakeStateMan,
  // whose access families are the real in-memory reference implementation — so
  // without these overrides an access check would pass here, and the no-hang
  // sweep exists precisely to catch a check that does anything but fail against
  // a source that answers nothing. `actAs` and the observables stay inherited:
  // a check may swap the session and read the (empty) recording, then hang on
  // the family call, which is the silence this class is for.
  @override
  AccessTemplateApi get accessTemplates => _dead ??= _DeadServices();

  @override
  AccessAdminApi get accessAdmin => _dead ??= _DeadServices();

  @override
  AuditApi get audit => _dead ??= _DeadServices();

  @override
  BackendConfigApi get backendConfig => _dead ??= _DeadServices();

  /// Releases what this object holds, out of band.
  ///
  /// Not `dispose`: that is part of the surface under test and must stay hung.
  /// This exists because [FakeStateMan] arms a periodic freshness watchdog in
  /// its constructor, and the integrity sweep builds one of these per check —
  /// a few dozen abandoned timers would keep sweeping an empty store for the
  /// rest of the run and turn a leak here into an inexplicable slowdown
  /// somewhere else.
  Future<void> halt() async {
    await super.dispose();
    await _dead?.close();
  }
}

/// One dead object behind all four data-service getters.
///
/// A single class rather than four, because there is only one thing being
/// simulated: the far end is not answering, and it is not answering about
/// browsing, history, charts and preferences alike.
///
/// `noSuchMethod` rather than thirty forwarding stubs, which is a deliberate
/// departure from the other variants in this directory. Those wrap an honest
/// implementation and change one method, so writing every member out is what
/// makes the one difference visible. Here every member has the same behaviour,
/// and spelling them out would only create a place for a future method to be
/// forgotten — a new query that answers instantly with a default would be a
/// hole in the very sweep this class exists to power.
class _DeadServices
    implements
        BrowseApi,
        TimeseriesApi,
        HistoryViewApi,
        PreferencesApi,
        AccessTemplateApi,
        AccessAdminApi,
        AuditApi,
        BackendConfigApi {
  /// Open and empty, never closed while the source lives: a listener waits
  /// rather than being told the news is over. A closed stream is an event, and
  /// events are the one thing this class does not produce.
  final _silence = StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _silence.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => _never<Never>();

  Future<void> close() async {
    if (!_silence.isClosed) await _silence.close();
  }
}

/// A future that is neither an answer nor an error.
///
/// `Future<Never>` is assignable to every `Future<T>`, which is what lets one
/// expression serve every method on four interfaces — and what lets
/// [_DeadServices.noSuchMethod] answer a `Future<List<BrowseNode>>` without
/// knowing that is what it was asked for.
Future<T> _never<T>() => Completer<T>().future;
