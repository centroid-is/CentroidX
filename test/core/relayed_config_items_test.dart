@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:tfc/core/device_local_preferences.dart'
    show kConfigItemsCachePrefsKey;
import 'package:tfc/core/relayed_config_items.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// The browser's mirror of the plant's configuration rows.
///
/// Three properties, each the one a browser was missing: the rows survive a
/// reload through the cache; a refresh fetches only when the backend's
/// fingerprint moved; and every trigger conflates into one refresh rather
/// than one per notification.
void main() {
  late InMemoryPreferences cache;
  late GatewayConfigItemsSlot slot;
  late _ScriptedRows backend;

  setUp(() {
    cache = InMemoryPreferences();
    slot = GatewayConfigItemsSlot();
    backend = _ScriptedRows();
  });

  RelayedConfigItems make() => RelayedConfigItems(
        cache: cache,
        slot: slot,
        logger: Logger(level: Level.off),
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the first boot', () {
    test('holds nothing before the client exists, and refresh says so',
        () async {
      final items = make();
      await items.restore();
      expect(items.isEmpty, isTrue);
      expect(items.keyMappings.keys, isEmpty);
      expect(await items.refresh(), isFalse,
          reason: 'no client yet — the ring RelayedPreferences documents');
    });

    test('a fill fetches every kind, one call per kind, and caches it',
        () async {
      final items = make();
      await items.restore();
      slot.fill(backend, backend.changes.stream);
      await settle();
      await settle();

      expect(backend.listedKinds, ['page', 'asset', 'key_mapping', 'preference'],
          reason: 'one kind per call is the size bound the protocol chose '
              'over paging');
      expect(items.itemsOf(const {ConfigKind.page}).map((i) => i.id),
          ['home']);
      expect(items.keyMappings.keys, ['tank.level'],
          reason: 'the key mappings the client is built from come out of the '
              'same rows');
      expect(await cache.getString(kConfigItemsCachePrefsKey), isNotNull,
          reason: 'the next boot must start from these before the link is up');
    });
  });

  group('the reload', () {
    test('the cached rows are what the next boot starts from', () async {
      final first = make();
      await first.restore();
      slot.fill(backend, backend.changes.stream);
      await settle();
      await settle();
      await first.dispose();

      // A new tab: same localStorage, no client yet.
      final second = RelayedConfigItems(
          cache: cache,
          slot: GatewayConfigItemsSlot(),
          logger: Logger(level: Level.off));
      await second.restore();
      expect(second.keyMappings.keys, ['tank.level'],
          reason: 'stateManProvider builds the client from these, before '
              'anybody has signed in');
      expect(second.fingerprint, backend.fingerprintNow);
    });
  });

  group('freshness', () {
    test('an unchanged fingerprint fetches nothing', () async {
      final items = make();
      await items.restore();
      slot.fill(backend, backend.changes.stream);
      await settle();
      await settle();
      final listsAfterFill = backend.listedKinds.length;

      backend.changes.add('some_preference');
      await settle();
      await settle();

      expect(backend.fingerprintCalls, greaterThanOrEqualTo(2),
          reason: 'the notification asks the fingerprint');
      expect(backend.listedKinds.length, listsAfterFill,
          reason: 'and fetches nothing, because nothing moved');
    });

    test('a moved fingerprint fetches a fresh snapshot and announces it',
        () async {
      final items = make();
      await items.restore();
      slot.fill(backend, backend.changes.stream);
      await settle();
      await settle();
      var announced = 0;
      items.changed.listen((_) => announced++);

      backend.rename('home', 'plant');
      backend.changes.add('page_editor_data');
      await settle();
      await settle();

      expect(items.itemsOf(const {ConfigKind.page}).map((i) => i.id),
          ['plant']);
      expect(announced, 1);
    });

    test('a burst of notifications is one refresh, not one each', () async {
      final items = make();
      await items.restore();
      slot.fill(backend, backend.changes.stream);
      await settle();
      await settle();
      final before = backend.fingerprintCalls;

      backend.holdFingerprints = true;
      for (var i = 0; i < 5; i++) {
        backend.changes.add('key_$i');
      }
      await settle();
      backend.holdFingerprints = false;
      backend.releaseFingerprints();
      await settle();
      await settle();
      await settle();

      expect(backend.fingerprintCalls - before, lessThanOrEqualTo(2),
          reason: 'one refresh was running, the burst marked it dirty, and '
              'at most one more ran afterwards — conflate, never queue');
    });

    test('a refusal before sign-in is answered false, not thrown', () async {
      final items = make();
      await items.restore();
      backend.refuse = true;
      slot.fill(backend, backend.changes.stream);
      await settle();
      expect(await items.refresh(), isFalse);
      expect(items.isEmpty, isTrue);

      backend.refuse = false;
      slot.requestRefresh();
      await settle();
      await settle();
      expect(items.isEmpty, isFalse,
          reason: 'the sign-in path requests a refresh, and that is the '
              'first read that can succeed');
    });
  });
}

/// A backend holding one page, one asset, one key mapping and one preference.
final class _ScriptedRows implements rp.ConfigItemsApi {
  final changes = StreamController<String>.broadcast();
  final listedKinds = <String>[];
  int fingerprintCalls = 0;
  bool refuse = false;
  bool holdFingerprints = false;
  final _held = <Completer<void>>[];

  final _rows = <rp.ConfigItemRecord>[
    const rp.ConfigItemRecord(
        kind: 'page',
        id: 'home',
        payload: '{"menu_item":{"label":"Home","path":"/"}}',
        rev: 1),
    const rp.ConfigItemRecord(
        kind: 'asset', id: 'a1', parentId: 'home', payload: '{}', rev: 1),
    const rp.ConfigItemRecord(
        kind: 'key_mapping',
        id: 'tank.level',
        payload: '{"opcua_node":{"namespace":2,"identifier":"tank"}}',
        rev: 3),
    const rp.ConfigItemRecord(
        kind: 'preference',
        id: 'page_editor_top_level_order',
        payload: '{"t":"s","v":"[\\"/\\"]"}',
        rev: 1),
  ];

  rp.ConfigItemsFingerprint get fingerprintNow => rp.ConfigItemsFingerprint(
        count: _rows.length,
        revSum: _rows.fold(0, (sum, r) => sum + r.rev),
      );

  void rename(String id, String to) {
    final index = _rows.indexWhere((r) => r.id == id);
    final old = _rows[index];
    _rows[index] = rp.ConfigItemRecord(
        kind: old.kind, id: to, payload: old.payload, rev: old.rev + 1);
  }

  void releaseFingerprints() {
    for (final c in _held) {
      c.complete();
    }
    _held.clear();
  }

  @override
  Future<List<rp.ConfigItemRecord>> items(String kind) async {
    if (refuse) throw StateError('awaiting_sign_in');
    listedKinds.add(kind);
    return [for (final r in _rows) if (r.kind == kind) r];
  }

  @override
  Future<rp.ConfigItemsFingerprint> fingerprint(List<String> kinds) async {
    if (refuse) throw StateError('awaiting_sign_in');
    fingerprintCalls++;
    if (holdFingerprints) {
      final c = Completer<void>();
      _held.add(c);
      await c.future;
    }
    return fingerprintNow;
  }
}
