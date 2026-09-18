/// The clock offset captured at hello, and what happens when it is absurd.
///
/// Source: 04-RESEARCH Finding 5b, executed against the real gateway.
/// `hello.serverTime = 1786711225713` with local `1786711225765` at the same
/// instant — 52 ms of skew, same machine. `tick.serverTime` tracked wall clock
/// exactly across a 7 s wait, and `SubTick.evaluatedAt` came back the same
/// magnitude. CR-04 (STATE.md line 79) is the ruling that makes this arithmetic
/// legal at all: the wire carries wall-clock epoch milliseconds everywhere, and
/// the gateway's internal measurement stays monotonic behind that.
///
/// So: `clockOffset = localNowMs - hello.serverTime`, captured at each hello,
/// and every staleness judgement in this package is made in the **server's**
/// clock.
///
/// What breaks in the plant otherwise. Panels in a fish factory are ordinary
/// machines in a wet, cold room; one of them will have a dead CMOS battery and
/// boot thinking it is 2016. If freshness were judged against that panel's own
/// clock, every value on it would be hours stale the moment it connected — the
/// whole screen grey, the operator blind, and nothing wrong with the plant.
/// CLI-05 is that a wrong local clock is a **warning**, never a grey plant, and
/// the case named `an implausible clock warns and keeps measuring staleness
/// against the server` is the one that bites an implementation which "fell
/// back to the local clock to be safe".
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/clock_offset.dart';

/// The two numbers Finding 5b measured, kept as the literals that were
/// observed rather than as round ones.
const int _measuredServerTime = 1786711225713;
const int _measuredLocalNow = 1786711225765;

void main() {
  group('a healthy pair of clocks', () {
    test('the offset is local now minus the server time at hello', () {
      final offset = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredLocalNow,
        threshold: const Duration(minutes: 5),
      );

      expect(offset.offsetMs, 52,
          reason: 'the sign matters: adding the offset to a server stamp has '
              'to give a local one, and Finding 5b measured local as the '
              'larger of the two');
      expect(offset.implausible, isFalse);
      expect(offset.warning, isNull);
    });

    test('a server stamp round-trips through both directions', () {
      final offset = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredLocalNow,
        threshold: const Duration(minutes: 5),
      );

      const int evaluatedAt = 1786711225813; // SubTick.evaluatedAt, Finding 5b.

      expect(offset.toLocal(evaluatedAt), evaluatedAt + 52);
      expect(
        offset.toServer(offset.toLocal(evaluatedAt)),
        evaluatedAt,
        reason: 'the conversion is used on every value the freshness watchdog '
            'looks at; a lossy one would drift the whole page towards stale',
      );
    });

    test('clocks that agree exactly give a zero offset', () {
      final offset = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredServerTime,
        threshold: const Duration(minutes: 5),
      );

      expect(offset.offsetMs, 0);
      expect(offset.implausible, isFalse);
    });
  });

  group('a panel whose own clock is wrong', () {
    test('an implausible clock warns and keeps measuring staleness against '
        'the server', () {
      // A dead CMOS battery: the panel boots ten years behind the gateway.
      const int localNow = _measuredServerTime - 315360000000;
      final offset = ClockOffset.fromHello(
        _measuredServerTime,
        localNow,
        threshold: const Duration(minutes: 5),
      );

      expect(offset.implausible, isTrue);
      expect(
        offset.warning,
        isNotNull,
        reason: 'the integrator has to be told the panel needs its clock set, '
            'or the warning is only ever a mystery in a log',
      );
      expect(
        offset.offsetMs,
        -315360000000,
        reason: 'the offset is still the measured difference — an '
            'implementation that zeroed it here, or fell back to the local '
            'clock "to be safe", would make every value on this panel read as '
            'ten years stale and grey the entire plant on a screen whose only '
            'fault is a dead battery',
      );
      expect(
        offset.toServer(localNow),
        _measuredServerTime,
        reason: 'staleness is judged in the server\'s clock, so a local stamp '
            'has to convert back to the gateway\'s idea of now even when the '
            'local clock is absurd',
      );
    });

    test('the threshold is the line, and it is inclusive of what is under it',
        () {
      final justInside = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredServerTime + 5000,
        threshold: const Duration(seconds: 5),
      );
      final justOutside = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredServerTime + 5001,
        threshold: const Duration(seconds: 5),
      );

      expect(justInside.implausible, isFalse);
      expect(justOutside.implausible, isTrue);
    });

    test('a panel running ahead is as implausible as one running behind', () {
      final ahead = ClockOffset.fromHello(
        _measuredServerTime,
        _measuredServerTime + 3600000,
        threshold: const Duration(minutes: 5),
      );

      expect(
        ahead.implausible,
        isTrue,
        reason: 'the check is on the magnitude; a panel an hour ahead is as '
            'wrong as one an hour behind and the operator needs telling either '
            'way',
      );
      expect(ahead.warning, contains('ahead'));
    });
  });
}
