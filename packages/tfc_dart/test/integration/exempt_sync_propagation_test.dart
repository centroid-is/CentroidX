// The exempt kind, between two stations, against a real Postgres.
//
// `ConfigKind.pageImage` writes no `config_change` rows at all (C-3), and both
// of the ways a station learns that another station wrote something are driven
// entirely by change rows: the NOTIFY trigger is `AFTER INSERT ON
// config_change`, and the fast path is a `config_change.id` watermark. So an
// image is invisible to both, and without the reconcile nudge 04-01 added it
// would reach the other panels only on the five-minute rev sweep — station A
// uploads a picture and saves the mimic, station B has the asset in seconds and
// a hole where the picture goes until the sweep. That is T-04-09d, and it is a
// regression against the keyed `flutter_preferences` trigger this milestone
// replaces.
//
// This is the lane that can prove it. SQLite has no LISTEN/NOTIFY, so the cheap
// suite can assert that the nudge payload is *encoded*, and nothing more; only
// a server can show it being delivered and acted on.
//
// **The sweep is switched off in all but name** — B runs with a one-hour
// interval — so a test here cannot pass because a poll rescued it. Everything
// B learns, it learns from a notification.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time, and from `packages/tfc_dart`: the compose lifecycle here issues a bare
// `docker compose down`, whose blast radius is entirely a property of the
// working directory it runs in.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'docker_compose.dart';
import 'eventually.dart';

/// The payload `PageImageStore` writes: a map, because `ConfigItem.decode()`
/// casts to one, holding the base64 of the bytes.
ConfigItem imageItem(String id, String bytes) => ConfigItem.of(
      kind: ConfigKind.pageImage,
      id: id,
      value: {'b64': base64Encode(utf8.encode(bytes))},
    );

ConfigItem pageItem(String id, String path) => ConfigItem.of(
      kind: ConfigKind.page,
      id: id,
      value: {
        'menu_item': {'label': path, 'path': path},
        'assets': <Object?>[],
      },
    );

ConfigItem assetItem(String id, String pageId, String imageId) => ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'asset_name': 'ImageConfig', 'image_id': imageId},
      parentId: pageId,
      sortIndex: 0,
    );

