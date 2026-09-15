/// The half of `PIPE.*` that cannot come from the shared source: the numbers
/// that are true of **one socket**, plus the one number that is true of the
/// process serving them all.
///
/// ## Why this is per session, and why that is the whole point
///
/// `LocalStateMan` is one instance serving every panel in the plant.
/// `PIPE.link_degraded`, `PIPE.effective_hz`, `PIPE.egress_kbps` and
/// `PIPE.pending_keys` are facts about one client's send buffer, one client's
/// tick rate and one client's sink — so served from the shared source they
/// would report whichever client last moved them. A quiet panel in the
/// packing hall would show the busiest panel's degradation, and the engineer
/// reading it would go and look at the wrong machine.
///
/// That is the same argument `policy_state_man.dart` makes about identity, and
/// it is why this overlay is built in `RelayServer._onConnect` rather than in
/// `start()`. The chain order is unchanged and load-bearing — **policy over
/// health over source** — so `canSee` still filters a key list that already
/// contains the health keys, and a policy that hides one hides it here too.
///
/// ## The certificate stays in this package (a deliberate deviation from
/// 08-CONTEXT ruling 9)
///
/// Ruling 9 files `cert.days_to_expiry` among the per-plant facts that belong
/// on `LocalStateMan`. It stays here, and the reason is structural rather
/// than convenient: the number is about the leaf **this process is serving**
/// — a property of the server's `SecurityContext`, read one line after
/// `useCertificateChain` from the very same `TlsConfig` — not a property of
/// the plant. Moving the producer upstream would either strand 06-09's
/// sixteen socket-level cases or force `tfc_relay_server` to hold
/// `tfc_relay_local` as a dev dependency, which puts an open62541 native
/// build in front of this package's suite and destroys the property that
/// justified a separate package in the first place. The *name* still comes
/// from [PipeKeys], so there is still exactly one spelling, and that was the
/// only thing that ever had to be shared.
///
/// ## Two modes, one class
///
///  * **Server mode** ([chainPath] set, [probe] null). One instance, built by
///    `RelayServer.start`, owning the certificate measurement and its store.
///    This is what `RelayServer.certHealth` hands back, and what
///    `cert_health_state_man.dart`'s `CertHealthStateMan` alias names.
///  * **Session mode** ([probe] set, [cert] pointing at the server-mode
///    instance). One per connection, in the chain slot, answering the six
///    per-session keys itself and forwarding the certificate key to the one
///    instance that measured it — so a `refresh()` on the server-mode overlay
///    pushes to every session subscribed to it, which is one store and not
///    one per panel.
///
/// A plaintext gateway has no server-mode instance at all, so a session's
/// [cert] is null and the certificate key is simply absent: a key reading
/// `errorConfig` forever on a gateway that was never given a certificate is a
/// permanent false alarm, which is how an operator learns to ignore the
/// indicator.
///
/// ## No timer, in either mode
///
/// `teardown_test.dart` walks every file under `lib/src`, treats a non-comment
/// `Timer.periodic(` outside `tick_engine.dart` as an offence, and pins the
/// package's repeating-timer count at exactly **one** (03-RESEARCH Finding 8:
/// "a timer that captures a session closure is exactly the ghost 03-11's
/// kill-cycle test hunts"). A per-session object holding one would be that
/// ghost with a health badge on it.
///
/// So the recompute is on a **deadline and on the read path**, never on a
/// clock of its own:
///
///  * the per-session gauges are field reads — a buffer's pending count, two
///    counters and a subtraction — so they are recomputed on every read
///    surface, and [ValueStore.applyBatch] means only a genuine change
///    notifies a subscriber;
///  * the certificate re-reads a file, so it keeps the cert overlay's hourly
///    [period] and its `refreshIfDue` shape. `relay_session.dart`'s `_ping`
///    calls [refreshIfDue] for the same reason it always did — four of the
///    registered methods never read `api.keys`, and `ping` is the one an
///    established panel sends all shift.
///
/// ## Quality, never a zero
///
/// A number that is not yet measurable reads [Quality.errorConfig] with a
/// **null** value, never 0. `effective_hz` before the first tick is *unknown*;
/// zero would mean "the pipe has stopped", which is a different and alarming
/// claim, and an indicator that cries wolf on every fresh connection is one
/// nobody reads. The certificate makes the identical statement about an
/// unreadable chain, and negative days stay a *reading* under good quality
/// because "three days past" is exactly what an engineer needs to know.
library;

