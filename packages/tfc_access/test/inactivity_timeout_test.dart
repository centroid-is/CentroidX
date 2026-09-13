/// The per-account inactivity timeout: what a stored number means, and what
/// the two ends of the range are for.
///
/// The one rule worth a file of its own is the null one. NULL in
/// `app_user.inactivity_timeout_minutes` means "no value of its own" and
/// resolves to the default — it does **not** mean "never expires". Only
/// `stationAccount` produces a session that never ends, and
/// [resolveInactivityTimeout]'s signature is what makes that unforgeable: it
/// cannot return null, so no stored number, however mangled, mints an immortal
/// human session.
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

void main() {
  group('resolveInactivityTimeout', () {
    test('null is the default, not "never"', () {
      expect(resolveInactivityTimeout(null), kDefaultInactivityTimeout);
    });

    test('a value in range passes through', () {
      expect(resolveInactivityTimeout(45), const Duration(minutes: 45));
      expect(resolveInactivityTimeout(kMinInactivityTimeout.inMinutes),
          kMinInactivityTimeout);
      expect(resolveInactivityTimeout(kMaxInactivityTimeout.inMinutes),
          kMaxInactivityTimeout);
    });

    test('zero and negatives clamp up to the one-minute floor', () {
      // Only reachable by editing the column with `psql` — the dialog and the
      // repository both refuse these. A session that ends the instant it
      // begins is a fault, not a tighter guard.
      expect(resolveInactivityTimeout(0), kMinInactivityTimeout);
      expect(resolveInactivityTimeout(-5), kMinInactivityTimeout);
    });

    test('an absurd value clamps down to the eight-hour ceiling', () {
      expect(resolveInactivityTimeout(100000), kMaxInactivityTimeout);
    });
  });

  group('isValidInactivityTimeoutMinutes', () {
    test('accepts the range the dialog offers, inclusive', () {
      expect(isValidInactivityTimeoutMinutes(kMinInactivityTimeout.inMinutes),
          isTrue);
      expect(isValidInactivityTimeoutMinutes(45), isTrue);
      expect(isValidInactivityTimeoutMinutes(kMaxInactivityTimeout.inMinutes),
          isTrue);
    });

    test('refuses either side of it', () {
      expect(isValidInactivityTimeoutMinutes(0), isFalse);
      expect(isValidInactivityTimeoutMinutes(-1), isFalse);
      expect(
          isValidInactivityTimeoutMinutes(kMaxInactivityTimeout.inMinutes + 1),
          isFalse);
    });
  });
}
