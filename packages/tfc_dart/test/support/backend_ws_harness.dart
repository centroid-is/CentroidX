/// The backend adapter, served over a real WebSocket — two legs and one rule.
///
/// [backendWsServed] is the **contract** leg: a `ServedStateMan` and a
/// `ChannelStateMan` on either end of a real WebSocket, with **no relay session
/// between them**. It exists to prove the transport, which is what makes
/// running the shared suite over WS (13-11) mean anything. A relay session
/// would refuse all 43 checks before `hello`, so the gate belongs on the other
/// leg and not on this one.
///
/// [backendRelayFixture] is the **production** leg: the real [RelayServer] that
/// [composeBackendRelay] built, bound on an OS-chosen port, with a raw client
/// socket in front of it. Nothing in the contract suite uses it. It exists so
/// that the rig runbook's protocol probes (criterion 3, deferred and
/// human-attended) have a local reproduction of the production path, and so a
/// later phase does not have to invent one.
///
/// ## The thing being served is the composition the binary builds
///
/// The one deliberate difference from `tfc_relay_server`'s `ws_harness.dart`,
/// which serves a `FakeStateMan`: this file serves the `BackendStateMan` that
/// [composeBackendRelay] assembles — the same function `bin/main.dart` calls,
/// with the same real `Database`, the same real `Preferences`, the same
/// `KeyMappingSeriesResolver` and the same [backendRelayPolicy]. Serving a
/// hand-assembled graph would make this leg evidence about a fixture, and
/// criterion 4 (13-10) exists because the graph nothing assembled was the only
/// one that shipped.
///
/// The consequence worth naming: the pipe, the fake worker and every lever are
/// on the **server** side of the socket. A case that calls `setValue` on the
/// client is putting a notification on the wire, which `ServedStateMan` applies
/// to a real `PipeMainEndpoint`, whose frame travels back as an update. A
/// harness that shortcut a lever to the client end would be testing the client.
///
/// ## Defaults are imported, never re-spelled
///
/// `staleAfter` is [kBackendStaleAfter] — the production number, and the same
/// object the in-memory leg runs at, because it comes from the same constant
/// rather than from a second literal. A defaults difference between two legs
/// reads as a *transport* difference and sends someone looking for a bug in the
/// socket layer that is really a `staleAfter` of 300 ms against one of 500
/// (`socket_harness.dart:137-145` is the recorded instance of that costing
/// time). The key list, the key mappings, the read-only key, the declared
/// method key and the first snapshot all come from
/// `harnessed_backend_state_man.dart` for the same reason — and so does
/// [HarnessedBackendStateMan] itself, so "the levers are the in-memory leg's
/// levers" is a fact about a shared class rather than a claim about two copies.
///
/// ## Nothing here throws out of the wiring
///
/// A failure while binding, serving or connecting is delivered to the thing the
/// case is awaiting — the client's channel on the contract leg, the `ready`
/// future on the production one. The reason is `ws_harness.dart`'s and it is
/// worth repeating: an exception raised from a listener callback lands in the
/// ambient isolate and `package:test` attributes it to whichever case happens
/// to be running when it arrives, so a wiring bug is reported against an
/// innocent check and diagnosed once per project, painfully.
///
/// ## Known transport bugs this file does not trip
///
/// - `closeCode` is null after a self-initiated close (dart-lang/http#1698):
///   nothing here asserts on a close code, and the production leg reports the
///   code the **client** observed if a later case wants one.
/// - `sink.add(List<int>)` sends a text frame on legacy web (#1648): every
///   frame on both legs is a `String`, which is what `StreamChannel<String>`
///   means, so there is no binary path to get wrong.
/// - `readyState` lies after OS sleep: never read.
///
/// ## The shared store
///
/// [composeBackendRelay] takes a non-nullable `Database` and `Preferences`, so
/// this leg needs both before its first case. [installBackendWsStore] registers
/// the `setUpAll`/`tearDownAll` that create them once per FILE — a real on-disk
/// SQLite `AppDatabase`, which is the production class over a different drift
/// executor and runs on a machine with no Docker daemon (13-09 Finding 1,
/// 13-10's fixture). Once per file rather than once per case because 43 cases
/// each creating a temp directory and a database is a minute of wall clock
/// bought for nothing: this leg declares `supportsDataServices: false`, so
/// nothing any case does reaches the store at all.
///
/// ## The alarm engine is OFF unless a case asks for one (14-11)
///
/// [composeBackendUnderTest] takes an optional `alarms:` configuration and an
/// injected `clock:`, and builds an `AlarmEngine` over the composition's own
/// value source when — and only when — both are supplied. **The default is no
/// engine, and that default is load-bearing rather than tidy.**
///
/// This file carries the shared contract suite. Forty-three checks are judged
/// against whatever `composeBackendUnderTest` returns, and a leg that grew an
/// alarm engine it did not ask for would be a change in *what the contract is
/// being run against*: another object holding subscriptions on the pipe,
/// another writer into the same `ValueStore`, another declared key on the
/// browse surface, and a second reader of the freshness sweep whose own arms
/// live elsewhere. The parity sweep (`backend_ws_parity_test.dart`) compares
/// this leg against the in-memory one on the assumption that they serve the
/// same graph; an engine here and none there would make that comparison a
/// comparison of two different backends. So `alarms: null` composes byte-for
/// byte what Phase 13 composed, `values:`/`freshness:` are not passed at all,
/// and [ComposedBackendUnderTest.engine] is null.
///
/// When alarms ARE asked for, the pair is built **before**
/// [composeBackendRelay] and passed in whole. That function refuses a half
/// pair by name (`backend_composition.dart`, "supply both or neither"), for
/// the reason it states: each of the two registers a pipe callback in its own
/// constructor, and a second one built inside the composition takes
/// `onKeyRetired` / `onWorkerDied` off the caller's object without saying so.
/// The engine reads through the same sweep the adapter serves from, which is
/// `bin/main.dart`'s arrangement after 14-08.
///
/// ## Three more knobs, all additive, all defaulted to what Phase 13 had (14-14)
///
/// [composeBackendUnderTest] now also takes `store:`, `alarmHistory:` and
/// `validator:`. Each defaults to exactly what this file did before it had
/// them, and 14-11's rule is inherited unchanged: **every existing consumer
/// passes unedited.**
///
///  * **`store:`** — the `Database` + `Preferences` pair to compose over. The
///    default is [installBackendWsStore]'s shared on-disk SQLite, which is
///    right for every leg whose subject is framing. An arm whose subject is an
///    `alarm_history` *column* needs a real Postgres, and the alternative to
///    this knob was a second copy of the `composeBackendRelay` call — which is
///    the one thing criterion 4 exists to forbid.
///  * **`alarmHistory:`** — an `AlarmHistoryWriter` for the engine. Null by
///    default, which is 14-11's arrangement and the reason `historyId` is null
///    throughout that file.
///  * **`validator:`** — a `TokenValidator`, and supplying one flips the
///    composed `relay` section's credential source to `validator`. That is not
///    decoration: `composeBackendRelay` refuses a validator alongside any other
///    source by name, because two sources of truth for the credential check is
///    what `relay_server.dart:155` refuses. It is also the only way to get a
///    session that is *not* `operate` — `PermissiveTokenValidator` answers
///    `operate` for everyone, deliberately and honestly, so a view-role station
///    does not exist without one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart' show AlarmManConfig;
import 'package:tfc_dart/core/alarm_stamp.dart' show kAlarmSkewWarnAfter;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart'
    show AlarmHistoryWriter;
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart'
    show BackendLiveValues, kBackendStaleAfter;
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
// Reaching into `tfc_relay_server/lib/src/` on purpose. `wsChannel` is the
// harness-side adapter that turns a `WebSocketChannel` into the
// `StreamChannel<String>` both ends of the contract kit speak, and it carries
// two expensive lessons in it: cast the STREAM and build the sink by hand (a
// `channel.cast<String>()` binds the sink with `addStream` for the life of the
// connection and every later writer gets `Bad state: Cannot add event while
// adding stream`), and republish MUTED so a closed `Peer` does not hand the
// socket's next error to the ambient isolate. Copying it here would give this
// package a second copy free to drift from the one `ws_harness.dart` uses —
// and then the two WS legs would no longer be running the same transport,
// which is the only thing this leg's parity claim rests on.
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'harnessed_backend_state_man.dart';
import 'memory_secrets.dart';