import 'dart:async';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart' show X509Utils;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The per-session facts, read late.
///
/// An interface rather than a reference to `RelaySession`, deliberately: this
/// library knows nothing about sessions, sockets or servers, which is what
/// lets every case below drive it with arithmetic. The composition root
/// (`relay_server.dart`) is the only thing that knows how to answer these,
/// and it is also the only thing that can — the overlay is constructed before
/// the session it reports on exists, so every answer here is a late read.
abstract interface class SessionProbe {
  /// This session's send buffer is shedding — the pipe is up but not keeping
  /// up.
  bool get linkDegraded;

  /// Ticks actually delivered to this session, per second, or null before
  /// there have been two.
  double? get effectiveHz;

  /// Kilobits per second through this session's sink, or null before anything
  /// has gone out.
  double? get egressKbps;

  /// Entries pending in this session's conflating buffer — the same number the
  /// backpressure verdict is computed from, so an operator sees the figure
  /// that will evict them rather than a second one that nearly matches.
  int get pendingKeys;

  /// Hold-to-run ticks dropped for this session, both halves summed.
  int get droppedHoldTicks;

  /// Event-loop lag on the gateway's one isolate, or null before the engine
  /// has measured a gap. Process-wide, and per-session only in where it is
  /// *served*: the overlay is the thing that can answer for it.
  int? get eventLoopLagMs;
}

