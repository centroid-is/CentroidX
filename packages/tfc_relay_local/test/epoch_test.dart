/// The multi-input epoch: the token that says which server this is.
///
/// `@TestOn('!windows')` for `opcua_link_test.dart:1-8`'s reason — the CI matrix
/// includes `windows-latest` and an in-process open62541 `Server` is not run
/// there. The annotation has no granularity below the file, so it goes here and
/// costs the pure arms their Windows run; the `opcua` **tag**, by contrast, is
/// per-group, so `--exclude-tags opcua` still leaves the combination arms
/// selectable. Those two facts pull in opposite directions and this is the
/// split that keeps the pure logic runnable in the cheap lane.
@TestOn('!windows')
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'support/opcua_server_fixture.dart';

/// The plant's own spelling, as everywhere else in this package.
const String speedKey = 'ST101.CN01.MOT01.speed';
const String secondKey = 'ST101.CN02.MOT01.speed';

/// This link's alias.
const String alias = 'ST101';

/// Generous: none of these cases is a latency measurement.
const Duration generous = Duration(seconds: 10);

/// A reading that is not the reading the next one is.
final DateTime startedAt = DateTime.utc(2026, 9, 2, 6, 30);
final DateTime startedLater = DateTime.utc(2026, 9, 2, 6, 31);

/// The keymapping entry the router would hand `resolve`.
KeyMappingEntry mappingFor(String key, {String? serverAlias = alias}) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = serverAlias;
  return KeyMappingEntry()..opcuaNode = node;
}

