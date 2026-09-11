/// The one redactor, judged directly.
///
/// This is the primary pin. Until 18-02 the redactor ran as two byte-identical
/// copies and neither could be called directly from here: `tfc_relay_local`'s
/// arms went through its own package, and `tfc_dart`'s copy was private, so its
/// entire coverage was one assertion exercising one rule of eight.
///
/// The arms in the two dependent packages survive as *usage* pins — they prove
/// each package still routes its upstream errors through this function. These
/// arms prove the function is right.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('redactUpstreamError, rule by rule', () {
    test('rule 1: takes the credentials out with the endpoint', () {
      final out = redactUpstreamError(
          'connect failed: opc.tcp://svc:hunter2@10.104.29.11:4840/ua/server');

      expect(out, isNot(contains('hunter2')),
          reason: 'the password rode in on the endpoint userinfo, which is '
              'where a real open62541 connect error puts it — and both '
              'consumers fan this string out to a panel (T-08-33)');
      expect(out, isNot(contains('10.104.29.11')));
      expect(out, contains('<endpoint>'),
          reason: 'the redacted form must still say what kind of thing was '
              'removed, or the diagnostic is worthless');
    });

    test('rule 2: takes a Windows certificate path out', () {
      final out = redactUpstreamError(r'cannot read C:\centroid\certs\client.pfx')!;
      expect(out, isNot(contains('client.pfx')));
      expect(out, contains('<path>'));
    });

    test('rule 3: takes a POSIX certificate path out', () {
      final out = redactUpstreamError('cannot read /etc/centroid/certs/client.pem')!;
      expect(out, isNot(contains('client.pem')));
      expect(out, contains('<path>'));
    });

    test('rule 3 stops short of ordinary prose: "and/or" is not a path', () {
      // Two segments minimum. A redactor that ate every slash would eat the
      // sentence it exists to preserve.
      expect(redactUpstreamError('the write was refused and/or lost'),
          contains('and/or'));
    });

    test('rule 4: takes a credential out even without a scheme in front of it',
        () {
      final out = redactUpstreamError('rejected (username=admin password=s3cr3t)');

      expect(out, isNot(contains('s3cr3t')));
      expect(out, isNot(contains('admin')));
      expect(out, contains('<redacted>'));
    });

    test('rule 5: takes a labelled host out', () {
      expect(redactUpstreamError('SocketException: address = 10.104.29.71:502'),
          isNot(contains('10.104.29.71')));
    });

    test('rule 5: takes a DNS hostname out, which names a machine as much as '
        'an address does', () {
      final out = redactUpstreamError(
          'SocketException: Failed host lookup, address = st101.svn.local')!;

      expect(out, isNot(contains('st101.svn.local')),
          reason: 'a hostname names the PLC and the site as clearly as its '
              'address does, and this is the ONLY rule that can catch one — no '
              'literal pattern will ever match a DNS name (08-REVIEW WR-11)');
      expect(out, contains('<host>'));
      expect(out, contains('Failed host lookup'),
          reason: 'and the part that says what went wrong survives, or the '
              'key is useless to the engineer it exists for');
    });

    test('rule 6: takes a BARE IPv4 out, with no label in front of it', () {
      final out = redactUpstreamError('connection refused by 10.104.29.71:502')!;
      expect(out, isNot(contains('10.104.29.71')));
      expect(out, contains('<host>'));
    });

    test('rules 7 and 8: takes an IPv6 literal out, in both of the shapes '
        'dart:io writes them', () {
      for (final raw in <String>[
        'SocketException: connect failed, address = fd00::10:104:29:11',
        'SocketException: connect failed, address = [fd00:1:2:3:4:5:6:7]:4840',
        'no route to ::1',
      ]) {
        final out = redactUpstreamError(raw)!;
        expect(out, isNot(contains('fd00')), reason: raw);
        expect(out, isNot(contains('::1')), reason: raw);
        expect(out, contains('<host>'), reason: raw);
      }
    });

    test('rule 8 unlabelled: a bare compressed IPv6 goes, with no address= in '
        'front of it', () {
      // The IPv6 samples above all carry an `address =` label except `::1`,
      // so without this arm rule 8 could be deleted and only one input would
      // notice.
      final out = redactUpstreamError('no route to fd00:1:2:3:4:5:6:7')!;
      expect(out, isNot(contains('fd00')));
      expect(out, contains('<host>'));
    });

    test('the over-broad rule stops somewhere: a clock time is not an IPv6 '
        'address', () {
      // `09:49:57` is two colons and a lot of hex digits. Redacting every
      // timestamp would make last_error unreadable for the sake of nothing.
      expect(redactUpstreamError('at 09:49:57 the session dropped'),
          contains('09:49:57'));
      expect(redactUpstreamError('at 14:30:52 the session dropped'),
          contains('14:30:52'));
    });

    test('keeps the part of the message that says what went wrong', () {
      expect(redactUpstreamError('BadUserAccessDenied from opc.tcp://plc:4840/'),
          contains('BadUserAccessDenied'),
          reason: 'redaction that removes the diagnosis as well as the '
              'credential just makes the operator ask somebody for the log');
    });

    test('bounds the length, because this becomes a fanned-out key value', () {
      final out = redactUpstreamError('x' * 5000)!;

      // 201, as a LITERAL, and deliberately not `maxRedactedErrorLength + 1`.
      // An arm written against the constant moves when the constant moves, so
      // raising the cap would not turn it red — the assertion would follow the
      // mutation instead of catching it. The number being pinned is 200.
      expect(out.length, lessThanOrEqualTo(201),
          reason: 'a link flapping under a verbose stack trace would otherwise '
              'push kilobytes per event at every subscriber of '
              'PIPE.upstream.<alias>.last_error');
      expect(out, endsWith('…'),
          reason: 'a truncated message must say it was truncated');
    });

    test('the cap is 200 and this arm is what says so', () {
      // Separate from the bound above so a raised cap fails on the NUMBER and
      // not only on a length comparison somebody could later relax.
      expect(maxRedactedErrorLength, 200);
    });

    test('passes null through', () {
      // A link that has never failed has no error, and inventing "" for it
      // would read as an error whose message nobody wrote down.
      expect(redactUpstreamError(null), isNull);
    });
  });

  group('rule ORDER is load-bearing, not incidental', () {
    // T-18-02b. The order these rules run in is a silent precondition of the
    // whole redactor, and an order nothing pins is an order a later tidy-up
    // will change. These arms fail if the rules are reordered even though
    // every individual rule still works.

    test('a credentialled URL collapses to ONE endpoint, whole', () {
      // NOTE ON WHAT THIS ARM DOES AND DOES NOT CATCH.
      //
      // It was written expecting to detect the scheme rule being moved below
      // the host rules. It does NOT, and that was established by mutation
      // rather than assumed: hoisting the bare-IPv4 rule above the scheme rule
      // leaves this output byte-identical, because the scheme pattern's
      // character class excludes only whitespace and `,;)"'` — not `<` or `>`
      // — so it re-consumes the `<host>` placeholder and still collapses the
      // whole URL, credential included.
      //
      // Scheme-before-host is therefore NOT a load-bearing ordering, and no
      // arm should claim to pin it. The ordering that IS load-bearing is
      // paths-before-IPv4, which the next arm pins.
      //
      // What this arm still earns its place for: the URL must collapse as one
      // unit, so a future rule that fragments it would be caught here.
      final out = redactUpstreamError(
          'closed talking to opc.tcp://svc:hunter2@10.0.0.5:4840/')!;

      expect(out, isNot(contains('hunter2')));
      expect(out, contains('<endpoint>'),
          reason: 'the whole URL must be replaced as ONE endpoint, not left '
              'as a half-eaten URL with a <host> inside it');
      expect(out, isNot(contains('opc.tcp://')));
    });

    test('the PATH rules run BEFORE the bare-IPv4 rule, or a certificate '
        'filename survives inside an address-named directory', () {
      // This plant names per-PLC certificate directories after the PLC's
      // address, so this is an ordinary path here and not a contrived one.
      //
      // Correct order: the POSIX-path rule sees the whole path — digits and
      // dots are ordinary segment characters to it — and replaces all of it.
      //
      // Hoist the bare-IPv4 rule above it and the address becomes `<host>`
      // FIRST. `<` and `>` are not segment characters, so the path rule can no
      // longer span the whole path: it eats the prefix, stops dead at the
      // placeholder, and `/client.pem` is left behind because the trailing
      // segment has no slash after it to match on. The filename leaks.
      //
      // Every per-rule arm above stays green through that reorder, which is
      // the point: rule ORDER is load-bearing and only an arm like this one
      // can see it.
      final out = redactUpstreamError(
          'cannot read /etc/centroid/certs/10.104.29.71/client.pem')!;

      expect(out, isNot(contains('client.pem')),
          reason: 'the certificate filename is the secret here, and it '
              'survives if a host rule fragments the path before the path '
              'rule has seen it');
      expect(out, isNot(contains('10.104.29.71')));
    });

    test('the labelled-host rule runs BEFORE the literal patterns, or a DNS '
        'name survives', () {
      // `address = 10.0.0.5` is catchable by both rule 5 and rule 6, so it
      // cannot detect the swap. `address = st101.svn.local` is catchable ONLY
      // by rule 5 — and if the literal patterns ran first they would consume
      // nothing here, which is why this arm needs the label AND a name.
      final out = redactUpstreamError(
          'Failed host lookup, address = st101.svn.local, port = 4840')!;

      expect(out, isNot(contains('st101.svn.local')));
      expect(out, contains('address = <host>'),
          reason: 'the label is kept so the message still reads — a bare '
              '<host> here would mean a literal pattern got there first');
    });

    test('the credential rule runs BEFORE the host rules, so a password that '
        'looks like an address is still a password', () {
      // `password=10.0.0.5` is matched by rule 4 AND by rule 6. Which one
      // wins is visible in the output: rule 4 says `password=<redacted>`,
      // rule 6 would say `password=<host>` — the value gone either way, but
      // the SECOND spelling means the credential rule is being shadowed and
      // a non-address password would not be caught by anything.
      final out = redactUpstreamError('rejected (password=10.0.0.5)')!;

      expect(out, contains('password=<redacted>'),
          reason: 'the credential rule must claim this first; if a host rule '
              'does, then rule 4 is dead for every password that happens to '
              'look like an address and nothing else notices');
    });
  });
}
