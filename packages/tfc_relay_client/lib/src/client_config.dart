/// Every number the panel side runs on, in one place, with the combinations
/// that cannot work refused at construction.
///
/// Pure data: no I/O, no clock — nothing here reads `DateTime.now` or starts a
/// `Timer`. The supervisor and the watchdog own the clock and are handed one
/// of these. Same shape as the gateway's `ServerConfig`, for the same reason:
/// a number that lives at five call sites is a number that drifts.
///
/// Five of the things here were measured or ruled on rather than chosen:
///
/// * **The deadline floor is one round trip, rounded up.** 04-RESEARCH
///   Finding 8 measured this transport at a **50.0 ms mean round trip over 50
///   `ping` calls**, quantised to the gateway's 50–100 ms fan-out period — an
///   RPC cannot come back faster than the next fan-out, because that is when
///   the reply is flushed. So the cheapest possible call already costs most of
///   a tenth of a second, and a deadline set anywhere near it fires on a
///   perfectly healthy link. On the control plane that is a reconnect loop; on
///   the write path it is worse, because a fired write deadline does not throw
///   — it resolves `WriteUnknown`, by design, since the write may well have
///   landed. A plant where ordinary writes come back "unknown" is a plant
///   where the operator stops believing the screen, and believing the screen
///   is the whole product. 500 ms is ten measured round trips: comfortably
///   above the floor, comfortably inside human patience.
/// * **The floor is itself a parameter.** [deadlineFloor] is a named argument
///   so a test can lower it deliberately. `truncated_write_test`'s polarity
///   flip — the case that proves a truncated write resolves unknown instead of
///   hanging — is only meaningful if the write deadline can fire inside the
///   case's own budget, which is a few hundred milliseconds. A hard floor
///   would make the flip untestable, and an untestable safety property is a
///   hope. Lowering it is explicit at the call site and greppable, which is
///   the point: nobody lowers it in production by accident.
/// * **Freshness is configured, never derived.** The 04-CONTEXT ruling: the
///   freshness deadline is a configured duration defaulting to **3 s** (design
///   band 2–5 s), and it is never computed from the transport cadence.
///   Finding 5 is why. The fan-out runs at 50–100 ms, so "death = three
///   periods" evaluates to 150–300 ms — a fine number on loopback and an
///   unusable one on a plant WAN, where a single garbage collection pause or
///   one Wi-Fi retransmit would grey every value on the screen at once. This
///   class therefore exposes no field the cadence could arrive through, and
///   `client_config_test.dart` reads this file as text to keep it that way.
/// * **The pinned root is a file path** (orchestrator ruling OQ4). One path
///   per station, provisioned with the rest of that station's configuration.
///   The alternative — installing the root into the machine's own trust store
///   — would mean dialling with `withTrustedRoots: true`, and a store anybody
///   with an installer can add to is a store that can vouch for a fake
///   gateway (T-06-20).
/// * **A dial needs a ceiling of its own.** 06-RESEARCH §C.4 probed a connect
///   to an address that answers nothing and measured **75 s** before macOS
///   gave up. That is longer than the whole backoff schedule, so without
///   [connectTimeout] the reconnect loop an operator can see stops describing
///   what the panel is actually doing.
///
/// The backoff ceiling is a refusal rather than a default because STACK
/// rejected `web_socket_client` over an infinite backoff loop. A panel that
/// has backed off to ten minutes is indistinguishable, to the operator
/// standing in front of it, from a panel that is dead — so they power-cycle
/// it, and the recovery path that was supposed to be automatic never runs.
library;

import 'dial/trust_capability.dart';

/// The knobs a `RemoteStateMan` is constructed with.
///
/// Named arguments with defaults, in `ServerConfig`'s style — the caller sets
/// what it cares about and the rest are the researched numbers.
final class ClientConfig {
  /// Deadline for control-plane calls: `hello`, `unsubscribe`, `read`,
  /// `readMany`. `json_rpc_2` has no per-request timeout of its own
  /// (04-RESEARCH Finding 1) and a peer that stops answering without closing
  /// leaves the future pending forever, so this is the only thing standing
  /// between a malformed peer and a panel stuck on a spinner.
  ///
  /// **`subscribe` used to be on this list and no longer is** (16-01, finding
  /// S1b). See [snapshotDeadline] for what that cost.
  final Duration controlDeadline;

