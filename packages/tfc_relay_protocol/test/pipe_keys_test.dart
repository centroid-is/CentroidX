import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The vocabulary is only worth having if it is the *only* spelling. These
/// arms judge that property directly: every declared name is in the reserved
/// namespace, the two lanes partition the roster by set arithmetic rather than
/// by a second hand-written list, and the per-alias builders round-trip the
/// alias they were given.
void main() {
  // A never-before-seen alias, deliberately not one of the plant's four, so
  // that anything answering correctly for it is answering by rule rather than
  // by having the name written down somewhere.
  const aliases = ['ST101', 'ST201', 'ST301', 'baader', 'bench-rig-7'];

  List<String> Function(String) allBuilders() => (alias) => [
        PipeKeys.upstreamConnected(alias),
        PipeKeys.upstreamState(alias),
        PipeKeys.upstreamLastError(alias),
        PipeKeys.upstreamEpoch(alias),
        PipeKeys.upstreamBirthCount(alias),
        PipeKeys.upstreamLastDeathAt(alias),
        PipeKeys.upstreamDataAgeMs(alias),
      ];

  group('the reserved namespace', () {
    test('the roster is not empty', () {
      // Anti-vacuity, first: every sweep below iterates `declared`, and a
      // sweep over an empty list passes against nothing.
      expect(PipeKeys.declared, isNotEmpty);
      expect(PipeKeys.declared.length, PipeKeys.declared.toSet().length,
          reason: 'a duplicate in the roster would make the partition '
              'arithmetic below pass while one lane silently held two copies '
              'of the same key');
    });

    test('every declared key starts with the prefix', () {
      for (final key in PipeKeys.declared) {
        expect(key.startsWith(PipeKeys.prefix), isTrue,
            reason: '$key is not in the reserved namespace, which means the '
                'freshness sweep will not skip it (HLTH-02), the keymapping '
                'ingest will not reserve it (HLTH-03), and nothing will ever '
                'route it — a roster entry that forgot the prefix is a key '
                'that does not exist');
      }
    });

    test('every key a builder mints starts with the prefix', () {
      for (final alias in aliases) {
        for (final key in allBuilders()(alias)) {
          expect(key.startsWith(PipeKeys.prefix), isTrue, reason: key);
        }
      }
    });

    test('isPipeKey is a prefix test, never a roster lookup', () {
      // The distinction is the whole design of HLTH-03: a key invented in a
      // later phase must be reserved on the day it is invented, without an
      // edit here. A roster lookup would leave every new health key
      // unreserved and unswept until somebody remembered to add it.
      expect(PipeKeys.isPipeKey('PIPE.invented_next_year'), isTrue);
      expect(PipeKeys.declared, isNot(contains('PIPE.invented_next_year')),
          reason: 'the point of the previous line is that it answers true for '
              'a key the roster has never heard of');

      expect(PipeKeys.isPipeKey('ST101.CN01.MOT01.speed'), isFalse);
      expect(PipeKeys.isPipeKey('PIPES.connected'), isFalse,
          reason: 'the prefix carries its dot, so a plant area called PIPES '
              'is not accidentally reserved wholesale');
    });
  });

  group('the per-alias builders', () {
    test('build the documented spelling', () {
      expect(PipeKeys.upstreamConnected('st101'), 'PIPE.upstream.st101.connected');
      expect(PipeKeys.upstreamState('st101'), 'PIPE.upstream.st101.state');
      expect(PipeKeys.upstreamLastError('st101'), 'PIPE.upstream.st101.last_error');
      expect(PipeKeys.upstreamEpoch('st101'), 'PIPE.upstream.st101.epoch');
      expect(
          PipeKeys.upstreamBirthCount('st101'), 'PIPE.upstream.st101.birth_count');
      expect(PipeKeys.upstreamLastDeathAt('st101'),
          'PIPE.upstream.st101.last_death_at');
      expect(PipeKeys.upstreamDataAgeMs('st101'),
          'PIPE.upstream.st101.data_age_ms');
    });

    test('round-trip the alias through aliasOf', () {
      for (final alias in aliases) {
        for (final key in allBuilders()(alias)) {
          expect(PipeKeys.aliasOf(key), alias,
              reason: '$key must name $alias back. The per-link health '
                  'producer reads the alias out of the key to attribute a '
                  'degradation to one PLC; a key it cannot parse degrades '
                  'nothing, or everything');
        }
      }
    });

    test('aliasOf is null for anything that is not an upstream key', () {
      for (final notUpstream in [
        PipeKeys.connected,
        PipeKeys.epoch,
        PipeKeys.certDaysToExpiry,
        PipeKeys.eventLoopLagMs,
        'ST101.CN01.MOT01.speed',
        'PIPE.upstream.st101', // truncated: no field
        'PIPE.upstream.st101.connected.extra', // one segment too many
      ]) {
        expect(PipeKeys.aliasOf(notUpstream), isNull, reason: notUpstream);
      }
    });

    test('an alias that would mint an unparseable key is refused', () {
      // Rule-2 guard rather than plan text: the key is dot-delimited, so an
      // alias carrying a dot produces a name `aliasOf` reads back as null.
      // That is precisely the "key nothing will ever route" this file exists
      // to prevent, and it is cheaper to refuse it at the mint than to
      // diagnose a link whose health keys attribute to no link.
      expect(() => PipeKeys.upstreamConnected('st101.plc'),
          throwsA(isA<ArgumentError>()));
      expect(() => PipeKeys.upstreamState(''), throwsA(isA<ArgumentError>()));
    });
  });

  group('the priority / conflated split', () {
    test('the two lanes partition the declared roster', () {
      final roster = PipeKeys.declared.toSet();

      expect(PipeKeys.priorityLane.union(PipeKeys.conflatedLane), roster,
          reason: 'a declared key in neither lane is a key the send buffer '
              'has no rule for');
      expect(PipeKeys.priorityLane.intersection(PipeKeys.conflatedLane), isEmpty,
          reason: 'a key in both lanes is delivered twice by two different '
              'disciplines, and the conflated copy can overtake the priority '
              'one');
    });

    test('state changes ride the priority lane', () {
      // "A degraded link must still deliver the news that it is degraded" —
      // that is the news, not the telemetry.
      for (final key in [
        PipeKeys.connected,
        PipeKeys.epoch,
        PipeKeys.linkDegraded,
        PipeKeys.upstreamConnected('ST201'),
        PipeKeys.upstreamState('ST201'),
        PipeKeys.upstreamLastError('ST201'),
        PipeKeys.upstreamEpoch('ST201'),
        PipeKeys.upstreamBirthCount('ST201'),
        PipeKeys.upstreamLastDeathAt('ST201'),
      ]) {
        expect(PipeKeys.ridesPriorityLane(key), isTrue, reason: key);
      }
    });

    test('gauges ride the conflated lane', () {
      // An unconflated fast-moving gauge is a queue, which the core value
      // forbids outright.
      for (final key in [
        PipeKeys.rttMs,
        PipeKeys.dataAgeMs,
        PipeKeys.reconnects,
        PipeKeys.effectiveHz,
        PipeKeys.egressKbps,
        PipeKeys.pendingKeys,
        PipeKeys.eventLoopLagMs,
        PipeKeys.droppedHoldTicks,
        PipeKeys.certDaysToExpiry,
        // 08-09's addition. It needed no edit to the suffix rule and that is
        // the point of the rule: a gauge added later is filed on the conflated
        // lane by the shape of its name, and putting it on the never-conflated
        // one would have made a fast-moving number into a queue.
        PipeKeys.upstreamDataAgeMs('ST201'),
      ]) {
        expect(PipeKeys.ridesPriorityLane(key), isFalse, reason: key);
      }
    });

    test('the lane sets and the suffix rule cannot disagree', () {
      // There are two mechanisms here — the declared sets, which the send
      // buffer can read at startup, and `ridesPriorityLane`, which is what a
      // per-alias key has to be judged by. They agree today. Nothing above
      // makes them *keep* agreeing: a key added to `priorityLane` whose suffix
      // says conflated leaves the partition intact and appears in neither
      // hand-written list, so every other arm in this group still passes while
      // one key is filed two different ways depending on which side of the
      // send buffer is asking. That is the drift this file exists to prevent,
      // wearing a different hat.
      expect(PipeKeys.declared.where(PipeKeys.ridesPriorityLane).toSet(),
          PipeKeys.priorityLane);
      expect(
          PipeKeys.declared
              .where((k) => !PipeKeys.ridesPriorityLane(k))
              .toSet(),
          PipeKeys.conflatedLane);
    });

    test('the lane is decided by suffix, so a new alias needs no edit here',
        () {
      // `bench-rig-7` appears in no list in the library. If this passes, the
      // rule is doing the work.
      expect(PipeKeys.ridesPriorityLane('PIPE.upstream.bench-rig-7.connected'),
          isTrue);
      expect(PipeKeys.ridesPriorityLane('PIPE.upstream.bench-rig-7.rtt_ms'),
          isFalse);
    });

    test('a plant key never rides the priority lane on a matching suffix', () {
      // `ST101.CN01.MOT01.connected` ends in a priority suffix and is an
      // ordinary tag. Promoting it would put plant telemetry on the lane that
      // is never conflated.
      expect(PipeKeys.ridesPriorityLane('ST101.CN01.MOT01.connected'), isFalse);
      expect(PipeKeys.ridesPriorityLane('ST101.CN01.MOT01.state'), isFalse);
    });
  });

  group('the collect keys (8b-01)', () {
    test('the six spellings', () {
      // Matched by AlarmMan configuration and read by panels; a respelling
      // compiles, keeps every suite green, and quietly stops matching —
      // the argument of this whole file, applied to the historian.
      expect(PipeKeys.collectEnabled, 'PIPE.collect.enabled');
      expect(PipeKeys.collectConnected, 'PIPE.collect.connected');
      expect(PipeKeys.collectRowsWritten, 'PIPE.collect.rows_written');
      expect(PipeKeys.collectRowsDropped, 'PIPE.collect.rows_dropped');
      expect(PipeKeys.collectQueuedRows, 'PIPE.collect.queued_rows');
      expect(PipeKeys.collectLastError, 'PIPE.collect.last_error');
    });

    test('all six are on the declared roster', () {
      // Per-plant facts on LocalStateMan (08-CONTEXT ruling 9's two homes):
      // one historian per gateway, so unlike the per-alias builders these
      // ARE a finite roster and belong on the declared list, where the
      // partition arithmetic above can see them.
      for (final key in [
        PipeKeys.collectEnabled,
        PipeKeys.collectConnected,
        PipeKeys.collectRowsWritten,
        PipeKeys.collectRowsDropped,
        PipeKeys.collectQueuedRows,
        PipeKeys.collectLastError,
      ]) {
        expect(PipeKeys.declared, contains(key),
            reason: '$key off the roster is a key in neither lane — a key '
                'the send buffer has no rule for');
      }
    });

    test('news rides priority, counters conflate', () {
      // "A degraded link must still deliver the news that it is degraded"
      // — the historian's version: enabled flipping, the connection to
      // Postgres dropping, and the error naming why are the news; the
      // three row counters are telemetry a tick late costs nobody.
      for (final news in [
        PipeKeys.collectEnabled,
        PipeKeys.collectConnected,
        PipeKeys.collectLastError,
      ]) {
        expect(PipeKeys.ridesPriorityLane(news), isTrue,
            reason: '$news is the news that collection state changed; on '
                'the conflated lane it can be dropped by the very '
                'congestion a failing historian causes');
        expect(PipeKeys.priorityLane, contains(news),
            reason: 'the lane set and the suffix rule must agree on $news '
                'or the two sides of the send buffer file it differently');
      }
      for (final gauge in [
        PipeKeys.collectRowsWritten,
        PipeKeys.collectRowsDropped,
        PipeKeys.collectQueuedRows,
      ]) {
        expect(PipeKeys.ridesPriorityLane(gauge), isFalse,
            reason: '$gauge is a fast-moving counter; unconflated it is a '
                'queue, which the core value forbids outright');
        expect(PipeKeys.conflatedLane, contains(gauge));
      }
    });

    test('aliasOf never mistakes collect for an upstream alias', () {
      // `PIPE.collect.enabled` splits into four dot segments exactly like
      // `PIPE.upstream.<alias>.<field>` — but it is not in the upstream
      // namespace, and a health producer that read `collect` back as an
      // alias would attribute historian trouble to a PLC called "collect".
      for (final key in [
        PipeKeys.collectEnabled,
        PipeKeys.collectConnected,
        PipeKeys.collectRowsWritten,
        PipeKeys.collectRowsDropped,
        PipeKeys.collectQueuedRows,
        PipeKeys.collectLastError,
      ]) {
        expect(PipeKeys.aliasOf(key), isNull, reason: key);
      }
    });

    test('a plant key ending in .enabled is not promoted', () {
      // The suffix rule gains `enabled`; the namespace guard must still
      // hold or every conveyor's enable bit rides the unconflated lane.
      expect(PipeKeys.ridesPriorityLane('ST101.CN01.MOT01.enabled'), isFalse,
          reason: 'plant telemetry on the never-conflated lane is how that '
              'lane becomes a queue');
    });
  });

  group('agreement with the rest of the workspace', () {
    test('the certificate key is spelled the way every deployment spells it',
        () {
      // Moved verbatim from `cert_health_state_man.dart`, where it shipped in
      // Phase 6. The alarm configuration in the plant matches on this string;
      // a rename here compiles, keeps every suite green, and quietly stops
      // matching.
      expect(PipeKeys.certDaysToExpiry, 'PIPE.cert.days_to_expiry');
    });

    test('the five client-side keys match the reference implementation', () {
      // Asserted against literals rather than against the contract kit's
      // `FakeStateMan.healthKeys` (`fake_state_man.dart:102-107`), because
      // this package has no dependencies at all and the kit depends on *it* —
      // importing the kit here would invert the workspace. The literals are
      // the enforcement available in this direction; the roster there stays
      // at five (a sixth entry puts a key on every contract leg, including
      // the in-memory ones with no upstream and no certificate).
      expect(
        [
          PipeKeys.connected,
          PipeKeys.rttMs,
          PipeKeys.dataAgeMs,
          PipeKeys.reconnects,
          PipeKeys.epoch,
        ],
        [
          'PIPE.connected',
          'PIPE.rtt_ms',
          'PIPE.data_age_ms',
          'PIPE.reconnects',
          'PIPE.epoch',
        ],
      );
    });

    test('the prefix is the one the reference implementation reserves', () {
      expect(PipeKeys.prefix, 'PIPE.');
    });

    test('a field spelled at two scopes is spelled the same way at both', () {
      // Three fields exist twice: once about the pipe (`PIPE.connected`) and
      // once about one PLC (`PIPE.upstream.st101.connected`). They are
      // different facts and both are wanted — but they are the same *word*,
      // and this file's whole argument is that a word has one spelling. A
      // client-side `data_age_ms` beside a per-link `dataAgeMs` would compile,
      // keep every suite green, and read as two unrelated fields on a page
      // that shows both.
      //
      // 08-09 added the seventh builder and this arm is what stops it drifting
      // from the client-side key of the same name.
      const alias = 'st101';
      for (final pair in <(String, String)>[
        (PipeKeys.connected, PipeKeys.upstreamConnected(alias)),
        (PipeKeys.epoch, PipeKeys.upstreamEpoch(alias)),
        (PipeKeys.dataAgeMs, PipeKeys.upstreamDataAgeMs(alias)),
      ]) {
        expect(pair.$2.split('.').last, pair.$1.split('.').last,
            reason: '${pair.$1} and ${pair.$2} name the same field at two '
                'scopes and must end in the same word');
      }
    });
  });
}
