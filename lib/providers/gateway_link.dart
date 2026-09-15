/// What the gateway link is doing, as one provider two surfaces read.
///
/// [gatewayLinkProvider] publishes a [GatewayLinkReport] — the status row
/// inside the Transport card and the panel's local gateway alarm
/// (`local_gateway_alarm.dart`, which feeds the app bar's alarm banner and
/// the Alarm View) both derive from this and **neither computes its own
/// message.** In direct mode it publishes `null`, which those surfaces
/// render as absence rather than as a standing alarm.
///
/// ## Five properties, and none of them is decoration
///
/// **1. The config is consulted first, and direct mode short-circuits before
/// `stateManProvider` is ever read.** That is what makes the chip's absence
/// *structural* rather than incidental: a direct station cannot grow a link
/// report by accident, and `test/widgets/base_scaffold_appbar_golden_test.dart`
/// — which overrides only `alarmManProvider` — does not have to learn about a
/// transport to keep rendering an app bar.
///
/// **2. The unwrap is by name, through
/// [GuardedStateMan.innerAs].** A bare `value is GatewayStateMan` on
/// `stateManProvider`'s value is **false on every real panel** and true only in
/// a hand-built test (15-RESEARCH F-1): that provider always answers a
/// `GuardedStateMan`, whose inner object is private with no getter. A guard
/// that is green in a test and false on every panel is worse than no guard, so
/// do not "simplify" the two lines below back to a type test.
///
/// **3. Seed, then merge.** `RemoteStateMan`'s constructor starts dialling
/// (`remote_state_man.dart:213`) and `linkStates` is a broadcast stream
/// (`connection_supervisor.dart:225-226`), so a transition can complete before
/// this provider exists. The subscription is attached first and the synchronous
/// `linkState` getter is read immediately after — the only ordering with no
/// window in it.
///
/// **4. The clock is injected.** [gatewayLinkClockProvider] defaults to
/// `DateTime.now` and is overridden by a golden or a unit arm; nothing calls
/// `DateTime.now()` at a render site, and `describeGatewayLink` is pure. The
/// goldens for these frames compare on macOS CI.
///
/// **5. `null` means direct mode and nothing else.** A station whose client
/// could not be *built* — a `caCertPath` naming a file that is not there, a
/// credential file that is not there, a certificate that parses as nothing —
/// publishes a [GatewayLinkKind.notBuilt] report, not `null`. It used to
/// publish `null`, which is the same value direct mode uses, and the two
/// surfaces render `null` as absence: the panel showed grey values on every
/// page with nothing anywhere saying why, on the one case of criterion 2 that
/// the failure happens *before a client exists* rather than on the wire. That
/// conflation was the defect; keeping the two facts apart is the fix, and
/// `test/providers/gateway_link_test.dart`'s "a transport that could not be
/// built" group pins both directions of it.
///
/// The still-honest silence is narrower than it was: `stateManProvider` merely
/// *building* is not a failure and publishes nothing, because a panel that
/// flashed a red pill for the first second of every boot is a panel whose red
/// pill stops being read.
///
/// ## Why this file is allowed a timer
///
/// `lib/providers/audit_trail.dart` states the house rule this file is the
/// exception to, so this paragraph is the symmetrical half of it. The patience
/// window is a function of *time*: past it a first attempt that has produced no
/// reason at all stops reading "connecting…" and starts reading what the panel
/// actually knows, and **no event announces that expiry** — the supervisor is
/// still inside its own deadline and the socket is still silent. A clock is the
/// only thing that can notice.
///
/// So there is one timer here, and it is:
///
///  * **one-shot**, not `Timer.periodic` — it re-derives once and the
///    conclusion it re-derives to is never `connecting` again;
///  * **created in `onListen` and cancelled in `onCancel`**, so nothing runs
///    while nobody is watching. Project memory `timers-must-be-listener-gated`:
///    an always-on periodic timer in this repo's plumbing fails *unrelated*
///    widget tests with "A Timer is still pending", and an unobserved provider
///    has nobody to tell anyway;
///  * **armed only while the report is `connecting`.** Every other kind is a
///    conclusion, and re-deriving a conclusion on a timer is a periodic timer
///    with extra steps.
///
/// [gatewayLinkTimerProbeProvider] makes that observable, because a timer that
/// quietly stopped being gated looks exactly like one that never was.
library;

