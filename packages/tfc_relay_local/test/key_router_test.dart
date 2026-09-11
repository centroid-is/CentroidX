/// Which link owns a key, and which keys the gateway will not own at all.
///
/// The order under test is not invented here. `StateMan.subscribe`
/// (`packages/tfc_dart/lib/core/state_man.dart:2054-2084`) already establishes
/// it — meta-key short-circuit, substitution, unresolved check, disabled check,
/// M2400, Modbus, OPC UA fallthrough — and [KeyRouter] carries that *shape*
/// with two deliberate departures, each asserted below:
///
///  1. `PIPE.` takes `@conn`'s slot (`:1805`, `:2057`, `:1994`).
///  2. `$` substitution does not exist on the gateway at all
///     (`state_man_api.dart:26-31` froze it as a client-local key rewrite), so
///     a key containing one is **refused**, never resolved.
@TestOn('vm')
library;

import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

void main() {
  group('departure 1: PIPE. short-circuits before anything else', () {
    test('a PIPE. key answers PipeKeyRoute without consulting a single link',
        () {
      // Every link here throws if asked anything at all. If the short-circuit
      // ever moves below the link loop this case fails with that throw rather
      // than with a wrong answer — a regression that reads as a crash is
      // cheaper than one that reads as a route.
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(NeverAskedLink(st101Alias), serverAlias: null),
          UpstreamLinkBinding(NeverAskedLink(st201Alias),
              serverAlias: st201Alias),
        ],
        mappings: livePlantKeyMappings(),
      );

      final route = router.route(PipeKeys.upstreamConnected(st101Alias));
      expect(route, isA<PipeKeyRoute>());
      expect(route.key, PipeKeys.upstreamConnected(st101Alias));
    });

    test('the short-circuit is by prefix, so a key no phase has invented yet '
        'is still gateway-native', () {
      final router = KeyRouter(
        links: [UpstreamLinkBinding(NeverAskedLink(st101Alias), serverAlias: null)],
        mappings: livePlantKeyMappings(),
      );

      expect(router.route('${PipeKeys.prefix}something.nobody.has.invented.yet'),
          isA<PipeKeyRoute>());
    });

    test('a squatted PIPE. name in the mappings never reaches a link', () {
      // Defence in depth against HLTH-03's own ingest rejection: even handed a
      // mappings object that already holds the squatted name, `route`
      // short-circuits ABOVE the mappings lookup, so the squatter is never
      // served. (That the key is also refused at ingest, and is therefore not
      // in the key set at all, is `reserved_prefix_test.dart`'s subject.)
      final squatted = livePlantKeyMappings();
      squatted.nodes[PipeKeys.upstreamConnected(st101Alias)] =
          opcUaEntry(alias: null);

      final router = KeyRouter(
        links: [UpstreamLinkBinding(NeverAskedLink(st101Alias), serverAlias: null)],
        mappings: squatted,
      );

      expect(router.route(PipeKeys.upstreamConnected(st101Alias)),
          isA<PipeKeyRoute>());
    });
  });

  group('departure 2: substitution does not exist on the gateway', () {
    test('a key containing \$ is refused, not resolved', () {
      final link = FakeUpstreamLink(alias: st101Alias);
      final router = KeyRouter(
        links: [UpstreamLinkBinding(link, serverAlias: null)],
        // The fake was built with no key set, so it claims EVERYTHING. If the
        // refusal ever stopped happening this key would be claimed rather than
        // merely unmapped, which is what makes this arm about substitution and
        // not about the mappings.
        mappings: keyMappingsOf([r'Line$line.Motor1']),
      );

      final route = router.route(r'Line$line.Motor1');
      expect(route, isA<RefusedRoute>());
      expect((route as RefusedRoute).reason,
          RouteRefusal.substitutionUnsupported);
      expect(route.message, contains(r'Line$line.Motor1'));
    });

    test('the refusal is a value, not an exception', () {
      final router = KeyRouter(
        links: [UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias), serverAlias: null)],
        mappings: livePlantKeyMappings(),
      );

      expect(() => router.route(r'$anything'), returnsNormally);
    });
  });

  group('a disabled alias is refused, and distinguishably so', () {
    test('a key on a switched-off server is aliasDisabled, not unmapped', () {
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: weigherAlias),
              serverAlias: weigherAlias),
        ],
        mappings: livePlantKeyMappings(),
        disabledAliases: const <String?>{weigherAlias},
      );

      final route = router.route(liveM2400Key);
      expect(route, isA<RefusedRoute>());
      expect((route as RefusedRoute).reason, RouteRefusal.aliasDisabled);
      expect(route.message, contains(weigherAlias));
    });

    test('the unnamed server can itself be switched off — null is a real '
        'entry in the disabled set', () {
      // `StateManConfig.disabledServerAliases` says so in as many words:
      // "null in the returned set means the unnamed (aliasless) server is off".
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias),
              serverAlias: null),
        ],
        mappings: livePlantKeyMappings(),
        disabledAliases: const <String?>{null},
      );

      expect((router.route(liveOpcUaKey) as RefusedRoute).reason,
          RouteRefusal.aliasDisabled);
    });

    test('an empty alias normalizes to the unnamed server, as the shipped '
        'config does', () {
      final mappings = keyMappingsOf([st101Key], alias: '');
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias),
              serverAlias: null),
        ],
        mappings: mappings,
        disabledAliases: const <String?>{null},
      );

      expect((router.route(st101Key) as RefusedRoute).reason,
          RouteRefusal.aliasDisabled);
    });
  });

  group('the resolution order is the shipped one', () {
    test('when two links both claim a key, the one declared first wins', () {
      // Both links are given an EXPLICIT key set. A fake built with an empty
      // one claims everything, which would make this case pass no matter what
      // the router did (08-03-SUMMARY says so out loud).
      final first = FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]);
      final second = FakeUpstreamLink(alias: st101Alias, keys: [liveM2400Key]);

      final router = KeyRouter(
        links: [
          // The shipped order, and the reason it is this order: the M2400
          // lookup reads `m2400_node`, the Modbus one reads `modbus_node` and
          // the OPC UA one is the FALLTHROUGH — it claims whatever is left.
          // Put the fallthrough first and it swallows keys the two specific
          // protocols were configured for.
          UpstreamLinkBinding(first, serverAlias: weigherAlias),
          UpstreamLinkBinding(second, serverAlias: st101Alias),
        ],
        mappings: livePlantKeyMappings(),
      );

      final route = router.route(liveM2400Key);
      expect(route, isA<ClaimedRoute>());
      expect((route as ClaimedRoute).link, same(first));
      expect(route.ref.alias, weigherAlias);
    });

    test('a link that declines one key falls through to the next, without the '
        'router learning a protocol', () {
      final first = FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]);
      final second = FakeUpstreamLink(alias: st101Alias, keys: [liveM2400Key]);
      // Declines exactly once — a link that has DECLINED a key, not a link
      // that has gone away.
      first.failNextResolve();

      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(first, serverAlias: weigherAlias),
          UpstreamLinkBinding(second, serverAlias: st101Alias),
        ],
        mappings: livePlantKeyMappings(),
      );

      expect((router.route(liveM2400Key) as ClaimedRoute).link, same(second));
      // And the decline was for one key only: the next ask claims again.
      expect((router.route(liveM2400Key) as ClaimedRoute).link, same(first));
    });

    test('every protocol in the live file finds its link', () {
      final opcUa = FakeUpstreamLink(alias: st101Alias, keys: [liveOpcUaKey]);
      final weigher =
          FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]);
      final modbus = FakeUpstreamLink(alias: modbusAlias, keys: [liveModbusKey]);
      final umas = FakeUpstreamLink(alias: umasAlias, keys: [liveUmasKey]);

      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(weigher, serverAlias: weigherAlias),
          UpstreamLinkBinding(modbus, serverAlias: modbusAlias),
          UpstreamLinkBinding(umas, serverAlias: umasAlias),
          UpstreamLinkBinding(opcUa, serverAlias: null),
        ],
        mappings: livePlantKeyMappings(),
      );

      expect((router.route(liveOpcUaKey) as ClaimedRoute).link, same(opcUa));
      expect((router.route(liveM2400Key) as ClaimedRoute).link, same(weigher));
      expect((router.route(liveModbusKey) as ClaimedRoute).link, same(modbus));
      expect((router.route(liveUmasKey) as ClaimedRoute).link, same(umas));
    });
  });

  group('a key nobody claims is refused, never defaulted', () {
    test('a mapped key no link claims is unmapped, and the refusal names it',
        () {
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias, keys: [st101Key]),
              serverAlias: st101Alias),
        ],
        mappings: contractKitKeyMappings(),
      );

      final route = router.route(st201Key);
      expect(route, isA<RefusedRoute>());
      expect((route as RefusedRoute).reason, RouteRefusal.unmapped);
      expect(route.message, contains(st201Key));
    });

    test('a key that is not in the mappings at all is unmapped too', () {
      final router = KeyRouter(
        links: [UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias), serverAlias: null)],
        mappings: contractKitKeyMappings(),
      );

      final route = router.route('ST999.CN01.MOT01.speed');
      expect((route as RefusedRoute).reason, RouteRefusal.unmapped);
      expect(route.message, contains('ST999.CN01.MOT01.speed'));
    });

    test('it does not throw, and it does not fall through to a default link',
        () {
      final only = FakeUpstreamLink(alias: st101Alias, keys: [st101Key]);
      final router = KeyRouter(
        links: [UpstreamLinkBinding(only, serverAlias: st101Alias)],
        mappings: contractKitKeyMappings(),
      );

      expect(() => router.route(st201Key), returnsNormally);
      expect(router.route(st201Key), isNot(isA<ClaimedRoute>()));
    });
  });

  group('server_alias: null, which is what the live plant file holds', () {
    test('a null-alias entry routes to the one link bound to the unnamed '
        'server', () {
      final unnamed = FakeUpstreamLink(alias: st101Alias);
      final named = FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]);

      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(named, serverAlias: weigherAlias),
          UpstreamLinkBinding(unnamed, serverAlias: null),
        ],
        mappings: livePlantKeyMappings(),
      );

      expect((router.route(liveOpcUaKey) as ClaimedRoute).link, same(unnamed));
    });

    test('two links bound to the unnamed server is an ambiguity, not a '
        'first-match pick', () {
      // `_getClientWrapper` takes `firstWhereOrNull` here
      // (`state_man.dart:1670-1679`). Silently picking the first is how a
      // value from ST201 ends up on an ST101 page, and nothing anywhere says
      // it happened.
      final one = FakeUpstreamLink(alias: st101Alias);
      final two = FakeUpstreamLink(alias: st201Alias);

      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(one, serverAlias: null),
          UpstreamLinkBinding(two, serverAlias: null),
        ],
        mappings: livePlantKeyMappings(),
      );

      expect(router.ambiguousAliases, contains(null));
      final route = router.route(liveOpcUaKey);
      expect(route, isA<RefusedRoute>());
      expect((route as RefusedRoute).reason, RouteRefusal.ambiguousAlias);
      expect(route.message, contains(st101Alias));
      expect(route.message, contains(st201Alias));
    });

    test('the ambiguity is per alias — the keys on a named alias still route',
        () {
      final weigher =
          FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]);

      final router = KeyRouter(
        links: [
          // Explicit key sets, and this is not decoration: a fake built with
          // an empty one claims EVERYTHING, so a null-alias fake declared
          // ahead of the weigher would claim the weigher's key and this case
          // would be measuring declaration order rather than the ambiguity.
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: st101Alias, keys: [liveOpcUaKey]),
              serverAlias: null),
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: st201Alias, keys: [liveOpcUaKey]),
              serverAlias: null),
          UpstreamLinkBinding(weigher, serverAlias: weigherAlias),
        ],
        mappings: livePlantKeyMappings(),
      );

      expect((router.route(liveM2400Key) as ClaimedRoute).link, same(weigher));
      expect((router.route(liveOpcUaKey) as RefusedRoute).reason,
          RouteRefusal.ambiguousAlias);
    });

    test('two links on the same NAMED alias are ambiguous by the same rule',
        () {
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: 'st101-a'),
              serverAlias: st101Alias),
          UpstreamLinkBinding(FakeUpstreamLink(alias: 'st101-b'),
              serverAlias: st101Alias),
        ],
        mappings: contractKitKeyMappings(),
      );

      expect(router.ambiguousAliases, contains(st101Alias));
      expect((router.route(st101Key) as RefusedRoute).reason,
          RouteRefusal.ambiguousAlias);
    });
  });

  group('every route carries the handle the link minted', () {
    test('a claim carries the UpstreamRef, epoch and all', () {
      final link = FakeUpstreamLink(alias: st101Alias, keys: [st101Key]);
      final router = KeyRouter(
        links: [UpstreamLinkBinding(link, serverAlias: st101Alias)],
        mappings: contractKitKeyMappings(),
      );

      final route = router.route(st101Key) as ClaimedRoute;
      expect(route.ref.key, st101Key);
      expect(route.ref.alias, st101Alias);
      expect(route.ref.epoch, link.epoch);
    });

    test('a handle minted before an epoch bump is stale, and the next route '
        'mints a fresh one', () {
      final link = FakeUpstreamLink(alias: st101Alias, keys: [st101Key]);
      final router = KeyRouter(
        links: [UpstreamLinkBinding(link, serverAlias: st101Alias)],
        mappings: contractKitKeyMappings(),
      );

      final before = (router.route(st101Key) as ClaimedRoute).ref;
      link.bumpEpoch();
      final after = (router.route(st101Key) as ClaimedRoute).ref;

      expect(after.epoch, isNot(before.epoch));
      // The old handle is refused by the link itself — this is SRV-07 living
      // on the type, and the reason the router hands the ref back rather than
      // asking the caller to re-resolve inside one epoch.
      expect(link.peek(before), isNull);
    });
  });

  group('the live plant file loads and routes, all of it', () {
    test('430-shaped entries, Line1.Motor1 names, null server_alias — not one '
        'rejection', () {
      final mappings = generatedKeyMappings(430);
      final link = FakeUpstreamLink(alias: st101Alias);

      final router = KeyRouter(
        links: [UpstreamLinkBinding(link, serverAlias: null)],
        mappings: mappings,
      );

      expect(router.keys, hasLength(430));
      for (final key in mappings.nodes.keys) {
        expect(router.route(key), isA<ClaimedRoute>(),
            reason: 'the live file is the one input this router cannot be '
                'wrong about');
      }
    });

    test('both naming conventions route through the same router', () {
      final live = livePlantKeyMappings();
      final kit = contractKitKeyMappings();
      final merged = KeyMappings(nodes: {...live.nodes, ...kit.nodes});

      final unnamed = FakeUpstreamLink(alias: 'unnamed');
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: weigherAlias, keys: [liveM2400Key]),
              serverAlias: weigherAlias),
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: modbusAlias, keys: [liveModbusKey]),
              serverAlias: modbusAlias),
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: umasAlias, keys: [liveUmasKey]),
              serverAlias: umasAlias),
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: st101Alias, keys: [st101Key]),
              serverAlias: st101Alias),
          UpstreamLinkBinding(
              FakeUpstreamLink(alias: st201Alias, keys: [st201Key]),
              serverAlias: st201Alias),
          UpstreamLinkBinding(unnamed, serverAlias: null),
        ],
        mappings: merged,
      );

      for (final key in merged.nodes.keys) {
        expect(router.route(key), isA<ClaimedRoute>(), reason: key);
      }
      expect((router.route(liveOpcUaKey) as ClaimedRoute).link, same(unnamed));
    });
  });

  group('the result is sealed, so 08-05 cannot forget an arm', () {
    test('every route is exactly one of claimed, pipe key, or refused', () {
      final router = KeyRouter(
        links: [
          UpstreamLinkBinding(FakeUpstreamLink(alias: st101Alias, keys: [st101Key]),
              serverAlias: st101Alias),
        ],
        mappings: contractKitKeyMappings(),
      );

      for (final key in <String>[st101Key, PipeKeys.connected, st201Key]) {
        final route = router.route(key);
        final described = switch (route) {
          ClaimedRoute() => 'claimed',
          PipeKeyRoute() => 'pipe',
          RefusedRoute() => 'refused',
        };
        expect(described, isNotEmpty);
      }
    });
  });
}

/// A link that fails loudly if the router talks to it at all.
///
/// `noSuchMethod` rather than fifteen stub members: the point is that *no*
/// member is reachable, and a hand-written stub would have to remember to
/// throw from each new one the interface grows.
final class NeverAskedLink implements UpstreamLink {
  NeverAskedLink(this.alias);

  @override
  final String alias;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
      'the router consulted a link (${invocation.memberName}) for a key that '
      'should have short-circuited above the link loop');
}
