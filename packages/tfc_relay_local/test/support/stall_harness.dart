/// The gateway and its three upstreams in a second isolate, pausable and
/// resumable — F22's SIGSTOP, and the deliberate **inversion** of
/// `suspend_harness.dart`.
///
/// **The whole design in one sentence: whatever is being frozen cannot be the
/// thing doing the observing.** `suspend_harness.dart` (client package) and its
/// copy `panel_isolate.dart` (this package) freeze a *panel* and keep the
/// gateway in the test isolate; F22 needs the mirror. Here the `LocalStateMan`,
/// its three `FakeUpstreamLink`s, the `RelayServer` and a self-driving plant
/// all live in the isolate this object can pause, and the panels stay in the
/// test isolate. A panel that was paused would observe nothing, and F22's
/// subject is what *five never-frozen panels* see when the gateway stops
/// turning.
///
/// **This harness is F22-only and is deliberately not generalised, and it is
/// kept separate from `panel_isolate.dart` on purpose.** `suspend_harness.dart`
/// states the refusal (`:16-20`): a "freeze any participant remotely" helper
/// would be a second fixture with its own lifetime rules that the next reader
/// has to learn before reading one row. The two harnesses freeze opposite ends
/// of the same pipe — a panel there, the gateway here — and merging them would
/// put both lifetimes in one file and make each row's reader carry the other
/// row's machinery. So this is a third file that copies the *pattern* — the
/// bounded [StalledGateway.ask] failing by command name, the error port with an
/// up-budget, idempotent pause/resume, a graceful-then-kill shutdown, and a
/// `resume()` in `addTearDown` — and inverts what sits inside the isolate.
///
/// **Nothing is shared across the boundary.** Everything a case injects,
/// samples or asserts about the *gateway* crosses as a plain map through
/// [StalledGateway.ask]; everything the panels see is an ordinary in-process
/// read of a real `RemoteStateMan` the case built itself. A shared object would
/// have to survive being paused.
///
/// **The plant drives itself inside the isolate.** A `Timer.periodic` bumps
/// every key of every link on a period, so "values kept changing right up to
/// the freeze, and again after it" is true without a lever crossing the
/// boundary mid-pause. That timer is not on the freeze suite's allow-list and
/// needs no entry: `freeze_test.dart`'s `timerOffenders` sweep scans `lib/src`
/// only (`freeze_test.dart:143`, `:756-786`; `periodicTimerAllowList` names
/// `lib/src` files), and this file is under `test/support`, exactly as
/// `panel_isolate.dart:408`'s ticker already is with no entry.
///
/// **Port 0, always.** 08-03's ninth freeze: no literal port anywhere under
/// `test/`, so two worktrees can run this suite at once. `ServerConfig.port`
/// defaults to zero; the isolate reports the bound port back and the panels
/// dial what the OS picked.
///
/// **A capability probe is the file's first case** (`suspend_gate_test.dart:
/// 228`'s shape). The in-repo pause measurement (07-RESEARCH §A.4: 15 ticks in
/// 300 ms, 0 across 600 ms of pause) was taken on a *client* isolate with no
/// listening socket. Whether a paused isolate that *owns a listening socket*
/// stops accepting and reading — so panels' bytes queue in the kernel exactly
/// as under SIGSTOP — is assumption A3, and the probe in `stall_gate_test.dart`
/// turns it into a number on this platform.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart' show addTearDown;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:tfc_relay_local/src/collect/timescale_sink.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show PipeKeys;
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'fake_upstream_link.dart';
import 'gate_b_fixture.dart' show gateBPage;
import 'keymap_fixtures.dart' show opcUaEntry;
import 'permissive_resolver.dart';

/// What F22e hands the gateway isolate so it historises one key into a real
/// TimescaleDB while it is being frozen — endpoint values from 8b-03's
/// env-addressed fixture, a table base the case owns and drops, the plant key
/// to collect and its sample interval. Plain values only: everything crosses
/// the isolate boundary as a map, like the rest of the spec.
typedef StallCollect = ({
  String host,
  int port,
  String database,
  String? username,
  String? password,
  String table,
  String key,
  Duration sampleInterval,
});

/// The default cadence of the plant driver inside the isolate.
///
/// Fifty milliseconds — the same order as [defaultAskBudget] is seconds — so a
/// case that watches a value advance sees several bumps in a short window, and
/// so the difference between "advancing" and "frozen" is a rate rather than a
/// single pair of reads that cannot tell "stopped" from "between sweeps"
/// (`stuck_momentary_gate_test.dart:_sampleTag`'s reason).
const Duration defaultPlantSweep = Duration(milliseconds: 50);

