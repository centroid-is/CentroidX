import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:test/test.dart';

/// The rule that decides *when* an alarm transition happened.
///
/// Every arm here is deterministic on purpose. The whole point of
/// [resolveAlarmStamp] is that the receipt instant comes from an injected
/// clock rather than from `DateTime.now()`, so a test can state both the
/// plant's instant and the backend's and assert which one won. A real clock
/// in this file would make the skew arms flake and would prove nothing about
/// the fallback.
///
/// D-1 (max, not min), D-2 (labelled fallback, never silent), CD-3 (60 s skew
/// default, reported and never clamped).

/// A [DateTime Function] that counts how often it was read.
class _CountingClock {
  _CountingClock(this.instant);

  final DateTime instant;
  int calls = 0;

  DateTime call() {
    calls++;
    return instant;
  }
}

void main() {
  // The backend's receipt instant for every arm below.
  final receipt = DateTime.utc(2026, 9, 6, 12, 0, 0);

  group('resolveAlarmStamp picks the newest plant instant', () {
    test('max, not min -- the newest of three source times wins', () {
      final clock = _CountingClock(receipt);
      final t1 = DateTime.utc(2026, 9, 6, 11, 50, 0);
      final t2 = DateTime.utc(2026, 9, 6, 11, 55, 0);
      final t3 = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final stamp = resolveAlarmStamp(
        // Deliberately out of order: the rule must not depend on arrival
        // order, only on the instants themselves.
        sourceTimes: [t2, t3, t1],
        clock: clock.call,
      );

      expect(stamp.at, t3,
          reason: 'a conjunction becomes true when the LAST condition does; '
              'min would stamp an alarm that started this minute with the '
              'instant of the last PLC restart');
      expect(stamp.source, AlarmTsSource.plant);
    });

    test('a single source time is that source time', () {
      final clock = _CountingClock(receipt);
      final t = DateTime.utc(2026, 9, 6, 11, 59, 45);

      final stamp = resolveAlarmStamp(sourceTimes: [t], clock: clock.call);

      expect(stamp.at, t);
      expect(stamp.source, AlarmTsSource.plant);
    });
  });

  group('resolveAlarmStamp falls back, labelled', () {
    test('one null poisons the set -- the receipt instant, labelled', () {
      final clock = _CountingClock(receipt);
      final t1 = DateTime.utc(2026, 9, 6, 11, 50, 0);
      final t3 = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final stamp = resolveAlarmStamp(
        sourceTimes: [t1, null, t3],
        clock: clock.call,
      );

      expect(stamp.at, receipt,
          reason: 'a max over a set with an unknown member is not a plant '
              'instant, however many known members it has');
      expect(stamp.source, AlarmTsSource.backendReceipt);
    });

    test('an empty set is a receipt stamp, not an exception', () {
      final clock = _CountingClock(receipt);

      final stamp = resolveAlarmStamp(
        sourceTimes: const <DateTime?>[],
        clock: clock.call,
      );

      expect(stamp.at, receipt,
          reason: 'a literal-only formula binds nothing; refusing to stamp '
              'means refusing to record the alarm');
      expect(stamp.source, AlarmTsSource.backendReceipt);
    });
  });

  group('AlarmTsSource wire names', () {
    // These strings go into the alarm_history.ts_source column and onto the
    // wire. A rename that kept the enum name would be silent, and a stop
    // analysis reading old rows would not notice.
    test('the wire names are exactly plant and backend_receipt', () {
      expect(AlarmTsSource.plant.wireName, 'plant');
      expect(AlarmTsSource.backendReceipt.wireName, 'backend_receipt');
    });
  });

  group('resolveAlarmStamp reports skew and never clamps it', () {
    test('a source time 5 minutes in the future is written unchanged', () {
      final clock = _CountingClock(receipt);
      final ahead = receipt.add(const Duration(minutes: 5));
      final skews = <Duration>[];
      final offenders = <DateTime>[];

      final stamp = resolveAlarmStamp(
        sourceTimes: [ahead],
        clock: clock.call,
        onSkew: (skew, sourceTime) {
          skews.add(skew);
          offenders.add(sourceTime);
        },
      );

      expect(stamp.at, ahead,
          reason: 'clamping to the receipt instant would hide a real PLC '
              'clock fault, which is the class of thing this milestone '
              'exists to make visible');
      expect(stamp.source, AlarmTsSource.plant);
      expect(skews, [const Duration(minutes: 5)],
          reason: 'reported once, with the signed magnitude');
      expect(offenders, [ahead]);
    });

    test('a source time 5 minutes in the past reports a negative skew', () {
      final clock = _CountingClock(receipt);
      final behind = receipt.subtract(const Duration(minutes: 5));
      final skews = <Duration>[];

      final stamp = resolveAlarmStamp(
        sourceTimes: [behind],
        clock: clock.call,
        onSkew: (skew, _) => skews.add(skew),
      );

      expect(stamp.at, behind);
      expect(skews, [const Duration(minutes: -5)],
          reason: 'the sign says which way the PLC clock is wrong');
    });

    test('a source time 30 s away is inside the default and is not reported',
        () {
      final clock = _CountingClock(receipt);
      final near = receipt.add(const Duration(seconds: 30));
      var called = 0;

      final stamp = resolveAlarmStamp(
        sourceTimes: [near],
        clock: clock.call,
        onSkew: (_, __) => called++,
      );

      expect(stamp.at, near);
      expect(called, 0, reason: 'CD-3 sets the default threshold at 60 s');
    });

    test('the threshold is a parameter, and it bites', () {
      final clock = _CountingClock(receipt);
      final near = receipt.add(const Duration(seconds: 30));
      var called = 0;

      final stamp = resolveAlarmStamp(
        sourceTimes: [near],
        clock: clock.call,
        skewWarnAfter: const Duration(seconds: 10),
        onSkew: (_, __) => called++,
      );

      expect(stamp.at, near);
      expect(called, 1);
    });

    test('the fallback path does not report skew', () {
      final clock = _CountingClock(receipt);
      var called = 0;

      resolveAlarmStamp(
        sourceTimes: [null],
        clock: clock.call,
        onSkew: (_, __) => called++,
      );

      expect(called, 0,
          reason: 'there is no plant instant to disagree with the clock');
    });
  });

  group('the clock is read once', () {
    test('exactly one read on the plant path', () {
      final clock = _CountingClock(receipt);

      resolveAlarmStamp(
        sourceTimes: [receipt.subtract(const Duration(seconds: 1))],
        clock: clock.call,
      );

      expect(clock.calls, 1,
          reason: 'two reads of a real clock are two different instants; '
              'the skew check and the fallback must judge against the same '
              'receipt');
    });

    test('exactly one read on the fallback path', () {
      final clock = _CountingClock(receipt);

      resolveAlarmStamp(sourceTimes: const <DateTime?>[], clock: clock.call);

      expect(clock.calls, 1);
    });
  });

  group('AlarmStamp is a value', () {
    test('two stamps with the same instant and source are equal', () {
      expect(
        AlarmStamp(at: receipt, source: AlarmTsSource.plant),
        AlarmStamp(at: receipt, source: AlarmTsSource.plant),
      );
      expect(
        AlarmStamp(at: receipt, source: AlarmTsSource.plant).hashCode,
        AlarmStamp(at: receipt, source: AlarmTsSource.plant).hashCode,
      );
      expect(
        AlarmStamp(at: receipt, source: AlarmTsSource.plant),
        isNot(AlarmStamp(at: receipt, source: AlarmTsSource.backendReceipt)),
      );
    });

    test('toString shows both the instant and the provenance', () {
      final s = AlarmStamp(at: receipt, source: AlarmTsSource.backendReceipt);
      expect(s.toString(), contains(receipt.toIso8601String()));
      expect(s.toString(), contains('backend_receipt'));
    });
  });
}