  /// Deadline for `subscribe` — the one call whose answer is a whole page.
  ///
  /// **Why it is not [controlDeadline].** A `hello` carries five fields. A
  /// `subscribe` answer carries a ~1500-key snapshot, measured at about 100 kB
  /// on this plant's largest page. Bounding both with the same one second is a
  /// statement that the two cost the same, and on any link slower than the
  /// bench they do not: at a tenth of a megabit — which is what the plant link
  /// degrades to under load, and what `slow_link_gate_test.dart` meters — that
  /// page needs eight seconds on the wire before the gateway has done anything
  /// wrong.
  ///
  /// **The two failures that came out of sharing the number**, both reproduced
  /// in `snapshot_deadline_test.dart` before this field existed:
  ///
  /// 1. *A self-sustaining lockout.* The hello succeeds, the snapshot is
  ///    abandoned at one second, `_resubscribeAll` rethrows, the supervisor
  ///    calls `_down` and redials — and asks for the same snapshot again, and
  ///    abandons it again, pushing another partial page into the congestion
  ///    that caused it. `backoff.reset()` lives only in `_enter(ready)`, and
  ///    correctly so, but `ready` is reachable only after a *completed* resync,
  ///    so the schedule never resets and the panel sits at the backoff ceiling
  ///    forever over a link that would serve it fine at steady state.
  /// 2. *A permanently dead page on a healthy socket.* The same expiry
  ///    mid-connection is not retried at all: `_recover` swallows it,
  ///    `_unestablish` sets `lastSeq = null`, and every rebuild path is guarded
  ///    on that being non-null. The gateway's late answer did establish the
  ///    subscription at its end and it goes on pushing, the heartbeat keeps the
  ///    socket up for days, and the page stays blank until somebody
  ///    power-cycles the panel.
  ///
  /// **Fifteen seconds, and it is not the link-death detector.** Nothing waits
  /// on this to notice a dead gateway: `FreshnessWatchdog` tears down a socket
  /// that has gone [freshnessDeadline] without a frame *of any kind*, and it
  /// covers the resyncing state as well as the ready one, so a gateway that
  /// has genuinely stopped speaking is gone in three seconds no matter what
  /// this says. What this bounds is the narrower failure `deadline.dart` was
  /// written for — a peer that keeps answering everything *else* while one
  /// request never settles — and that one has no other floor under it, so the
  /// number can afford to be generous. Fifteen seconds is the metered eight
  /// plus room for the gateway to assemble the page and for the already
  /// committed backlog ahead of it to drain.
  ///
  /// **Setting it below [controlDeadline] is the defect, deliberately
  /// configured.** It is not refused at construction, because the honest
  /// refusal would have to know which calls are snapshot-bearing and this class
  /// is pure data. It is said here instead, where whoever types the number is
  /// already reading.
  final Duration snapshotDeadline;

  /// Deadline for `write`. Longer than [controlDeadline] because a write
  /// travels further — through the gateway into the PLC and back — and because
  /// expiry here is not an error but a three-state outcome: the call resolves
  /// `WriteUnknown`, never throws, and is never auto-retried. `writeStatus` on
  /// reconnect is how the unknown is resolved.
  final Duration writeDeadline;

  /// How long a value may go without a refresh before it is shown as stale.
  ///
  /// A configured number, deliberately independent of the gateway's fan-out
  /// cadence — see the library doc. The watchdog is a single deadline reset by
  /// *any* inbound frame, not one timer per subscription, because `readyState`
  /// lies after an OS sleep (STACK) and because N timers on a 1500-key page is
  /// N timers to cancel correctly on every reconnect.
  final Duration freshnessDeadline;

  /// First reconnect window. Attempt *n* draws uniformly from
  /// `[0, min(backoffCap, backoffBase * 2^n)]` — full jitter, so the first
  /// retry after a one-second blip is usually well under this.
  final Duration backoffBase;

  /// Ceiling on the reconnect window, at most [maxBackoffCap].
  final Duration backoffCap;