/// How long the served end has to appear after the client's connect returns.
///
/// `ws_harness.dart`'s `_acceptBudget`, same value and same argument: generous,
/// because it is a *wiring* budget and not a measurement. What it protects
/// against is a harness that hangs forever when the accept never happens — the
/// denial-of-service shape of a wiring bug (T-13-11-c).
const _acceptBudget = Duration(seconds: 5);

// ---------------------------------------------------------------------------
// The shared store.
// ---------------------------------------------------------------------------

Directory? _storeDir;
Database? _database;
Preferences? _prefs;

/// The real on-disk store both legs compose over. Null until [installBackendWsStore].
Database get backendWsDatabase =>
    _database ??
    (throw StateError('no Database yet: call installBackendWsStore() at the '
        'top of main() before runStateManContract, or the first case will '
        'compose against nothing'));

/// The real preference store both legs compose over.
Preferences get backendWsPreferences =>
    _prefs ??
    (throw StateError('no Preferences yet: call installBackendWsStore() at '
        'the top of main() before runStateManContract'));

/// Registers the `setUpAll`/`tearDownAll` that own the shared store.
///
/// Call once, at the top of `main()`, **before** `runStateManContract`. A
/// top-level `setUpAll` runs before every group in the file, and the contract
/// umbrella's factory is invoked inside a case, so the ordering holds without
/// either side knowing about the other.
void installBackendWsStore() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('backend-ws-contract');
    _storeDir = dir;
    // The production class over a real on-disk database — the same fixture
    // `backend_composition_test.dart` uses, and for the same reason: SQLite is
    // the production code path with a different executor behind drift, and it
    // runs on a machine with no Docker daemon.
    final database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'backend-ws-contract'),
      sqliteFolder: dir,
    ));
    _database = database;
    // `Preferences.create` reaches for SecureStorage, which has no default
    // on Windows and reaches a real AWS client on macOS. See
    // `memory_secrets.dart`.
    useMemorySecrets();
    _prefs = await Preferences.create(db: database);
  });

  tearDownAll(() async {
    await _database?.close();
    _database = null;
    _prefs = null;
    final dir = _storeDir;
    _storeDir = null;
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  });
}

/// The `relay` section an operator would write, with the port left to the OS.
///
/// `port: 0` and no credentials: this is a loopback fixture, and a token file
/// would be a second thing to get wrong in a leg whose subject is framing.
/// `RelayServer`'s own credential arms live in `tfc_relay_server`.
///
/// [ownValidator] flips the credential source to `validator`, which is the one
/// spelling `composeBackendRelay` will accept a `validator:` argument beside —
/// it refuses the pair by name otherwise, and the refusal is the point: two
/// sources of truth for the credential check is what `relay_server.dart:155`
/// refuses, and the composition root says so first.
Map<String, dynamic> _relaySection({int port = 0, bool ownValidator = false}) =>
    <String, dynamic>{
      'relay': <String, dynamic>{
        'port': port,
        'credentials': <String, dynamic>{
          'source': ownValidator ? 'validator' : 'none',
        },
      },
    };

