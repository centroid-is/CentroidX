/// What the gateway link is doing, in words an operator can act on.
///
/// **This is the only place in the app that reads the client's reason text.**
/// `ConnectionSupervisor` publishes `lastDownReason` and `stopReason` as prose
/// — nine producers, five of which fall to one kind here — and the only thing
/// that tells them apart is the prefix each one starts with. So the match lives
/// in exactly one predicate, [_voiceOf], deliberately narrow, and anything it
/// does not recognise falls to [GatewayLinkKind.unreachable] carrying the
/// client's text whole in [GatewayLinkReport.raw]. Widening that predicate is
/// how a programming error in the client starts being reported to an operator
/// as a plant condition — the same trap `failure_taxonomy.dart`'s
/// `isLinkLossMessage` names and refuses. The prefixes are copied verbatim into
/// [GatewayLinkReasons], each with the `connection_supervisor.dart` line it came
/// from, and the client's sentences are **not reworded here**: `_refusalReason`
/// is integrator-facing text pinned by `tls_client_test.dart`, and its
/// deliberate refusal to name *which* certificate fault it is was argued and
/// measured across three platforms. This file wraps it. It does not improve it.
///
/// **It is pure.** No widgets, no `DateTime.now()`, no I/O. Elapsed time
/// arrives as a [Duration] the caller measured, which is why the string
/// `DateTime.now(` does not appear below. The goldens for these frames compare
/// on macOS CI, and an ambient clock inside the mapper would churn every one of
/// them on every run; a pure function makes eleven frames eleven constants.
///
/// **The known limitation, recorded rather than closed.** A gateway whose event
/// loop freezes while its socket stays up leaves `LinkState.ready` and produces
/// no `lastDownReason` at all, so this surface reads
/// [GatewayLinkKind.connected] throughout one. The facts that describe it —
/// `RemoteStateMan.stallReason`, `stalledMs` and `stallAge` — are deliberately
/// not consumed here, and there is deliberately no seventh kind for them: a
/// stall is a *freshness* fact about values, not a fact about the link, and
/// Phase 16 owns freshness. Do not add the kind; the next person reading this
/// surface should know what it does not cover rather than discover it on a
/// frozen plant.
library;

import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

/// How long a first connection may be in flight before the panel stops saying
/// "connecting" and says what it actually knows.
///
/// The supervisor keeps retrying forever, which is correct; past this the
/// **UI stops pretending**. Overridable per call to [describeGatewayLink] so a
/// test does not have to spend fifteen seconds to see the other side of it.
const Duration kGatewayFirstConnectPatience = Duration(seconds: 15);

/// The client reason-string prefixes this file matches, and nothing else.
///
/// Copied out of `packages/tfc_relay_client/lib/src/connection_supervisor.dart`
/// at the line named on each one — **never retyped**. Three of them contain an
/// apostrophe, written there as `\'` inside single quotes; they are
/// double-quoted here so no escape can straighten one, because a straightened
/// quote silently never matches and every TLS fault would quietly become a
/// cable fault. The arm that proves these are still prefixes of what a *real*
/// supervisor produces lives in plan 15-04, where a live supervisor makes the
/// string: a unit test fed a hand-copied constant cannot tell a copy from a
/// retype.
abstract final class GatewayLinkReasons {
  /// `connection_supervisor.dart:483` — a dial that produced no socket, and the
  /// failure was not a handshake.
  static const String didNotAnswer = "the gateway did not answer";

  /// `connection_supervisor.dart:480` — a `HandshakeException` on the dial.
  static const String certificateNotTrusted =
      "the gateway's certificate was not trusted by this panel";

  /// `connection_supervisor.dart:602` — the `-32003` `_stop` arm. Terminal.
  static const String credentialRefused =
      "the gateway refused this panel's credential";

  /// `connection_supervisor.dart:584` — the `-32004` `_stop` arm. Terminal.
  static const String versionRefused =
      "the gateway refused this build's protocol version";

  /// `connection_supervisor.dart:933` — an established link letting go. Falls
  /// to [GatewayLinkKind.unreachable], but must not read as "check the cable".
  static const String transportEnded = "the transport ended";

  /// `connection_supervisor.dart:952` — the half-open case, where the socket is
  /// open and the gateway has stopped speaking. Also [GatewayLinkKind
  /// .unreachable], also not a cable.
  static const String wentQuiet = "no frame of any kind for";

  /// `connection_supervisor.dart:417` — a throw out of `connect` itself.
  static const String dialFailed = "the dial failed";

