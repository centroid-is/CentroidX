/// HLTH-03: `PIPE.` is reserved, and a keymapping that claims a name inside it
/// is refused **per key, never per file**.
///
/// One decision inside HLTH-03 decides whether it is useful. The shipped
/// `updateKeyMappings` (`packages/tfc_dart/lib/core/state_man.dart:2086-2223`)
/// never throws: it classifies, returning
/// `KeyMappingsUpdateResult {added, removed, changed, resubscribed,
/// reloadReasons}` (`:702-735`). HLTH-03's rejection list is a **sixth field**
/// on that shape. One bad mapping in a file of 1,500 must cost exactly that
/// mapping — the same principle as the sanitize rule, applied to configuration
/// instead of to data.
///
/// Every `PIPE.` name in this file is read from [PipeKeys], never re-spelled.
/// The one code literal in the whole repository is `PipeKeys.prefix`, and that
/// is the point: the reserved list and the producer cannot drift apart by a
/// typo.
@TestOn('vm')
library;

import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

void main() {
  group('the sixth field: rejection is per key', () {
    test('a file of three entries with one PIPE. claim loads the other two',
        () {
      final router = _router(keyMappingsOf([st101Key, st201Key]));

      final squatter = PipeKeys.upstreamConnected(st101Alias);
      final result = router.applyKeyMappings(
          keyMappingsOf([st101Key, st201Key, squatter]));

      expect(result.rejected, hasLength(1));
      expect(result.rejected[squatter], RouteRefusal.reservedPrefix);
      expect(result.added, isEmpty);
      expect(router.keys, hasLength(2));
      expect(router.keys, containsAll([st101Key, st201Key]));
    });

    test('the rejected key is not in the key set, and routing it never reaches '
        'a link', () {
      final squatter = PipeKeys.upstreamConnected(st101Alias);
      final router = _router(keyMappingsOf([st101Key, squatter]));

      expect(router.keys, isNot(contains(squatter)));
      expect(router.lastIngest.rejected[squatter],
          RouteRefusal.reservedPrefix);
      // `route` answers PipeKeyRoute rather than a refusal, and the two facts
      // are the same fact: the gateway DOES serve this name — from its own
      // health producer (08-09), never from the plant. What HLTH-03 refuses is
      // the *mapping*, which is exactly the spoofing attempt: an alarm reading
      // a conveyor speed as a link state (T-08-12). The squatter gets no
      // link, no keymapping and no say in what the key means.
      expect(router.route(squatter), isA<PipeKeyRoute>());
    });

    test('nothing throws, even when the whole file is a claim', () {
      final router = _router(keyMappingsOf([st101Key]));

      final all = keyMappingsOf([
        PipeKeys.connected,
        PipeKeys.epoch,
        PipeKeys.certDaysToExpiry,
        PipeKeys.linkDegraded,
        PipeKeys.upstreamConnected(st101Alias),
        PipeKeys.upstreamLastError(st201Alias),
      ]);

      late final KeyMappingsIngestResult result;
      expect(() => result = router.applyKeyMappings(all), returnsNormally);
      expect(result.rejected, hasLength(6));
      expect(result.rejected.values,
          everyElement(RouteRefusal.reservedPrefix));
      expect(router.keys, isEmpty);
      expect(result.removed, contains(st101Key));
    });
  });

  group('at scale, because "the rest load" is the whole requirement', () {
    test('200 entries with one PIPE. claim load 199', () {
      // A three-entry fixture cannot show this. The live file is 430 entries
      // and the files this gateway will be handed run to 1,500; the failure
      // HLTH-03 exists to prevent is one squatted name taking a plant's whole
      // configuration down with it (T-08-14).
      final generated = generatedKeyMappings(199);
      final squatter = PipeKeys.upstreamConnected(st101Alias);
      generated.nodes[squatter] = opcUaEntry(alias: null);
      expect(generated.nodes, hasLength(200),
          reason: 'the fixture itself must be the size this case claims');

      final router = _router(KeyMappings(nodes: {}));
      final result = router.applyKeyMappings(generated);

      printOnFailure('loaded ${router.keys.length}, '
          'rejected ${result.rejected.length}');
      expect(result.added, hasLength(199));
      expect(result.rejected, hasLength(1));
      expect(router.keys, hasLength(199));
      expect(router.keys, isNot(contains(squatter)));
    });

    test('the live plant file — 430 entries, Line1.Motor1 names, server_alias '
        'null — loads without a single rejection', () {
      final live = generatedKeyMappings(430);
      for (final entry in livePlantKeyMappings().nodes.entries) {
        live.nodes[entry.key] = entry.value;
      }

      final router = _router(KeyMappings(nodes: {}));
      final result = router.applyKeyMappings(live);

      expect(result.rejected, isEmpty,
          reason: 'assumption A7 — no existing keymapping claims PIPE. — was '
              'confirmed against the measured file. A rejection here is a '
              'false positive costing a plant a tag');
      expect(router.keys, hasLength(live.nodes.length));
    });
  });

  group('the rule is a prefix rule', () {
    test('a PIPE. name no phase has invented yet is reserved anyway', () {
      final router = _router(KeyMappings(nodes: {}));
      final invented = '${PipeKeys.prefix}something.nobody.has.invented.yet';

      final result = router.applyKeyMappings(keyMappingsOf([invented]));
      expect(result.rejected[invented], RouteRefusal.reservedPrefix);
    });

    test('PipeKeys.certDaysToExpiry is reserved by the same rule, from the '
        'first commit', () {
      // Read from the constant, never re-spelled: ruling 9 as amended keeps
      // the PRODUCER in tfc_relay_server while the NAME has one home, and this
      // case is what would notice the two drifting.
      final router = _router(KeyMappings(nodes: {}));

      final result =
          router.applyKeyMappings(keyMappingsOf([PipeKeys.certDaysToExpiry]));
      expect(result.rejected[PipeKeys.certDaysToExpiry],
          RouteRefusal.reservedPrefix);
      expect(router.keys, isEmpty);
    });

    test('a key that merely CONTAINS PIPE. later in the name is not rejected — '
        'the plant has pipes', () {
      // What a false rejection costs: a conveyor tag silently unmapped, a page
      // reading unknown forever, and nothing in any log saying why. The
      // operator sees a dash where a flow used to be and the configuration
      // file looks correct, because it is.
      final router = _router(KeyMappings(nodes: {}));
      const plantTag = 'ST101.PIPE.flow';

      final result = router.applyKeyMappings(keyMappingsOf([plantTag]));
      expect(result.rejected, isEmpty);
      expect(router.keys, contains(plantTag));
      expect(router.route(plantTag), isA<ClaimedRoute>());
    });

    test('a plant area called PIPES is not reserved by accident', () {
      final router = _router(KeyMappings(nodes: {}));
      const plantTag = 'PIPES.CN01.flow';

      expect(router.applyKeyMappings(keyMappingsOf([plantTag])).rejected,
          isEmpty);
      expect(router.keys, contains(plantTag));
    });
  });

  group('the other five fields still classify, as the shipped result does', () {
    test('added, removed and changed are what moved', () {
      final router = _router(keyMappingsOf([st101Key, st201Key]));

      final next = KeyMappings(nodes: {
        st101Key: opcUaEntry(alias: null, identifier: 'GVL.moved'),
        liveOpcUaKey: opcUaEntry(alias: null),
      });
      final result = router.applyKeyMappings(next);

      expect(result.added, {liveOpcUaKey});
      expect(result.removed, {st201Key});
      expect(result.changed, {st101Key});
      expect(result.rejected, isEmpty);
      expect(result.requiresReload, isFalse);
    });

    test('an unchanged entry is not reported as changed', () {
      final router = _router(keyMappingsOf([st101Key]));
      final result = router.applyKeyMappings(keyMappingsOf([st101Key]));

      expect(result.added, isEmpty);
      expect(result.removed, isEmpty);
      expect(result.changed, isEmpty);
    });

    test('an M2400 edit asks for a reload; an OPC UA edit does not', () {
      final router = _router(livePlantKeyMappings());

      final next = livePlantKeyMappings();
      next.nodes[liveM2400Key]!.m2400Node!.statusFilter = 3;
      final result = router.applyKeyMappings(next);

      expect(result.changed, {liveM2400Key});
      expect(result.requiresReload, isTrue);
      expect(result.reloadReasons.join(' '), contains(liveM2400Key));
    });

    test('a rejected key counts as neither added nor changed', () {
      final squatter = PipeKeys.upstreamConnected(st101Alias);
      final router = _router(keyMappingsOf([st101Key, squatter]));

      final result =
          router.applyKeyMappings(keyMappingsOf([st101Key, squatter]));
      expect(result.added, isEmpty);
      expect(result.changed, isEmpty);
      expect(result.removed, isEmpty);
      expect(result.rejected, hasLength(1));
    });
  });

  group('a key that can never route is refused at the same door', () {
    test('a \$ variable is rejected at ingest, not left to fail per read', () {
      final router = _router(KeyMappings(nodes: {}));

      final result = router.applyKeyMappings(keyMappingsOf([r'Line$n.Motor1']));
      expect(result.rejected[r'Line$n.Motor1'],
          RouteRefusal.substitutionUnsupported);
      expect(router.keys, isEmpty);
    });

    test('and it costs exactly that key', () {
      final router = _router(KeyMappings(nodes: {}));

      final result = router
          .applyKeyMappings(keyMappingsOf([r'Line$n.Motor1', st101Key]));
      expect(result.rejected, hasLength(1));
      expect(router.keys, {st101Key});
    });
  });
}

/// A router over one link that claims everything, so every case here is about
/// the ingest rather than about which link won.
KeyRouter _router(KeyMappings mappings) => KeyRouter(
      links: [
        UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias),
            serverAlias: null),
      ],
      mappings: mappings,
    );