/// A `Database` and the `Preferences` over it, as one argument.
///
/// One record rather than two parameters because half a pair is the mistake
/// worth making unrepresentable: a composition given a Postgres database and
/// the shared SQLite preferences would read its `alarm_man_config` out of one
/// store and write its history into another, and nothing would say so.
typedef BackendStore = ({Database database, Preferences preferences});

/// The graph, plus the fake plant behind it and the levers that drive it.
///
/// Everything on the server side of the socket, in one object, so a teardown
/// can release it in one place.
final class ComposedBackendUnderTest {
  ComposedBackendUnderTest._(
    this.composition,
    this.harness,
    this.pipe, {
    required this.engine,
    required AlarmManConfig? alarmConfig,
    required this.monotonic,
    required this.alarmPublications,
    required this.store,
  }) : _alarmConfig = alarmConfig;

  /// What [composeBackendRelay] built — the shipping graph, unstarted.
  final BackendRelayComposition composition;

  /// The same lever-carrying wrapper the in-memory leg is judged through.
  final HarnessedBackendStateMan harness;

  /// The real pipe every lever's frame crosses.
  final PipeMainEndpoint pipe;

  /// The alarm engine, or **null** when the caller asked for none.
  ///
  /// Null is the default and the Phase 13 shape; see the library doc for why
  /// the contract legs must keep composing without one.
  final AlarmEngine? engine;

  final AlarmManConfig? _alarmConfig;

  /// One monotonic clock for the whole fixture, started at composition.
  ///
  /// Every publication and every client receipt is stamped off **this one
  /// stopwatch**, so the publish→receipt gap Research Open Question 2 asks for
  /// is a difference of two readings of one monotonic counter rather than of
  /// two wall-clock samples. Both ends are in this isolate, so there is no
  /// second clock to reconcile — and a wall clock read twice can go backwards
  /// across an NTP step, which would turn the measurement into a negative
  /// number nobody could explain.
  final Stopwatch monotonic;

  /// Every `ALARM.*` publication the engine made, in order, stamped.
  ///
  /// Recorded by a decorator **around** [PipeStoreAlarmPublisher], never
  /// instead of it: the production seam is what actually writes into
  /// `PipeMainEndpoint.store`, and a recorder that replaced it would measure a
  /// fixture rather than the path a panel is served from.
  final List<AlarmPublication> alarmPublications;

  /// The `Database` + `Preferences` this graph was composed over.
  ///
  /// The shared SQLite pair unless the caller supplied its own. Surfaced for
  /// the same reason every other collaborator is: an arm that asserts on a row
  /// must be reading the store the backend wrote it into, and a fixture that
  /// hid it would let the two be different objects.
  final BackendStore store;

  /// Seeds `alarm_man_config` and starts the engine, or does nothing.
  ///
  /// Two steps rather than one because the seed is asynchronous and
  /// [composeBackendUnderTest] is not: the whole graph is allocated
  /// synchronously (the composition root's own rule), and the two awaits live
  /// here.
  ///
  /// **After every `pipe.addWorker`, never before** — `AlarmEngine.start`'s
  /// own ordering obligation (D-7 / P-4). The fixture registers its one worker
  /// during composition, so calling this from `ready` satisfies it.
  ///
  /// The configuration goes into the shared, real [Preferences] rather than an
  /// in-memory stand-in, because that is the class `bin/main.dart` hands the
  /// engine. The store is shared per FILE, so a second case with a different
  /// configuration overwrites the first — which is correct, since each case
  /// seeds before its own `start()` and nothing reads the row afterwards.
  Future<void> startAlarms() async {
    final engine = this.engine;
    if (engine == null) return;
    await store.preferences
        .setString(kAlarmManConfigKey, jsonEncode(_alarmConfig!.toJson()));
    await engine.start();
  }

  /// Releases the engine's input subscriptions, if there is an engine.
  ///
  /// Before `composition.dispose()`, which disposes the sweep the engine is
  /// reading through: a watcher cancelling a subscription on a disposed source
  /// is an error raised out of a teardown, which `package:test` attributes to
  /// whichever case is running next.
  Future<void> disposeAlarms() async => engine?.dispose();
}

/// One `ALARM.*` publication, and when it happened on the fixture's clock.
typedef AlarmPublication = ({
  String key,
  relay.DynamicValue value,
  int atMicros,
});

/// [AlarmStatePublisher] that times every publication and forwards it.
///
/// The delegate is the production [PipeStoreAlarmPublisher]. This class adds a
/// list append and a stopwatch read and changes nothing else, so the value a
/// client receives crossed exactly the path 14-05 built.
final class _TimingAlarmPublisher implements AlarmStatePublisher {
  _TimingAlarmPublisher(this._inner, this._monotonic, this._records);

  final AlarmStatePublisher _inner;
  final Stopwatch _monotonic;
  final List<AlarmPublication> _records;

  @override
  void publish(String key, relay.DynamicValue value) {
    // Stamped BEFORE the delegate runs. The gap being measured is
    // "the backend decided" to "the client heard", and putting the reading
    // after `applyBatch` would silently exclude whatever the store's own
    // notification arithmetic costs — which is part of the answer.
    _records.add((key: key, value: value, atMicros: _monotonic.elapsedMicroseconds));
    _inner.publish(key, value);
  }
}