  /// `connection_supervisor.dart:606` — the gateway answered the hello with an
  /// error that was neither `-32003` nor `-32004`.
  static const String handshakeRefused = "the handshake was refused";

  /// `connection_supervisor.dart:609` — the socket died mid-resync.
  static const String diedBeforeSnapshot =
      "the link died before the snapshot landed";
}

/// What the link is doing. Six, and no seventh — every switch over this enum is
/// exhaustive with no fallthrough arm, matching `LinkState`'s own
/// four-and-no-fifth discipline, so a new member is a compile error rather than
/// a state some surface renders as a blank.
enum GatewayLinkKind {
  /// A session is up and holding snapshots.
  connected,

  /// A first attempt is in flight and still inside the patience window.
  connecting,

  /// No usable session, and the panel is still retrying. The widest kind: five
  /// of the client's nine reason producers land here, under three different
  /// sentences.
  unreachable,

  /// This panel would not trust the certificate the gateway presented. Still
  /// retrying — a certificate can be replaced under a running panel.
  untrustedCertificate,

  /// The gateway has decided about this token and the retry loop has stopped.
  credentialRefused,

  /// The gateway will not speak this build's protocol and the retry loop has
  /// stopped.
  versionRefused,
}

/// One sentence, and the kind it reports under.
///
/// Private, because it is a *prose* distinction and the public vocabulary is
/// [GatewayLinkKind]. Three voices report under [GatewayLinkKind.unreachable]:
/// the kind is what the exhaustive switch and the golden frames are built on,
/// and the sentence is what tells an operator which end of the wire to walk to.
/// Collapsing them would send somebody to the switch cupboard for a gateway
/// whose event loop froze — the wrong-end failure this whole file exists to
/// prevent.
enum _Voice {
  connected,
  connecting,

  /// The dial never landed: address, port, cable.
  dialNeverLanded,

  /// An established link let go.
  linkDropped,

  /// The socket is open and nothing is arriving.
  wentQuiet,

  /// The patience expired with no reason reported at all.
  noAnswerYet,
  certificateRefused,
  credentialRefused,
  versionRefused;

  /// The public kind this voice reports under. Total, no `default`.
  GatewayLinkKind get kind => switch (this) {
        _Voice.connected => GatewayLinkKind.connected,
        _Voice.connecting => GatewayLinkKind.connecting,
        _Voice.dialNeverLanded => GatewayLinkKind.unreachable,
        _Voice.linkDropped => GatewayLinkKind.unreachable,
        _Voice.wentQuiet => GatewayLinkKind.unreachable,
        _Voice.noAnswerYet => GatewayLinkKind.unreachable,
        _Voice.certificateRefused => GatewayLinkKind.untrustedCertificate,
        _Voice.credentialRefused => GatewayLinkKind.credentialRefused,
        _Voice.versionRefused => GatewayLinkKind.versionRefused,
      };

  /// Whether the client's retry loop has stopped. Two of nine, and both of them
  /// are answers that will not change on the next attempt.
  bool get terminal =>
      this == _Voice.credentialRefused || this == _Voice.versionRefused;
}

/// What to put on a panel about the gateway link, right now.
///
/// Immutable and comparable so a widget can rebuild on change and a golden can
/// be driven from a `const`.
final class GatewayLinkReport {
  const GatewayLinkReport({
    required this.kind,
    required this.headline,
    required this.detail,
    required this.url,
    this.raw,
    this.terminal = false,
    this.sanHint,
  });

  /// The closed vocabulary the goldens and the colour mapping are built on.
  final GatewayLinkKind kind;

  /// One line, naming the thing and the address. Written here, never spliced
  /// from the client's text.
  final String headline;

  /// Two sentences at most, naming the end of the wire to go and check.
  /// Written here, never spliced from the client's text.
  final String detail;

  /// The client's own reason string, carried whole and unedited — or null when
  /// there was no reason (a healthy link, or a dial still in flight).
  ///
  /// **This is the paste-into-a-ticket field, and the only one that may carry
  /// text this file did not write.** The `OS Error` line at the end of a dial
  /// failure is the only part of a remote fault a support engineer can act on,
  /// so it is kept intact rather than summarised. It follows that [raw] is the
  /// one field a surface must render as diagnostic detail rather than as
  /// operator prose: [headline] and [detail] are this file's words and are safe
  /// on a panel anybody can read, and [raw] is the gateway's.
  final String? raw;

  /// Whether the client has stopped retrying. A terminal report must read
  /// differently from a retrying one: nobody is going to walk away and let it
  /// fix itself.
  final bool terminal;