  /// How far the gateway's clock may sit from this panel's before the client
  /// says so.
  ///
  /// Exceeding it **warns and keeps using the gateway's clock** for staleness
  /// (04-RESEARCH Finding 5b: `clockOffset = localNowMs - hello.serverTime`,
  /// captured at each hello; measured at 52 ms same-machine). It never greys
  /// the plant — a panel whose own clock drifted must still show values, and a
  /// disagreement about wall time is not a disagreement about the process.
  final Duration implausibleClockThreshold;

  /// How many gateway fan-out periods a subscription may go without being
  /// re-evaluated before it is reported stale.
  ///
  /// A *ratio*, not a duration, and that is the point (04-REVIEW WR-08). The
  /// per-subscription verdict answers "has the plant stopped evaluating this
  /// page", which is a question about the gateway's cadence — advertised at
  /// `hello` as `capabilities.tickMs` — and not about the socket. Reusing
  /// [freshnessDeadline] for it marked every slowly-evaluated page permanently
  /// stale, which is the grey that cries wolf.
  ///
  /// 30 against the measured 50 ms fan-out is 1.5 s, and against a 1 s
  /// production tick is 30 s: the limit follows the plant rather than the
  /// panel. `FreshnessWatchdog` floors it at [freshnessDeadline], so it can
  /// never fire before "the link is gone" and send somebody to look at a
  /// sensor when the problem is a switch.
  final double subscriptionStalenessMultiple;

  /// How often a live hold-to-run feeds the plant's deadman counter.
  ///
  /// The operator is holding a button and a machine is jogging. What keeps it
  /// jogging is not a message saying "still held" — it is a counter on the tag
  /// that keeps going up, which the PLC watches and gives up on after
  /// [holdDeadman]. The panel sends one increment every [holdPulsePeriod]; the
  /// safety property is the increments STOPPING, so a panel that crashes, is
  /// backgrounded or loses its link stops the machine by doing nothing at all.
  ///
  /// **Why this is not spelled `holdTickPeriod`.** `client_config_test.dart`'s
  /// last case (`:202-222`, "the freshness deadline cannot learn a transport
  /// period") reads *this file* as text, strips the `///` lines, lowercases
  /// the remainder and asserts it does not contain the substring `tick`. That
  /// sweep is not fussiness. The gateway advertises its fan-out cadence at
  /// `hello` as `capabilities.tickMs`, measured at 50-100 ms; the moment this
  /// class can name that cadence, somebody derives the freshness deadline from
  /// it as "three periods", ships a 150 ms staleness horizon, and one garbage
  /// collection pause greys every value in the plant at once. The sweep exists
  /// so that the derivation cannot be written here at all, and the price of
  /// keeping it is this paragraph plus a field name without the substring.
  /// The alternatives were considered and rejected: putting the cadence on
  /// `HoldToRunController` or in a separate `HoldToRunConfig` would make the
  /// hold the one client timing number with no named injectable home in this
  /// class (04-01's must-have truths), which is a worse rule to break than a
  /// naming preference (D-P5-K).
  ///
  /// **Validated with `_positive`, never `_atLeastFloor`.** 100 ms is a fifth
  /// of the default [deadlineFloor], and routing a cadence through the
  /// deadline validator would make `ClientConfig()` with no arguments throw at
  /// construction. It is not a deadline: nothing waits on one pulse, and a
  /// dropped pulse costs nothing the next one does not fix.
  final Duration holdPulsePeriod;

  /// How many missed pulses the PLC tolerates before it drops the output.
  ///
  /// A *ratio*, for the same reason [subscriptionStalenessMultiple] is one:
  /// the quantity follows the cadence rather than being an independent
  /// millisecond count that somebody has to remember to change twice.
  /// [holdDeadman] is the product, and 100 ms x 10 is the one second the plant
  /// was configured for (05-CONTEXT decision 3 — the user chose tolerance for
  /// a Wi-Fi hiccup mid-jog over a near-instant stop, and accepted up to a
  /// second of coasting after a release on a dead link).
  ///
  /// **At least 3.** Below that, two dropped frames stop the machine — which
  /// is the tolerance decision inverted while wearing the clothes of a safety
  /// tightening. An operator whose jog cuts out every time the panel's Wi-Fi
  /// retransmits holds the button harder and then calls somebody.
  ///
  /// **Nothing in Dart enforces the PLC's timer.** This number is the client's
  /// *statement* of what the plant's `FB_HoldToRun` is configured for; the TON
  /// preset on the other side is a number in a PLC program that no Dart code
  /// can read or set. The two are kept in step by the design document
  /// (`relay-comm-design.md` §4.6a) and by nothing else, which is why the
  /// derived [holdDeadman] exists at all: so there is exactly one place to
  /// compare against when somebody changes one of them.
  final int holdMissedPulsesBeforeStop;