/// The shared source, plus the keys one session knows about itself.
///
/// Implements [StateManApi] and **adds no interface member**, which is how the
/// frozen interface count stays frozen. Written as explicit member-by-member
/// delegation rather than `noSuchMethod` forwarding, for the reason
/// `policy_state_man.dart:80-87` gives: a forwarder would silently absorb a
/// member added in a later phase, and here a new member is a compile error and
/// therefore a decision.
final class SessionHealthStateMan implements StateManApi {
  SessionHealthStateMan({
    required this.source,
    this.chainPath,
    this.cert,
    this.probe,
    int Function()? nowMs,
    this.period = const Duration(hours: 1),
  })  : _nowMs = nowMs ?? _wallClock,
        _servedNotAfter =
            chainPath == null ? null : _notAfterOf(chainPath) {
    if (chainPath != null && cert != null) {
      throw ArgumentError('an overlay that measures the certificate itself '
          'cannot also forward the key to another one: two producers for one '
          'key is two numbers that disagree, and the one a panel sees would '
          'be an implementation detail');
    }
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// The shared source every session on this gateway is served from.
  final StateManApi source;

  /// The mounted leaf, by path, on the **server-mode** instance; null on a
  /// session-mode one and on a plaintext gateway.
  ///
  /// A path and not bytes, deliberately: 06-03's SEC-01 sweep asserts that no
  /// key material is reachable from the configuration, and an overlay that
  /// cached the PEM would be a second copy of the chain living in a long-lived
  /// object for the life of the process.
  final String? chainPath;

  /// The server-mode overlay this one forwards `cert.days_to_expiry` to, or
  /// null on a plaintext gateway.
  final SessionHealthStateMan? cert;

  /// The session this overlay reports on, or null on the server-mode
  /// instance.
  final SessionProbe? probe;

  /// How stale the certificate number may get before the next reader pays for
  /// a recompute. One hour — 06-CONTEXT's "once an hour is plenty" for a value
  /// measured in days. Injectable so a case can drive the deadline without
  /// waiting one out.
  final Duration period;

  final int Function() _nowMs;

  /// One node, one batch entry point — the same store the real
  /// implementations use, so `listen` notifies through production code rather
  /// than through something written for a test.
  final _store = ValueStore();

  /// Closers for the streams [subscribe] has handed out that are still open.
  final _closeHandedOutStreams = <Future<void> Function()>{};

  /// The `notAfter` of the leaf the running gateway is actually presenting,
  /// read once when this overlay was built.
  ///
  /// **Why the number cannot be the file alone.** `SecurityContext
  /// .useCertificateChain` reads [chainPath] once, inside
  /// `RelayServer.start()`, and the running `HttpServer` presents that leaf
  /// until the process is replaced. [_measureCert] re-reads the file on every
  /// recompute. So the yearly re-issue — mount the new leaf, defer the restart
  /// because restarting takes the plant off its screens — would have this key
  /// jump from 29 days to 365 while every panel keeps validating the old leaf
  /// and counting down to its original `notAfter`. The alarm clears, the
  /// ticket is closed, and the plant stops on the original date with no
  /// warning at all.
  ///
  /// **The operational consequence, stated so nobody has to discover it:** a
  /// rotation needs a restart, and this key keeps counting the old leaf down
  /// until it gets one.
  final DateTime? _servedNotAfter;

  /// When the certificate was last computed, in epoch ms, or null before the
  /// first time.
  int? _computedAtMs;

  /// The last computed certificate reading, on the server-mode instance.
  DynamicValue? get value => _store.peek(PipeKeys.certDaysToExpiry);

  /// The six keys a session answers about itself.
  static const perSessionKeys = <String>[
    PipeKeys.linkDegraded,
    PipeKeys.effectiveHz,
    PipeKeys.egressKbps,
    PipeKeys.pendingKeys,
    PipeKeys.droppedHoldTicks,
    PipeKeys.eventLoopLagMs,
  ];

  /// Every key this instance answers out of its own store.
  Set<String> get ownKeys => {
        if (probe != null) ...perSessionKeys,
        if (chainPath != null) PipeKeys.certDaysToExpiry,
      };

  /// Every key this instance adds to the source's list — its own, plus the one
  /// it forwards.
  Set<String> get addedKeys => {
        ...ownKeys,
        if (cert != null) PipeKeys.certDaysToExpiry,
      };

  /// Recomputes the certificate now, whatever the deadline says.
  ///
  /// Called once by `RelayServer.start` so the value exists before the first
  /// subscribe, and available to a deployment that wants the number moved on a
  /// cadence of its own. Only a genuine change notifies — that is
  /// [ValueStore.applyBatch]'s contract — so an hourly recompute on a value
  /// that ticks once a day pushes once a day.
  void refresh() {
    if (chainPath == null) return;
    _computedAtMs = _nowMs();
    _store.applyBatch({PipeKeys.certDaysToExpiry: _measureCert()});
  }

  /// Recomputes whatever is due: the gauges always, the certificate on its
  /// deadline, and the forwarded certificate on the instance that owns it.
  ///
  /// On every read surface, and on the heartbeat — `relay_session.dart`'s
  /// `_ping` calls it, which is why this is public. See this library's doc for
  /// why a deadline and not a timer.
  void refreshIfDue() {
    _refreshGauges();
    cert?.refreshIfDue();
    if (chainPath == null) return;
    final last = _computedAtMs;
    if (last != null && _nowMs() - last < period.inMilliseconds) return;
    refresh();
  }

  /// The six per-session readings, measured now.
  ///
  /// Free enough to run on every read: a pending count, three counters and two
  /// divisions. Nothing here touches the file system or the network, which is
  /// exactly why it needs no deadline of its own — the argument the
  /// certificate needs one is that it re-reads a file.
  void _refreshGauges() {
    final live = probe;
    if (live == null) return;
    _store.applyBatch({
      PipeKeys.linkDegraded: DynamicValue.of(live.linkDegraded),
      PipeKeys.effectiveHz: _number(live.effectiveHz),
      PipeKeys.egressKbps: _number(live.egressKbps),
      PipeKeys.pendingKeys: DynamicValue.of(live.pendingKeys),
      PipeKeys.droppedHoldTicks: DynamicValue.of(live.droppedHoldTicks),
      PipeKeys.eventLoopLagMs: _number(live.eventLoopLagMs),
    });
  }

  /// A reading, or the honest absence of one. Never 0 — see this library's
  /// doc.
  static DynamicValue _number(num? measured) =>
      measured == null ? _unreadable : DynamicValue.of(measured);

  /// The days left on the *earlier* of the leaf being served and the leaf on
  /// disk.
  ///
  /// The file is still re-read on every recompute, because the missing and
  /// unparseable answers depend on it and because a mount that went away is a
  /// thing an operator needs told. Taking the earlier of the two is right in
  /// both directions: a rotation that has not been restarted into keeps
  /// counting the certificate the panels are validating, and a shorter leaf
  /// mounted for a restart that is coming is a deadline reported the moment it
  /// exists rather than the moment it bites.
  DynamicValue _measureCert() {
    final onDisk = _notAfterOf(chainPath!);
    // Deliberately every failure, and deliberately not rethrown: a missing
    // mount, a directory where a file should be, a PEM the parser rejects and
    // a permission error are all the same statement to an operator — this
    // gateway cannot tell you when its certificate runs out — and none of them
    // is a reason to fail the request that happened to be first through the
    // door after the deadline.
    if (onDisk == null) return _unreadable;
    final served = _servedNotAfter;
    final soonest =
        served == null || onDisk.isBefore(served) ? onDisk : served;
    final now = DateTime.fromMillisecondsSinceEpoch(_nowMs());
    return DynamicValue.of(soonest.difference(now).inDays);
  }

  /// The `notAfter` of the leaf in the PEM at [path], or null when there is no
  /// answer to give.
  ///
  /// `validity` is non-nullable while `tbsCertificate` is nullable — the
  /// upstream field names in `X509CertificateData` are a known trap. The null
  /// branch is spelled out rather than `!`-ed so a chain the parser accepts
  /// but cannot describe reads as unknown instead of crashing whichever
  /// request happened to trigger the recompute.
  static DateTime? _notAfterOf(String path) {
    try {
      final pem = File(path).readAsStringSync();
      return X509Utils.x509CertificateFromPem(pem).tbsCertificate?.validity
          .notAfter;
    } catch (_) {
      return null;
    }
  }

  /// The answer that is not a number. Never `0` — see this library's doc.
  static final _unreadable =
      DynamicValue.of(null, quality: Quality.errorConfig);

  /// Whether [key] is the certificate key this instance forwards elsewhere.
  bool _forwarded(String key) =>
      cert != null && key == PipeKeys.certDaysToExpiry;

  // ---------------------------------------------------------------------------
  // StateManApi — explicit delegation, member by member.
  // ---------------------------------------------------------------------------

  /// The plant's keys, plus this session's own.
  ///
  /// A union, not a replacement: a gateway that served its own health keys
  /// *instead of* the plant would be a blank screen with a healthy badge on
  /// it. This is also the broadest recompute trigger in the class —
  /// `value_handlers.dart` consults it on `read`, `readFresh`, `readMany` and
  /// `write`, and `session_handlers.dart` on `subscribe`.
  @override
  List<String> get keys {
    refreshIfDue();
    return <String>{...source.keys, ...addedKeys}.toList();
  }

  @override
  ValueListenable<DynamicValue> listen(String key) {
    if (_forwarded(key)) return cert!.listen(key);
    if (!ownKeys.contains(key)) return source.listen(key);
    refreshIfDue();
    return _store.node(key);
  }

  /// A broadcast view of the same node, never a second source of truth.
  @override
  Stream<DynamicValue> subscribe(String key) {
    if (_forwarded(key)) return cert!.subscribe(key);
    if (!ownKeys.contains(key)) return source.subscribe(key);
    refreshIfDue();
    final node = _store.node(key);
    late final StreamController<DynamicValue> controller;
    void push() => controller.add(node.value);
    late final Future<void> Function() close;
    close = () async {
      _closeHandedOutStreams.remove(close);
      await controller.close();
    };
    controller = StreamController<DynamicValue>.broadcast(
      onListen: () {
        node.addListener(push);
        _closeHandedOutStreams.add(close);
      },
      onCancel: () {
        node.removeListener(push);
        _closeHandedOutStreams.remove(close);
      },
    );
    _closeHandedOutStreams.add(close);
    return controller.stream;
  }

  @override
  DynamicValue? read(String key) {
    if (_forwarded(key)) return cert!.read(key);
    if (!ownKeys.contains(key)) return source.read(key);
    refreshIfDue();
    return _store.peek(key);
  }

  /// A forced round trip is a forced recompute.
  ///
  /// `readFresh` is the method a diagnostics page calls precisely *because* it
  /// doubts the cache, so honouring the deadline here would answer the doubt
  /// with the cached number.
  @override
  Future<DynamicValue> readFresh(String key) async {
    if (_forwarded(key)) return cert!.readFresh(key);
    if (!ownKeys.contains(key)) return source.readFresh(key);
    _refreshGauges();
    if (key == PipeKeys.certDaysToExpiry) refresh();
    return _store.peek(key) ?? _unreadable;
  }

  /// One round trip for the plant's keys, plus this overlay's answered from
  /// here.
  ///
  /// The delegate is skipped entirely when nothing but health keys were asked
  /// for: `readMany` counts round trips as an observable, and a round trip
  /// nobody needed would be a number a test is entitled to be surprised by.
  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    final mine = [for (final key in keys) if (ownKeys.contains(key)) key];
    final forwarded =
        [for (final key in keys) if (_forwarded(key)) key];
    if (mine.isEmpty && forwarded.isEmpty) return source.readMany(keys);
    refreshIfDue();
    final rest = [
      for (final key in keys)
        if (!ownKeys.contains(key) && !_forwarded(key)) key,
    ];
    final answers = rest.isEmpty
        ? <String, DynamicValue>{}
        : {...await source.readMany(rest)};
    for (final key in mine) {
      answers[key] = _store.peek(key) ?? _unreadable;
    }
    if (forwarded.isNotEmpty) {
      answers.addAll(await cert!.readMany(forwarded));
    }
    return answers;
  }