void main() {
  group('an exempt kind between two stations', () {
    late Database remote;

    /// A second connection, standing in for a `psql` session: it counts and it
    /// asserts. Assertions must not ride the connection under test.
    late pg.Connection other;

    var station = 0;
    var action = 0;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      remote = await connectToDatabase();
      other = await getTestConnection();
    });

    tearDownAll(() async {
      await other.close();
      await remote.close();
      await stopDockerCompose();
    });

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
    });

    /// A station: its own local SQLite file, its own store, one shared remote.
    ///
    /// [sweepInterval] is an hour, and that is the whole point of the file: a
    /// test that asserts on the notification path must not be able to pass
    /// because a poll rescued it.
    Future<ConfigStore> newStation({
      Duration sweepInterval = const Duration(hours: 1),
    }) async {
      final name = 'station-${station++}';
      final dir = await Directory.systemTemp.createTemp('exempt-sync-$name-');
      final local = AppDatabase.createLocal(dir);
      final store = ConfigStore(
        local: local,
        stationScope: ConfigScope.forStation(name),
        station: name,
        sweepInterval: sweepInterval,
      );
      addTearDown(() async {
        await store.syncSettled;
        await store.close();
        await local.close();
        await dir.delete(recursive: true);
      });
      await store.open();
      // The production path, wrapper and all: the notification channel is what
      // is under test, and `attachRemoteDatabase` does not open one.
      store.attachRemote(remote);
      await store.syncSettled;
      return store;
    }

    Future<ConfigWriteResult> write(
      ConfigStore store, {
      required Set<ConfigKind> kinds,
      required List<ConfigItem> wanted,
    }) =>
        store.writeItems(
          kinds: kinds,
          wanted: wanted,
          actionId: 'action-${action++}',
          who: 'tester',
          roleName: 'Engineering',
        );

    /// What [store] holds for [kind], by id.
    Map<String, ConfigItem> heldBy(ConfigStore store, ConfigKind kind) => {
          for (final item in store.itemsOf({kind})) item.id: item,
        };

    Future<int> changeRowsFor(String kind) async {
      final result = await other.execute(
        pg.Sql.named(
            'SELECT count(*) FROM config_change WHERE kind = @kind'),
        parameters: {'kind': kind},
      );
      return (result.first.first! as num).toInt();
    }

    test('an image A uploads reaches B without a change row to carry it',
        () async {
      final a = await newStation();
      final b = await newStation();

      await write(a,
          kinds: const {ConfigKind.pageImage},
          wanted: [imageItem('aaa111', 'the multivac photo')]);

      // The premise, asserted rather than assumed: there is nothing in the
      // change log for the watermark path to find, so anything B learns it
      // learns from the nudge.
      expect(await changeRowsFor(ConfigKind.pageImage.wireName), 0);

      await eventually(
        () => heldBy(b, ConfigKind.pageImage).keys.toList(),
        equals(['aaa111']),
        reason: 'the reconcile nudge is the only way this row can arrive — the '
            'sweep is an hour away and the change log is empty',
      );
      expect(
        base64Decode(
            heldBy(b, ConfigKind.pageImage)['aaa111']!.decode()['b64']
                as String),
        utf8.encode('the multivac photo'),
      );
    });

    test('a collection on A removes the ghost on B the same way', () async {
      final a = await newStation();
      final b = await newStation();

      await write(a, kinds: const {ConfigKind.pageImage}, wanted: [
        imageItem('aaa111', 'kept'),
        imageItem('bbb222', 'orphan'),
      ]);
      await eventually(
          () => heldBy(b, ConfigKind.pageImage).keys.toList()..sort(),
          equals(['aaa111', 'bbb222']));

      // `removeUnreferenced` is one guarded save of the referenced set;
      // replace-within-kind does the deleting.
      await write(a,
          kinds: const {ConfigKind.pageImage},
          wanted: [imageItem('aaa111', 'kept')]);

      expect(await changeRowsFor(ConfigKind.pageImage.wireName), 0,
          reason: 'a deletion of an exempt row is not history either — it is '
              'the other 6.7 MB C-3 was about');
      await eventually(() => heldBy(b, ConfigKind.pageImage).keys.toList(),
          equals(['aaa111']));
    });

    test('a save carrying an asset and its image lands whole on B', () async {
      final a = await newStation();
      final b = await newStation();

      // One action over three kinds: the page, the asset that draws the
      // picture, and the picture. The trigger fires for the page and asset
      // change rows; the nudge fires for the image, which has none. B is only
      // "whole" when both have been acted on.
      await write(a, kinds: const {
        ConfigKind.page,
        ConfigKind.asset,
        ConfigKind.pageImage,
      }, wanted: [
        pageItem('page-1', '/packing'),
        assetItem('asset-1', 'page-1', 'aaa111'),
        imageItem('aaa111', 'the multivac photo'),
      ]);

      // A list of two lists rather than a record: `equals`' deep matcher does
      // not descend into records, so a record probe fails on a value that is
      // right — which is a test that can only ever be red.
      await eventually(
        () => [
          heldBy(b, ConfigKind.asset).keys.toList(),
          heldBy(b, ConfigKind.pageImage).keys.toList(),
        ],
        equals([
          ['asset-1'],
          ['aaa111'],
        ]),
        reason: 'the asset arriving without its image is the broken-image '
            'window T-04-09d is about',
      );

      // And the asset really does point at the image that arrived, so this is
      // not two unrelated rows that happened to both be there.
      final asset = heldBy(b, ConfigKind.asset)['asset-1']!;
      expect(asset.decode()['image_id'], 'aaa111');
      expect(heldBy(b, ConfigKind.pageImage), contains('aaa111'));

      // The mixed action wrote history for the halves that have it and none
      // for the half that does not.
      expect(await changeRowsFor(ConfigKind.asset.wireName), 1);
      expect(await changeRowsFor(ConfigKind.page.wireName), 1);
      expect(await changeRowsFor(ConfigKind.pageImage.wireName), 0);
    });

    test('B does not advance its watermark on a nudge', () async {
      // A nudge names kinds that write no change rows, so there is nothing for
      // the watermark to advance to — and advancing it anyway would carry it
      // past change rows this station has not read, losing another station's
      // ordinary edits silently.
      final a = await newStation();
      final b = await newStation();

      await write(a,
          kinds: const {ConfigKind.keyMapping},
          wanted: [
            ConfigItem.of(
              kind: ConfigKind.keyMapping,
              id: 'a_key',
              value: {
                'opcua_node': {'namespace': 4, 'identifier': 'N'},
              },
            ),
          ]);
      await eventually(
          () => heldBy(b, ConfigKind.keyMapping).keys.toList(),
          equals(['a_key']));
      // **The snapshot lands before the watermark does.** `_pull` applies the
      // rows and only then advances (`config_sync.dart`, `_apply` then
      // `_advanceWatermark`, two awaits apart), so `heldBy` going true says
      // nothing about the watermark yet. Reading it here without settling
      // first is a timing assumption that holds on a fast runner and not on a
      // slow one — inserting a 400 ms delay between those two statements
      // reproduces the Windows failure exactly, and only in this test.
      await b.syncSettled;
      final watermark = b.watermark;
      expect(watermark, greaterThan(0));

      await write(a,
          kinds: const {ConfigKind.pageImage},
          wanted: [imageItem('aaa111', 'a picture')]);
      await eventually(() => heldBy(b, ConfigKind.pageImage).keys.toList(),
          equals(['aaa111']));
      // Settled on this side too, and for the opposite reason: the assertion
      // below is that nothing advanced, and a watermark write still in flight
      // would let it pass while the advance it forbids happened a moment
      // later. Both halves have to be quiescent for the comparison to mean
      // what it says.
      await b.syncSettled;

      expect(b.watermark, watermark,
          reason: 'the nudge is not a change-log event and must not be '
              'consumed as one');
    });
  });
}