  /// How long the machine keeps moving after the pulses stop.
  ///
  /// **Derived, never stored.** Two independently settable numbers that must
  /// agree is precisely how they stop agreeing — and here the disagreement is
  /// invisible until an operator lets go of a button and something keeps
  /// moving for longer than anybody expected.
  Duration get holdDeadman => holdPulsePeriod * holdMissedPulsesBeforeStop;

  /// The fastest this panel will ever beat its heartbeat at the gateway.
  ///
  /// **What the heartbeat is for.** Nothing the gateway *sends* keeps a
  /// session alive; only inbound application frames move its `_lastSeen`, and
  /// its reaper closes any session that has been silent longer than the
  /// deadline it advertises at `hello`. A panel that is merely watching a page
  /// — which is what every panel in the plant does all shift — sends nothing
  /// at all after its handshake, so without a periodic frame of its own it is
  /// closed with `4003`, redials, and resyncs its whole page, once a deadline,
  /// for ever. That was measured on this build before `HeartbeatPump` existed:
  /// three reaps and three redials in twenty-one idle seconds (07-08-SUMMARY
  /// deviation 3). CLAUDE.md's Flutter-web constraint rules out the other
  /// answer — "no browser ping frames — **server pings + app heartbeat**".
  ///
  /// **This is a floor, not the period.** The period is a third of the
  /// deadline the gateway advertised, which is how the panel follows a gateway
  /// that was reconfigured rather than carrying a constant nobody diffs. This
  /// number is what stops that arithmetic from producing something absurd
  /// against a gateway that advertises a very short deadline, or nothing at
  /// all: one second is already thirty frames a minute per panel, and a
  /// hundred panels beating faster than that is a self-inflicted load with no
  /// operator-visible benefit. See `HeartbeatPump.period`.
  ///
  /// **Validated with `_positive`, never `_atLeastFloor`.** The same
  /// load-bearing choice [holdPulsePeriod] and [connectTimeout] make, and for
  /// the same reason: this is a *cadence*, not a deadline on an answer.
  /// Nothing waits on one beat and a dropped one costs nothing the next does
  /// not fix, so routing it through the deadline validator would only forbid
  /// the legitimate caller — a gate case that has to observe several beats
  /// inside its own budget and therefore sets this below
  /// [defaultDeadlineFloor]. 05-07 learned this on the hold cadence; the
  /// lesson is written down here rather than rediscovered.
  final Duration heartbeatFloor;

  /// The smallest deadline any of the three above may be set to.
  ///
  /// A parameter rather than a constant on purpose; see the library doc.
  final Duration deadlineFloor;

  /// The credential this station presents on the first frame, or null when the
  /// gateway it dials runs no token file.
  ///
  /// **What it is.** A per-station secret the integrator mounts alongside the
  /// panel's other configuration — one opaque string that tells the gateway
  /// *which panel* is speaking and, through the gateway's own map, whether
  /// that panel may write or only watch.
  ///
  /// **What it is not: a person's identity.** Nobody logs in to a panel. The
  /// screen by the filleting line is used by whoever is standing at it, all
  /// shift, with wet gloves on — a credential that identified people would be
  /// a credential shared by everyone on the shift within a day, which is worse
  /// than no claim at all because it would look like an audit trail. This
  /// string answers "which station", and the plant's own supervision answers
  /// who was at it.
  ///
  /// **Null is the shipped default and stays supported.** Every fixture in
  /// this workspace dials a gateway running the permissive validator, and a
  /// panel with no token still sends a well-formed hello — the field is simply
  /// absent from the frame. So switching a gateway to a real token file is a
  /// deployment change, not a protocol change.
  ///
  /// **Not validated here.** A length or shape rule in this constructor would
  /// be a second opinion about a secret whose only real judge is the gateway,
  /// and a panel that refuses to construct because its mounted credential
  /// looks wrong is a dark screen at shift start instead of a refusal an
  /// operator can read. The gateway decides; this class carries.
  final String? token;

