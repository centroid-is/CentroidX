/// A real panel in a second isolate that engages a hold-to-run deadman, and
/// which this object can pause, kill abruptly, or shut down gracefully — F26's
/// three deaths of a held momentary control, spelled so they work on all three
/// platforms.
///
/// **The pattern is `tfc_relay_client/test/support/suspend_harness.dart`, not
/// the class.** This is a copy of that file's ideas and not an import: no
/// `package:` URI reaches another package's `test/` directory (the same reason
/// `gate_b_fixture.dart` copies `gate_fixture.dart` rather than importing it),
/// and the pieces carried across are exactly the ones its own doc names —
/// the report pushed on the paused side's *own* timer so absence is observed
/// rather than inferred; the bounded [PanelIsolate.ask] that fails naming the
/// command instead of hanging; the error port and the up-budget so a dying
/// isolate is a named failure and not a suite timeout; idempotent
/// pause/resume, a graceful-then-kill shutdown, and a `resume()` registered in
/// `addTearDown` so a case failing between pause and resume cannot leave a
/// paused isolate holding a socket the gateway is still writing to.
///
/// **What this harness adds over its source: a live hold.** `suspend_harness`
/// carries a panel that watches a value; this one carries a panel that *holds
/// a button*. The panel engages a hold-to-run deadman on a named key at
/// construction (through the shipped `HoldToRunController`, so the pulse
/// cadence and the release paths are the product's, not this file's) and feeds
/// the counter until it is paused, killed, or shut down. F26's whole subject
/// is what happens to that counter when the panel stops being there.
///
/// **The plant and the gateway stay in the test isolate; only the panel
/// moves** (`suspend_harness.dart:22-27`, restated). Everything a case injects
/// or asserts about the *plant* — above all the deadman counter on the plant
/// tag, read back off the fake link — is an ordinary in-process read. The only
/// thing that crosses the isolate boundary is what the panel itself can see,
/// and it crosses as plain maps: nothing is shared, because a shared object
/// would have to survive being paused. The row's observable is what the PLC
/// would see, so it is read from the plant side and never from the panel that
/// is about to die.
///
/// **Two channels, and the report is the instrument** (`suspend_harness.dart:
/// 29-38`, restated). [PanelIsolate.ask] is a bounded request/reply that fails
/// naming the command rather than hanging — a paused isolate cannot answer,
/// which is a stronger statement than "no reports arrived". The panel also
/// *pushes* a [PanelReport] on every one of its own periodic ticks: a paused
/// or killed isolate sends nothing, so its silence is measured on this side
/// rather than assumed.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart' show addTearDown;
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show WriteApplied;

/// One push from the panel's isolate: its own tick counter and what it could
/// see of its hold at that instant.
///
/// Sent as a plain map and rebuilt here, per the no-shared-objects rule above.
/// [tick] is the panel's own periodic timer, counted in the panel's isolate —
/// the only number that stops when that isolate's event loop does, which is
/// what makes a paused or killed panel's silence observable. [held] and
/// [pulses] are the panel's *own* idea of its hold; the counter that matters
/// for safety is the one on the plant tag, read on the test side.
typedef PanelReport = ({
  int tick,
  bool ready,
  bool held,
  int pulses,
});

/// The default cadence of the panel's own report timer.
///
/// Twenty milliseconds, `suspend_harness.dart:73-80`'s number and its reason:
/// short enough that a pause of a few hundred milliseconds is tens of missed
/// reports, so "zero arrived across the pause" is unmissable rather than a
/// matter of interpretation.
const Duration defaultPanelTick = Duration(milliseconds: 20);

/// The default hold-to-run pulse cadence the panel feeds its deadman at.
///
/// Fifty milliseconds — half the shipped `ClientConfig.holdPulsePeriod`
/// default so a case's window sees several counter advances without waiting on
/// the production 100 ms, and still far above the report tick so the two
/// timers do not alias. The PLC's `T#1000MS` deadman tolerance
/// (`relay-comm-design.md` §4.6a) is unchanged by this: the cadence a gate row
/// drives the counter at is not the PLC's `TON` preset.
const Duration defaultHoldPulse = Duration(milliseconds: 50);