/// How long [StalledGateway.ask] waits before failing by name.
///
/// `panel_isolate.dart:87-94`'s bound and its reason, mirrored: the one thing
/// this harness must never do is hang. A case that asks a paused gateway a
/// question is either asserting the pause or has made a mistake, and both want
/// an error naming the command inside a second, not a suite timeout naming
/// nothing.
const Duration defaultAskBudget = Duration(seconds: 5);

/// How long [StalledGateway.spawn] waits for the gateway to report `up`.
///
/// Generous, `panel_isolate.dart:96-103`'s reason: spawning an isolate,
/// building a `LocalStateMan` over three links, connecting them and binding a
/// server on a loaded three-platform runner is not fast, and this is not a
/// measurement — it is the difference between a named failure and a suite
/// timeout that names nothing.
const Duration _upBudget = Duration(seconds: 20);

/// One push from the gateway isolate: its own sweep counter and the latest
/// value the plant wrote.
///
/// Sent as a plain map and rebuilt here. [sweep] is the plant driver's own
/// counter, which stops the instant the isolate's event loop does — the only
/// number that makes the freeze observable from the gateway's own side, the
/// mirror of `PanelReport.tick`.
typedef GatewayReport = ({int sweep, int latest});

/// A gateway and its three PLCs living in an isolate this object can freeze.
final class StalledGateway {
  StalledGateway._(this._isolate, this._fromGateway, this._toGateway, this.port,
      this.collectFailures);

  final Isolate _isolate;
  final ReceivePort _fromGateway;
  final SendPort _toGateway;

  /// The ephemeral port the OS picked at bind, reported back from the isolate.
  /// The panels a case builds dial this — never a literal.
  final int port;

  /// [CollectionRunner.entryFailures] as of the `up` report — empty when the
  /// collection chain stood up whole, and always empty when [spawn] was given
  /// no `collect` spec. F22e asserts on this before trusting a single row:
  /// a gap proven against a historian that never started is no proof.
  final Map<String, String> collectFailures;

  final _pending = <int, Completer<Object?>>{};

  /// Every report the gateway has pushed, most recent last.
  ///
  /// Kept whole rather than counted (`panel_isolate.dart:120-126`): the freeze
  /// is a question about a *sequence* — how many sweeps happened before the
  /// pause, how many during it — and a counter cannot answer both.
  final List<GatewayReport> reports = <GatewayReport>[];

  Capability? _resumeCapability;
  var _nextId = 0;
  var _killed = false;

  /// How many reports have arrived. A pause is measured as a delta on this.
  int get reportsSeen => reports.length;

  /// The most recent report, or null before the first sweep push.
  GatewayReport? get last => reports.isEmpty ? null : reports.last;

  /// Whether the gateway isolate is currently frozen.
  bool get isPaused => _resumeCapability != null;