  /// The one certificate authority this panel trusts, or null when it dials
  /// plaintext `ws://`.
  ///
  /// **Null is the shipped default and stays supported.** Every fixture in
  /// this workspace and all ten of the gateway's bind sites are plaintext on
  /// loopback; making TLS the default here would rewrite them for no
  /// requirement, and a rewritten fixture is how a suite quietly stops testing
  /// what it used to.
  ///
  /// **Non-null means the system trust store is never consulted.**
  /// `RemoteStateMan` builds one `SecurityContext(withTrustedRoots: false)`
  /// from it, so a rogue root installed on the station — by an installer, by a
  /// corporate MDM, by somebody with a USB stick — cannot vouch for anything
  /// claiming to be the gateway (T-06-20). That is the whole of SEC-02 on this
  /// side, and it is why the alternative ruled out in 06-CONTEXT (install the
  /// root into the OS store and trust that store) is not available here.
  final ClientTlsConfig? tls;

  /// Whether this panel may send its [token] over an unencrypted dial.
  ///
  /// **False, and the default is the whole point.** `ConnectionSupervisor`
  /// puts [token] on the hello frame unconditionally, so a per-station
  /// credential that grants `operate` on the plant's PLCs would cross the LAN
  /// in the clear once per reconnect, for as long as the panel runs — and
  /// anybody with a span port or a mirrored switch port would have a working
  /// credential. That is not a hypothetical rollout: design §7.1 presents the
  /// gateway's `tls` and `auth` as independently nullable "because they rotate
  /// on different clocks", which is an explicit invitation to turn the token
  /// file on before TLS.
  ///
  /// **What it is for.** The fixtures. Every fault leg that drives the
  /// credential path — `auth_refusal_test.dart` today, Phase 7's proxy legs
  /// next — runs over plaintext loopback, and a rule with no way out would
  /// either take that coverage away or be reverted by whoever needed it back.
  /// An explicit, greppable opt-in is the difference between a fixture and a
  /// deployment: `grep -rn allowTokenOverPlaintext` over a plant's
  /// configuration answers the question in one line.
  ///
  /// It does not excuse a pinned root on a plaintext dial. That is a different
  /// mistake — see [checkDialable].
  final bool allowTokenOverPlaintext;

  /// How long one dial may spend before it is abandoned and the schedule
  /// takes over.
  ///
  /// **Measured, and the number it guards against is 75 seconds**
  /// (06-RESEARCH §C.4, probed on macOS against an unbound address): a TCP
  /// connect to an address that answers nothing does not fail, it waits for
  /// the operating system to give up. Unbounded, one attempt outlives the
  /// entire backoff schedule an operator can see — a panel pointed at a
  /// firewall that drops SYNs sits in `connecting` for over a minute per
  /// attempt while the health line says the same thing it says for a link
  /// that is one second old.
  ///
  /// **Validated with `_positive`, never `_atLeastFloor`.** It is not a
  /// deadline on an answer, it is a ceiling on a socket coming up, and a case
  /// that wants a blackholed dial to give up inside its own budget has to be
  /// able to set it well below the floor.
  ///
  /// **What it does not do**, recorded because it looks like it should:
  /// `IOWebSocketChannel.connect` applies this as a `Future.timeout`
  /// (`io.dart:50-53`), which abandons the connect rather than cancelling it.
  /// The socket underneath may still come up and is then dropped with nobody
  /// holding it. That is a leak per timed-out attempt, which is why the
  /// default is a generous hang guard rather than a tight bound: this exists
  /// so the reconnect loop keeps running, not to make dialling fast.
  final Duration connectTimeout;