/// Composes the shipping graph over a fake worker and the shared store.
///
/// The only thing that is not production here is the *worker*: a
/// [FakePlantLink] instead of an acquisition isolate, which is what lets a case
/// say "the plant published 1200" without a PLC. Everything between that link
/// and the socket — the pipe, the live values, the sweep, the write router,
/// the browse tree, the resolver, the policy, the server — is what
/// `bin/main.dart` constructs.
/// [alarms] and [clock] are **both or neither**, refused below by name.
///
/// The shape is `composeBackendRelay`'s own, for its own reason: a mistake in
/// a composition must be loud where the composition is written. An engine with
/// no clock is not constructible at all (`AlarmEngine.clock` is required and
/// has no default, D-2), and a clock with no configuration would be an
/// argument that does nothing — the quietest kind of wrong.
ComposedBackendUnderTest composeBackendUnderTest({
  int port = 0,
  AlarmManConfig? alarms,
  DateTime Function()? clock,
  Duration alarmSkewWarnAfter = kAlarmSkewWarnAfter,
  Logger? alarmLogger,
  BackendStore? store,
  AlarmHistoryWriter? alarmHistory,
  TokenValidator? validator,
}) {
  if ((alarms == null) != (clock == null)) {
    throw ArgumentError('composeBackendUnderTest: `alarms` and `clock` must '
        'be supplied together or not at all — '
        '${alarms == null ? '`clock` was passed without `alarms`' : '`alarms` was passed without `clock`'}. '
        'An AlarmEngine has no default clock (D-2: `DateTime.now` is the '
        'composition root\'s, and this fixture is a composition root), and a '
        'clock with no configuration would be an argument that does nothing');
  }
  if (alarmHistory != null && alarms == null) {
    throw ArgumentError('composeBackendUnderTest: `alarmHistory` was passed '
        'with no `alarms`. There is no engine to hand it to, so it would be an '
        'argument that does nothing — the same quiet kind of wrong the pair '
        'above is refused for');
  }

  // The shared SQLite pair unless the caller brought its own. Read through a
  // local so the two getters — which THROW when `installBackendWsStore` was
  // not called — are not touched at all on the injected path.
  final backing = store ??
      (database: backendWsDatabase, preferences: backendWsPreferences);

  final plant = FakePlantLink('contract-ws');
  final pipe = PipeMainEndpoint(
    // The same short write deadline the in-memory leg runs at
    // (`harnessed_backend_state_man.dart`): the write cases are about the
    // three-state outcome, not about how long a plant is given to answer.
    writeDeadline: const Duration(milliseconds: 400),
    logger: Logger(level: Level.off),
  );
  pipe.addWorker(plant, contractPlantKeys());

  // ------------------------------------------------------------- the alarms
  //
  // Built BEFORE the composition and passed in whole, which is `bin/main.dart`'s
  // arrangement after 14-08 and the only one `composeBackendRelay` accepts:
  // half a pair is refused there by name, because each object registers a pipe
  // callback in its constructor and a second one built inside the composition
  // would silently take those callbacks off the caller's.
  //
  // Null when no case asked for an engine, and then `values:`/`freshness:` are
  // not passed at all — so the Phase 13 legs compose the graph they always did.
  BackendLiveValues? liveValues;
  BackendFreshnessSweep? sweep;
  AlarmEngine? engine;
  final alarmPublications = <AlarmPublication>[];
  final monotonic = Stopwatch()..start();

  if (alarms != null) {
    final logger = alarmLogger ?? Logger(level: Level.off);
    liveValues = BackendLiveValues(
      pipe: pipe,
      keyMappings: contractKeyMappings(),
      // Imported, never re-spelled — this library's doc, and the same constant
      // the composition would have used had it built the pair itself.
      staleAfter: kBackendStaleAfter,
      logger: logger,
    );
    sweep = BackendFreshnessSweep(
      values: liveValues,
      staleAfter: kBackendStaleAfter,
      pipe: pipe,
      logger: logger,
    );
    engine = AlarmEngine(
      // The SAME object the adapter serves every session from — see below,
      // where `composition.freshness` is handed to the lever wrapper. One
      // value source for one plant is the whole of 14-08's argument.
      values: sweep,
      preferences: backing.preferences,
      publisher: _TimingAlarmPublisher(
          PipeStoreAlarmPublisher(pipe), monotonic, alarmPublications),
      clock: clock!,
      // Null on every leg that did not ask for one, which is 14-11's shape:
      // `historyId` stays null and no case is dragged into the Docker lane for
      // a field it does not measure.
      history: alarmHistory,
      skewWarnAfter: alarmSkewWarnAfter,
      logger: logger,
    );
  }

  final composition = composeBackendRelay(
    config: RelayConfig.fromJson(
        _relaySection(port: port, ownValidator: validator != null),
        source: 'backend_ws_harness')!,
    pipe: pipe,
    keyMappings: contractKeyMappings(),
    database: backing.database,
    prefs: backing.preferences,
    validator: validator,
    // The gateway's way back to the engine (14-14). Null when there is none,
    // and then an `ackAlarm` is refused by name rather than accepted into
    // nothing — which is the answer every Phase 13 leg has always received.
    alarms: engine,
    // Both or neither. Null/null on every Phase 13 leg, which is the same call
    // those legs have always made.
    values: liveValues,
    freshness: sweep,
    // 13-04 Finding 1, and the identical asymmetry the in-memory leg declares.
    // Production passes NONE — a true statement about SVN's address space,
    // because `KeyMappingEntry` has no callable concept — and both contract
    // legs declare exactly one, so
    // `checkBrowseNodeTypesDistinguishFoldersFromVariables` runs against a real
    // code path rather than going red with no bug behind it. Do not "fix" this
    // by teaching the mapping about methods.
    methodKeys: contractMethodKeys,
    // Imported, never re-spelled. See this library's doc.
    staleAfter: kBackendStaleAfter,
    log: Logger(level: Level.off),
  );

  final writes = composition.api.writes;
  if (writes is! BackendWrites) {
    throw StateError('composeBackendRelay handed back a '
        '${writes.runtimeType} where BackendWrites was expected. The write '
        'harness levers read `upstreamAttempts` and `mintedCmds` off that '
        'class; a different one means the composition changed and this '
        'harness is now driving something else');
  }

  final harness = HarnessedBackendStateMan(
    composition.api,
    pipe: pipe,
    plant: plant,
    values: composition.freshness,
    writes: writes,
  );

  // The plant's first publishing interval, as an ordinary frame down the
  // ordinary path — `checkFetchDetailDescribesTheNode` wants a current reading
  // on the browse fixture's variable, and a real worker's first publish is
  // where one comes from. Same snapshot as the in-memory leg's.
  plant.deliverAll(contractInitialSnapshot());

  return ComposedBackendUnderTest._(
    composition,
    harness,
    pipe,
    engine: engine,
    alarmConfig: alarms,
    monotonic: monotonic,
    alarmPublications: alarmPublications,
    store: backing,
  );
}