  /// The extra sentence for a certificate refusal dialled by name, or null.
  ///
  /// Fires only when the dialled host is a DNS name, because on an address dial
  /// the name is not a candidate cause and a hint that is always shown is a hint
  /// nobody reads (rig FIND-B).
  final String? sanHint;

  /// The endpoint this report is about, as configured. Render it through
  /// nothing but this file — see the userinfo note on [describeGatewayLink].
  final Uri url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayLinkReport &&
          other.kind == kind &&
          other.headline == headline &&
          other.detail == detail &&
          other.raw == raw &&
          other.terminal == terminal &&
          other.sanHint == sanHint &&
          other.url == url;

  @override
  int get hashCode =>
      Object.hash(kind, headline, detail, raw, terminal, sanHint, url);

  @override
  String toString() =>
      'GatewayLinkReport(${kind.name}, terminal: $terminal, "$headline")';
}

/// Maps what the client already publishes onto something an operator can act on.
///
/// **The order of decision is load-bearing:**
///
/// 1. `stopReason` first. The retry loop has stopped, and nothing about the
///    link state or the clock changes that.
/// 2. Then `LinkState.ready` — a live session.
/// 3. Then `lastDownReason`, by prefix.
/// 4. Only then, with **both reasons null** and the state not ready, the
///    patience window.
///
/// **Steps 1 and 3 running before step 4 is the whole of F-6.** The client has
/// no `everReady` flag and no first-attempt timestamp, so [elapsed] can only be
/// anchored at first *observation* — which means an operator walking up to a
/// panel that has been broken since the morning shift would be shown a fresh
/// fifteen-second "connecting…" every time a widget was rebuilt. A reason that
/// already exists is proof the panel has been here before, so it wins.
///
/// **Nothing operator-facing carries a credential.** The token is never a
/// parameter here, the client's message is never spliced into [
/// GatewayLinkReport.headline] or [GatewayLinkReport.detail], and the URL is
/// rendered through [_render], which drops `userInfo`. The client already
/// refuses to splice `config.token` into its own `stopReason`
/// (`connection_supervisor.dart:596-600`) precisely because a panel stands where
/// anybody can read it; this file must not undo that on the last hop to a
/// screen.
GatewayLinkReport describeGatewayLink({
  required LinkState state,
  required Uri url,
  required Duration elapsed,
  String? lastDownReason,
  String? stopReason,
  Duration patience = kGatewayFirstConnectPatience,
}) {
  final _Voice voice;
  final String? raw;

  if (stopReason != null) {
    // 1. The loop has stopped. An unrecognised stop reason is still reported —
    //    as `unreachable`, not-terminal — rather than dropped on the floor.
    final matched = _voiceOf(stopReason);
    voice = matched.terminal ? matched : _Voice.dialNeverLanded;
    raw = stopReason;
  } else if (state == LinkState.ready) {
    // 2. A live session. `resyncing` is deliberately not here: values are not
    //    trustworthy yet, so it stays with the connecting/patience arms below.
    voice = _Voice.connected;
    raw = null;
  } else if (lastDownReason != null) {
    // 3. The reason wins over the clock. See F-6 above.
    voice = _voiceOf(lastDownReason);
    raw = lastDownReason;
  } else if (elapsed < patience) {
    // 4. Genuinely a first attempt, genuinely still young.
    voice = _Voice.connecting;
    raw = null;
  } else {
    voice = _Voice.noAnswerYet;
    raw = null;
  }

  final where = _render(url);
  final showSanHint =
      voice == _Voice.certificateRefused && url.scheme == 'wss' && !_isIpLiteral(url.host);

  return GatewayLinkReport(
    kind: voice.kind,
    headline: _headline(voice, where, elapsed, patience),
    detail: _detail(voice, where),
    url: url,
    raw: raw,
    terminal: voice.terminal,
    sanHint: showSanHint ? _sanHint(url.host) : null,
  );
}

