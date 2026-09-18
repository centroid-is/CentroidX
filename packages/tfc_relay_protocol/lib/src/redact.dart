/// Strips credentials, endpoints and filesystem paths out of an upstream error
/// before it can reach a panel.
///
/// A pure core over a `String`. No dependency, no I/O — which is what lets it
/// sit below both the gateway and the backend, and is why it is here rather
/// than in either of them.
///
/// ## Why one copy, and why in this package
///
/// This ran as two byte-identical copies until 18-02: a public one in
/// `tfc_relay_local`'s `upstream_link.dart` and a private one inlined into
/// `tfc_dart`'s `write_translation.dart`, the latter carrying a comment saying
/// the two "must stay in step" — a promise with no mechanism behind it. The
/// mechanism is this file.
///
/// **One redactor used by every adapter is the property worth keeping, and a
/// second pass at a call site would hide an adapter that forgot to apply it.**
/// That is the argument for centralising rather than for defence in depth: if
/// each call site redacted again on the way out, an adapter that never redacted
/// at all would produce identical output to one that did, and the omission
/// would be invisible exactly where it mattered. One pass, at one boundary,
/// fails loudly.
///
/// ## What it defends
///
/// The threat is not an attacker inside the error string; it is the ordinary
/// case (T-08-33). open62541, the Modbus stack and `dart:io` all put the thing
/// they were talking to into the message — `opc.tcp://svc:hunter2@10.104.29.11:
/// 4840/`, `/etc/centroid/certs/client.pem`, `SocketException: … address =
/// 10.104.29.71` — and both consumers fan that string out where an
/// unprivileged panel can read it: `tfc_relay_local` as
/// `PIPE.upstream.<alias>.last_error`, a subscribable key value, and `tfc_dart`
/// as a `WriteReason.message` on a three-state write outcome. The alias is
/// already public; the credential, the certificate path and the plant topology
/// are not.
///
/// Deliberately over-broad. Redacting a version string that looks like an IPv4
/// address costs a diagnostic detail; missing a password costs a credential,
/// and the redacted forms still say *what kind* of thing was removed. The
/// unredacted string stays available to the gateway's own log, which is not a
/// key.
library;

/// Returns [raw] with credentials, endpoints, paths and hosts replaced by
/// labels saying what kind of thing was removed, bounded by
/// [maxRedactedErrorLength]. Null in, null out.
///
/// **Over-broad still has an edge, and it is written down.** 08-REVIEW WR-11
/// added IPv6 literals and the `address = <token>` shapes — the latter being
/// the only rule that can catch a DNS hostname, which names a PLC and a site
/// as plainly as an address does and which no literal pattern will ever match.
/// The IPv6 rules stop short of two-colon runs on purpose: `09:49:57` is a
/// timestamp, and a redactor that ate every clock time would make this key
/// unreadable in exchange for nothing.
///
/// **Rule order is load-bearing, and 18-02 measured exactly where.** The
/// interesting dependency is not the obvious one:
///
///  * **The path rules must run before the bare-IPv4 rule.** This one is real
///    and it leaks. `/etc/centroid/certs/10.104.29.71/client.pem` is redacted
///    whole by the POSIX-path rule, because digits and dots are ordinary
///    segment characters to it. Let the IPv4 rule go first and the address
///    becomes `<host>`; `<` and `>` are not segment characters, so the path
///    rule can no longer span the path — it stops at the placeholder and
///    leaves `/client.pem` standing. The certificate filename survives while
///    every per-rule arm stays green.
///  * **The labelled-host rule must run before the literal patterns**, because
///    it is the only one that can catch a DNS name.
///  * **Scheme-before-host is NOT observable**, and the comment that used to
///    claim it was wrong. Hoisting the IPv4 rule above the scheme rule changes
///    nothing: the scheme pattern's character class does not exclude `<` or
///    `>`, so it re-consumes the `<host>` placeholder and still collapses the
///    whole URL — credential included — to `<endpoint>`. Verified by mutation,
///    not assumed.
///
/// The two that are load-bearing are pinned by `test/redact_test.dart`'s
/// `rule ORDER is load-bearing` group. Reordering without running it is how a
/// tidy-up leaks a filename.
String? redactUpstreamError(String? raw) {
  if (raw == null) return null;
  var out = raw;

  // Any scheme://… — this is the one that carries userinfo, so it goes first
  // and takes the credentials with it.
  out = out.replaceAll(
      RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s,;)"' "'" r']+'), '<endpoint>');

  // Windows paths (certificate stores, key files).
  out = out.replaceAll(
      RegExp(r'[a-zA-Z]:\\[^\s,;)"' "'" r']*'), '<path>');

  // Absolute POSIX paths. Two segments minimum, so ordinary prose containing
  // "and/or" survives and "/etc/ssl/private/client.pem" does not.
  out = out.replaceAll(
      RegExp(r'/(?:[A-Za-z0-9._@\-]+/)+[A-Za-z0-9._@\-]*'), '<path>');

  // key=value credentials that never had a scheme in front of them.
  out = out.replaceAllMapped(
      RegExp(
          r'\b(user|username|uid|login|password|passwd|pwd|token|secret|api[_-]?key)'
          r'\s*[=:]\s*\S+',
          caseSensitive: false),
      (m) => '${m[1]}=<redacted>');

  // The shapes `dart:io` writes a peer in: `address = <token>`,
  // `host = <token>`. This one comes BEFORE the literal patterns below because
  // it is the only one that can catch a **DNS hostname** — `st101.svn.local`
  // names the PLC and the site as plainly as an address does, and no literal
  // pattern will ever match it (08-REVIEW WR-11). The label is kept so the
  // message still reads.
  out = out.replaceAllMapped(
      RegExp(r'\b(address|host|hostname|remoteAddress|peer)\s*[=:]\s*([^\s,;)]+)',
          caseSensitive: false),
      (m) => '${m[1]} = <host>');

  // Bare hosts: an IPv4 literal with an optional port.
  out = out.replaceAll(
      RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'), '<host>');

  // IPv6 literals, in the two shapes that actually occur (08-REVIEW WR-11).
  //
  // **The bracketed form first**, because it carries the port inside a
  // structure the bare patterns would only half-eat.
  out = out.replaceAll(
      RegExp(r'\[[0-9A-Fa-f:]{2,}\](?::\d+)?'), '<host>');

  // Then the two bare forms. The threshold is not arbitrary and it is where
  // "deliberately over-broad" has to stop: a compressed address is recognised
  // by its `::`, and an uncompressed one by having **at least three** colons.
  // Two colons is `09:49:57`, and redacting every timestamp in every message
  // would make `last_error` unreadable for the sake of nothing.
  out = out.replaceAll(
      RegExp(r'(?<![\w:])[0-9A-Fa-f]{0,4}::[0-9A-Fa-f:]*[0-9A-Fa-f](?::\d+)?'),
      '<host>');
  out = out.replaceAll(
      RegExp(r'(?<![\w:])[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){3,}(?![\w:])'),
      '<host>');

  // A key value is read on a screen. An unbounded error string is also an
  // unbounded thing to fan out to every subscriber of that key.
  return out.length <= maxRedactedErrorLength
      ? out
      : '${out.substring(0, maxRedactedErrorLength)}…';
}

/// How much of an upstream error survives redaction.
///
/// Long enough to name the failure, short enough that a link flapping under a
/// verbose stack trace cannot push kilobytes per event at every subscriber of
/// `PIPE.upstream.<alias>.last_error`.
const int maxRedactedErrorLength = 200;