/// Waits until [link] reports [UpstreamLinkState.connected].
Future<void> awaitConnected(OpcUaUpstreamLink link,
    {Duration within = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(within);
  while (link.state != UpstreamLinkState.connected) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the link never reached connected; it is ${link.state} and the '
          'heartbeat has not ticked');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// A server's identity, under the test's control.
///
/// The bump choreography and the *reading* of an identity are two different
/// subjects, and conflating them makes both harder to test: a case about "what
/// happens when the server changed" should not also be a case about restarting
/// a server, and `stale_handle_test.dart` is where the reading is proved
/// against one that genuinely did. This holder is the injected
/// [EpochInputsReader]; production's is [readEpochInputs].
final class PretendIdentity {
  PretendIdentity();

  /// What the next reading will say. Starts as a perfectly ordinary server.
  EpochInputs current = EpochInputs(
    startTime: DateTime.utc(2026, 9, 2, 6, 30),
    namespaceArrayHash:
        hashNamespaceArray(const ['http://opcfoundation.org/UA/', 'urn:st101']),
  );

  /// How many times the link asked.
  int reads = 0;

  /// The server is now a different one.
  void change() => current = EpochInputs(
        startTime: DateTime.utc(2026, 9, 2, 9, 15),
        namespaceArrayHash: hashNamespaceArray(
            const ['http://opcfoundation.org/UA/', 'urn:st101']),
      );

  /// The server answered none of the three questions.
  void goSilent() => current = EpochInputs.unreadable;

  Future<EpochInputs> read(
    ua.ClientApi client, {
    required Duration deadline,
    ua.NodeId? buildStampNode,
  }) async {
    reads++;
    return current;
  }
}

/// Polls [predicate] until it holds or [within] runs out.
Future<void> until(bool Function() predicate, String what,
    {Duration within = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('the combination is pure, deterministic and honest', () {
    test('a change in StartTime alone changes the epoch', () {
      final before = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b']),
          buildStamp: '7');
      final after = EpochInputs(
          startTime: startedLater,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b']),
          buildStamp: '7');

      expect(after.combine(), isNot(before.combine()),
          reason: 'StartTime moving is the roadmap\'s named detector for a '
              'server that restarted underneath the handles we hold');
    });

    test('a change in the NamespaceArray hash alone changes the epoch', () {
      final before = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b']),
          buildStamp: '7');
      final after = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b', 'c']),
          buildStamp: '7');

      expect(after.combine(), isNot(before.combine()),
          reason: 'a re-import that renumbers namespace indices is exactly the '
              'event this input exists to catch, and it can happen with the '
              'TF6100 service — and therefore StartTime — untouched');
    });

    test('a change in the build stamp alone changes the epoch', () {
      final before = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b']),
          buildStamp: '7');
      final after = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a', 'b']),
          buildStamp: '8');

      expect(after.combine(), isNot(before.combine()),
          reason: 'the build stamp is the one input the integrator controls, '
              'and it is the fallback that survives A1 being wrong');
    });

    test('the same unchanged reading produces the same epoch, one hundred '
        'times', () {
      // The anti-vacuity arm for every case above — three arms saying "these
      // differ" prove nothing if the function differs from itself — and the
      // one that catches a hash folded over a Map with non-deterministic
      // iteration order.
      final epochs = <String>{};
      for (var i = 0; i < 100; i++) {
        epochs.add(EpochInputs(
          startTime: DateTime.utc(2026, 9, 2, 6, 30),
          namespaceArrayHash: hashNamespaceArray(
              const ['http://opcfoundation.org/UA/', 'urn:st101']),
          buildStamp: 'build-4711',
        ).combine());
      }
      print('DETERMINISM 100 combinations produced ${epochs.length} distinct '
          'epoch(s): ${epochs.single}');
      expect(epochs, hasLength(1));
    });

    test('the NamespaceArray hash is order-sensitive', () {
      final forwards =
          hashNamespaceArray(const ['http://opcfoundation.org/UA/', 'urn:st101']);
      final backwards =
          hashNamespaceArray(const ['urn:st101', 'http://opcfoundation.org/UA/']);

      expect(backwards, isNot(forwards),
          reason: 'the namespace INDEX is what a NodeId carries, so the same '
              'uris in a different order name different nodes. A set hash '
              'here would read a renumbering as no change at all');
    });

    test('all three unreadable is marked as such and never agrees with a real '
        'reading', () {
      const nothing = EpochInputs();
      final real = EpochInputs(
          startTime: startedAt,
          namespaceArrayHash: hashNamespaceArray(const ['a']),
          buildStamp: '7');

      expect(nothing.isUnreadable, isTrue);
      expect(isUnreadableEpoch(nothing.combine()), isTrue,
          reason: 'a server that answered nothing must SAY it answered '
              'nothing; an identifier derived from three nulls is a plausible '
              'zero applied to an identity');
      expect(nothing.combine(), isNot(real.combine()));
      expect(isUnreadableEpoch(real.combine()), isFalse);
      expect(real.contributed, hasLength(3),
          reason: 'the epoch has to be able to say which inputs it rests on, '
              'or a partially-blind detector looks exactly like a working one');
      expect(nothing.contributed, isEmpty);
    });

    test('a partial reading still yields an epoch, and says which inputs it '
        'rests on', () {
      final partial = EpochInputs(startTime: startedAt);

      expect(partial.isUnreadable, isFalse);
      expect(isUnreadableEpoch(partial.combine()), isFalse);
      expect(partial.contributed, <EpochInput>{EpochInput.startTime});
      expect(
          partial.combine(),
          isNot(EpochInputs(
                  startTime: startedAt,
                  namespaceArrayHash: hashNamespaceArray(const ['a']))
              .combine()),
          reason: 'a server that stopped answering one of its own identity '
              'nodes has changed in a way this gateway cannot rule out');
    });

    test('the unconnected epoch is neither a reading nor the unreadable one',
        () {
      expect(unconnectedEpoch, isNot(unreadableEpoch),
          reason: '"never asked" and "asked and got nothing" are different '
              'statements, and only the second one is evidence about a server');
      expect(isUnreadableEpoch(unconnectedEpoch), isFalse);
    });
  });

  group('reading the inputs off a real server', () {
    late OpcUaServerFixture fixture;
    late ua.Client client;
    late Timer driver;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(valueKeys: [speedKey]);
      addTearDown(fixture.dispose);
      client = ua.Client(logLevel: ua.LogLevel.UA_LOGLEVEL_ERROR);
      // The crank has to turn for `connect` to complete — measured, not
      // assumed: without this the connect future never finishes and the case
      // dies on the suite timeout rather than on an assertion.
      driver = Timer.periodic(const Duration(milliseconds: 10), (_) {
        try {
          client.runIterate(const Duration(milliseconds: 10));
        } catch (_) {
          // A crank turned against a client a test already deleted.
        }
      });
      addTearDown(() async {
        driver.cancel();
        await client.delete();
      });
      await client.connect(fixture.endpoint).timeout(generous);
    });

    test('StartTime and the NamespaceArray both arrive, and the epoch rests '
        'on both', () async {
      final inputs = await readEpochInputs(client, deadline: generous);

      print('INPUTS start=${inputs.startTime} ns=${inputs.namespaceArrayHash} '
          'stamp=${inputs.buildStamp} contributed=${inputs.contributed}');
      expect(inputs.startTime, isNotNull,
          reason: 'ns=0;i=2257 is Server_ServerStatus_StartTime and every OPC '
              'UA server has it');
      expect(inputs.namespaceArrayHash, isNotNull);
      expect(inputs.buildStamp, isNull,
          reason: 'the build stamp is opt-in: nobody configured a key here');
      expect(inputs.contributed,
          <EpochInput>{EpochInput.startTime, EpochInput.namespaceArray});
      expect(isUnreadableEpoch(inputs.combine()), isFalse);
    });

    test('a configured build-stamp key that does not resolve is the unreadable '
        'case, not an exception', () async {
      final inputs = await readEpochInputs(client,
          deadline: generous,
          buildStampNode: ua.NodeId.fromString(fixtureNamespace, 'no-such-tag'));

      expect(inputs.buildStamp, isNull,
          reason: 'a misconfigured build-stamp key must not take the whole '
              'epoch down with it — the other two inputs still identify the '
              'server, and a throw here would leave the link with no epoch at '
              'all on a server that is answering perfectly well');
      expect(inputs.contributed,
          <EpochInput>{EpochInput.startTime, EpochInput.namespaceArray});
    });

    test('a configured build-stamp key that resolves contributes', () async {
      final inputs = await readEpochInputs(client,
          deadline: generous,
          buildStampNode: fixtureNodeId(speedKey));

      expect(inputs.buildStamp, isNotNull);
      expect(inputs.contributed, hasLength(3));
    });

    test('a server that answers nothing yields the unreadable epoch, not a '
        'plausible one', () async {
      await fixture.dispose();

      final inputs =
          await readEpochInputs(client, deadline: const Duration(seconds: 2));

      expect(inputs.isUnreadable, isTrue);
      expect(isUnreadableEpoch(inputs.combine()), isTrue);
      print('UNREADABLE epoch=${inputs.combine()}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, tags: 'opcua');

  group('the bump: one batch, one announcement, one re-browse', () {
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;
    late PretendIdentity identity;
    late List<String> log;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(valueKeys: [speedKey, secondKey]);
      addTearDown(fixture.dispose);
      identity = PretendIdentity();
      link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        useIsolate: false,
        epochReader: identity.read,
      );
      addTearDown(link.dispose);
      log = <String>[];
      await link.connect(deadline: generous);
      await awaitConnected(link);
    });

    test('the epoch is read on session activation, and it is a reading rather '
        'than a placeholder', () async {
      expect(identity.reads, greaterThan(0),
          reason: 'the epoch is re-read on session activation and on nothing '
              'else — not on a timer, because a timer asks a healthy server a '
              'question it already answered');
      expect(link.epoch, isNot(unconnectedEpoch));
      expect(isUnreadableEpoch(link.epoch), isFalse);
      expect(link.epoch, identity.current.combine());
    });

    test('a reconnection that finds the same server produces NO bump',
        () async {
      final epochs = <String>[];
      final states = <UpstreamLinkState>[];
      link.epochStream.listen(epochs.add);
      link.stateStream.listen(states.add);
      final before = link.epoch;

      // Three activations in a row against a server that did not change. A
      // flapping link must not read as forty reprogrammings (T-08-32).
      await link.debugRefreshEpoch();
      await link.debugRefreshEpoch();
      await link.debugRefreshEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.epoch, before);
      expect(epochs, isEmpty,
          reason: 'an epochStream event means every handle this link ever '
              'issued is stale, and issuing one because a socket reopened '
              'would make every reconnect a plant-wide re-resolution');
      expect(states, isNot(contains(UpstreamLinkState.reprogrammed)));
      expect(link.reBrowses, 0);
      expect(identity.reads, greaterThanOrEqualTo(4),
          reason: 'the anti-vacuity half: it must have ASKED three more times '
              'and decided nothing changed, not skipped the question');
    });

    test('a bump degrades every key in one batch BEFORE it announces '
        'reprogrammed', () async {
      final refA = link.resolve(speedKey, mappingFor(speedKey))!;
      final refB = link.resolve(secondKey, mappingFor(secondKey))!;
      link.subscribe(refA).listen((v) => log.add('$speedKey:${v.quality.code}'));
      link.subscribe(refB).listen((v) => log.add('$secondKey:${v.quality.code}'));
      await until(
          () =>
              link.peek(refA)?.quality == Quality.good &&
              link.peek(refB)?.quality == Quality.good,
          'both keys to report a good value');
      log.clear();
      link.stateStream.listen((s) => log.add('state:${s.wireName}'));

      identity.change();
      await link.debugRefreshEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      print('BUMP ORDER $log');
      final announced = log.indexOf('state:${UpstreamLinkState.reprogrammed.wireName}');
      expect(announced, isNonNegative,
          reason: 'an epoch bump that nobody can see is a silent '
              're-resolution, which is the thing this mechanism replaces');
      final degrades = <int>[
        for (var i = 0; i < log.length; i++)
          if (log[i].endsWith(':${Quality.badCommFault.code}')) i,
      ];
      expect(degrades, hasLength(2),
          reason: 'every key on the alias degrades, in ONE pass');
      expect(degrades.every((i) => i < announced), isTrue,
          reason: 'a panel that receives `reprogrammed` and then reads a key '
              'that has not yet degraded sees a good value under a '
              'reprogrammed link — the exact combination the epoch exists to '
              'make impossible');
    });

    test('birthCount does not move on a bump', () async {
      final before = link.birthCount;

      identity.change();
      await link.debugRefreshEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(link.birthCount, before,
          reason: 'a reprogram is not a reconnection. Conflating them makes '
              'the Sparkplug counter lie about link stability, which is the '
              'one number a client uses to tell "same session, still running" '
              'from "a new session that may have missed updates"');
    });

    test('a key that survived comes back uncertain; a key that left the '
        'address space is errorConfig and stays there', () async {
      final refA = link.resolve(speedKey, mappingFor(speedKey))!;
      final refB = link.resolve(secondKey, mappingFor(secondKey))!;
      link.subscribe(refA).listen((_) {});
      link.subscribe(refB).listen((_) {});
      await until(
          () =>
              link.peek(refA)?.quality == Quality.good &&
              link.peek(refB)?.quality == Quality.good,
          'both keys to report a good value');

      // The reprogram that dropped a tag.
      fixture.deleteNode(secondKey);
      identity.change();
      await link.debugRefreshEpoch();

      final freshA = link.resolve(speedKey, mappingFor(speedKey))!;
      final freshB = link.resolve(secondKey, mappingFor(secondKey))!;
      expect(freshA.epoch, link.epoch,
          reason: 'a key that still resolves gets a handle under the NEW '
              'epoch; that is what makes it usable again');
      expect(freshA.epoch, isNot(refA.epoch));
      await until(() => link.peek(freshB)?.quality == Quality.errorConfig,
          'the deleted tag to settle on errorConfig');
      await until(
          () =>
              link.peek(freshA)?.quality == Quality.uncertainLastKnown ||
              link.peek(freshA)?.quality == Quality.good,
          'the surviving tag to come back');

      // And it STAYS there: errorConfig means waiting will not fix it, and a
      // later mass degrade must not relabel it as a comms fault.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(link.peek(freshB)!.quality, Quality.errorConfig);
      expect(link.peek(freshB)!.value, isNull);
    });

    test('a server that stops answering is not read as a reprogram', () async {
      final epochs = <String>[];
      link.epochStream.listen(epochs.add);
      final before = link.epoch;

      identity.goSilent();
      await link.debugRefreshEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.epoch, before,
          reason: 'absence of evidence is not evidence of change. Adopting '
              'the unreadable epoch here would turn every comms glitch into a '
              'plant-wide re-resolution, and the keys are already degrading '
              'for the honest reason');
      expect(epochs, isEmpty);
      expect(link.reBrowses, 0);
    });
  }, tags: 'opcua');

  group('one re-browse, whatever the key count', () {
    test('a bump across fifty keys re-browses exactly once', () async {
      final keys = <String>[
        for (var i = 1; i <= 50; i++)
          'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
      ];
      final fixture = await OpcUaServerFixture.start(valueKeys: keys);
      addTearDown(fixture.dispose);
      final identity = PretendIdentity();
      final link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        useIsolate: false,
        epochReader: identity.read,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);
      final refs = <UpstreamRef>[
        for (final key in keys) link.resolve(key, mappingFor(key))!,
      ];
      for (final ref in refs) {
        link.subscribe(ref).listen((_) {});
      }
      await until(() => refs.every((r) => link.peek(r) != null),
          'all fifty keys to report something', within: const Duration(minutes: 1));

      identity.change();
      await link.debugRefreshEpoch();

      print('REBROWSE ${keys.length} keys bumped -> ${link.reBrowses} '
          're-browse(s)');
      expect(link.reBrowses, 1,
          reason: 'a slow level is a slow panel, but fifty of them is a '
              'browse storm against a controller that just restarted '
              '(T-08-31)');
      expect(refs.every((r) => link.peek(r) == null), isTrue,
          reason: 'every handle issued under the old epoch is stale, and peek '
              'refuses all fifty of them without a list to walk');
    }, timeout: const Timeout(Duration(minutes: 4)));
  }, tags: 'opcua');
}