  /// Refused: these are readings of the world, not setpoints.
  ///
  /// The refusal **reuses the read-only shape** a device gives rather than
  /// inventing one — `not_writable` / `Bad_NotWritable` — so nothing on the
  /// panel side needs a special case for a health key, and an operator gets
  /// the sentence they already know. A write that *moved* one of these values
  /// would let somebody silence an alarm by typing a number into it.
  @override
  Future<WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) async {
    if (_forwarded(key)) {
      return cert!.write(key, value, expect: expect, cmd: cmd);
    }
    if (!ownKeys.contains(key)) {
      return source.write(key, value, expect: expect, cmd: cmd);
    }
    return _refuseWrite(cmd);
  }

  static WriteResult _refuseWrite(String? cmd) => WriteRejected(
      cmd ?? newUlid(),
      const WriteReason('not_writable',
          message: 'a pipeline health key is a reading, not a setpoint',
          status: 'Bad_NotWritable'));

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      source.writeStatus(cmds);

  /// Refused the same way [write] is, through the same shape.
  ///
  /// An inert handle rather than a throw: `hold_handle.dart` makes a handle
  /// whose engagement is a [WriteRejected] un-held and un-feedable, and
  /// `value_handlers.dart` already knows not to record one. So the hold path
  /// inherits the refusal with no arm of its own.
  @override
  Future<HoldHandle> holdToRun(String key) async {
    if (_forwarded(key)) return cert!.holdToRun(key);
    if (!ownKeys.contains(key)) return source.holdToRun(key);
    return HoldHandle(
      key: key,
      engagement: _refuseWrite(null),
      onTick: (_) {},
      onRelease: (_) async => _refuseWrite(null),
    );
  }

  @override
  BrowseApi get browse => source.browse;

  @override
  TimeseriesApi get timeseries => source.timeseries;

  @override
  HistoryViewApi get historyViews => source.historyViews;

  @override
  PreferencesApi get preferences => source.preferences;

  // ------------------------------------------------------- the access families
  //
  // Delegated, exactly like the four above, and that is a decision rather than
  // an omission.
  //
  // This overlay adds health keys and **no authority**. It has a source, so a
  // refusal minted here would be *faking* an absence rather than reporting one,
  // and it would hide which layer actually has nothing behind it. Delegating
  // cannot fail open either: the shipped composition is **policy over health
  // over source** (`relay_server.dart:755`), so the object every handler is
  // handed is a `PolicyStateMan`, and that one refuses all four. When 17-07
  // gives the policy decorator a real gate, these four need no edit —
  // which is the same reason the four data-service getters above are one line
  // each.

  @override
  AccessTemplateApi get accessTemplates => source.accessTemplates;

  @override
  AccessAdminApi get accessAdmin => source.accessAdmin;

  @override
  AuditApi get audit => source.audit;

  @override
  BackendConfigApi get backendConfig => source.backendConfig;

  /// Releases this overlay's own store, then delegates — but **only** from the
  /// server-mode instance.
  ///
  /// Nothing in `RelayServer.close()` calls it, and nothing should: the source
  /// is one instance shared by every session, so a per-session dispose would
  /// take the whole plant off the air when one panel goes home. That was a
  /// latent hazard while the overlay was per server and is a live one now that
  /// it is per session, so session mode does not delegate at all. What this
  /// overlay owns and does release is its store's listeners and any stream it
  /// handed out; it owns no timer, which is the point of the argument above.
  @override
  Future<void> dispose() async {
    for (final close in _closeHandedOutStreams.toList()) {
      await close();
    }
    _store.dispose();
    if (probe == null) await source.dispose();
  }
}
