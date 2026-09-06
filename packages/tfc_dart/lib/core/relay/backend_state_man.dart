/// The backend's `StateManApi`: a composer, and an honest refusal.
///
/// `centroidx-backend` has to hand `RelayServer` one object implementing
/// `StateManApi` (`relay_server.dart:141`). This is that object. It **composes**
/// — it does not extend `tfc_dart`'s `StateMan`, which does not implement
/// `StateManApi` at all and whose throwing `read`/`write` is precisely the
/// anti-pattern the interface replaces. Nor does it reuse `LocalStateMan`:
/// `tfc_relay_local` depends on `tfc_dart` (`tfc_relay_local/pubspec.yaml:36`),
/// so the edge that would let this file import it is a dependency cycle. Both
/// facts together are why this adapter exists as its own thing.
///
/// ## Whole from day one, and refusing by name
///
/// The class implements the entire interface immediately, with every
/// collaborator nullable, and each member either delegates or throws a named
/// [UnsupportedError]. Two properties follow, and both are the point:
///
///  1. **A later plan adds a file, never an edit here.** Each capability is one
///     constructor argument. Wave 2 (values) and wave 3 (writes) therefore touch
///     disjoint files and can run in parallel.
///  2. **A half-composed adapter cannot answer with silence.** A member with
///     nothing behind it says so, names itself, names what is missing and says
///     what to change. It never returns an empty list, an empty map, a null or a
///     stream that emits nothing. The rig already taught this once: at the
///     panel, silence and success look the same, and the operator finds out
///     which it was from the machine.
///
/// `LocalStateMan` spells its own three absences with a deliberate mix of
/// `StateError` and `UnsupportedError` (`local_state_man.dart:1405,1440,1478`),
/// chosen there by what catches them in `RelaySession`. This class uses
/// [UnsupportedError] uniformly and for a different reason: an absence here is
/// never a deployment fact ("this plant has no historian") but always an
/// incomplete composition, and `data_handlers.dart:216` already treats
/// `UnsupportedError` from `preferences` as the survivable case.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// `StateManApi` over whatever the backend's composition root supplied.
///
/// Every argument is optional, so `BackendStateMan()` is a legal object: it is
/// a complete `StateManApi` that can honestly answer nothing, which is what the
/// refusal tests stand on and what a boot with the relay section absent gets.
final class BackendStateMan implements relay.StateManApi {
  /// Composes an adapter from the collaborators the caller actually has.
  ///
  /// Named and nullable on purpose. A positional list would make "the backend
  /// has a value source but no historian" an exercise in counting nulls, and a
  /// required argument would force plan 13-02 to invent a stub for a
  /// collaborator plan 13-05 has not written yet — a stub being exactly the
  /// permissive default this design refuses to have.
  BackendStateMan({
    this.values,
    this.writes,
    relay.BrowseApi? browse,
    relay.TimeseriesApi? timeseries,
    relay.HistoryViewApi? historyViews,
    relay.PreferencesApi? preferences,
  })  : _browse = browse,
        _timeseries = timeseries,
        _historyViews = historyViews,
        _preferences = preferences;

  /// The live half: the pipe's cache and its refcounted subscriptions.
  final BackendValueSource? values;

  /// The command half: the pipe's write router.
  final BackendWriteSource? writes;

  final relay.BrowseApi? _browse;
  final relay.TimeseriesApi? _timeseries;
  final relay.HistoryViewApi? _historyViews;
  final relay.PreferencesApi? _preferences;

  /// The one shape every refusal in this class takes.
  ///
  /// Three things, always, in this order: the member as it is spelled on the
  /// interface, the collaborator that is missing, and one sentence saying what
  /// to change. Later plans keep spelling it this way — the roster test matches
  /// on `BackendStateMan.<member>` and on the collaborator's type name, so a
  /// message that drops either half fails the suite rather than reaching a
  /// client.
  ///
  /// Deliberately not "not implemented" and never "TODO": the member IS
  /// implemented. What is absent is the thing behind it, and that is the only
  /// fact an operator or an integrator can act on.
  Never _missing(String member, String collaborator, String why) =>
      throw UnsupportedError('BackendStateMan.$member is not available: this '
          'adapter was composed without a $collaborator. $why');

  /// What every value-side refusal says once the member name is stripped off.
  static const _noValues = 'The backend\'s PipeMainEndpoint was not handed to '
      'the composition root, so this adapter has no value cache to answer '
      'from; wire one in bin/main.dart\'s relay block.';

  /// What every write-side refusal says.
  static const _noWrites = 'The backend\'s write router was not handed to the '
      'composition root, so there is no route from this adapter to the plant '
      'and a command would be accepted and dropped; wire one in '
      'bin/main.dart\'s relay block.';

  // --------------------------------------------------------------- live values

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      values?.listen(key) ??
      _missing('listen', 'BackendValueSource', _noValues);

  @override
  Stream<relay.DynamicValue> subscribe(String key) =>
      values?.subscribe(key) ??
      _missing('subscribe', 'BackendValueSource', _noValues);

