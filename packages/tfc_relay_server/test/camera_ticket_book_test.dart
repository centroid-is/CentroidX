/// The camera ticket book: the credential mechanism, and only that.
///
/// Design source: `.planning/quick/20260908-rtsp-over-relay/DESIGN.md` §4.
/// Video never rides the JSON-RPC socket; the relay *authorises* a media
/// side-channel by minting a short-lived ticket after `AccessPolicy
/// .groupForCamera` has answered server-side. This class is what carries that
/// answer to the media port — mint, validate, expire — and it must hold NO
/// policy: the moment it answers "and therefore may view X" it has crossed
/// into the master system's territory (the one-master-system ruling, Jón
/// 2026-09-06). The pins here are therefore all about credential mechanics.
///
/// No clock, no I/O: callers pass `nowMs`, `send_buffer.dart`'s idiom, so
/// every behaviour is deterministic under test.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_server/src/media/camera_ticket_book.dart';

void main() {
  group('mint and validate', () {
    test('a minted ticket validates for its camera path within its TTL', () {
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 2000),
        isTrue,
      );
    });

    test('a ticket is bound to exactly one camera path', () {
      // The relay authorised ONE camera. A ticket that opened any path would
      // turn "may view the packing hall" into "may view everything", with the
      // widening decided by the dumb pipe rather than by AccessPolicy.
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_serverroom', nowMs: 2000),
        isFalse,
      );
    });

    test('an unknown secret never validates', () {
      final book = CameraTicketBook();
      book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(
        book.validate(
            secret: 'not-a-ticket', cameraPath: 'cam_packhall', nowMs: 2000),
        isFalse,
      );
    });

    test('a ticket may validate more than once within its TTL', () {
      // mpv's RTSP handshake and MediaMTX's auth hook may ask more than once
      // per open (DESCRIBE/SETUP/PLAY are one authenticated session, but the
      // hook contract does not promise exactly one call). Single-use would
      // make playback racy against the very retry ladder the tile runs on;
      // the bound is time, not count.
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 2000),
        isTrue,
      );
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 3000),
        isTrue,
      );
    });

    test('two live tickets for the same camera coexist', () {
      // Two panels watching the same camera each hold their own credential;
      // minting for the second must not revoke the first mid-stream.
      final book = CameraTicketBook();
      final a = book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      final b = book.mint(cameraPath: 'cam_packhall', nowMs: 1500, ttlMs: 30000);
      expect(a.secret, isNot(b.secret));
      expect(
        book.validate(
            secret: a.secret, cameraPath: 'cam_packhall', nowMs: 2000),
        isTrue,
      );
      expect(
        book.validate(
            secret: b.secret, cameraPath: 'cam_packhall', nowMs: 2000),
        isTrue,
      );
    });
  });

  group('expiry', () {
    test('a ticket is dead the millisecond its TTL elapses', () {
      // Valid while now < expiresAt: the boundary belongs to the dead side,
      // so "TTL 30 s" can never mean 30.001.
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(ticket.expiresAtMs, 31000);
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 30999),
        isTrue,
      );
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 31000),
        isFalse,
      );
    });

    test('an expired ticket stays dead — validation later never revives it',
        () {
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 1000);
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 5000),
        isFalse,
      );
      expect(
        book.validate(
            secret: ticket.secret, cameraPath: 'cam_packhall', nowMs: 1500),
        isFalse,
        reason: 'once seen expired it is removed; a caller replaying an old '
            'nowMs must not find it resurrected',
      );
    });

    test('minting prunes expired tickets, so the book cannot grow unboundedly',
        () {
      // The book lives for the process. Eight tiles retrying on the 60 s
      // ladder for a weekend must not leave a weekend of dead tickets on the
      // heap; every mint sweeps what the passage of time has already killed.
      final book = CameraTicketBook();
      for (var i = 0; i < 100; i++) {
        book.mint(cameraPath: 'cam_$i', nowMs: i * 10, ttlMs: 100);
      }
      book.mint(cameraPath: 'cam_last', nowMs: 1_000_000, ttlMs: 100);
      expect(book.outstanding, 1);
    });
  });

  group('the bound', () {
    test('minting past maxOutstanding evicts the soonest-to-expire ticket',
        () {
      // Fail-closed would refuse the mint — and refuse the OPERATOR, on the
      // retry that would have brought a tile back. The soonest-to-expire
      // ticket is the one nearest death anyway, and anyone able to flood
      // mints has already been authenticated and authorised per mint, so the
      // eviction is not an unauthenticated denial lever.
      final book = CameraTicketBook(maxOutstanding: 2);
      final a = book.mint(cameraPath: 'cam_a', nowMs: 1000, ttlMs: 10000);
      final b = book.mint(cameraPath: 'cam_b', nowMs: 1000, ttlMs: 50000);
      final c = book.mint(cameraPath: 'cam_c', nowMs: 2000, ttlMs: 50000);
      expect(book.outstanding, 2);
      expect(
        book.validate(secret: a.secret, cameraPath: 'cam_a', nowMs: 3000),
        isFalse,
        reason: 'a expires at 11000, soonest of the three — evicted',
      );
      expect(
        book.validate(secret: b.secret, cameraPath: 'cam_b', nowMs: 3000),
        isTrue,
      );
      expect(
        book.validate(secret: c.secret, cameraPath: 'cam_c', nowMs: 3000),
        isTrue,
      );
    });
  });

  group('the secret', () {
    test('defaults to 64 lowercase hex characters — 256 random bits', () {
      final book = CameraTicketBook();
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(ticket.secret, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('successive mints never repeat a secret', () {
      final book = CameraTicketBook();
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(book
            .mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000)
            .secret);
      }
      expect(seen, hasLength(200));
    });

    test('the generator is injectable, so tests above this class can be '
        'deterministic', () {
      var n = 0;
      final book = CameraTicketBook(secretGenerator: () => 'secret-${n++}');
      final ticket =
          book.mint(cameraPath: 'cam_packhall', nowMs: 1000, ttlMs: 30000);
      expect(ticket.secret, 'secret-0');
      expect(
        book.validate(
            secret: 'secret-0', cameraPath: 'cam_packhall', nowMs: 2000),
        isTrue,
      );
    });
  });

  group('source pins', () {
    // The same style of pin auth_test.dart holds over file_token_validator:
    // the properties below are invisible to a black-box test, so the source
    // is the test surface.
    final source = File('lib/src/media/camera_ticket_book.dart')
        .readAsStringSync();

    test('the secret comparison is constant-time, never String ==', () {
      // `==` on String returns the moment it finds a difference, and the
      // moment it returns is the side channel. The lookup may be a map get
      // (it compares hashes first), but the confirming comparison must be
      // the fixed-time loop.
      expect(source, contains('_constantTimeEquals'));
      expect(source, isNot(contains('== ticket.secret')));
      expect(source, isNot(contains('secret == ')));
    });

    test('the book holds no policy: no AccessGroup, no tfc_access import', () {
      // The constitution's carve-out for the relay is the credential
      // mechanism ONLY. The day this file names a group it has become the
      // second policy system no_second_policy_test.dart exists to refuse.
      // The import is the pin, not the word — the doc comment legitimately
      // *talks about* the boundary it must not cross.
      expect(source, isNot(contains("import 'package:tfc_access")));
      expect(source, isNot(contains('AccessGroup')));
    });

    test('the book reads no clock: nowMs is always the caller\'s', () {
      expect(source, isNot(contains('DateTime.now')));
      expect(source, isNot(contains('Stopwatch')));
      expect(source, isNot(contains('Timer')));
    });
  });
}