  /// Stands up a gateway over [aliases] × [keysPerAlias] keys in a second
  /// isolate, binds its server on port 0, and waits for the bound port.
  ///
  /// [heartbeatDeadline], [tick] and [stallThreshold] are the gateway's own
  /// `ServerConfig` knobs, passed through so a case reads the reaper deadline
  /// and the stall threshold off numbers it set rather than off constants this
  /// file chose. Their defaults are `ServerConfig`'s own.
  ///
  /// **Fails rather than hangs** (`panel_isolate.dart:153-158`): an error port
  /// and a bound on the wait, so a gateway that throws before reporting `up` —
  /// a bad config, a link that will not connect — is a named failure and not a
  /// suite timeout with `errorsAreFatal: false` swallowing the cause.
  ///
  /// The teardown is registered here rather than left to the caller, for
  /// `panel_isolate.dart:160-162`'s reason: a caller that forgets
  /// `addTearDown(gateway.shutdown)` leaks a live isolate holding a listening
  /// socket every panel is still writing to.
  static Future<StalledGateway> spawn({
    List<String> aliases = const <String>['ST101', 'ST201', 'ST301'],
    int keysPerAlias = 50,
    Duration plantSweep = defaultPlantSweep,
    Duration tick = ServerConfig.minTick,
    Duration? stallThreshold,
    Duration? heartbeatDeadline,
    // Long by default, because F22a-d are not staleAfter rows (the plant
    // keeps re-delivering, so a short link staleAfter would grey values for
    // a reason that is not the freeze). F22e passes a SHORT one on purpose:
    // its whole subject is the freeze outliving the deadline, so the values
    // the pause left behind degrade before the quiesced plant refreshes them.
    Duration staleAfter = const Duration(seconds: 30),
    StallCollect? collect,
  }) async {
    if (aliases.isEmpty || aliases.toSet().length != aliases.length) {
      throw ArgumentError('aliases must be non-empty and distinct (got '
          '$aliases): F22\'s catalogue row is three upstreams, and two links '
          'claiming one alias is two producers for its health keys');
    }
    final fromGateway = ReceivePort();
    // Registered before anything can throw, so a spawn that fails partway does
    // not leak an open ReceivePort keeping the test isolate alive.
    addTearDown(fromGateway.close);
    final up = Completer<Map<String, Object?>>();
    late final StalledGateway gateway;

    fromGateway.listen((Object? message) {
      final report = (message! as Map).cast<String, Object?>();
      switch (report['kind']) {
        case 'up':
          if (!up.isCompleted) up.complete(report);
        case 'report':
          gateway.reports.add((
            sweep: report['sweep']! as int,
            latest: report['latest']! as int,
          ));
        case 'reply':
          gateway._pending.remove(report['id'])?.complete(report['value']);
      }
    });

    // Where an isolate that dies before it can report goes.
    final errors = ReceivePort();
    errors.listen((Object? error) {
      if (!up.isCompleted) {
        up.completeError(
            StateError('the gateway isolate died before it came up: $error'));
      }
    });

    final isolate = await Isolate.spawn(
      stalledGatewayEntryPoint,
      <String, Object?>{
        'reports': fromGateway.sendPort,
        'aliases': aliases,
        'keysPerAlias': keysPerAlias,
        'sweepMs': plantSweep.inMilliseconds,
        'tickMs': tick.inMilliseconds,
        'staleAfterMs': staleAfter.inMilliseconds,
        if (stallThreshold != null) 'stallThresholdMs': stallThreshold.inMilliseconds,
        if (heartbeatDeadline != null)
          'heartbeatMs': heartbeatDeadline.inMilliseconds,
        if (collect != null)
          'collect': <String, Object?>{
            'host': collect.host,
            'port': collect.port,
            'database': collect.database,
            'username': collect.username,
            'password': collect.password,
            'table': collect.table,
            'key': collect.key,
            'sampleIntervalMs': collect.sampleInterval.inMilliseconds,
          },
      },
      debugName: 'stall-harness-gateway',
      errorsAreFatal: false,
      onError: errors.sendPort,
    );
    addTearDown(errors.close);

    final Map<String, Object?> ready;
    try {
      ready = await up.future.timeout(
        _upBudget,
        onTimeout: () => throw TimeoutException(
            'the gateway isolate never reported "up" within '
            '${_upBudget.inSeconds} s. It is wedged in its own construction, '
            'could not connect its links, or died without reporting — and a '
            'case that waits on this for ever fails as a suite timeout naming '
            'nothing',
            _upBudget),
      );
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }

    gateway = StalledGateway._(
      isolate,
      fromGateway,
      ready['commands']! as SendPort,
      ready['port']! as int,
      ((ready['collectFailures'] ?? const <String, Object?>{}) as Map)
          .cast<String, String>(),
    );
    addTearDown(gateway.shutdown);
    return gateway;
  }