  /// The last known value for [key] — or a refusal, never a null.
  ///
  /// `StateManApi.read` returns null for "not known yet". That is a statement
  /// about a key in a store this adapter does not have, so an adapter composed
  /// without a value source cannot truthfully make it: answering null here
  /// would report "no value has arrived" to a client, when the fact is "nothing
  /// is connected and no value ever will". The two are indistinguishable on the
  /// wire and only one of them is true, which is the whole silence-as-success
  /// failure this phase is built around. A composed adapter's null still means
  /// exactly what the interface says it means.
  @override
  relay.DynamicValue? read(String key) {
    final source = values;
    if (source == null) {
      _missing('read', 'BackendValueSource', _noValues);
    }
    return source.read(key);
  }

  @override
  Future<relay.DynamicValue> readFresh(String key) async {
    final source = values;
    if (source == null) {
      _missing('readFresh', 'BackendValueSource', _noValues);
    }
    return source.readFresh(key);
  }

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) async {
    final source = values;
    if (source == null) {
      _missing('readMany', 'BackendValueSource', _noValues);
    }
    return source.readMany(keys);
  }

  /// Every key this adapter can serve — or a refusal, never an empty list.
  ///
  /// An empty list is a real answer ("this source serves nothing"), and a key
  /// picker that receives it draws an empty tree with no error on it. That is
  /// the same failure as [read] returning null, one level up.
  @override
  List<String> get keys =>
      values?.keys ?? _missing('keys', 'BackendValueSource', _noValues);

  // -------------------------------------------------------------------- writes

  @override
  Future<relay.WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) async {
    final sink = writes;
    if (sink == null) {
      _missing('write', 'BackendWriteSource', _noWrites);
    }
    // The cmd is forwarded, never re-minted: a relay is not originating the
    // operator action, and a second id is a write nobody can reconcile.
    return sink.write(key, value, expect: expect, cmd: cmd);
  }

  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) async {
    final sink = writes;
    if (sink == null) {
      _missing('writeStatus', 'BackendWriteSource', _noWrites);
    }
    return sink.writeStatus(cmds);
  }

  @override
  Future<relay.HoldHandle> holdToRun(String key) async {
    final sink = writes;
    if (sink == null) {
      // Deliberately a refusal and not an inert handle. A hold-to-run handle
      // that looks engaged and moves nothing is a deadman the operator believes
      // in; 13-CONTEXT says in as many words that this member must not be
      // silently unsupported.
      _missing('holdToRun', 'BackendWriteSource', _noWrites);
    }
    return sink.holdToRun(key);
  }

  // --------------------------------------------------------- sub-interfaces
  //
  // Each getter refuses from the getter itself, not from the sub-interface's
  // members. Handing back a BrowseApi whose every method throws would move the
  // discovery one call later, and the message would then name a member of
  // BrowseApi when the thing that is actually wrong is the composition.

  @override
  relay.BrowseApi get browse =>
      _browse ??
      _missing(
          'browse',
          'BrowseApi',
          'The key mappings the backend already holds were not handed to the '
              'composition root, so there is no address space to enumerate; '
              'wire the mapping-backed browse in bin/main.dart\'s relay block.');

  @override
  relay.TimeseriesApi get timeseries =>
      _timeseries ??
      _missing(
          'timeseries',
          'TimeseriesApi',
          'The backend\'s Database was not handed to the composition root, so '
              'there is no historian to read; see bin/main.dart\'s relay '
              'block. An empty answer here would draw every chart flat, for '
              'months, with nothing saying why.');

  @override
  relay.HistoryViewApi get historyViews =>
      _historyViews ??
      _missing(
          'historyViews',
          'HistoryViewApi',
          'The backend\'s Database was not handed to the composition root, so '
              'there is nowhere to keep a saved view; see bin/main.dart\'s '
              'relay block. Answering "you have saved nothing" to a plant that '
              'has saved plenty is an operator saving their view a second '
              'time, and then a third.');

  @override
  relay.PreferencesApi get preferences =>
      _preferences ??
      _missing(
          'preferences',
          'PreferencesApi',
          'The backend\'s Database was not handed to the composition root, so '
              'there is no shared preference store to serve; see '
              'bin/main.dart\'s relay block. Device-local settings are '
              'deliberately not on this pipe either way.');

  // ------------------------------------------------------------------ teardown

  /// Releases whatever was composed, and nothing else.
  ///
  /// The one member that does not refuse when the composition is empty:
  /// disposing something that was never composed is a no-op, contract cases
  /// register this with `addTearDown`, and a teardown that threw would fail
  /// every case that used an empty adapter as a fixture — reporting the fixture
  /// instead of the test.
  ///
  /// The sub-interfaces are deliberately not disposed here. They are handed in
  /// by the composition root, which owns the backend's `Database` and outlives
  /// this adapter; closing a connection pool this object merely borrowed is how
  /// a relay restart takes the historian down with it.
  @override
  Future<void> dispose() async {
    await values?.dispose();
    await writes?.dispose();
  }
}