// ---------------------------------------------------------------------------
// The contract leg.
// ---------------------------------------------------------------------------

/// Both halves of one WS-served backend, for a test that needs to reach past
/// the client. Ordinary drivers want [backendWsServed] and never see this.
final class BackendWsServed {
  BackendWsServed._(this.backend, this.api, this._wiring, this.ready);

  /// The composition and its levers, on the far side of the socket.
  final ComposedBackendUnderTest backend;

  /// The implementation under test, on this side: everything it can answer
  /// arrived over the wire.
  final ChannelStateMan api;

  final _BackendWsWiring _wiring;

  /// Completes once the served end exists.
  final Future<void> ready;

  /// The served peer, for a test that wants to close one end explicitly.
  ServedStateMan get session => _wiring.requireSession();

  Future<void> teardown() => _wiring.teardown(ready);
}

/// The backend adapter served over a real WebSocket, both ends wired.
BackendWsServed serveBackendOverWs() {
  final backend = composeBackendUnderTest();
  final completer = StreamChannelCompleter<String>();
  final wiring = _BackendWsWiring(backend);
  final ready = wiring.connect(completer);

  final api = ChannelStateMan(
    channel: completer.channel,
    // `staleAfter`, `roundTrips` and `statusNotifications` are read straight
    // off the served instance and never mirrored onto the wire — they are
    // promises about a count, and a count a connected client could query would
    // be an access-control decision (`harness.dart:16-25`).
    observables: backend.harness,
    closeServed: () => wiring.teardown(ready),
  );

  _serverSideOf[api] = backend;
  return BackendWsServed._(backend, api, wiring, ready);
}

/// Which composition is on the far side of which client.
///
/// An `Expando` rather than a `Map`, so a client the runner has finished with
/// takes its composition with it instead of pinning a pipe, a fake worker and
/// an unstarted server alive for the rest of the file.
final _serverSideOf = Expando<ComposedBackendUnderTest>('backend behind a WS client');

/// The lever surface on the SERVER side of [api]'s socket.
///
/// Three contract hooks need it — the upstream write-attempt count, the write
/// stall, and the link drop with a write in flight — and all three are
/// properties of the plant, which on this leg is across a wire. The kit's
/// default is to read them off the api itself, which is right for an in-memory
/// leg and wrong here: `ChannelStateMan` has no plant, and a hook that found
/// one on the client would be measuring the client.
///
/// Fails by name rather than by cast. A `ClassCastError` from inside a hook is
/// reported against whichever check invoked it, and the check's own message —
/// the thing that says which property was lost — never prints.
HarnessedBackendStateMan backendServerHarness(relay.StateManApi api) {
  final backend = _serverSideOf[api];
  if (backend == null) {
    throw StateError('no served backend is registered for this '
        '${api.runtimeType}. The contract hooks reach the plant across the '
        'socket, so the api handed to them must be one `backendWsServed()` '
        'returned — a differently-built client has no pipe behind it and the '
        'write cases would be measuring nothing');
  }
  return backend.harness;
}

/// The driver-facing factory: one WS-served backend adapter, per case.
///
/// ```dart
/// runStateManContract(backendWsServed, ...);
/// ```
///
/// The same shape as `wsServedFake` (`ws_harness.dart:466`) and
/// `makeHarnessedBackendStateMan` (`harnessed_backend_state_man.dart:374`),
/// and it takes no capability arguments for the same reason the latter does
/// not: what this leg can do is decided by the composition, not by the caller.
relay.StateManApi backendWsServed() {
  final served = serveBackendOverWs();
  // Registered at acquisition, so a case that fails an assertion before its own
  // teardown line still releases the descriptors. Idempotent, so the
  // sub-suites' own `addTearDown(api.dispose)` — which also closes the served
  // end — is not a problem.
  addTearDown(served.teardown);
  return served.api;
}

/// The descriptors one contract-leg harness owns, and the order to release them.
final class _BackendWsWiring {
  _BackendWsWiring(this.backend);

  final ComposedBackendUnderTest backend;

  HttpServer? _http;
  WebSocketChannel? _client;
  final _sessions = <ServedStateMan>[];
  var _torn = false;

  ServedStateMan requireSession() {
    if (_sessions.isEmpty) {
      throw StateError('the harness has no served session until `ready` has '
          'completed; await it before reaching for one');
    }
    return _sessions.first;
  }