  /// Refuses the combinations of [uri] and this config that cannot work.
  ///
  /// Called by `RemoteStateMan`'s constructor — the first place a panel's
  /// address and its trust decision are both in scope. It lives here rather
  /// than there because this is the file that holds the other refusals, and a
  /// rule about configuration that lived in the class it configures would be
  /// the second place to look.
  ///
  /// **Three combinations, and the two added later are the mirror of the
  /// first.** The original rule refused `wss` with no root — an encrypted dial
  /// the panel cannot verify. Both of its reflections were accepted in
  /// silence: a pinned root on a `ws` dial (a configuration that *reads* as
  /// encrypted while the traffic is not, because `RemoteStateMan` builds the
  /// context and hands it to a dial that never consults it), and a station
  /// credential on a `ws` dial (which puts a key to the plant's machines on
  /// the LAN in the clear, once per reconnect, forever). Only the credential
  /// case has an opt-in, because only that one has a legitimate caller — see
  /// [allowTokenOverPlaintext].
  ///
  /// **Why `wss` without a pinned root is refused rather than attempted.**
  /// Measured (06-RESEARCH §A.3, row 6): a client on the system trust store
  /// dialling a gateway whose leaf came from the plant's private CA fails
  /// every handshake with `CERTIFICATE_VERIFY_FAILED` — byte-identical to what
  /// a genuine impostor produces, and to an expired leaf, and to a wrong
  /// hostname (trap 16). The panel would look attacked when it is
  /// misconfigured, once per attempt, forever, and the engineer sent to look
  /// at it starts with the wrong question.
  void checkDialable(Uri uri) {
    // The browser's rules are different in both directions, and stricter
    // overall. It cannot pin — there is no API to add a trust root, to pin
    // one, or to read the peer certificate — so `wss` with no root is the
    // *only* thing it can do, and a configured root is a claim it cannot
    // honour. And it must never dial plaintext: whether the browser stops a
    // `ws://` dial depends on how the page was served, not on anything
    // configured here, so a page opened over `http://` would put the station
    // credential and every plant write on the wire in the clear.
    if (!kCanPinTrustRoot) {
      if (uri.scheme != 'wss') {
        throw ArgumentError('a browser client dials wss:// only, and this is '
            '$uri. Plaintext would put the station credential and every write '
            'on the wire in the clear, and whether the browser refuses it '
            'depends on how the page was served rather than on this config. '
            'Serve the page over https and dial wss.');
      }
      if (tls != null) {
        throw ArgumentError('a root certificate was configured for a browser '
            'client dialling $uri, and a browser cannot use one: there is no '
            'API to add a trust root, to pin, or to read the peer '
            'certificate. The gateway has to be trusted by the machine\'s own '
            'store — a publicly-trusted certificate, or the plant root '
            'provisioned into it. Clear this field so the configuration stops '
            'claiming a pin that does not exist.');
      }
      return;
    }
    if (uri.scheme == 'wss' && tls == null) {
      throw ArgumentError('this panel is configured to dial $uri but no '
          'rootCertPath was given: an encrypted dial with no pinned root '
          'falls back on the machine\'s own trust store, which does not carry '
          'the plant\'s private CA. Every handshake would then fail with the '
          'same message a real impostor produces, so the panel would report '
          'an attack rather than a missing file. Mount the root the '
          'integrator provisioned and name it in ClientTlsConfig, or dial ws '
          'deliberately.');
    }
    if (uri.scheme != 'wss' && tls != null) {
      throw ArgumentError('this panel was given a pinned root but dials $uri: '
          'the root is never consulted on a plaintext dial, so the '
          'configuration reads as encrypted and the link is not. Every value '
          'and every write would cross the plant LAN in the clear while the '
          'config file says otherwise, which is the kind of thing found by a '
          'packet capture months later. Dial wss, or drop the root '
          'deliberately.');
    }
    if (uri.scheme != 'wss' && token != null && !allowTokenOverPlaintext) {
      throw ArgumentError('this panel would send its station credential over '
          '$uri in the clear. Anybody on the plant LAN who can see the frame '
          'then has a credential that writes to the machines, and the frame '
          'is re-sent on every reconnect for as long as the panel runs. Dial '
          'wss, or set allowTokenOverPlaintext explicitly if this is a '
          'fixture.');
    }
  }

  /// Ten measured round trips. The default [deadlineFloor].
  static const Duration defaultDeadlineFloor = Duration(milliseconds: 500);

