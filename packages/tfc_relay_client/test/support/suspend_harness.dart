/// A real panel in a second isolate, pausable and resumable — F16's SIGSTOP,
/// spelled in a way that works on all three platforms.
///
/// **Why an isolate at all.** The catalogue's lever for F16 is `SIGSTOP` on the
/// client process. In-process that is impossible — a stopped process cannot run
/// the code that would assert anything about itself — and `Process.killPid` with
/// `ProcessSignal.sigstop` needs a child process with its own entry point and
/// gives nothing at all on Windows. `Isolate.pause()` is the genuine analogue:
/// the paused isolate's event loop stops, so its socket is not read and bytes
/// pile up in the kernel exactly as they do under `SIGSTOP`, and it is a
/// VM-level API with no platform story. 07-RESEARCH §A.4 measured it — 15 ticks
/// in 300 ms, **0 ticks across 600 ms of pause**, then the ordinary rate again
/// — and `suspend_gate_test.dart` re-runs that measurement as its first case so
/// the number is this platform's rather than that probe's.
///
/// **This harness is F16-only and is deliberately not generalised.** It exists
/// because a test cannot call a method on a client that lives in another
/// isolate; a "run any client remotely" helper would be a second fixture with
/// its own lifetime rules, and the next reader would have to learn it before
/// reading one row. 07-RESEARCH §A.4's instruction, followed.
///
/// **The plant, the gateway and any proxy stay in the test isolate.** Only the
/// panel moves. Everything a case injects, samples or asserts about the
/// *gateway* is therefore an ordinary in-process read; the only thing that
/// crosses the isolate boundary is what the panel itself can see, and it
/// crosses as plain maps. Nothing is shared, because a shared object would have
/// to survive being paused.
///
/// **Two channels, and the second one is the instrument.**
///
///  * [SuspendedPanel.ask] is a bounded request/reply — the command protocol.
///    It fails naming the command rather than hanging, which is what makes "the
///    isolate is not answering" an assertion instead of a timeout on the case.
///  * The panel also *pushes* a [PanelReport] on every one of its own periodic
///    ticks, and the tick counter in that report is the whole of F16's
///    no-burst clause. A pushed report is what lets a case say "zero of these
///    arrived across the pause": a paused isolate sends nothing, so the absence
///    is observed rather than inferred, and there is no poll racing the pause.
///
/// **Subscription happens at construction, so there is no `subscribe`
/// command.** `RemoteStateMan` takes its page as a constructor argument and
/// dials from its own constructor, so the keys handed to [SuspendedPanel.spawn]
/// are the panel's page from the first frame. A `subscribe` command would be a
/// second way to build the same state, live only in this file, and F16 has no
/// clause that needs one.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart' show addTearDown;
import 'package:tfc_relay_client/src/remote_state_man.dart';

import 'fault_fixture.dart' show faultClientConfig;

/// One push from the panel's isolate: its tick counter and what it could see
/// of itself at that instant.
///
/// Sent as a plain map and rebuilt here, per the no-shared-objects rule above.
/// [tick] is the panel's own periodic timer, counted in the panel's isolate —
/// which is the number the pause is measured with, because it is the only
/// number that stops when that isolate's event loop does.
typedef PanelReport = ({
  int tick,
  bool ready,
  bool stale,
  int beats,
  int heartbeatTimers,
  Object? value,
  int staleSubs,
});

/// The default cadence of the panel's own timer, and 07-RESEARCH §A.4's.
///
/// Twenty milliseconds because that is the period the executed probe used: a
/// thirty-second pause is 1500 of them, so a VM that replayed overdue periodic
/// timers instead of coalescing them would be unmissable, and a period long
/// enough to be ambiguous would make the row's headline clause a matter of
/// interpretation.
const Duration defaultPanelTick = Duration(milliseconds: 20);