  /// Asks the gateway one question and waits, bounded, for its answer.
  ///
  /// **Fails naming the command rather than hanging** (`panel_isolate.dart:
  /// 250-282`). A paused isolate cannot answer — that is the whole of what a
  /// pause is — so a case may use this call's failure as evidence that the
  /// event loop genuinely stopped, which is a stronger statement than "no
  /// reports arrived".
  Future<Object?> ask(
    String command, {
    Duration budget = defaultAskBudget,
  }) {
    if (_killed) {
      throw StateError('this gateway has been shut down, so "$command" has '
          'nobody to answer it. A command after the teardown is a case holding '
          'the harness past its own lifetime');
    }
    final id = _nextId++;
    final answer = Completer<Object?>();
    _pending[id] = answer;
    _toGateway.send(<String, Object?>{'cmd': command, 'id': id});
    return answer.future.timeout(
      budget,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'the gateway did not answer "$command" within '
            '${budget.inMilliseconds} ms. Either it is paused — a paused '
            'isolate runs nothing, including its command loop, which is what '
            'makes it a SIGSTOP analogue — or it is gone',
            budget);
      },
    );
  }

  /// Freezes the gateway's event loop. Idempotent.
  ///
  /// This is F22's injection: the gateway stops ticking, stops serving its
  /// socket and stops driving its plant, so five never-frozen panels see the
  /// silence a Veeam snapshot produced at Ignition.
  void pause() {
    if (_resumeCapability != null) return;
    _resumeCapability = _isolate.pause();
  }

  /// Starts it again. Idempotent.
  ///
  /// **Idempotent on purpose, and it is the teardown that needs it**
  /// (`panel_isolate.dart:296-300`). A case that fails between [pause] and
  /// [resume] would otherwise leave a paused gateway behind — one that cannot
  /// answer the shutdown command and wedges the whole run, because every later
  /// case's panels dial a port nothing is accepting on.
  void resume() {
    final capability = _resumeCapability;
    if (capability == null) return;
    _resumeCapability = null;
    _isolate.resume(capability);
  }

  /// How many reports arrived since [mark].
  int reportsSince(int mark) => reports.length - mark;

  /// Resumes if paused, asks the gateway to stop and dispose, and kills the
  /// isolate. Idempotent, and safe to register with `addTearDown`.
  ///
  /// The graceful half is not politeness (`panel_isolate.dart:331-337`): the
  /// isolate owns a listening socket and three upstream links, and killing it
  /// under a live panel would leave that panel dialling a dead port for the
  /// rest of the run. The kill is the fallback for a gateway that cannot
  /// answer, and it runs either way.
  Future<void> shutdown() async {
    if (_killed) return;
    resume();
    try {
      await ask('shutdown', budget: const Duration(seconds: 5));
    } on Object {
      // A gateway that cannot say goodbye is killed instead; rethrowing here
      // would replace a case's real failure with its teardown's.
    }
    _killed = true;
    _isolate.kill(priority: Isolate.immediate);
    _fromGateway.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('the gateway was shut down before this '
          'command was answered'));
    }
    _pending.clear();
  }
}