/// The one predicate that reads the client's text, and the only one.
///
/// Prefix, not `contains`: every producer builds its string by prepending a
/// fixed sentence to an interpolated cause, so the prefix is the part that is
/// ours to match and the tail is the part that is the operator's to read. A
/// string matching nothing lands on [_Voice.dialNeverLanded] — the widest and
/// most conservative sentence — and the caller keeps it whole in
/// [GatewayLinkReport.raw].
_Voice _voiceOf(String reason) {
  if (reason.startsWith(GatewayLinkReasons.certificateNotTrusted)) {
    return _Voice.certificateRefused;
  }
  if (reason.startsWith(GatewayLinkReasons.credentialRefused)) {
    return _Voice.credentialRefused;
  }
  if (reason.startsWith(GatewayLinkReasons.versionRefused)) {
    return _Voice.versionRefused;
  }
  if (reason.startsWith(GatewayLinkReasons.transportEnded)) {
    return _Voice.linkDropped;
  }
  if (reason.startsWith(GatewayLinkReasons.wentQuiet)) {
    return _Voice.wentQuiet;
  }
  // `didNotAnswer`, `dialFailed`, `handshakeRefused`, `diedBeforeSnapshot` and
  // anything unrecognised all mean the same thing to the person standing at the
  // panel: there is no session and the dial is where to look.
  return _Voice.dialNeverLanded;
}

/// One line. Total over [_Voice], no `default`.
String _headline(_Voice voice, String where, Duration elapsed, Duration patience) =>
    switch (voice) {
      _Voice.connected => 'Connected to $where',
      _Voice.connecting => 'Connecting to $where…',
      _Voice.dialNeverLanded => 'No connection to $where',
      _Voice.linkDropped => 'The connection to $where ended',
      _Voice.wentQuiet => 'The gateway at $where has gone quiet',
      _Voice.noAnswerYet =>
        'No answer from $where after ${elapsed.inSeconds} s',
      _Voice.certificateRefused => 'The certificate at $where was refused',
      _Voice.credentialRefused => 'The gateway refused this panel',
      _Voice.versionRefused => 'The gateway refused this build',
    };

/// The end of the wire to go and check. Total over [_Voice], no `default`.
String _detail(_Voice voice, String where) => switch (voice) {
      _Voice.connected =>
        'The panel is holding a live session and the values on screen are '
            'coming from it.',
      _Voice.connecting =>
        'The first attempt is still in flight. If nothing comes back, this '
            'will say so rather than keep spinning.',
      _Voice.dialNeverLanded =>
        'The dial never landed. Check the address and the port above, that '
            'the gateway is running, and the cable and switch between this '
            'panel and it. The panel keeps retrying.',
      _Voice.linkDropped =>
        'A session that was up has ended and the panel is reconnecting. '
            'Nothing here says which end let go, so give it a moment before '
            'going to look.',
      _Voice.wentQuiet =>
        'The socket is still open but the gateway has stopped sending, so the '
            'panel is rebuilding the connection. This is the gateway end, not '
            'the wire between it and here.',
      _Voice.noAnswerYet =>
        'Nothing has come back and no reason has been reported. Check the '
            'address and the port above, and that the gateway is running. The '
            'panel keeps retrying.',
      _Voice.certificateRefused =>
        'The gateway answered and this panel would not trust the certificate '
            'it presented. Check the CA root file configured above — this '
            'panel trusts that file and nothing else. It keeps retrying.',
      _Voice.credentialRefused =>
        'The panel has stopped retrying: the gateway has already decided about '
            'this token and would refuse it again. Check the credential file '
            'configured above, then restart the panel.',
      _Voice.versionRefused =>
        'The panel has stopped retrying: this build and the gateway speak '
            'different protocol versions, so one of the two has to be '
            'updated.',
    };

/// The extra sentence for a certificate refused on a dial by name.
///
/// Rig FIND-B: the probe leaf carries `SAN: IP Address:10.50.10.11` and no DNS
/// name at all, so an operator who typed a hostname fails the handshake with a
/// message about *trust* and goes to the CA file — the wrong end entirely.
String _sanHint(String host) =>
    'The gateway certificate must also carry a subject-alternative name for '
    'exactly $host. A certificate issued for an address will fail here with a '
    'message about trust rather than about the name.';

/// The URL as it may be shown, with any `userInfo` dropped.
///
/// A credential in a preferences row is still a credential, and rendering it
/// back is how it ends up in a photograph of a panel.
String _render(Uri url) => url.replace(userInfo: '').toString();

/// Whether [host] is an address rather than a name.
///
/// **Duplicated, knowingly, and only until 15-02 lands.** Plan 15-02 puts the
/// same host-shape question on `GatewayConfig` for its hostname advisory, and
/// there should be one spelling of "is this an address or a name" in this
/// phase. `InternetAddress.tryParse` would be the obvious answer and is not
/// available: `dart:io` must not be imported here, because this file is
/// deliberately pure and 15-07's goldens depend on that. Collapse this onto
/// `GatewayConfig`'s helper when both are on the branch.
bool _isIpLiteral(String host) {
  // IPv6 literals are the only hosts that can carry a colon.
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
  }
  return true;
}