/// How long [PanelIsolate.ask] waits before failing by name.
///
/// `suspend_harness.dart:82-89`'s bound and its reason: the one thing this
/// harness must never do is hang. A case that asks a paused isolate a question
/// is either making an assertion about the pause or has made a mistake, and
/// both want an error naming the command inside a second rather than a case
/// that dies on package:test's own timeout with no clue in the report.
const Duration defaultAskBudget = Duration(seconds: 5);

/// How long [PanelIsolate.spawn] waits for the panel to report `up`.
///
/// Generous, and for `suspend_harness.dart:91-97`'s reason: spawning an
/// isolate, dialling a gateway, taking a snapshot and engaging a hold on a
/// loaded three-platform runner is not fast, and this is not a measurement —
/// it is the difference between a named failure and a suite timeout that names
/// nothing.
const Duration _upBudget = Duration(seconds: 15);

/// A `RemoteStateMan` holding one hold-to-run deadman in its own isolate,
/// which this object can pause, kill, or shut down.
final class PanelIsolate {
  PanelIsolate._(this._isolate, this._fromPanel, this._toPanel, this.engaged);

  final Isolate _isolate;
  final ReceivePort _fromPanel;
  final SendPort _toPanel;

  /// Whether the panel's engage came back applied — false if it was refused
  /// or the panel holds no hold at all (a null `holdKey`).
  final bool engaged;

  final _pending = <int, Completer<Object?>>{};

  /// Every report the panel has pushed, most recent last.
  ///
  /// Kept whole rather than counted, `suspend_harness.dart:110-120`'s reason:
  /// the row's questions are about the *sequence* — how many arrived after a
  /// pause, whether any arrived after a kill — and a counter cannot answer
  /// either.
  final List<PanelReport> reports = <PanelReport>[];

  Capability? _resumeCapability;
  var _nextId = 0;
  var _killed = false;

  /// How many reports have arrived. A pause or a kill is measured as a delta
  /// on this.
  int get reportsSeen => reports.length;

  /// The most recent report, or null before the first tick.
  PanelReport? get last => reports.isEmpty ? null : reports.last;

  /// Whether this panel is currently stopped.
  bool get isPaused => _resumeCapability != null;