/// How long [SuspendedPanel.ask] waits before failing by name.
///
/// Bounded, and short. The one thing this harness must never do is hang: a case
/// that asks a paused isolate a question is either making an assertion about
/// the pause or has made a mistake, and both of those want an error naming the
/// command inside a second rather than a case that dies on package:test's own
/// thirty-second timeout with no clue in the report.
const Duration defaultAskBudget = Duration(seconds: 5);

/// How long [SuspendedPanel.spawn] waits for the panel to report `up`.
///
/// Generous — spawning an isolate, dialling a gateway and taking a snapshot on
/// a loaded three-platform runner is not a fast thing — because this is not a
/// measurement, it is the difference between a named failure and a suite
/// timeout that names nothing.
const Duration _upBudget = Duration(seconds: 10);

/// A `RemoteStateMan` living in its own isolate, which this object can stop.
final class SuspendedPanel {
  SuspendedPanel._(this._isolate, this._fromPanel, this._toPanel, this.tick);

  final Isolate _isolate;
  final ReceivePort _fromPanel;
  final SendPort _toPanel;

  /// The cadence of the panel's own periodic timer.
  final Duration tick;

  final _pending = <int, Completer<Object?>>{};

  /// Every report the panel has pushed, most recent last.
  ///
  /// Kept whole rather than counted, because the row's questions are about the
  /// *sequence* — which report first said stale, which first held the plant's
  /// new value — and a counter cannot answer either. Bounded in practice by the
  /// case's own wall clock: at 20 ms a forty-second case pushes about two
  /// thousand of these, which is the same order as `FrameSeam.inbound` holds
  /// for an ordinary fault leg.
  final List<PanelReport> reports = <PanelReport>[];

  Capability? _resumeCapability;
  var _nextId = 0;
  var _killed = false;

  /// How many reports have arrived. The pause is measured as a delta on this.
  int get reportsSeen => reports.length;

  /// The most recent report, or null before the first tick.
  PanelReport? get last => reports.isEmpty ? null : reports.last;

  /// Whether this panel is currently stopped.
  bool get isPaused => _resumeCapability != null;

  /// Spawns a panel in a second isolate and waits for it to come up.
  ///
  /// [uri] null spawns the ticker and **no client** — that is the capability
  /// probe's shape, and it is the same spawn, the same timer and the same pause
  /// machinery as the row uses, so a probe that passes is a statement about the
  /// instrument the row is driven with rather than about a second one.
  ///
  /// [watch] is the one key whose value rides every report. One key and not the
  /// page, because a report is pushed fifty times a second and the row's
  /// question is about a single value being stale.
  ///
  /// **Fails rather than hangs, the same way [ask] does** (07-REVIEW WR-08).
  /// A panel isolate that throws before sending its `up` message — a bad URI, a
  /// config that fails validation, a missing native asset — used to leave
  /// `up.future` uncompleted for ever with `errorsAreFatal: false` swallowing
  /// the error, so the case hung until the suite-level timeout with no
  /// diagnostic at all. There is an error port now, and a bound on the wait.
  ///
  /// The teardown is registered here rather than left to the caller for the
  /// same class of reason: both existing callers remember `addTearDown(panel
  /// .shutdown)`, and the third that forgets leaks a live isolate holding a
  /// socket the gateway is still writing to.
  static Future<SuspendedPanel> spawn({
    Uri? uri,
    Set<String> keys = const <String>{},
    String? watch,
    Duration tick = defaultPanelTick,
  }) async {
    final fromPanel = ReceivePort();
    // Registered before anything can throw: a spawn that fails partway leaves
    // no `panel` to hang the teardown off, and an open ReceivePort keeps the
    // test isolate alive after the suite is done.
    addTearDown(fromPanel.close);
    final up = Completer<SendPort>();
    late final SuspendedPanel panel;

    fromPanel.listen((Object? message) {
      final report = (message! as Map).cast<String, Object?>();
      switch (report['kind']) {
        case 'up':
          up.complete(report['commands']! as SendPort);
        case 'report':
          panel.reports.add((
            tick: report['tick']! as int,
            ready: report['ready']! as bool,
            stale: report['stale']! as bool,
            beats: report['beats']! as int,
            heartbeatTimers: report['heartbeatTimers']! as int,
            value: report['value'],
            staleSubs: report['staleSubs']! as int,
          ));
        case 'reply':
          panel._pending.remove(report['id'])?.complete(report['value']);
      }
    });

    // Where an isolate that dies before it can report goes. Without it
    // `errorsAreFatal: false` swallows the error and the handshake below waits
    // for a message nobody is left to send.
    final errors = ReceivePort();
    errors.listen((Object? error) {
      if (!up.isCompleted) {
        up.completeError(StateError('the panel isolate died before it came '
            'up: $error'));
      }
    });

    final isolate = await Isolate.spawn(
      panelIsolate,
      <String, Object?>{
        'reports': fromPanel.sendPort,
        'uri': uri?.toString(),
        'keys': keys.toList(),
        'watch': watch,
        'tickMs': tick.inMilliseconds,
      },
      // Named so a hung run's `--observe` output says which isolate this is,
      // and errors-are-fatal off so a panel that throws reports through the
      // command protocol instead of taking the suite down with it.
      debugName: 'suspend-harness-panel',
      errorsAreFatal: false,
      onError: errors.sendPort,
    );
    addTearDown(errors.close);

    final commands = await up.future.timeout(
      _upBudget,
      onTimeout: () => throw TimeoutException(
          'the panel isolate never reported "up" within '
          '${_upBudget.inSeconds} s. It is either wedged in its own '
          'construction or it died without reporting — and a case that waits '
          'on this for ever fails as a suite timeout naming nothing',
          _upBudget),
    );

    panel = SuspendedPanel._(isolate, fromPanel, commands, tick);
    addTearDown(panel.shutdown);
    return panel;
  }

