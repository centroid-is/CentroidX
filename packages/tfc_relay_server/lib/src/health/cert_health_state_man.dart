/// What is left of the Phase 6 certificate overlay after Phase 8 replaced it:
/// two names, and the argument for why the file did not simply go away.
///
/// ## The merge was a replacement, not a deletion
///
/// 06-09's handoff said "deleting this file is the whole of the merge", and
/// that was true of the *certificate* job — `PIPE.cert.days_to_expiry` is one
/// number for the process and the class that produced it did nothing else.
/// What Phase 8 discovered is that the **chain slot** the overlay held is
/// needed for something the shared source cannot do at all:
/// `PIPE.link_degraded`, `PIPE.effective_hz`, `PIPE.egress_kbps` and
/// `PIPE.pending_keys` are facts about *one socket*, and `LocalStateMan` is
/// one instance serving every panel in the plant.
///
/// So [SessionHealthStateMan] took the slot, kept the certificate measurement
/// verbatim — the served-versus-on-disk subtlety (06-09 WR-01), the
/// truncation, the never-zero rule — and grew the six keys only a session
/// knows. The class that used to live here is now that class in *server mode*:
/// one instance, built by `RelayServer.start`, owning the certificate and its
/// store, with every session's overlay forwarding the key to it so that one
/// `refresh()` pushes to every subscriber rather than to one store per panel.
///
/// ## Why the file stayed
///
/// [CertHealthStateMan] is what `RelayServer.certHealth` is typed as and what
/// `health_cert_test.dart` — 06-09's sixteen socket-level cases, which this
/// phase is required to leave standing — imports and names. An alias keeps
/// every one of those spellings meaning exactly what it meant, while there is
/// still only one class and only one certificate producer. A rename that
/// touched sixteen passing cases would have been a rewrite of the evidence
/// rather than of the code, and a rewritten fixture is how a suite quietly
/// stops testing what it used to.
///
/// The same argument applies to [certDaysToExpiryKey], which has been an alias
/// for `PipeKeys.certDaysToExpiry` since 08-02 for the reason that file
/// records: a key name is matched by AlarmMan configuration out in the plant,
/// so a second spelling does not fail a test — it compiles, it keeps every
/// suite green, and it quietly stops matching every deployment.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'session_health_state_man.dart';

export 'session_health_state_man.dart' show SessionHealthStateMan;

/// The Phase 6 name for the overlay that measures the gateway's own leaf.
///
/// A `typedef` and not a subclass: there is one class, and `isA` and `as`
/// against this name are the same test they always were. See this library's
/// doc for why the name survived the class.
typedef CertHealthStateMan = SessionHealthStateMan;

/// How many whole days are left on the gateway's leaf.
///
/// In the reserved `PIPE.` namespace because it is the pipe reporting on
/// itself. Named as a constant rather than spelled at each site so HLTH-03's
/// reserved list and this producer cannot drift apart by a typo.
///
/// Since 08-02 the *name* lives in the protocol package with the rest of the
/// `PIPE.` vocabulary, which by then had producers in three packages at once;
/// this stays as the alias every existing caller already imports. The
/// *producer* deliberately did not move with it (ruling 9 as amended, argued
/// in full in `session_health_state_man.dart`): it is judged by socket-level
/// cases here, and relocating it would have put an upstream package's native
/// build in front of this suite for the sake of one string.
const certDaysToExpiryKey = PipeKeys.certDaysToExpiry;