  /// Spawns a panel in a second isolate and waits for it to come up.
  ///
  /// [uri] is the gateway (or a fault proxy in front of it) the panel dials —
  /// **never** a literal port; the caller passes what the fixture bound.
  ///
  /// [holdKey] null spawns the ticker and a client but engages **no hold** —
  /// that is the capability probe's shape, the same spawn and the same pause
  /// machinery the rows use, so a probe that passes is a statement about the
  /// instrument rather than about a second one. Non-null engages a hold on
  /// that key before reporting `up`.
  ///
  /// **Fails rather than hangs** (`suspend_harness.dart:146-156`,
  /// 07-REVIEW WR-08). A panel isolate that throws before sending `up` — a bad
  /// URI, a config that fails validation, a hold that never engages — used to
  /// leave the wait uncompleted for ever with `errorsAreFatal: false`
  /// swallowing the error, so the case hung until the suite-level timeout with
  /// no diagnostic. There is an error port now, and a bound on the wait.
  ///
  /// The teardown is registered here rather than left to the caller for the
  /// same class of reason: a caller that forgets `addTearDown(panel.shutdown)`
  /// leaks a live isolate holding a socket the gateway is still writing to.
  static Future<PanelIsolate> spawn({
    required Uri uri,
    String? holdKey,
    Set<String> keys = const <String>{},
    Duration tick = defaultPanelTick,
    Duration holdPulse = defaultHoldPulse,
  }) async {
    final fromPanel = ReceivePort();
    // Registered before anything can throw: a spawn that fails partway leaves
    // no `panel` to hang the teardown off, and an open ReceivePort keeps the
    // test isolate alive after the suite is done.
    addTearDown(fromPanel.close);
    final up = Completer<Map<String, Object?>>();
    late final PanelIsolate panel;

    fromPanel.listen((Object? message) {
      final report = (message! as Map).cast<String, Object?>();
      switch (report['kind']) {
        case 'up':
          if (!up.isCompleted) up.complete(report);
        case 'report':
          panel.reports.add((
            tick: report['tick']! as int,
            ready: report['ready']! as bool,
            held: report['held']! as bool,
            pulses: report['pulses']! as int,
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
        up.completeError(
            StateError('the panel isolate died before it came up: $error'));
      }
    });

    final isolate = await Isolate.spawn(
      panelEntryPoint,
      <String, Object?>{
        'reports': fromPanel.sendPort,
        'uri': uri.toString(),
        'holdKey': holdKey,
        'keys': keys.toList(),
        'tickMs': tick.inMilliseconds,
        'pulseMs': holdPulse.inMilliseconds,
      },
      // Named so a hung run's `--observe` output says which isolate this is,
      // and errors-are-fatal off so a panel that throws reports through the
      // error port instead of taking the suite down with it.
      debugName: 'panel-isolate-hold',
      errorsAreFatal: false,
      onError: errors.sendPort,
    );
    addTearDown(errors.close);

    final Map<String, Object?> ready;
    try {
      ready = await up.future.timeout(
        _upBudget,
        onTimeout: () => throw TimeoutException(
            'the panel isolate never reported "up" within '
            '${_upBudget.inSeconds} s. It is either wedged in its own '
            'construction, could not reach the gateway, or died without '
            'reporting — and a case that waits on this for ever fails as a '
            'suite timeout naming nothing',
            _upBudget),
      );
    } on Object {
      // The wait failed; the isolate must not be left running behind it.
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }

    panel = PanelIsolate._(
        isolate, fromPanel, ready['commands']! as SendPort,
        ready['engaged']! as bool);
    addTearDown(panel.shutdown);
    return panel;
  }

  /// Asks the panel one question and waits, bounded, for its answer.
  ///
  /// **Fails naming the command rather than hanging** (`suspend_harness.dart:
  /// 235-268`). A paused isolate cannot answer — that is the whole of what a
  /// pause is — so a case may use this call's failure as evidence that the
  /// event loop genuinely stopped, which is a stronger statement than "no
  /// reports arrived".
  Future<Object?> ask(
    String command, {
    Duration budget = defaultAskBudget,
  }) {
    if (_killed) {
      throw StateError('this panel has been killed or shut down, so "$command" '
          'has nobody to answer it. A command issued after the teardown is a '
          'case holding the harness past its own lifetime');
    }
    final id = _nextId++;
    final answer = Completer<Object?>();
    _pending[id] = answer;
    _toPanel.send(<String, Object?>{'cmd': command, 'id': id});
    return answer.future.timeout(
      budget,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
            'the panel did not answer "$command" within '
            '${budget.inMilliseconds} ms. Either it is paused — a paused '
            'isolate runs nothing, including its command loop, which is what '
            'makes it the background-app analogue — or it is gone',
            budget);
      },
    );
  }

  /// Stops the panel's event loop. Idempotent.
  ///
  /// This is F26c's injection: a paused isolate stops beating and stops
  /// feeding its deadman, so the plant counter freezes and the gateway's
  /// reaper eventually takes the session.
  void pause() {
    if (_resumeCapability != null) return;
    _resumeCapability = _isolate.pause();
  }

  /// Starts it again. Idempotent.
  ///
  /// **Idempotent on purpose, and it is the teardown that needs it**
  /// (`suspend_harness.dart:278-288`). A case that fails between [pause] and
  /// [resume] would otherwise leave a paused isolate behind — one that cannot
  /// answer the shutdown command, holds a socket the gateway is still writing
  /// to, and is invisible in the report except as the next case being slow.
  void resume() {
    final capability = _resumeCapability;
    if (capability == null) return;
    _resumeCapability = null;
    _isolate.resume(capability);
  }

  /// Kills the isolate immediately, with no close and no chance to release the
  /// hold. Idempotent.
  ///
  /// This is F26b's injection: the app was killed. The panel sends nothing
  /// more — no ticks, no release, no goodbye — and the gateway learns of it
  /// only when the socket dies or the reaper sweeps the silence. A resume
  /// first, so a paused-then-killed panel's descriptors are actually released
  /// rather than frozen with the isolate.
  void kill() {
    if (_killed) return;
    _killed = true;
    resume();
    _isolate.kill(priority: Isolate.immediate);
    _failPending('the panel was killed before this command was answered');
  }

  /// How many reports arrived since [mark].
  int reportsSince(int mark) => reports.length - mark;