  /// Binds, serves and connects — then hands the client its channel.
  ///
  /// **Never throws.** A failure anywhere is delivered to the channel, so the
  /// client's `Peer` sees a broken transport and every contract check fails on
  /// its own deadline naming its own property, instead of one wiring
  /// exception being attributed to whichever case was running.
  Future<void> connect(StreamChannelCompleter<String> completer) async {
    try {
      final accepted = Completer<void>();
      _http = await shelf_io.serve(
        webSocketHandler((WebSocketChannel ws, String? _) {
          _sessions.add(serveStateMan(backend.harness, wsChannel(ws)));
          if (!accepted.isCompleted) accepted.complete();
        }),
        // A numeric loopback address, never 'localhost': the name resolves to
        // two families on this machine and a bind on one with a connect to the
        // other is a hang that reads as a protocol failure.
        InternetAddress.loopbackIPv4,
        0,
      );

      final ws =
          IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${_http!.port}'));
      _client = ws;
      await ws.ready;
      await accepted.future.timeout(_acceptBudget);
      completer.setChannel(wsChannel(ws));
    } catch (error, stack) {
      completer.setError(error, stack);
    }
  }

  /// Releases every descriptor, innermost first, and only once.
  ///
  /// Inside out: the served sessions (which own only their peers), then the
  /// HTTP server, then whatever is left of the client socket, then the
  /// composition — whose `dispose` closes the unstarted `RelayServer` and the
  /// adapter but deliberately not the borrowed `Database` — and last the
  /// fixture's own pipe and fake worker, which have to outlive anything still
  /// draining through them.
  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;

    // A half-built harness is still a harness: wait for the sequence to finish
    // before releasing what it managed to open, and do not let its failure
    // stop the release.
    await ready.catchError((Object _) {});

    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();

    await _http?.close(force: true);
    await _client?.sink.close().catchError((Object _) {});
    await backend.composition.dispose();
    backend.harness.shutdownFixture();
  }
}

// ---------------------------------------------------------------------------
// The production leg.
// ---------------------------------------------------------------------------

/// The real [RelayServer] the binary builds, bound, with a raw client socket.
///
/// **Nothing in the contract suite uses this.** It is here so the rig runbook's
/// protocol probes have a local reproduction of the production path — the
/// session gate, `hello`, the policy layer and the resolver all in front of the
/// same adapter — and so the phase that finally runs those probes does not have
/// to invent a fixture under time pressure on a plant test rig.
/// **Two panels are two of these, not one used twice** (14-11). The fixture
/// opens one client itself and [BackendRelayFixture.connectClient] opens more,
/// each with its own socket, its own request ids, its own subscriptions and its
/// own inbound frame log. Sharing one socket and calling `subscribe` twice
/// would put both "panels" in one session, where agreement is arithmetic rather
/// than evidence: criterion 5 is about two *sessions* being told the same
/// thing, and a fan-out that happens once cannot disagree with itself.
final class BackendRelayFixture {
  BackendRelayFixture._(this.backend, this._wiring, this.ready);

  /// The composition, its levers, and the plant behind them.
  final ComposedBackendUnderTest backend;

  final _BackendRelayWiring _wiring;

  /// Completes when the server is bound, the alarm engine (if any) has
  /// started, and the first client socket is open.
  final Future<void> ready;

  /// The bound port. Available once [ready] has completed.
  int get port => backend.composition.server.port;

  /// The first client — the one the fixture opened for itself.
  BackendRelayClient get client => _wiring.requireClient();

  /// Every frame the first client has received, in order.
  List<String> get inbound => client.inbound;

  /// The close code the CLIENT observed — the only one worth asserting on for
  /// a close the server initiated (`web_socket_channel` #1698).
  int? get observedCloseCode => client.observedCloseCode;

  /// Sends [method] on the first client and returns its result.
  Future<Object?> request(String method,
          {Object? params,
          String? what,
          Duration budget = const Duration(seconds: 5)}) =>
      client.request(method, params: params, what: what, budget: budget);

  /// Says hello on the first client and hands back the negotiated result.
  Future<relay.HelloResult> hello(
          {Duration budget = const Duration(seconds: 5)}) =>
      client.hello(budget: budget);

  /// Opens **another** independent client against the same bound server.
  ///
  /// A second panel, in every sense that matters here: a second TCP connection,
  /// a second `RelaySession` on the server, a second handle table and a second
  /// subscription. Nothing about it is shared with the first except the backend
  /// it is asking.
  Future<BackendRelayClient> connectClient(String name) =>
      _wiring.addClient(name);

  Future<void> teardown() => _wiring.teardown(ready);
}

/// Stands the shipping composition up on a real port, with a client in front.
///
/// [alarms] / [clock] are forwarded to [composeBackendUnderTest] and, when
/// supplied, the engine is started as part of [BackendRelayFixture.ready] —
/// **after** the composition registered its worker, which is
/// `AlarmEngine.start`'s ordering obligation (D-7 / P-4), and **before** the
/// first client connects, which is what makes a case able to say "the alarm was
/// already standing when this panel arrived".
BackendRelayFixture backendRelayFixture({
  AlarmManConfig? alarms,
  DateTime Function()? clock,
  Duration alarmSkewWarnAfter = kAlarmSkewWarnAfter,
  Logger? alarmLogger,
  BackendStore? store,
  AlarmHistoryWriter? alarmHistory,
  TokenValidator? validator,
}) {
  final backend = composeBackendUnderTest(
    alarms: alarms,
    clock: clock,
    alarmSkewWarnAfter: alarmSkewWarnAfter,
    alarmLogger: alarmLogger,
    store: store,
    alarmHistory: alarmHistory,
    validator: validator,
  );
  final wiring = _BackendRelayWiring(backend);
  final ready = wiring.connect();
  final fixture = BackendRelayFixture._(backend, wiring, ready);
  addTearDown(fixture.teardown);
  return fixture;
}