  /// The hard ceiling on [backoffCap]: past half a minute the operator has
  /// already decided the panel is dead.
  static const Duration maxBackoffCap = Duration(seconds: 30);

  /// The floor under [holdMissedPulsesBeforeStop]. See that field for why.
  static const int _minMissedPulses = 3;

  ClientConfig({
    this.controlDeadline = const Duration(seconds: 1),
    this.snapshotDeadline = const Duration(seconds: 15),
    this.writeDeadline = const Duration(seconds: 2),
    this.freshnessDeadline = const Duration(seconds: 3),
    this.backoffBase = const Duration(milliseconds: 250),
    this.backoffCap = maxBackoffCap,
    this.implausibleClockThreshold = const Duration(minutes: 5),
    this.deadlineFloor = defaultDeadlineFloor,
    this.subscriptionStalenessMultiple = 30,
    this.holdPulsePeriod = const Duration(milliseconds: 100),
    this.holdMissedPulsesBeforeStop = 10,
    this.heartbeatFloor = const Duration(seconds: 1),
    this.token,
    this.tls,
    this.allowTokenOverPlaintext = false,
    this.connectTimeout = const Duration(seconds: 10),
  }) {
    if (!(subscriptionStalenessMultiple > 1)) {
      throw ArgumentError('subscriptionStalenessMultiple '
          '($subscriptionStalenessMultiple) must be greater than 1: at one '
          'period or less every subscription is stale again immediately after '
          'the refresh that cleared it, and a page that is always grey is a '
          'page nobody reads');
    }
    _positive('deadlineFloor', deadlineFloor);
    _atLeastFloor('controlDeadline', controlDeadline);
    // After controlDeadline, and the order is load-bearing:
    // `client_config_test.dart`'s "a raised floor refuses a default that was
    // fine before" reads the *name* out of the message a raised floor produces,
    // and it names controlDeadline. A check inserted above this line would
    // change which field a raised floor complains about first.
    _atLeastFloor('snapshotDeadline', snapshotDeadline);
    _atLeastFloor('writeDeadline', writeDeadline);
    _atLeastFloor('freshnessDeadline', freshnessDeadline);

    // `_positive`, and the choice is load-bearing: see [holdPulsePeriod]. The
    // deadline floor defaults to 500 ms and the cadence is 100 ms, so
    // `_atLeastFloor` here would throw on the default construction of this
    // class and no panel in the plant would start.
    _positive('holdPulsePeriod', holdPulsePeriod);
    if (holdMissedPulsesBeforeStop < _minMissedPulses) {
      throw ArgumentError('holdMissedPulsesBeforeStop '
          '($holdMissedPulsesBeforeStop) must be at least $_minMissedPulses: '
          'below that, two dropped frames stop the machine mid-jog, which '
          'inverts the tolerance the plant decided on — up to a second of '
          'coasting is accepted precisely so that one Wi-Fi retransmit does '
          'not drop the output under an operator who never let go');
    }

    // `_positive`, and the choice is load-bearing for the same reason
    // [holdPulsePeriod]'s is: a fault case that wants a blackholed dial to
    // give up inside its own budget sets this to a few hundred milliseconds,
    // which is below the deadline floor and has nothing to do with it.
    _positive('connectTimeout', connectTimeout);

    // The third cadence, validated the third time for the same reason. Zero
    // here would be the worst of the three: `Timer.periodic(Duration.zero)`
    // is a beat every event-loop turn, which is a panel flooding the one
    // gateway that serves every screen in the factory.
    _positive('heartbeatFloor', heartbeatFloor);

    _positive('backoffBase', backoffBase);
    _positive('backoffCap', backoffCap);
    _positive('implausibleClockThreshold', implausibleClockThreshold);

    if (backoffCap > maxBackoffCap) {
      throw ArgumentError('backoffCap (${_ms(backoffCap)}) is above the hard '
          'ceiling ${_ms(maxBackoffCap)}: a panel that waits longer than that '
          'to retry looks dead to the operator standing in front of it, who '
          'power-cycles it instead of letting the reconnect run');
    }
    if (backoffBase > backoffCap) {
      throw ArgumentError('backoffBase (${_ms(backoffBase)}) is above '
          'backoffCap (${_ms(backoffCap)}): the very first retry would already '
          'be clamped, which makes the schedule a constant, and a constant '
          'brings every panel in the factory back in the same instant');
    }
  }

