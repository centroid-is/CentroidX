/// The behaviour every `UpstreamLink` owes its caller, driven only through the
/// interface.
///
/// [runUpstreamLinkContract] takes the subject as a factory rather than naming
/// `FakeUpstreamLink`, because **the real adapters run this same group**: the
/// OPC UA link (08-07) against an in-process `Server`, the Modbus/UMAS and
/// M2400 links (08-10) against their stubs. A case written here is a case all
/// four implementations are judged by, which is the same bargain
/// `tfc_stateman_contract` strikes for `StateManApi` one layer up.
///
/// The levers the cases need are not on `UpstreamLink` — they are how the
/// *plant* is made to misbehave, and a production link must never expose them.
/// They come from [UpstreamLinkDriver], obtained through [driverOf], which
/// fails with a message rather than a cast error for the reason `harnessOf`
/// does (`harness.dart:143-147`): an implementation that arrives without a
/// control surface should be told what to add, not handed a `_CastError`
/// naming a line in somebody else's package.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';

/// The two fixture keys every subject must serve, in the plant's own
/// `AREAnn.DEVnn.SUBnn` spelling (`browse_contract.dart:111-118` speaks it
/// too, and project memory records CN01–CN20 as the pre-freezer run).
const String speedKey = 'ST101.CN01.MOT01.speed';
const String setpointKey = 'ST101.CN01.MOT01.setpoint';

/// A key no subject serves. `resolve` must answer null for it rather than
/// throwing — that null is what lets 08-04's router try the next link without
/// knowing a single protocol.
const String foreignKey = 'ST999.CN99.MOT99.setpoint';

/// The keys a subject is constructed with.
const List<String> contractFixtureKeys = <String>[speedKey, setpointKey];

/// Stands in for the configured keymapping entry. Opaque to the contract: what
/// it holds is the adapter's business, and the loose `Object` is deliberate
/// until the typed mapping entry exists (08-CONTEXT's recorded NIT).
const Map<String, Object?> fixtureMapping = <String, Object?>{};

/// Generous, because none of these cases is a latency measurement. The two
/// cases that *are* about a deadline set their own.
const Duration generousDeadline = Duration(seconds: 5);

/// The [UpstreamLinkDriver] side of [link], or a failure saying what is
/// missing.
UpstreamLinkDriver driverOf(UpstreamLink link) {
  // An explicit cast, not a promotion, for `harnessOf`'s reason
  // (`harness.dart:139-143`): `UpstreamLinkDriver` is not a subtype of
  // `UpstreamLink`, and Dart promotes only towards subtypes. The `is` test is
  // what makes the cast safe, and what turns the failure into the message
  // below instead of a `_CastError`.
  if (link is UpstreamLinkDriver) return link as UpstreamLinkDriver;
  fail('${link.runtimeType} does not implement UpstreamLinkDriver, so no case '
      'in this group can make a value arrive for it or make its link drop. An '
      'UpstreamLink under test must expose the test-only control surface '
      'declared in test/support/fake_upstream_link.dart.');
}