/// One client socket in front of the bound server: a panel, for these purposes.
///
/// The JSON-RPC envelope is spelled out over `dart:convert` rather than taken
/// from `json_rpc_2` — `_BackendRelayWiring`'s original argument, unchanged: a
/// probe fixture whose *client* is the same library the server uses proves less
/// about the wire than one that writes the frames itself.
final class BackendRelayClient {
  BackendRelayClient._(this.name, this._socket, this._monotonic);

  /// What this panel is called in a failure message.
  final String name;

  final WebSocketChannel _socket;
  final Stopwatch _monotonic;

  final List<String> _inbound = <String>[];
  final List<String> _sent = <String>[];
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final StreamController<ServerNotification> _notifications =
      StreamController<ServerNotification>.broadcast();

  int _nextId = 1;
  var _closed = false;
  Timer? _heartbeat;

  /// Every method name this client has SENT, in order.
  ///
  /// The counterpart to [inbound], and the thing an arm needs to say "this
  /// panel never asked for that": counting answered ids cannot distinguish a
  /// `preferences.getString` from a heartbeat.
  List<String> get sentMethods => List.unmodifiable(_sent);

  /// How many heartbeats this client has sent since [hello].
  int get heartbeats => _sent.where((m) => m == relay.Methods.ping).length;

  /// Whether the server has closed this socket.
  bool get closedByServer => _socket.closeCode != null;

  /// Every frame this client has received, in order, as it came off the wire.
  ///
  /// Raw strings on purpose. An arm that wants to say "this number never
  /// crossed this socket except inside that payload" has to look at the bytes,
  /// not at a decoded convenience view that already threw away the frames it
  /// did not understand.
  List<String> get inbound => List.unmodifiable(_inbound);

  /// The close code this client observed (`web_socket_channel` #1698).
  int? get observedCloseCode => _socket.closeCode;

  /// Every server→client notification, stamped on the fixture's clock.
  Stream<ServerNotification> get notifications => _notifications.stream;

  void _listen() {
    _socket.stream.listen(
      _onFrame,
      // Delivered to whoever is awaiting, never rethrown into the ambient
      // isolate: an error raised from a listener callback is attributed to
      // whichever case is running when it arrives.
      onError: _failAllPending,
      onDone: () => _failAllPending(StateError(
          'client "$name"\'s socket closed with ${_pending.length} '
          'request(s) still outstanding')),
      cancelOnError: false,
    );
  }

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    // Stamped first, before any decoding this fixture does: the number Open
    // Question 2 wants is when the frame ARRIVED, not when the harness got
    // round to parsing it.
    final atMicros = _monotonic.elapsedMicroseconds;
    _inbound.add(frame);
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) {
      final method = decoded['method'];
      if (method is String && !_notifications.isClosed) {
        _notifications.add((
          method: method,
          params: (decoded['params'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{},
          atMicros: atMicros,
        ));
      }
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = decoded['error'];
    if (error != null) {
      completer.completeError(RelayRefusal(name, error));
    } else {
      completer.complete(decoded['result']);
    }
  }

  void _failAllPending(Object error, [StackTrace? stack]) {
    final waiting = List.of(_pending.values);
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
  }

  /// Sends [method] and returns its result inside a named budget.
  Future<Object?> request(String method,
      {Object? params,
      String? what,
      Duration budget = const Duration(seconds: 5)}) {
    final described = what ?? 'a $method response over a real socket';
    final id = _nextId++;
    _sent.add(method);
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket.sink.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(budget, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException(
          '$described did not arrive at client "$name" within $budget', budget);
    });
  }

  /// Says hello, starts beating, and hands back the negotiated result.
  ///
  /// ## The heartbeat is not optional, and this fixture learned that the hard
  /// way (14-11)
  ///
  /// **Nothing the gateway sends keeps a session alive.** Only inbound
  /// application frames move `_lastSeen` (`relay_session.dart:1264`), so a
  /// panel that is merely *watching a page* is reaped one
  /// `heartbeatDeadline` after its handshake — six seconds, at this
  /// composition's defaults. Every case in Phase 13 that used this fixture
  /// finished well inside that window, so the omission cost nothing and was
  /// invisible.
  ///
  /// It stopped being invisible the moment an arm needed a session to survive
  /// past `kBackendStaleAfter` (ten seconds). Measured: the socket was closed
  /// at ~6 s, the panel stopped receiving anything at all, and the arm's
  /// "the banner is still good" assertion passed **because nobody was there
  /// to be told otherwise** — a negative arm made vacuously true by a
  /// collapse, which is the exact failure mode this project has a rule about.
  /// Sabotage (d) is what found it: removing BOTH freshness exclusions turned
  /// nothing red.
  ///
  /// The period is a third of the deadline the gateway **advertised**, never a
  /// literal: `relay_session.dart:1258-1271` is emphatic that a constant on
  /// the client that must match a server config nobody diffs fails silently a
  /// year later. A gateway that advertises nothing usable gets no pump, which
  /// is the same conclusion `HelloResult.heartbeatDeadlineMs` reaches.
  ///
  /// [token] rides in `HelloParams.token`, the typed slot 06-02 added so a
  /// credential never travels in an open map the session logs and copies. Null
  /// by default, and a tokenless hello is byte-identical to the frame this
  /// fixture sent before the parameter existed — which is what keeps every
  /// Phase 13 leg unchanged.
  Future<relay.HelloResult> hello(
      {String? token, Duration budget = const Duration(seconds: 5)}) async {
    final raw = await request(
      relay.Methods.hello,
      params: relay.HelloParams(
        protocol: relay.protocolVersion,
        supported: const [relay.protocolVersion],
        client: relay.PeerInfo('backend-ws-harness/$name', '0.1.0'),
        token: token,
      ).toJson(),
      what: 'the hello result over a real socket',
      budget: budget,
    );
    final result =
        relay.HelloResult.fromJson((raw as Map).cast<String, Object?>());

    final deadlineMs = result.heartbeatDeadlineMs;
    if (deadlineMs != null) {
      _heartbeat?.cancel();
      _heartbeat =
          Timer.periodic(Duration(milliseconds: deadlineMs ~/ 3), (_) {
        if (_closed) return;
        // Fire-and-forget WITH a handler. A bare future here becomes an
        // unhandled asynchronous error attributed to whichever case is running
        // when the socket finally goes, and a beat that fails is not news: the
        // session is gone, and whatever the case was awaiting will say so.
        unawaited(request(relay.Methods.ping,
                what: 'a heartbeat pong', budget: const Duration(seconds: 5))
            .catchError((Object _) => null));
      });
    }
    return result;
  }

  /// Acknowledges one `(alarmUid, ruleIndex)` — one `ackAlarm` frame, no more.
  ///
  /// Built through `AckAlarmParams`, never a map literal, and named through
  /// `Methods.ackAlarm`. That is deliberate rather than convenient: it makes
  /// the frame this fixture puts on the wire the **same construction**
  /// `RemoteStateMan.ackAlarm` uses (14-13 builds it the same way and pins the
  /// literal in its own package's arms), so a field renamed on either side
  /// fails to compile here rather than becoming a second spelling that drifts.
  /// A hand-written map would make this fixture's agreement with the gateway
  /// evidence about a map.
  ///
  /// Throws [RelayRefusal] when the gateway refuses, carrying the code.
  Future<void> ackAlarm(String alarmUid, int ruleIndex,
          {Duration budget = const Duration(seconds: 5)}) =>
      request(
        relay.Methods.ackAlarm,
        params: relay.AckAlarmParams(alarmUid: alarmUid, ruleIndex: ruleIndex)
            .toJson(),
        what: 'the ackAlarm answer for $alarmUid rule $ruleIndex',
        budget: budget,
      );

  /// Subscribes [keys] under the name [sub] and returns the server's answer.
  Future<relay.SubscribeResult> subscribe(String sub, List<String> keys,
      {Duration budget = const Duration(seconds: 5)}) async {
    final raw = await request(
      relay.Methods.subscribe,
      params: relay.SubscribeParams(sub: sub, keys: keys).toJson(),
      what: 'the subscribe answer for ${keys.join(', ')}',
      budget: budget,
    );
    return relay.SubscribeResult.fromJson((raw as Map).cast<String, Object?>());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _failAllPending(StateError('client "$name" was torn down'));
    await _notifications.close();
    await _socket.sink.close().catchError((Object _) {});
  }
}