  /// Resumes if paused, asks the panel to release its hold and dispose its
  /// client, and kills the isolate. Idempotent, and safe to register with
  /// `addTearDown`.
  ///
  /// The graceful half is not politeness (`suspend_harness.dart:305-333`): the
  /// panel owns a real socket to a real gateway and a live hold on a machine,
  /// and a case that killed the isolate under it would leave the gateway
  /// holding the session — and the deadman — until its own reaper noticed,
  /// which is the thing the row measures, arriving in the *next* case's
  /// ledger. The kill is the fallback for a panel that cannot answer, and it
  /// runs either way.
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
    _failPending('the panel was shut down before this command was answered');
  }

  void _failPending(String why) {
    for (final pending in _pending.values) {
      pending.completeError(StateError(why));
    }
    _pending.clear();
  }
}

/// The panel's entry point: a real `RemoteStateMan`, a hold-to-run controller,
/// a periodic report, and a command loop.
///
/// Top-level because `Isolate.spawn` requires it. Everything it is handed is a
/// plain value; everything it sends back is a plain map.
Future<void> panelEntryPoint(Map<String, Object?> spec) async {
  final reports = spec['reports']! as SendPort;
  final commands = ReceivePort();
  final uri = Uri.parse(spec['uri']! as String);
  final holdKey = spec['holdKey'] as String?;
  final tick = Duration(milliseconds: spec['tickMs']! as int);
  final pulse = Duration(milliseconds: spec['pulseMs']! as int);

  final client = RemoteStateMan(
    uri: uri,
    // The shipped defaults; a hold row must be judged against the deadlines
    // the plant runs with, not ones this file lowered to make a number appear.
    config: ClientConfig(),
    keys: (spec['keys']! as List).cast<String>().toSet(),
  );

  // Wait for the link to be ready before engaging: a hold engaged on a link
  // that is not up is a refusal, and the row wants a live hold to kill.
  final readyBy = DateTime.now().add(const Duration(seconds: 12));
  while (!client.isReady) {
    if (DateTime.now().isAfter(readyBy)) {
      throw StateError('the panel isolate could not reach ready before '
          'engaging its hold — the gateway at $uri never opened the barrier');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  HoldToRunController? controller;
  var engaged = false;
  if (holdKey != null) {
    controller = HoldToRunController(
      api: client,
      key: holdKey,
      pulsePeriod: pulse,
    );
    final engagement = await controller.press();
    engaged = engagement is WriteApplied;
  }

  var ticks = 0;
  final ticker = Timer.periodic(tick, (_) {
    ticks++;
    reports.send(<String, Object?>{
      'kind': 'report',
      'tick': ticks,
      'ready': client.isReady,
      'held': controller?.isHeld ?? false,
      'pulses': controller?.debugPulsesSent ?? 0,
    });
  });

  commands.listen((Object? message) async {
    final command = (message! as Map).cast<String, Object?>();
    final id = command['id'];
    Object? answer;
    switch (command['cmd']) {
      case 'isReady':
        answer = client.isReady;
      case 'isHeld':
        answer = controller?.isHeld ?? false;
      case 'pulses':
        answer = controller?.debugPulsesSent ?? 0;
      case 'tickCount':
        answer = ticks;
      case 'shutdown':
        ticker.cancel();
        // Release the hold before disposing, so a graceful shutdown puts a 0
        // on the tag itself rather than leaving it to the reaper — which is
        // the difference the F26 arms are measuring against.
        // Captured into a final local before the first `await`. `controller`
        // is a mutable local the message handler closes over, so the promotion
        // from `!= null` is discarded across an await — sound, and rejected by
        // newer analyzers than the one Flutter bundles (CI's `setup-dart` runs
        // a newer stable, which is why this passed locally and failed there).
        final held = controller;
        if (held != null) {
          await held.release().then((_) {}, onError: (Object _) {});
          await held.dispose();
        }
        await client.dispose();
        answer = 'gone';
      default:
        answer = 'unknown command "${command['cmd']}": this harness answers '
            'isReady, isHeld, pulses, tickCount and shutdown, and nothing '
            'else — it is F26\'s and is not a general remote-control channel';
    }
    reports.send(<String, Object?>{'kind': 'reply', 'id': id, 'value': answer});
    if (command['cmd'] == 'shutdown') commands.close();
  });

  reports.send(<String, Object?>{
    'kind': 'up',
    'commands': commands.sendPort,
    'engaged': engaged,
  });
}
