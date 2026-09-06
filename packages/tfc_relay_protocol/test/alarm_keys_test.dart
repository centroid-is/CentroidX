import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The `ALARM.` namespace is only worth reserving if it is reserved by *rule*
/// and spelled *once*. These arms judge both directly, on the shape
/// `pipe_keys_test.dart` established: literals for the names that reach a
/// deployment, a prefix test for a key nobody has invented yet, and the
/// trailing dot pinned so a plant area called `ALARMS` is not swallowed.
void main() {
  group('the reserved namespace', () {
    test('the prefix is exactly the documented spelling', () {
      // Asserted against a literal, not against itself. The freshness sweep
      // and the backend's declared key list both test with this constant, so
      // an arm that compared it to `AlarmKeys.prefix` would pass for every
      // possible value of it — including a respelling that silently stops
      // matching every deployment.
      expect(AlarmKeys.prefix, 'ALARM.');
    });

    test('the active-set key is exactly the documented spelling', () {
      // Matched by configuration out in the plant and bound by panels. A
      // second spelling compiles, keeps every suite green, and quietly stops
      // matching — the argument `pipe_keys.dart` is a whole file about.
      expect(AlarmKeys.active, 'ALARM.active');
    });

    test('the active-set key is inside its own namespace', () {
      expect(AlarmKeys.isAlarmKey(AlarmKeys.active), isTrue,
          reason: 'a name that escaped its own prefix is a key the freshness '
              'exclusion will not skip and the ingest will not reserve');
    });

    test('isAlarmKey is a prefix test, never a roster lookup', () {
      // The distinction is the mechanism, exactly as for `PIPE.`: a key
      // invented in a later phase must be swept correctly and reserved
      // correctly on the day it is invented, with no edit to this file.
      expect(AlarmKeys.isAlarmKey('ALARM.invented_next_year'), isTrue);
      expect(AlarmKeys.isAlarmKey('ALARM.shelved'), isTrue);
    });

    test('the trailing dot is load-bearing', () {
      // A plant area called ALARMS must not be reserved wholesale — every tag
      // under it would be excluded from the freshness sweep, which is the
      // "grey means nothing" failure inverted: a whole area that can never go
      // stale however long it has been silent.
      expect(AlarmKeys.isAlarmKey('ALARMS.tank'), isFalse);
      expect(AlarmKeys.isAlarmKey('ALARMS.tank.level'), isFalse);
    });

    test('an ordinary plant tag is not in the namespace', () {
      expect(AlarmKeys.isAlarmKey('ST101.CN01.MOT01.speed'), isFalse);
      expect(AlarmKeys.isAlarmKey('ST101.CN01.MOT01.alarm'), isFalse,
          reason: 'the prefix anchors at the start; a tag that merely '
              'contains the word is plant telemetry');
    });
  });

  group('agreement with the PIPE. namespace', () {
    test('neither prefix is a prefix of the other', () {
      // Two reserved namespaces that overlapped would give every skip site in
      // the workspace two answers for one key, and which one wins would
      // depend on the order the conditions were written in.
      expect(AlarmKeys.prefix.startsWith(PipeKeys.prefix), isFalse);
      expect(PipeKeys.prefix.startsWith(AlarmKeys.prefix), isFalse);
      expect(AlarmKeys.prefix, isNot(PipeKeys.prefix));
    });

    test('each namespace refuses the other namespace\'s keys', () {
      // The sweep sites carry `isPipeKey(key) || isAlarmKey(key)`. If either
      // predicate answered for the other's keys the two conditions would be
      // one condition, and removing the wrong half would look harmless.
      expect(AlarmKeys.isAlarmKey(PipeKeys.connected), isFalse);
      expect(AlarmKeys.isAlarmKey(PipeKeys.certDaysToExpiry), isFalse);
      expect(PipeKeys.isPipeKey(AlarmKeys.active), isFalse);
      expect(PipeKeys.isPipeKey(AlarmKeys.prefix), isFalse);
    });

    test('an ALARM. key is never promoted onto the never-conflated lane', () {
      // `ridesPriorityLane` guards on the `PIPE.` namespace first. The active
      // set is a snapshot that can carry hundreds of entries; unconflated it
      // is a queue, which the core value forbids outright.
      expect(PipeKeys.ridesPriorityLane(AlarmKeys.active), isFalse);
    });

    test('aliasOf never reads an ALARM. key as an upstream link', () {
      expect(PipeKeys.aliasOf(AlarmKeys.active), isNull);
    });
  });

  group('the barrel', () {
    test('resolves AlarmKeys without reaching into src/', () {
      // This file imports only `package:tfc_relay_protocol/tfc_relay_protocol.dart`.
      // If the export were missing this arm would not compile, and the
      // `expect` keeps it from being a comment: an unexported constant is a
      // constant every consumer respells by hand.
      expect(AlarmKeys.active, isNotEmpty);
      expect(AlarmKeys.prefix, isNotEmpty);
    });
  });
}