  /// Asks the panel one question and waits, bounded, for its answer.
  ///
  /// **Fails naming the command rather than hanging.** A paused isolate cannot
  /// answer — that is the whole of what a pause is — so this call is also an
  /// instrument: a case may use its failure as evidence that the event loop
  /// genuinely stopped, which is a stronger statement than "no reports
  /// arrived".
  Future<Object?> ask(
    String command, {
    String? key,
    Duration budget = defaultAskBudget,
  }) {
    if (_killed) {
      throw StateError('this panel has been shut down, so "$command" has '
          'nobody to answer it. A command issued after the teardown is a case '
          'holding the harness past its own lifetime');
    }
    final id = _nextId++;
    final answer = Completer<Object?>();
    _pending[id] = answer;
    _toPanel.send(<String, Object?>{'cmd': command, 'id': id, 'key': key});
    return answer.future.timeout(
      budget,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'the panel did not answer "$command" within '
            '${budget.inMilliseconds} ms. Either it is paused — a paused '
            'isolate runs nothing, including its command loop, which is what '
            'makes it a SIGSTOP analogue — or it is gone',
            budget);
      },
    );
  }

  /// Stops the panel's event loop. Idempotent.
  void pause() {
    if (_resumeCapability != null) return;
    _resumeCapability = _isolate.pause();
  }

  /// Starts it again. Idempotent.
  ///
  /// **Idempotent on purpose, and it is the teardown that needs it.** A case
  /// that fails between [pause] and [resume] would otherwise leave a paused
  /// isolate behind — one that cannot answer the shutdown command, holds a
  /// socket the gateway is still writing to, and is invisible in the report
  /// except as the next case being slow.
  void resume() {
    final capability = _resumeCapability;
    if (capability == null) return;
    _resumeCapability = null;
    _isolate.resume(capability);
  }

  /// How many reports arrived since [mark].
  int reportsSince(int mark) => reports.length - mark;

  /// The index of the first report at or after [mark] satisfying [test], or
  /// null if none has.
  ///
  /// Indices rather than reports, because every question F16 asks about the
  /// resume is an *ordering* question — did the panel say stale before it said
  /// anything new — and an ordering question needs positions.
  int? firstReportWhere(bool Function(PanelReport report) test, {int mark = 0}) {
    for (var i = mark; i < reports.length; i++) {
      if (test(reports[i])) return i;
    }
    return null;
  }

  /// Resumes if paused, asks the panel to dispose its client, and kills the
  /// isolate. Idempotent, and safe to register with `addTearDown`.
  ///
  /// The graceful half is not politeness: the panel owns a real socket to a
  /// real gateway, and a case that killed the isolate under it would leave the
  /// gateway holding a session until its own reaper noticed — which is the
  /// thing the row measures, arriving in the *next* case's ledger. The kill is
  /// the fallback for a panel that cannot answer, and it runs either way.
  Future<void> shutdown() async {
    if (_killed) return;
    resume();
    try {
      await ask('shutdown', budget: const Duration(seconds: 5));
    } on Object {
      // A panel that cannot say goodbye is killed instead. The failure is not
      // interesting on its own — the kill below is what guarantees the suite
      // exits — and rethrowing here would replace a case's real failure with
      // its teardown's.
    }
    _killed = true;
    _isolate.kill(priority: Isolate.immediate);
    _fromPanel.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('the panel was shut down before this '
          'command was answered'));
    }
    _pending.clear();
  }
}