import 'dart:async';
// For `FileSystemException` and nothing else: the one type test that turns a
// throw out of client construction into "which file could not be opened". It is
// here, and not in `lib/core/gateway_link_status.dart`, because that file is
// pure by declaration and thirteen golden frames depend on it.
import 'dart:io' show FileSystemException;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show LinkState, RemoteStateMan;

import '../core/gateway_link_status.dart';
import '../core/gateway_state_man.dart';
import 'gateway.dart';
import 'state_man.dart';

/// Where [gatewayLinkProvider] reads the time.
///
/// Injected so a golden or a unit arm can freeze it. `DateTime.now` appears in
/// this file exactly once — here, as this provider's default — and nowhere at a
/// render site, which is what keeps eleven golden frames eleven constants
/// rather than eleven images that churn on every run.
final gatewayLinkClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// How long a first attempt may be in flight before the panel stops saying
/// "connecting" and says what it knows.
///
/// A provider rather than a bare constant read so an arm does not have to spend
/// fifteen seconds to observe the other side of the window. Production reads
/// the default and nothing overrides it.
final gatewayLinkPatienceProvider =
    Provider<Duration>((ref) => kGatewayFirstConnectPatience);

/// Whether the one patience timer is armed, and what it was armed for.
///
/// Held as mutable fields on a plain object behind a `Provider`, the shape
/// `GatewayAlarmSlot` in `state_man.dart` already establishes — a global would
/// be shared between containers in one test run, and provider state would be
/// thrown away by the very rebuild the observation is about.
///
/// It exists because "the timer is listener-gated" has no other observation
/// point: a leaked timer is invisible until it fails somebody else's widget
/// test in another file. Two field writes per emission is the whole cost.
final class GatewayLinkTimerProbe {
  /// Whether a patience timer is armed right now.
  bool armed = false;

  /// The kind of every report a timer was armed for, in order. Anything but
  /// [GatewayLinkKind.connecting] in here is the gating having broken.
  final List<GatewayLinkKind> armedFor = <GatewayLinkKind>[];
}

/// The one [GatewayLinkTimerProbe] for this container.
final gatewayLinkTimerProbeProvider =
    Provider<GatewayLinkTimerProbe>((ref) => GatewayLinkTimerProbe());