void main() {
  runUpstreamLinkContract(
    'FakeUpstreamLink',
    () => FakeUpstreamLink(alias: 'ST101', keys: contractFixtureKeys),
  );

  // Not part of the per-subject contract: one shared function, tested once.
  group('redactUpstreamError', () {
    test('takes the credentials out with the endpoint', () {
      final out = redactUpstreamError(
          'connect failed: opc.tcp://svc:hunter2@10.104.29.11:4840/ua/server');

      expect(out, isNot(contains('hunter2')),
          reason: 'the password rode in on the endpoint userinfo, which is '
              'where a real open62541 connect error puts it — and 08-09 makes '
              'this string a value any panel can subscribe to (T-08-08)');
      expect(out, isNot(contains('10.104.29.11')));
      expect(out, contains('<endpoint>'),
          reason: 'the redacted form must still say what kind of thing was '
              'removed, or the diagnostic is worthless');
    });

    test('takes certificate paths out, on both platforms', () {
      expect(redactUpstreamError('cannot read /etc/centroid/certs/client.pem'),
          isNot(contains('client.pem')));
      expect(redactUpstreamError(r'cannot read C:\centroid\certs\client.pfx'),
          isNot(contains('client.pfx')));
    });

    test('takes a bare host out', () {
      expect(redactUpstreamError('SocketException: address = 10.104.29.71:502'),
          isNot(contains('10.104.29.71')));
    });

    test('WR-11: takes an IPv6 literal out, in both of the shapes dart:io '
        'writes them', () {
      // The plant's own addressing. `dart:io` puts the peer into its
      // SocketException messages, and 08-09 turns lastError into
      // PIPE.upstream.<alias>.last_error — a key any unprivileged panel may
      // subscribe to. Plant topology is what T-08-08 is about.
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

    test('WR-11: takes a DNS hostname out, which is a name for a machine as '
        'much as an address is', () {
      // No port literal in the sample: freeze 5 sweeps test files for
      // hard-coded ports and cannot tell a listening port from a word in a
      // string, and the hostname is what this case is about.
      final out = redactUpstreamError(
          'SocketException: Failed host lookup, address = st101.svn.local')!;

      expect(out, isNot(contains('st101.svn.local')),
          reason: 'a hostname names the PLC and the site as clearly as its '
              'address does, and the redactor is documented as deliberately '
              'over-broad — missing one costs plant topology on a key every '
              'panel can read');
      expect(out, contains('<host>'));
      expect(out, contains('Failed host lookup'),
          reason: 'and the part that says what went wrong survives, or the '
              'key is useless to the engineer it exists for');
    });

    test('WR-11: a clock time is not an IPv6 address', () {
      // The over-broad rule still has to stop somewhere: `09:49:57` is two
      // colons and a lot of hex digits, and redacting every timestamp would
      // make last_error unreadable for the sake of nothing.
      final out = redactUpstreamError('at 09:49:57 the session dropped')!;
      expect(out, contains('09:49:57'));
    });

    test('takes a credential out even without a scheme in front of it', () {
      final out =
          redactUpstreamError('rejected (username=admin password=s3cr3t)');

      expect(out, isNot(contains('s3cr3t')));
      expect(out, isNot(contains('admin')));
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
      //
      // It was written against the constant until 18-02, and 18-02's sabotage
      // pass caught it: raising the cap to 20000 left this arm GREEN, because
      // the assertion moved with the constant and asserted the mutation
      // against itself. An arm that cannot fail when the thing it names gets
      // worse is not pinning that thing. The number being pinned is 200.
      expect(out.length, lessThanOrEqualTo(201),
          reason: 'a link flapping under a verbose stack trace would otherwise '
              'push kilobytes per event at every subscriber of '
              'PIPE.upstream.<alias>.last_error');
    });

    test('passes null through', () {
      // A link that has never failed has no error, and inventing "" for it
      // would read as an error whose message nobody wrote down.
      expect(redactUpstreamError(null), isNull);
    });
  });
}

/// The contract, run against one subject.
void runUpstreamLinkContract(String subject, UpstreamLink Function() newLink) {
  group('$subject: the UpstreamLink contract', () {
    late UpstreamLink link;
    late UpstreamLinkDriver drive;

    setUp(() async {
      link = newLink();
      drive = driverOf(link);
      // The link constructs cheaply and connects on demand
      // (`state_man.dart:1292-1293`'s division), so every case connects first.
      await link.connect(deadline: generousDeadline);
    });

    tearDown(() async {
      await link.dispose();
    });

    UpstreamRef refFor(String key) {
      final ref = link.resolve(key, fixtureMapping);
      expect(ref, isNotNull, reason: 'the subject does not claim $key');
      return ref!;
    }

    group('resolve', () {
      test('claims its own keys and stamps them with the current epoch', () {
        final ref = refFor(speedKey);

        expect(ref.key, speedKey);
        expect(ref.alias, link.alias);
        expect(ref.epoch, link.epoch,
            reason: 'a handle minted under a different epoch than the one the '
                'link is on is stale the moment it is created');
      });

      test('answers null for a key it does not own', () {
        expect(link.resolve(foreignKey, fixtureMapping), isNull,
            reason: 'null is "not mine", and it is what lets the router try '
                'the next link without knowing any protocol. A throw here '
                'would make the fallthrough order a try/catch ladder');
      });

      test('two handles for the same key under the same epoch are equal', () {
        expect(refFor(speedKey), refFor(speedKey));
      });
    });

    group('setValue', () {
      test('is what peek then reports', () {
        final at = DateTime.utc(2026, 9, 1, 12);
        drive.setValue(speedKey, 42, quality: Quality.good, sourceTime: at);

        final seen = link.peek(refFor(speedKey));

        expect(seen, isNotNull);
        expect(seen!.value, 42);
        expect(seen.quality, Quality.good);
        expect(seen.sourceTime, at);
      });

      test('is what read then answers, quality and source time included',
          () async {
        final at = DateTime.utc(2026, 9, 1, 12);
        drive.setValue(speedKey, 7,
            quality: Quality.uncertainLastKnown, sourceTime: at);

        final seen =
            await link.read(refFor(speedKey), deadline: generousDeadline);

        expect(seen.value, 7);
        expect(seen.quality, Quality.uncertainLastKnown);
        expect(seen.sourceTime, at);
      });

      test('reaches a subscription that is already live', () async {
        final ref = refFor(speedKey);
        final first = link.subscribe(ref).first;

        drive.setValue(speedKey, 99, sourceTime: DateTime.utc(2026, 9, 1));

        final seen = await first.timeout(generousDeadline);
        expect(seen.value, 99);
      });

      test('setValues delivers many keys', () {
        drive.setValues({speedKey: 1, setpointKey: 2});

        expect(link.peek(refFor(speedKey))!.value, 1);
        expect(link.peek(refFor(setpointKey))!.value, 2);
      });
    });

    group('disconnectUpstream', () {
      test('moves the link to disconnected and records the death', () {
        expect(link.lastDeathAt, isNull,
            reason: 'a link that has never dropped has no death instant, and '
                'a plausible one here would read as a real death');

        drive.disconnectUpstream();

        expect(link.state, UpstreamLinkState.disconnected);
        expect(link.lastDeathAt, isNotNull);
      });

      test('degrades every key on this link to badCommFault', () {
        drive.setValues({speedKey: 1, setpointKey: 2});

        drive.disconnectUpstream();

        expect(link.peek(refFor(speedKey))!.quality, Quality.badCommFault);
        expect(link.peek(refFor(setpointKey))!.quality, Quality.badCommFault);
      });

      test('announces exactly once, not once per key', () {
        drive.setValues({speedKey: 1, setpointKey: 2});
        final before = drive.statusNotifications;

        drive.disconnectUpstream();

        expect(drive.statusNotifications, before + 1,
            reason: 'one event is one announcement however many keys it cost. '
                'At 1500 keys a per-key fan-out is 1500 events arriving in the '
                'instant the client is trying to redraw the page they are '
                'about — a denial of service against the operator\'s own '
                'screen, which is why Sparkplug sends one NDEATH per node');
      });

      test('a second call is not a second event', () {
        drive.disconnectUpstream();
        final after = drive.statusNotifications;

        drive.disconnectUpstream();

        expect(drive.statusNotifications, after,
            reason: 'already-down is not an event');
      });
    });

    group('the band guard', () {
      test('a key already worse than badCommFault stages no change', () {
        drive.setValue(speedKey, 1);
        drive.setQuality(speedKey, Quality.errorConfig);

        drive.disconnectUpstream();

        expect(link.peek(refFor(speedKey))!.quality, Quality.errorConfig,
            reason: 'errorConfig means the tag is gone and waiting will not '
                'fix it; badCommFault means the link is down and waiting '
                'might. Overwriting the first with the second tells the '
                'operator to wait for something that is never coming back');
      });

      test('and the announcement still happens', () {
        drive.setValue(speedKey, 1);
        drive.setQuality(speedKey, Quality.errorConfig);
        final before = drive.statusNotifications;

        drive.disconnectUpstream();

        expect(drive.statusNotifications, before + 1,
            reason: 'the link went down. That is an event even if no key\'s '
                'quality had to move — the degradation and the announcement '
                'are separate acts');
      });
    });

    group('reconnectUpstream', () {
      test('moves the link back to connected and counts a birth', () {
        drive.disconnectUpstream();
        final births = link.birthCount;

        drive.reconnectUpstream();

        expect(link.state, UpstreamLinkState.connected);
        expect(link.birthCount, births + 1,
            reason: 'the bdSeq analogue: monotonic per process, incremented on '
                'each transition INTO connected');
      });

      test('leaves values uncertain until each is re-read', () {
        drive.setValue(speedKey, 1);
        drive.disconnectUpstream();

        drive.reconnectUpstream();

        expect(link.peek(refFor(speedKey))!.quality, Quality.uncertainLastKnown,
            reason: 'the link being back is not evidence about the number. '
                'Straight back to good would republish an hour-old reading as '
                'current the instant the socket reopened');
      });
    });

    group('dropKey', () {
      test('makes resolve answer null', () {
        drive.dropKey(speedKey);

        expect(link.resolve(speedKey, fixtureMapping), isNull);
      });

      test('tells a live subscription, and does not end its stream', () async {
        final ref = refFor(speedKey);
        final seen = <DynamicValue>[];
        var closed = false;
        final sub = link.subscribe(ref).listen(seen.add, onDone: () {
          closed = true;
        });
        addTearDown(sub.cancel);

        drive.dropKey(speedKey);
        await pumpEventQueue();

        expect(seen, hasLength(1));
        expect(seen.single.quality, Quality.errorConfig,
            reason: 'the tag is gone upstream: a configuration fault, not a '
                'transient. Waiting will not fix it');
        expect(seen.single.value, isNull,
            reason: 'and it must not keep rendering the last plausible number');
        expect(closed, isFalse,
            reason: 'an ended stream is indistinguishable to a widget from a '
                'key that stopped changing — AutoDisposingStream\'s '
                'close-on-source-end is on the do-not-inherit list');
      });
    });

    group('read deadlines', () {
      test(
          'a deadline shorter than the link answers badCommFault, and does not '
          'throw or hang', () async {
        drive.readLatency = const Duration(seconds: 30);
        drive.setValue(speedKey, 1);

        final seen = await link
            .read(refFor(speedKey), deadline: const Duration(milliseconds: 20))
            .timeout(const Duration(seconds: 2),
                onTimeout: () => fail('read outran its own deadline — this is '
                    'state_man.dart:1868 inherited, and a disconnected PLC '
                    'pends the caller forever'));

        expect(seen.quality, Quality.badCommFault);
        expect(seen.value, isNull,
            reason: 'a timed-out read has no reading, and the last one is not '
                'an answer to the question that was asked');
      });
    });

    group('write', () {
      test('applies by default, under the caller\'s cmd', () async {
        final result = await link.write(refFor(setpointKey), DynamicValue.of(5),
            cmd: 'cmd-1', deadline: generousDeadline);

        expect(result, isA<WriteApplied>());
        expect(result.cmd, 'cmd-1');
      });

      test('answers whatever nextWriteOutcome was set to', () async {
        drive.setNextWriteOutcome(
            const WriteUnknown('cmd-2', WriteReason('plc_timeout')));

        final result = await link.write(refFor(setpointKey), DynamicValue.of(5),
            cmd: 'cmd-2', deadline: generousDeadline);

        expect(result, isA<WriteUnknown>());
      });

      test('a read-only link rejects rather than throwing', () async {
        drive.setSupportsWrites(false);

        final result = await link.write(refFor(setpointKey), DynamicValue.of(5),
            cmd: 'cmd-3', deadline: generousDeadline);

        expect(link.supportsWrites, isFalse);
        expect(result, isA<WriteRejected>());
        final rejected = result as WriteRejected;
        expect(rejected.reason.status, 'Bad_NotWritable',
            reason: 'M2400DeviceClientAdapter.write throws UnsupportedError '
                '(state_man.dart:1266-1268) and state_man_api.dart:114-117 '
                'names that throw as what not to copy: a throw on the write '
                'path reads to the operator as "the write failed", which is '
                'the one thing a refusal to try does not prove about the '
                'plant');
        expect(rejected.reason.kind, 'not_writable');
      });

      test('a deadline shorter than the link is unknown, never rejected',
          () async {
        drive.writeLatency = const Duration(seconds: 30);

        final result = await link
            .write(refFor(setpointKey), DynamicValue.of(5),
                cmd: 'cmd-4', deadline: const Duration(milliseconds: 20))
            .timeout(const Duration(seconds: 2),
                onTimeout: () => fail('write outran its own deadline'));

        expect(result, isA<WriteUnknown>(),
            reason: 'the request was already on the wire when the clock ran '
                'out. "It did not happen" and "I cannot tell whether it '
                'happened" are different things to tell an operator standing '
                'next to the machine');
      });
    });

    group('roundTrips', () {
      test('counts a read', () async {
        final before = drive.roundTrips;

        await link.read(refFor(speedKey), deadline: generousDeadline);

        expect(drive.roundTrips, before + 1);
      });

      test('counts a write', () async {
        final before = drive.roundTrips;

        await link.write(refFor(setpointKey), DynamicValue.of(1),
            cmd: 'cmd-5', deadline: generousDeadline);

        expect(drive.roundTrips, before + 1);
      });

      test('counts establishing a subscription', () {
        final before = drive.roundTrips;
        final createsBefore = link.upstreamSubscriptionsCreated;

        final sub = link.subscribe(refFor(speedKey)).listen((_) {});
        addTearDown(sub.cancel);

        expect(drive.roundTrips, before + 1);
        expect(link.upstreamSubscriptionsCreated, createsBefore + 1,
            reason: 'deltas of creates. There is no delete counter to balance '
                'against — the binding\'s onCancel discards the delete future '
                '(state_man.dart:848-861)');
      });

      test('peek is never a round trip', () {
        drive.setValue(speedKey, 1);
        final before = drive.roundTrips;

        link.peek(refFor(speedKey));

        expect(drive.roundTrips, before,
            reason: 'peek is the synchronous cached read; a round trip here '
                'would make the cheapness half of the read contract false');
      });
    });

    group('a handle resolved under a superseded epoch', () {
      test('cannot be read from', () async {
        drive.setValue(speedKey, 1);
        final stale = refFor(speedKey);
        drive.bumpEpoch();

        final seen = await link.read(stale, deadline: generousDeadline);

        expect(seen.value, isNull,
            reason: 'SRV-07: no stale-handle read ever returns a value. The '
                'handle addresses a node that may now mean a different tag, '
                'so answering from it is not a stale read but a confidently '
                'wrong one');
        expect(seen.quality.isBad || seen.quality.isError, isTrue);
      });

      test('cannot be peeked from', () {
        drive.setValue(speedKey, 1);
        final stale = refFor(speedKey);
        drive.bumpEpoch();

        expect(link.peek(stale), isNull);
      });

      test('cannot be written through', () async {
        final stale = refFor(setpointKey);
        drive.bumpEpoch();

        final result = await link.write(stale, DynamicValue.of(5),
            cmd: 'cmd-6', deadline: generousDeadline);

        expect(result, isNot(isA<WriteApplied>()),
            reason: 'a write through a handle from before a PLC download is a '
                'write at whatever tag now occupies that address');
      });

      test('streams no values', () async {
        final stale = refFor(speedKey);
        drive.bumpEpoch();
        final seen = <DynamicValue>[];
        final sub = link.subscribe(stale).listen(seen.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();

        drive.setValue(speedKey, 123);
        await pumpEventQueue();

        expect(seen.where((v) => v.value != null), isEmpty,
            reason: 'the subscription was established against an address the '
                'link no longer vouches for');
      });

      test('a freshly resolved handle works again', () async {
        drive.bumpEpoch();
        drive.setValue(speedKey, 5);

        final seen =
            await link.read(refFor(speedKey), deadline: generousDeadline);

        expect(seen.value, 5,
            reason: 'the epoch bump invalidates handles, not the link');
      });

      test('the epoch change is announced on epochStream', () async {
        final next = link.epochStream.first;

        drive.bumpEpoch();

        expect(await next.timeout(generousDeadline), link.epoch);
      });
    });

    group('a value sanitize refuses', () {
      test('fails one tag and not the poll cycle', () {
        drive.setValue(setpointKey, 11);

        // 70 levels deep: past DynamicValue.maxDepth, which is the bound the
        // gateway's own converters are held to (dynamic_value.dart:148-156).
        Object? nested = 1;
        for (var i = 0; i < 70; i++) {
          nested = <String, Object?>{'n': nested};
        }
        drive.emitRaw(speedKey, nested);

        expect(link.peek(refFor(speedKey))!.quality, Quality.errorConfig,
            reason: 'the one tag whose payload could not be sanitized carries '
                'the fault');
        expect(link.peek(refFor(setpointKey))!.value, 11,
            reason: 'sanitize failure = ONE TAG fails, never a poll cycle. A '
                'struct-heavy PLC is exactly where this bites, and taking the '
                'cycle down with it would blank a whole plant screen for one '
                'bad tag');
        expect(drive.sanitizeRefusals, 1);
      });

      test('keeps the raw payload available for the ingest tests', () {
        drive.emitRaw(speedKey, double.nan);

        expect(drive.rawEmissions.single.key, speedKey);
        expect((drive.rawEmissions.single.raw as double).isNaN, isTrue,
            reason: '08-05 points the gateway\'s own converter at this, and a '
                'payload already normalised by DynamicValue would be a '
                'converter tested against its own output');
      });
    });

    group('failNextResolve', () {
      test('makes exactly the next resolve answer null', () {
        drive.failNextResolve();

        expect(link.resolve(speedKey, fixtureMapping), isNull);
        expect(link.resolve(speedKey, fixtureMapping), isNotNull,
            reason: 'one-shot: 08-04 needs a link that declines one key, not '
                'a link that has gone away');
      });
    });

    group('state and capability', () {
      test('stateStream carries the transitions', () async {
        final seen = <UpstreamLinkState>[];
        final sub = link.stateStream.listen(seen.add);
        addTearDown(sub.cancel);

        drive.disconnectUpstream();
        drive.reconnectUpstream();
        await pumpEventQueue();

        expect(seen, [
          UpstreamLinkState.disconnected,
          UpstreamLinkState.connected,
        ]);
      });

      test('lastError is redacted before it leaves the link', () {
        drive.setLastError('connect failed: opc.tcp://svc:hunter2@10.0.0.1/');

        expect(link.lastError, isNot(contains('hunter2')),
            reason: 'redaction has to happen at this boundary: by the time '
                'this is PIPE.upstream.<alias>.last_error it has already been '
                'fanned out to every subscriber (T-08-08)');
      });

      test('supportsBrowse is a declared capability', () {
        drive.setSupportsBrowse(false);

        expect(link.supportsBrowse, isFalse);
      });

      test('staleAfter is a real deadline', () {
        expect(drive.staleAfter, greaterThan(Duration.zero),
            reason: 'every freshness case reads its budget from here. Zero '
                'would make every value instantly stale and the sweep '
                'unfalsifiable');
      });

      test('the five wire names are the five states', () {
        expect(UpstreamLinkState.values.map((s) => s.wireName).toSet(), {
          'connected',
          'connecting',
          'disconnected',
          'unhealthy',
          'reprogrammed',
        },
            reason: 'StatusParams.state accepts exactly these five '
                '(messages.dart:458-479). A sixth name here that is not there '
                'produces a StatusParams no client can decode');
      });
    });
  });
}
