// The page-image store, once its blobs stopped being preferences.
//
// Three things are proved here that the old preference-backed suite could not
// even express:
//
//   1. an image is a `config_item` row of `kind='page_image'`, written through
//      the one guarded save, so an upload is checked and appears in the trail
//      like every other configuration write;
//   2. neither a put nor a garbage-collection pass writes a `config_change`
//      row — C-3's defusal, asserted at the call site rather than only in
//      04-01's unit test of the policy;
//   3. a re-put of identical bytes writes *nothing at all*, which is what
//      content addressing is for.
//
// (2) is asserted by serialising the whole change table before and after and
// comparing the two, rather than by counting rows against a number this test
// expects: a count assertion passes just as happily when the writer stopped
// writing for some other reason.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'package:tfc/page_creator/assets/image_store.dart';

import '../helpers/image_fixtures.dart';
import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GuardedConfigStore guarded;
  late AppDatabase remote;
  late PageImageStore store;

  /// The whole change log, serialised. Compared before and after an operation
  /// that must not touch it — the absence of a row is what is being proved,
  /// and only a whole-table comparison can prove an absence.
  Future<List<String>> changeLog() async => [
        for (final row in await (remote.select(remote.configChangeTable)
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get())
          row.toString(),
      ];

  Future<List<ConfigItemRow>> imageRows() =>
      (remote.select(remote.configItemTable)
            ..where((t) => t.kind.equals(ConfigKind.pageImage.wireName))
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  setUp(() async {
    guarded = await createTestConfigStore(
      session: kConfiguringTestSession,
      onRemote: (r) => remote = r,
    );
    store = PageImageStore(guarded);
  });

  group('PageImageStore over page_image rows', () {
    test('a put stores the bytes once, under the content-derived id',
        () async {
      final id = await store.save(fixturePngBytes);

      expect(id, await PageImageStore.imageIdFor(fixturePngBytes));
      expect(await store.load(id), fixturePngBytes);
      expect(await store.storedIds(), {id});

      final rows = await imageRows();
      expect(rows, hasLength(1));
      expect(rows.single.id, id);
      expect(rows.single.scope, ConfigScope.shared.wireName);
      // The payload is a map, because `ConfigItem.decode()` casts to one. A
      // bare base64 string would read back as a corrupt row on every path
      // that goes through the item rather than through this class.
      final payload = jsonDecode(rows.single.payload);
      expect(payload, isA<Map<String, dynamic>>());
      expect(base64Decode((payload as Map)['b64'] as String), fixturePngBytes);
    });

    test('the same bytes dedupe to one row and the re-put writes nothing',
        () async {
      final a = await store.save(fixturePngBytes);
      final rowsAfterFirst = await imageRows();

      final b = await store.save(fixturePngBytes);
      final c = await store.save(fixtureJpegBytes);

      expect(a, b);
      expect(a, isNot(c));
      expect(await store.storedIds(), {a, c});
      // The re-put did not touch the row it found: same rev, same timestamp.
      final png = (await imageRows()).firstWhere((r) => r.id == a);
      expect(png.rev, rowsAfterFirst.single.rev);
      expect(png.updatedAt, rowsAfterFirst.single.updatedAt);
    });

    test('an unknown id and a corrupt payload both load as null', () async {
      expect(await store.load('feedfacefeedfacefeedface'), isNull);

      // A row somebody hand-edited: right kind, right id, payload nothing can
      // decode. One bad image must cost that image and never the page.
      await guarded.save(
        [
          ConfigItem.of(
            kind: ConfigKind.pageImage,
            id: 'bad',
            value: const {'b64': 'not base64!!'},
          ),
        ],
        kind: ConfigKind.pageImage,
      );
      expect(await store.load('bad'), isNull);
      expect(await store.storedIds(), {'bad'});
    });

    test('refuses blobs over the cap, before encoding one', () async {
      final big = Uint8List(PageImageStore.maxBytes + 1);
      await expectLater(
          store.save(big), throwsA(isA<PageImageTooLargeException>()));
      expect(await store.storedIds(), isEmpty);
      expect(await imageRows(), isEmpty);
    });

    test('removeUnreferenced deletes the orphans and pins the siblings',
        () async {
      final keep = await store.save(fixturePngBytes);
      final drop = await store.save(fixtureJpegBytes);
      final alsoKeep = await store.save(fixtureBmpBytes);

      final removed = await store.removeUnreferenced({keep, alsoKeep});

      expect(removed, 1);
      expect(await store.storedIds(), {keep, alsoKeep});
      expect(await store.load(drop), isNull);
      // T-04-09c: the wanted set is built from the referenced ids, so a
      // collection that removes one must leave the others' bytes readable.
      expect(await store.load(keep), fixturePngBytes);
      expect(await store.load(alsoKeep), fixtureBmpBytes);
    });

    test('keepNewerThan spares an unreferenced image that was just stored',
        () async {
      // An image is stored when it is picked and referenced when its page is
      // saved, on whichever station picked it. A collector on another
      // station in between must not take it.
      final fresh = await store.save(fixturePngBytes);

      expect(
          await store.removeUnreferenced({},
              keepNewerThan:
                  DateTime.now().subtract(const Duration(hours: 24))),
          0);
      expect(await store.storedIds(), {fresh});

      // And a cut-off in the future spares nothing: the grace is by age.
      expect(
          await store.removeUnreferenced({},
              keepNewerThan: DateTime.now().add(const Duration(hours: 1))),
          1);
      expect(await store.storedIds(), isEmpty);
    });

    test('a collection that removes nothing writes nothing', () async {
      final keep = await store.save(fixturePngBytes);
      final before = await imageRows();

      expect(await store.removeUnreferenced({keep}), 0);

      final after = await imageRows();
      expect(after.single.rev, before.single.rev);
      expect(after.single.updatedAt, before.single.updatedAt);
    });

    test('neither a put nor a garbage collection writes a config_change row',
        () async {
      // Seeded through the store so the log has something in it: an assertion
      // that two empty lists are equal proves nothing about a writer.
      final seeded = await guarded.saveKeyMappings(
        sampleKeyMappings(),
        reason: 'so the change log is not empty',
      );
      expect(seeded.diff.isEmpty, isFalse);
      final before = await changeLog();
      expect(before, isNotEmpty);

      final keep = await store.save(fixturePngBytes);
      final drop = await store.save(fixtureJpegBytes);
      expect(await changeLog(), before,
          reason: 'C-3: an image put carries no history');

      expect(await store.removeUnreferenced({keep}), 1);
      expect(await changeLog(), before,
          reason: 'C-3: nor does collecting one');

      // And the rows themselves did happen — otherwise the assertions above
      // would pass on a store that wrote nothing at all.
      expect(await imageRows(), hasLength(1));
      expect(await store.load(drop), isNull);
    });

    test('the exemption is the kind, not a preference-key prefix', () {
      expect(historyExempt(ConfigKind.pageImage, 'anything'), isTrue);
      expect(
        historyExempt(ConfigKind.preference, 'page_editor_image:abc'),
        isFalse,
        reason: '04-05 exempted these by id prefix while images were still '
            'preferences; the prefix hack came out with this plan',
      );
    });
  });

  group('the guard in front of it', () {
    test('an image upload is checked at configure and refused without it',
        () async {
      final anonymous = await createTestConfigStore(
        onRemote: (r) => remote = r,
      );
      final refused = PageImageStore(anonymous);

      await expectLater(
          refused.save(fixturePngBytes), throwsA(isA<AccessDenied>()));
      expect(await imageRows(), isEmpty);
    });

    test('the upload lands in the audit trail', () async {
      final audit = _RecordingAuditSink();
      final signedIn = await createTestConfigStore(
        session: kConfiguringTestSession,
        audit: audit,
        onRemote: (r) => remote = r,
      );

      await PageImageStore(signedIn).save(fixturePngBytes);

      final row = audit.rows.single;
      expect(row.allowed, isTrue);
      expect(row.surface, 'pref');
      // The same key the page and its assets are checked under: an image is
      // not separately permissioned from the mimic that draws it.
      expect(row.itemKey, kConfigWriteKeys[ConfigKind.pageImage]);
      expect(row.groupRequired, 'configure');
    });
  });
}

class _RecordingAuditSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}