  void _atLeastFloor(String name, Duration value) {
    if (value < deadlineFloor) {
      throw ArgumentError('$name (${_ms(value)}) is below the deadline floor '
          '(${_ms(deadlineFloor)}): a measured round trip on this transport is '
          '50 ms and is quantised to the gateway fan-out, so a deadline that '
          'short expires on a healthy link — turning every write into a false '
          'unknown and every subscribe into a reconnect. Lower deadlineFloor '
          'explicitly if this is a test that needs the deadline to fire.');
    }
  }

  static void _positive(String name, Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError('$name (${_ms(value)}) must be positive: a '
          'non-positive interval either disables the check it belongs to or '
          'turns a retry into a spin');
    }
  }

  static String _ms(Duration d) => '${d.inMilliseconds} ms';
}

/// The one certificate authority this station recognises — named by the file
/// the integrator mounted, or carried as the certificate text itself.
///
/// One trust source, deliberately. The gateway's `TlsConfig` carries a chain,
/// a key and a password because a gateway proves who it is; a panel only has
/// to recognise one signature, so a second trust anchor here would be a second
/// thing to provision on every station for a capability nothing asks for. The
/// two constructors are two ways to *provision* that one anchor, and exactly
/// one of [rootCertPath] and [rootCertPem] is ever non-null.
///
/// **Material is allowed here because a CA root is public, and only because
/// of that.** Orchestrator ruling OQ4 ("a path, never bytes") was written to
/// keep *key* material out of preferences rows, log lines and crash dumps —
/// and it still governs everything that is a secret: the gateway's `TlsConfig`
/// is untouched, and `client_config_test.dart` keeps sweeping this file for
/// byte-carrying fields. A root certificate is the thing the gateway hands to
/// anyone who asks; refusing to carry it forced every station to answer "what
/// is a pem path", which is an integrator's question aimed at an operator.
/// The one cost material has — it shows up where the config is printed — is
/// paid by [toString], which never renders the body.
///
/// Whichever way the root arrives, it is consumed exactly once, when
/// `RemoteStateMan` builds its one `SecurityContext` — not per attempt. See
/// that constructor for why.
final class ClientTlsConfig {
  /// The path variant: the root is a file mounted on this station.
  ClientTlsConfig({required String rootCertPath})
      : rootCertPath = rootCertPath,
        rootCertPem = null {
    if (rootCertPath.isEmpty) {
      throw ArgumentError('rootCertPath is empty: SecurityContext reads an '
          'empty path as the process working directory and fails with a '
          'message about a directory nobody configured, once per dial, with '
          'nothing in it naming the certificate the panel was supposed to '
          'trust');
    }
  }

  /// The material variant: the root certificate itself, as PEM text — what
  /// the trust-acquisition flow pins after the operator approved its
  /// fingerprint, and what a fleet tool would seed into the device-local
  /// store.
  ClientTlsConfig.pem(String rootCertPem)
      : rootCertPem = rootCertPem,
        rootCertPath = null {
    if (rootCertPem.trim().isEmpty) {
      throw ArgumentError('rootCertPem is empty: material that decayed to '
          'nothing builds a context that trusts nothing, and every handshake '
          'then fails with the exact message a real impostor produces — the '
          'panel would report an attack instead of a missing certificate');
    }
  }

  /// The PEM file the integrator provisioned to this station, or null when
  /// the root travels as [rootCertPem].
  final String? rootCertPath;

  /// The root certificate as PEM text, or null when the root is named by
  /// [rootCertPath].
  final String? rootCertPem;

  /// Names the trust source; never renders the certificate body. Public
  /// material or not, a 2 kB PEM in every log line and support ticket trains
  /// people to stop reading configs.
  @override
  String toString() => rootCertPath != null
      ? 'ClientTlsConfig(rootCertPath: $rootCertPath)'
      : 'ClientTlsConfig(rootCertPem: <${rootCertPem!.length} chars of '
          'public certificate material>)';
}
