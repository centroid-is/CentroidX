/// The panel side of the relay pipe: `RemoteStateMan`, the `StateManApi`
/// implementation that speaks WebSocket + JSON-RPC to the gateway.
///
/// Pure Dart, no Flutter. The Flutter adapter is a later milestone, and this
/// package must keep resolving without it — pulling analyzer into the app's
/// version solve is the analyzer-cap blocker that has stopped this repo twice
/// in twelve months.
///
/// This barrel is the embedder's whole surface: build a `ClientConfig`, point
/// a client at a gateway, read values from it. Deliberately *not* exported are
/// the internal seams — the connection supervisor, the WS transport adapter,
/// the resync engine, the freshness watchdog, the deadline wrapper, the
/// backoff schedule — because an embedder constructs a `RemoteStateMan` and
/// reads values from it, it does not reach into a connection. Tests inside
/// this package import those directly as
/// `package:tfc_relay_client/src/<file>.dart`, which is legal within the
/// owning package and keeps this file from becoming an edit chokepoint for
/// every plan in the phase.
///
/// Exactly two plans of Phase 4 edit this file: 04-01 (which creates it and
/// exports the config) and 04-08 (which adds the client itself). Phase 5 adds
/// one more, 05-07, and the third export it brings is here for the same reason
/// the second one is: an embedder genuinely **constructs** a
/// [HoldToRunController], the way it constructs a [RemoteStateMan]. A jog
/// button is a thing an application builds; it is not a seam inside a
/// connection.
///
/// What is here, and nothing else:
///
///  * [ClientConfig] — the deadlines, the backoff window, the staleness
///    horizon, and the hold-to-run cadence the controller is handed.
///  * [RemoteStateMan] — the `StateManApi` an embedder holds, plus
///    `defaultPageSubscription`, the name its constructor keys are filed under.
///  * [LinkState] — the four-state connection indicator an operator-facing
///    health line renders. The supervisor that owns the state machine is not
///    exported with it: a caller reads where the link is, it does not drive the
///    reconnect loop.
///  * [HoldToRunController] — one hold-to-run button, with its release
///    triggers injected so the Flutter binding above it stays a documented
///    pattern rather than a widget this pure-Dart package cannot import.
///
/// Deliberately absent, and each for the same reason — an embedder constructs a
/// client and reads values from it, it does not reach into a connection:
/// `connection_supervisor.dart` (beyond [LinkState]), `ws_transport.dart`,
/// `resync_engine.dart`, `freshness_watchdog.dart`, `deadline.dart`,
/// `backoff.dart`, `readiness_barrier.dart`, `subscription_state.dart`,
/// `failure_taxonomy.dart` (beyond [AlarmAckUnsupported]), `clock_offset.dart`
/// and `client_sub_apis.dart`. Tests inside this package import those directly
/// as `package:tfc_relay_client/src/<file>.dart`, which is legal within the
/// owning package.
library;

export 'src/client_config.dart';
export 'src/connection_supervisor.dart' show LinkState;
// The "no link" answer every call resolves to when the barrier times out —
// exported because a consumer that drives `sessionLogin` must be able to tell
// a dead link from a credential verdict (the app's gateway sign-in maps it to
// "unavailable", never "wrong password").
export 'src/deadline.dart' show LinkDown;
// One name off the taxonomy, and only because a consumer must be able to spell
// it: `RelayAlarmSource` (14-09) catches this to tell "this gateway predates
// alarm acknowledge" from "acknowledge was refused", and a type an embedder
// cannot name is a distinction it cannot act on. The rest of the file stays
// internal — a caller that wants `classifyFailure` is reaching into a
// connection.
export 'src/failure_taxonomy.dart' show AlarmAckUnsupported;
export 'src/hold_to_run_controller.dart';
export 'src/remote_state_man.dart';