/// A JSON-RPC error frame, with its code and message still readable.
///
/// Was a bare `StateError` carrying the whole error object inside a sentence.
/// It still prints that sentence, character for character, so nothing that
/// merely *reports* a refusal changed — but an arm that has to tell `-32005
/// forbidden` from `-32011 this gateway serves no alarm engine` can now read
/// the number instead of matching a substring of a message. Those two answers
/// are the difference between "your station may not do that" and "this backend
/// is misconfigured", and a fixture that could not distinguish them would make
/// a permissions arm pass on a composition mistake.
final class RelayRefusal implements Exception {
  RelayRefusal(this.client, this.error);

  /// Which panel was refused.
  final String client;

  /// The `error` member as it came off the wire.
  final Object? error;

  Map<String, Object?> get _map =>
      error is Map ? (error! as Map).cast<String, Object?>() : const {};

  /// The JSON-RPC error code, or null if the frame carried none.
  int? get code => _map['code'] as int?;

  /// The gateway's own sentence.
  String get message => '${_map['message']}';

  @override
  String toString() => 'the server refused client "$client": $error';
}

/// One server→client frame that carried no id, and when it landed.
typedef ServerNotification = ({
  String method,
  Map<String, Object?> params,
  int atMicros,
});

/// The descriptors one production fixture owns: the bound server, and every
/// client socket in front of it.
final class _BackendRelayWiring {
  _BackendRelayWiring(this.backend);

  final ComposedBackendUnderTest backend;

  final List<BackendRelayClient> clients = <BackendRelayClient>[];
  var _torn = false;

  BackendRelayClient requireClient() {
    if (clients.isEmpty) {
      throw StateError('the fixture has no client until `ready` has '
          'completed; await it before reaching for the socket');
    }
    return clients.first;
  }

  /// Binds, starts the alarm engine and connects. The error is handled here as
  /// well as delivered, so a fixture nobody awaited cannot surface as an
  /// unhandled async error in an unrelated case.
  Future<void> connect() {
    final ready = _connect();
    unawaited(ready.catchError((Object _) {}));
    return ready;
  }

  Future<void> _connect() async {
    await backend.composition.server.start();
    // After the worker registration the composition performed, and before any
    // client exists. Both halves are deliberate — see [backendRelayFixture].
    await backend.startAlarms();
    await addClient('A');
  }

  Future<BackendRelayClient> addClient(String name) async {
    if (_torn) {
      throw StateError('the fixture has been torn down; client "$name" cannot '
          'be opened against a server that is closing');
    }
    final ws = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${backend.composition.server.port}'));
    final client = BackendRelayClient._(name, ws, backend.monotonic);
    clients.add(client);
    // Listening BEFORE `ready` is awaited: the channel buffers until the first
    // listener, and a frame that arrived while nobody was listening would be a
    // notification this fixture never saw.
    client._listen();
    await ws.ready;
    return client;
  }

  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;
    await ready.catchError((Object _) {});
    // The engine first: its watchers hold subscriptions on the sweep that
    // `composition.dispose()` is about to release.
    await backend.disposeAlarms();
    await backend.composition.dispose();
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    backend.harness.shutdownFixture();
  }
}