/// The gateway's entry point: three fake PLCs into a real `LocalStateMan`, a
/// real `RelayServer` on port 0, a self-driving plant, a periodic report, and
/// a command loop.
///
/// Top-level because `Isolate.spawn` requires it. Everything it is handed is a
/// plain value; everything it sends back is a plain map.
Future<void> stalledGatewayEntryPoint(Map<String, Object?> spec) async {
  final reports = spec['reports']! as SendPort;
  final commands = ReceivePort();
  final aliases = (spec['aliases']! as List).cast<String>();
  final keysPerAlias = spec['keysPerAlias']! as int;
  final sweep = Duration(milliseconds: spec['sweepMs']! as int);
  final tick = Duration(milliseconds: spec['tickMs']! as int);
  final staleAfterMs = spec['staleAfterMs'] as int? ?? 30000;
  final stallThresholdMs = spec['stallThresholdMs'] as int?;
  final heartbeatMs = spec['heartbeatMs'] as int?;
  final collectSpec = (spec['collect'] as Map?)?.cast<String, Object?>();

  // One fake PLC per alias, each claiming exactly its own page — an empty key
  // set on FakeUpstreamLink claims EVERYTHING, which a per-alias gateway must
  // never do.
  final pages = <FakeUpstreamLink, List<String>>{};
  final links = <FakeUpstreamLink>[];
  for (final alias in aliases) {
    final page = gateBPage(alias, keysPerAlias);
    final link = FakeUpstreamLink(alias: alias, keys: page);
    links.add(link);
    pages[link] = page;
  }

  final mappings = KeyMappings(nodes: {
    for (final entry in pages.entries)
      for (final key in entry.value)
        key: opcUaEntry(alias: entry.key.alias, identifier: key)
          // F22e's one collected key: the entry rides the same mapping every
          // other key gets, plus the collect block the runner plans from.
          ..collect = collectSpec != null && key == collectSpec['key']
              ? CollectEntry(
                  key: key,
                  name: collectSpec['table']! as String,
                  sampleInterval: Duration(
                      milliseconds: collectSpec['sampleIntervalMs']! as int),
                )
              : null,
  });

  final plant = LocalStateMan(
    links: links,
    router: KeyRouter.overLinks(links, mappings: mappings),
    // See spawn's staleAfter doc: long for F22a-d, short on F22e's order.
    staleAfter: Duration(milliseconds: staleAfterMs),
  );

  // Seed the first sweep synchronously, before the server exists, so the first
  // panel to subscribe gets a page of real values rather than
  // uncertainNotYetKnown (gate_b_fixture.dart:688-694's lifecycle rule).
  var value = 1000;
  for (final entry in pages.entries) {
    entry.key.setValues({for (final key in entry.value) key: value});
  }

  await plant.start();

  // F22e's collection chain, composed the way bin/relay_gateway.dart composes
  // it — sink, plan, runner on the plant's own health producer — and living
  // IN THIS ISOLATE on purpose (`useIsolate: false`): a sink on its own
  // isolate would keep flushing through the very freeze the arm exists to
  // see. Nothing here runs when the spec carries no collect block.
  TimescaleSink? sink;
  CollectionRunner? runner;
  if (collectSpec != null) {
    final config = CollectionConfig(
      enabled: true,
      endpoint: CollectionEndpoint(
        host: collectSpec['host']! as String,
        port: collectSpec['port']! as int,
        database: collectSpec['database']! as String,
        username: collectSpec['username'] as String?,
        password: collectSpec['password'] as String?,
      ),
      connectTimeout: const Duration(seconds: 2),
      queryTimeout: const Duration(seconds: 5),
    );
    sink = TimescaleSink(
      config,
      publisherId: 'f22e-stall',
      useIsolate: false,
      sleep: (_) => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await sink.start();
    runner = CollectionRunner(
      plan: CollectionPlan.from(mappings, config),
      stateMan: plant,
      sink: sink,
      health: plant.collectHealth,
    );
    await runner.start();
  }

  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: plant,
    config: ServerConfig(
      // No port: ServerConfig defaults to 0, the ephemeral bind spelled by
      // omission so the no-literal-port sweep finds nothing.
      tick: tick,
      stallThreshold: stallThresholdMs == null
          ? const Duration(milliseconds: 300)
          : Duration(milliseconds: stallThresholdMs),
      heartbeatDeadline: heartbeatMs == null
          ? const Duration(seconds: 6)
          : Duration(milliseconds: heartbeatMs),
    ),
  );
  final status = wireStatusNotifications(plant, server);
  await server.start();

  var sweeps = 0;
  // F22e's quiesce lever: while false the driver ticks but publishes nothing,
  // so the plant's held values age exactly as a real PLC's do across its
  // first silent publishing interval. Flipped by the quiesce/drive commands,
  // for the window F22e is judging and no longer.
  var driving = true;
  // The self-driving plant. Not on the freeze allow-list and needs no entry:
  // the sweep is under test/support (see the library doc), which timerOffenders
  // does not scan.
  final driver = Timer.periodic(sweep, (_) {
    if (!driving) return;
    value++;
    sweeps++;
    for (final entry in pages.entries) {
      entry.key.setValues({for (final key in entry.value) key: value});
    }
    reports.send(<String, Object?>{
      'kind': 'report',
      'sweep': sweeps,
      'latest': value,
    });
  });

  commands.listen((Object? message) async {
    final command = (message! as Map).cast<String, Object?>();
    final id = command['id'];
    Object? answer;
    switch (command['cmd']) {
      case 'sessionCount':
        answer = server.sessions.sessionCount;
      case 'sweeps':
        answer = sweeps;
      case 'latest':
        answer = value;
      case 'quiesce':
        driving = false;
        answer = 'quiet';
      case 'drive':
        driving = true;
        answer = 'driving';
      case 'drops':
        // The counter behind PIPE.collect.rows_dropped, read through the
        // plant the way a panel reads it — null-under-errorConfig before the
        // runner's first refresh, which the delta arithmetic reads as zero.
        answer = (plant.read(PipeKeys.collectRowsDropped)?.value as int?) ?? 0;
      case 'shutdown':
        driver.cancel();
        // Collection first, mirroring bin/relay_gateway.dart's order
        // (8b-03 deviation 4): the runner stops sampling and flushes while
        // the sink still owns a connection, before anything else tears down.
        await runner?.stop();
        await sink?.close();
        await status.cancel();
        await server.close();
        await plant.dispose();
        answer = 'gone';
      default:
        answer = 'unknown command "${command['cmd']}": this harness answers '
            'sessionCount, sweeps, latest, quiesce, drive, drops and '
            'shutdown, and nothing else — it is F22\'s and is not a general '
            'remote-control channel';
    }
    reports.send(<String, Object?>{'kind': 'reply', 'id': id, 'value': answer});
    if (command['cmd'] == 'shutdown') commands.close();
  });

  reports.send(<String, Object?>{
    'kind': 'up',
    'commands': commands.sendPort,
    'port': server.port,
    if (runner != null) 'collectFailures': runner.entryFailures,
  });
}
