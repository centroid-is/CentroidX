/// Short-lived, path-bound credentials for the camera media side-channel.
///
/// Design source: `.planning/quick/20260908-rtsp-over-relay/DESIGN.md`.
/// Camera video never rides the JSON-RPC socket — the conflating send buffer
/// cannot carry an ordered inter-frame byte stream without becoming the queue
/// the project's constitution forbids — so the relay *authorises* instead: a
/// `camera.*` handler asks `AccessPolicy.groupForCamera` (the rule, stated
/// once, in the master system), and on yes mints a ticket here. The media
/// endpoint's auth hook presents what the panel presented, and this book
/// answers whether it is the credential the relay issued, for that one
/// camera, while it still lives.
///
/// ## This file is a credential mechanism, and nothing else
///
/// The one-master-system ruling (Jón, 2026-09-06) grants the relay exactly
/// one carve-out: *"the credential mechanism only… The moment it answers
/// 'and therefore may do X', it has crossed into the master system's
/// territory."* So there is no group here, no identity, no import of
/// `tfc_access` — `camera_ticket_book_test.dart` pins the absence in the
/// source. Whether the panel MAY view the camera was decided before `mint`
/// was called; this class only makes that decision presentable at a port the
/// relay does not own.
///
/// ## No clock, no I/O
///
/// Callers pass `nowMs` — `send_buffer.dart`'s idiom — so expiry is
/// deterministic under test and this class can never be the thing that
/// stalls. The only impurity is the secret generator, injected for the same
/// reason the clock is passed in.
library;

import 'dart:math';

/// One issued credential: the secret a panel will present, the single camera
/// path it opens, and the millisecond at which it stops working.
final class CameraTicket {
  const CameraTicket({
    required this.secret,
    required this.cameraPath,
    required this.expiresAtMs,
  });

  /// What the panel carries in the RTSP userinfo. 256 random bits as lowercase
  /// hex under the default generator.
  final String secret;

  /// The one path this ticket opens. Bound at mint because the relay
  /// authorised one camera; a ticket that opened any path would widen "may
  /// view the packing hall" into "may view everything" at the dumb pipe,
  /// where no policy lives to refuse it.
  final String cameraPath;

  /// The ticket is valid while `nowMs < expiresAtMs`. The boundary belongs to
  /// the dead side, so a TTL can never overshoot by the millisecond the
  /// comparison would otherwise gift it.
  final int expiresAtMs;
}

/// Mints and validates [CameraTicket]s. One instance per gateway process,
/// owned by the future `camera.*` handler.
final class CameraTicketBook {
  CameraTicketBook({
    this.maxOutstanding = 1024,
    String Function()? secretGenerator,
  }) : _generate = secretGenerator ?? _randomHex256;

  /// The most tickets alive at once. Minting past it evicts the
  /// soonest-to-expire ticket rather than refusing: a refusal would deny the
  /// *operator*, on the very retry that would have brought a tile back, and
  /// everyone able to reach `mint` has already been authenticated and
  /// authorised per call — the eviction is not an unauthenticated denial
  /// lever. The evicted ticket was the one nearest death anyway. 1024 is
  /// generous against the real arrival rate: the retry ladder clamps each
  /// tile at one open per minute.
  final int maxOutstanding;

  final String Function() _generate;

  /// Keyed by secret. The map lookup compares hashes, not secrets; the
  /// confirming comparison in [validate] is the fixed-time one.
  final Map<String, CameraTicket> _bySecret = <String, CameraTicket>{};

  /// Live tickets. Only honest after the lazy prunes in [mint] and
  /// [validate]; a caller that has not touched the book since time passed may
  /// read a count that includes tickets time has already killed, which is the
  /// price of holding no clock.
  int get outstanding => _bySecret.length;

  /// Issues a ticket for [cameraPath], valid from [nowMs] for [ttlMs].
  ///
  /// Every mint sweeps expired tickets first — the book lives for the
  /// process, and eight tiles retrying over a weekend must not leave a
  /// weekend of dead tickets on the heap.
  CameraTicket mint({
    required String cameraPath,
    required int nowMs,
    required int ttlMs,
  }) {
    _prune(nowMs);
    while (_bySecret.length >= maxOutstanding && _bySecret.isNotEmpty) {
      _evictSoonestToExpire();
    }
    final ticket = CameraTicket(
      secret: _generate(),
      cameraPath: cameraPath,
      expiresAtMs: nowMs + ttlMs,
    );
    _bySecret[ticket.secret] = ticket;
    return ticket;
  }

  /// Whether [secret] is a live ticket for exactly [cameraPath] at [nowMs].
  ///
  /// A false answer says nothing about why — unknown, expired and
  /// wrong-camera are indistinguishable to the caller, the same
  /// hidden-vs-absent doctrine `KeyPolicy.canSee` documents. An expired
  /// ticket is removed on sight and stays dead even to a caller replaying an
  /// earlier `nowMs`.
  bool validate({
    required String secret,
    required String cameraPath,
    required int nowMs,
  }) {
    final ticket = _bySecret[secret];
    if (ticket == null) return false;
    if (nowMs >= ticket.expiresAtMs) {
      _bySecret.remove(secret);
      return false;
    }
    // The map get above compared hashes. This is the credential comparison,
    // and it must not be `==`: String's returns the moment it finds a
    // difference, and the moment it returns is the side channel.
    if (!_constantTimeEquals(secret.codeUnits, ticket.secret.codeUnits)) {
      return false;
    }
    if (!_constantTimeEquals(
        cameraPath.codeUnits, ticket.cameraPath.codeUnits)) {
      return false;
    }
    return true;
  }

  void _prune(int nowMs) {
    _bySecret.removeWhere((_, ticket) => nowMs >= ticket.expiresAtMs);
  }

  /// Removes exactly one ticket — the soonest to expire — and is
  /// structurally unable to remove none. Sabotage finding, 2026-09-08: an
  /// earlier shape started from a sentinel (`victim = null`, `soonest =
  /// maxint`) and only assigned inside the comparison, so a flipped
  /// comparison — or a book whose every ticket expired at the sentinel —
  /// selected no victim, removed nothing, and turned [mint]'s `while` into a
  /// spin. Seeding from the first entry makes "non-empty in, one fewer out"
  /// a property of the shape rather than of the comparison being right.
  void _evictSoonestToExpire() {
    final iterator = _bySecret.entries.iterator;
    if (!iterator.moveNext()) return;
    var victim = iterator.current.key;
    var soonest = iterator.current.value.expiresAtMs;
    while (iterator.moveNext()) {
      if (iterator.current.value.expiresAtMs < soonest) {
        soonest = iterator.current.value.expiresAtMs;
        victim = iterator.current.key;
      }
    }
    _bySecret.remove(victim);
  }
}

/// 256 bits from the OS CSPRNG as 64 lowercase hex characters.
///
/// `Random.secure` is the same source `tls/mint.dart` draws serial numbers
/// from; hex rather than base64url because the string travels as RTSP
/// userinfo, where `+`/`/`/`=` would need escaping some client would
/// eventually get wrong.
String _randomHex256() {
  final rng = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Whether two buffers are equal, in time that does not depend on where they
/// first differ. Same shape and same argument as the one in
/// `auth/file_token_validator.dart`; duplicated four lines rather than
/// exported, because publishing a timing primitive from an auth file so a
/// media file can import it is a worse coupling than the four lines.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
