/// The relay gateway: the WebSocket + JSON-RPC session layer that serves
/// `StateManApi` to every panel.
///
/// Pure Dart, server-side, no Flutter — and the Flutter app must not depend on
/// this package at all. The app depends on `tfc_relay_protocol`; this package
/// depends on `package:test` transitively through its own dev kit, and pulling
/// analyzer into the app's version solve is the analyzer-cap blocker that has
/// stopped this repo twice in twelve months.
///
/// This barrel is the embedder's whole surface: configure a server, supply a
/// token validator, start it. Deliberately *not* exported are the internal
/// seams — `relay_session`, `tick_engine`, `frame_encoder`, `handle_table`,
/// `subscription_registry` — because an embedder configures and starts a
/// server, it does not reach into a session. Tests inside this package import
/// those directly as `package:tfc_relay_server/src/<file>.dart`, which is legal
/// within the owning package and keeps this file from becoming an edit
/// chokepoint for every plan in the phase.
library;

// On the barrel for `key_policy.dart`'s reason exactly: an embedder supplies
// an alarm engine at construction, so `RelayServer(alarmAcks:)`'s type has to
// be nameable by the code that builds the server. The handler bodies behind
// `ackAlarm` are deliberately *not* here — they are an internal seam, like
// `relay_session.dart`, and an embedder supplies an engine rather than
// dispatching a method by hand.
export 'src/alarm_ack_sink.dart';
// On the barrel because an embedder configures the path (`ServerConfig.auth`'s
// type has to be nameable), reads the role off a session's identity, and — if
// it prefers to build the validator itself rather than name a file — passes a
// `FileTokenValidator` to `validator:`.
export 'src/auth/auth_config.dart';
export 'src/auth/file_token_validator.dart';
export 'src/auth/identity.dart';
export 'src/auth/session_login_validator.dart';
// On the barrel because `RelayServer.certHealth` is public and an embedder
// that wants the number recomputed on its own cadence has to be able to name
// the type — and because `certDaysToExpiryKey` is the string Phase 8's HLTH-03
// reserved list and any AlarmMan configuration both have to spell exactly.
// Unlike `PolicyStateMan` this is not a seam an embedder wraps a source with;
// the gateway builds it, and the embedder reads it.
export 'src/health/cert_health_state_man.dart';
// On the barrel for the same reason `token_validator.dart` is: an embedder
// supplies a policy at construction, so `RelayServer(policy:)`'s type has to
// be nameable by the code that builds the server. The decorator that consults
// it is *not* exported — that is an internal seam, and an embedder configures
// a policy rather than wrapping a source by hand.
export 'src/policy/key_policy.dart';
export 'src/relay_server.dart';
export 'src/server_config.dart';
export 'src/tls/mint.dart';
// On the barrel because an embedder configures it: `ServerConfig.tls`'s type
// has to be nameable by the code that builds a `ServerConfig`.
export 'src/tls/tls_config.dart';
export 'src/token_validator.dart';