/// The panel's entry point: a real `RemoteStateMan`, a periodic report, and a
/// command loop.
///
/// Top-level because `Isolate.spawn` requires it. Everything it is handed is
/// a plain value; everything it sends back is a plain map.
Future<void> panelIsolate(Map<String, Object?> spec) async {
  final reports = spec['reports']! as SendPort;
  final commands = ReceivePort();
  final uriText = spec['uri'] as String?;
  final watch = spec['watch'] as String?;
  final tick = Duration(milliseconds: spec['tickMs']! as int);

  // Null uri is the capability probe: the ticker and the pause machinery with
  // no client under them. See [SuspendedPanel.spawn].
  final client = uriText == null
      ? null
      : RemoteStateMan(
          uri: Uri.parse(uriText),
          // The same knobs every other fault leg in this package runs with, so
          // "the panel detected staleness" is judged against the deadline the
          // rest of the gate is judged against rather than against one this
          // file chose.
          config: faultClientConfig(),
          keys: (spec['keys']! as List).cast<String>().toSet(),
        );

  var ticks = 0;
  final ticker = Timer.periodic(tick, (_) {
    ticks++;
    reports.send(<String, Object?>{
      'kind': 'report',
      'tick': ticks,
      'ready': client?.isReady ?? false,
      'stale': client?.viewIsStale ?? false,
      'beats': client?.debugHeartbeatsSent ?? 0,
      'heartbeatTimers': client?.debugHeartbeatTimerCount ?? 0,
      'value': watch == null ? null : client?.read(watch)?.value,
      'staleSubs': client?.staleSubscriptions.length ?? 0,
    });
  });

  commands.listen((Object? message) async {
    final command = (message! as Map).cast<String, Object?>();
    final id = command['id'];
    Object? answer;
    switch (command['cmd']) {
      case 'read':
        answer = client?.read(command['key']! as String)?.value;
      case 'isReady':
        answer = client?.isReady ?? false;
      case 'viewIsStale':
        answer = client?.viewIsStale ?? false;
      case 'staleSubscriptions':
        answer = client?.staleSubscriptions.toList() ?? const <String>[];
      case 'tickCount':
        answer = ticks;
      case 'shutdown':
        ticker.cancel();
        await client?.dispose();
        answer = 'gone';
      default:
        answer = 'unknown command "${command['cmd']}": this harness answers '
            'read, isReady, viewIsStale, staleSubscriptions, tickCount and '
            'shutdown, and nothing else — it is F16\'s and is not a general '
            'remote-control channel';
    }
    reports.send(<String, Object?>{'kind': 'reply', 'id': id, 'value': answer});
    if (command['cmd'] == 'shutdown') commands.close();
  });

  reports.send(<String, Object?>{
    'kind': 'up',
    'commands': commands.sendPort,
  });
}