/// What to put on a panel about the gateway link — or null, in direct mode.
final gatewayLinkProvider = StreamProvider<GatewayLinkReport?>((ref) {
  final clock = ref.watch(gatewayLinkClockProvider);
  final patience = ref.watch(gatewayLinkPatienceProvider);
  final probe = ref.watch(gatewayLinkTimerProbeProvider);

  // 1. Config first. Null while the device-local row is still being read; this
  //    provider rebuilds when it lands.
  final config = ref.watch(gatewayConfigProvider).valueOrNull;

  // 2. The unwrap, by name and read-only, and ONLY in gateway mode — reading
  //    `stateManProvider` on a direct station would build every OPC UA session
  //    on the panel just to be told there is no link to report on. See property
  //    2 in the library doc for why this is not `value is GatewayStateMan`.
  RemoteStateMan? client;
  GatewayLinkBuildFailure? failure;
  if (config != null && config.isGateway) {
    final built = ref.watch(stateManProvider);
    final guarded = built.valueOrNull;
    client = guarded is GuardedStateMan
        ? guarded.innerAs<GatewayStateMan>()?.remote
        : null;
    if (client == null && built.hasError) {
      // Property 5, and the reason this branch reads the whole `AsyncValue`
      // rather than `.valueOrNull`. See the library doc.
      //
      // The `dart:io` type test lives here rather than in
      // `gateway_link_status.dart` because that file is pure and thirteen
      // golden frames depend on it staying so. `PathNotFoundException` extends
      // `FileSystemException`, which is what a missing CA root and a missing
      // credential file both arrive as; `path` on it is the string the operator
      // typed into Server Config, never the file's contents.
      final error = built.error!;
      failure = GatewayLinkBuildFailure(
        raw: error.toString(),
        path: error is FileSystemException ? error.path : null,
      );
    }
  }
  final remote = client;
  final buildFailure = failure;

  StreamSubscription<LinkState>? states;
  Timer? patienceTimer;
  DateTime? firstObserved;
  late final StreamController<GatewayLinkReport?> controller;

  void disarm() {
    patienceTimer?.cancel();
    patienceTimer = null;
    probe.armed = false;
  }

  void emit() {
    if (remote == null || controller.isClosed) return;

    // The patience window is anchored at first *observation*, because the
    // client has neither an `everReady` flag nor a first-attempt timestamp
    // (15-RESEARCH F-6). That would restart the fifteen seconds every time a
    // widget rebuilt — which is why `describeGatewayLink` lets a reason that
    // already exists win over the clock, and why this provider's only job here
    // is to supply an honest elapsed.
    final now = clock();
    firstObserved ??= now;
    final report = describeGatewayLink(
      state: remote.linkState,
      lastDownReason: remote.lastDownReason,
      stopReason: remote.stopReason,
      url: remote.uri,
      elapsed: now.difference(firstObserved!),
      patience: patience,
    );
    controller.add(report);

    // Disarm unconditionally, then re-arm only for the one kind that expires.
    disarm();
    if (report.kind != GatewayLinkKind.connecting) return;
    final remaining = patience - now.difference(firstObserved!);
    probe
      ..armed = true
      ..armedFor.add(report.kind);
    patienceTimer =
        Timer(remaining.isNegative ? Duration.zero : remaining, emit);
  }

  controller = StreamController<GatewayLinkReport?>(
    onListen: () {
      // Still reading the device-local row: say nothing yet rather than
      // publish a "no report" this provider is about to contradict.
      if (config == null) return;
      if (!config.isGateway) {
        controller.add(null);
        return;
      }
      if (remote == null) {
        // **The two nulls that used to be one.** A station whose client could
        // not be built published exactly what a direct station publishes, so
        // the chip rendered `SizedBox.shrink()` and the Transport card rendered
        // no row — the panel knew what was wrong and said nothing. A build
        // failure is a conclusion reached before there is anything to listen
        // to, so it is emitted here and no timer is armed for it: nothing on a
        // wire can change it, and the provider rebuilds if the config or
        // `stateManProvider` does.
        //
        // `buildFailure == null` is still the honest silence: gateway mode with
        // `stateManProvider` merely *building*. The consumers render that
        // unresolved state as absence on purpose — no status row, and no
        // local gateway alarm (`local_gateway_alarm.dart` maps it to null).
        if (buildFailure == null) {
          controller.add(null);
          return;
        }
        controller.add(describeGatewayLinkFailure(
          // `GatewayConfig.uri` throws on a URL that will not parse, and this
          // provider is the one caller that can be looking at exactly that —
          // `stateManProvider` refuses an undiallable row by name, which is one
          // of the failures being reported here. An empty Uri renders as the
          // empty string, and neither sentence for this kind interpolates it.
          url: Uri.tryParse(config.url.trim()) ?? Uri(),
          failure: buildFailure,
        ));
        return;
      }
      // Listen first, then seed. See property 3 in the library doc.
      states = remote.linkStates
          .listen((_) => emit(), onError: (Object _) => emit());
      emit();
    },
    onCancel: () {
      disarm();
      final subscription = states;
      states = null;
      return subscription?.cancel();
    },
  );

  ref.onDispose(() {
    disarm();
    unawaited(states?.cancel());
    states = null;
    unawaited(controller.close());
  });

  return controller.stream;
});

/// Whether a sign-in could reach an authority from this panel right now.
///
/// True in direct mode and on a healthy gateway; false on a gateway panel
/// whose link cannot carry a credential — a wrong URL, an unreachable
/// address, a refused certificate, a refused token, a client that never got
/// built. `resolveAccessGate` reads it, and `lib/access_routes.dart` sets out
/// what it is for: the Server Config exemption is keyed on "nobody can sign in
/// here", and on a gateway panel this is the half of that question the
/// authority alone cannot answer.
///
/// **A `Provider` over [gatewayLinkProvider] rather than a second computation
/// of the same fact.** The route gate and the menu badge both ask here, so the
/// lock on the menu entry and the gate on the page cannot disagree about a
/// dead link — which is the same rule `routeAllowedWhenNobodyCanSignIn`
/// enforces for the path half of the question.
///
/// **Cheap in direct mode.** [gatewayLinkProvider] reads the device-local
/// transport row and emits null without ever watching `stateManProvider`
/// unless the station is in gateway mode, so a direct panel does not build an
/// OPC UA session to answer this.
final relayCanAuthenticateProvider = Provider<bool>((ref) {
  return gatewayLinkCanAuthenticate(ref.watch(gatewayLinkProvider).valueOrNull);
});
