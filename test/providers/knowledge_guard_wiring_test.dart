// The knowledge base's wiring: three providers that used to hand out raw Drift
// indexes now hand out the guards, and the five places that type-tested for the
// concrete `DriftPlcCodeIndex` type-test for `PlcCodeIndexExtras` instead.
//
// The four call-graph tests below are the point of this file. They are reads —
// they feed the PLC detail panel — and before the type-test move they fail by
// returning `[]`, silently, with nothing thrown and nothing logged. They were
// written and observed **passing against the unwrapped providers**, then
// observed **failing the moment the wrap landed**, then made to pass again by
// moving the type test. A test that only ever passed would say nothing about
// the most dangerous change in this plan.
//
// `ProviderContainer` rather than widget tests — this is provider graph
// behaviour and does not need a tree.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart' show Icons;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import 'package:tfc/core/config/page_codec.dart' show pageItems;
import 'package:tfc/core/guarded_knowledge_stores.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart' show Asset;
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/page.dart' show AssetPage;
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/drawing.dart';
import 'package:tfc/providers/plc.dart';
import 'package:tfc/providers/server_database.dart';
import 'package:tfc/providers/tech_doc.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

const String _kStation = 'test-panel';

/// The `action_id` the fixture layout is seeded under, so the `config_change`
/// rows a test asserts on are the ones the *cleanup* wrote.
const String _kSeedAction = 'test-seed';

/// The asset the fixture indexes.
const String _kAsset = 'CN01';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _FakeAuthProvider implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    if (username == 'jon' && password == 'correct horse') {
      return const AuthenticatedUser(username: 'jon', roleName: 'Engineering');
    }
    return null;
  }
}

/// An in-memory stand-in for the OS keychain.
class _MemorySecrets implements MySecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

ParsedCodeBlock _block({
  required String name,
  required String type,
  required String declaration,
  String? implementation,
  required String filePath,
  List<ParsedVariable> variables = const [],
}) =>
    ParsedCodeBlock(
      name: name,
      type: type,
      declaration: declaration,
      implementation: implementation,
      fullSource: [declaration, if (implementation != null) implementation]
          .join('\n'),
      filePath: filePath,
      variables: variables,
      children: const [],
    );

/// A program that writes two of its own variables, declares an FB instance and
/// calls it, and writes a GVL variable — enough to populate all three call-graph
/// tables the four providers read.
List<ParsedCodeBlock> _fixtureBlocks() => [
      _block(
        name: 'FB_Pump',
        type: 'FunctionBlock',
        declaration: 'VAR\n  speed : REAL;\nEND_VAR',
        implementation: 'speed := 100.0;',
        filePath: 'POUs/FB_Pump.TcPOU',
        variables: const [
          ParsedVariable(name: 'speed', type: 'REAL', section: 'VAR'),
        ],
      ),
      _block(
        name: 'MAIN',
        type: 'Program',
        declaration:
            'VAR\n  pump1 : FB_Pump;\n  running : BOOL;\nEND_VAR',
        implementation:
            'pump1();\nrunning := TRUE;\nGVL_Main.pump3_speed := 42.0;',
        filePath: 'POUs/MAIN.TcPOU',
        variables: const [
          ParsedVariable(name: 'pump1', type: 'FB_Pump', section: 'VAR'),
          ParsedVariable(name: 'running', type: 'BOOL', section: 'VAR'),
        ],
      ),
    ];

/// A layout carrying [docId] twice: on a top-level asset, and on a subdevice
/// inside a composite.
///
/// **Built through the model, never as a JSON string.** The fixture this
/// replaces hand-wrote `{"page1":{"assets":{"a1":{"techDocId":3}}}}` — an
/// object where `AssetPage.toJson()` emits an array — so it agreed with the
/// `assets is! Map<String, dynamic>` guard that skipped every real page, and
/// the cleanup went a year without removing one id (D-4). Ids are set by hand
/// so an assertion can name a row.
Map<String, AssetPage> _layoutLinkedTo(int docId) {
  final linked = LEDConfig(key: 'CN04.Run')
    ..id = 'led-linked'
    ..techDocId = docId;
  final spare = LEDConfig(key: 'CN05.Run')..id = 'led-spare';
  final slice = BeckhoffEL1008Config(nameOrId: '1')..techDocId = docId;
  final rack = BeckhoffCX5010Config()
    ..id = 'rack'
    ..subdevices = <Asset>[slice];
  return {
    '/': AssetPage(
      menuItem: const MenuItem(label: 'Home', icon: Icons.home, path: '/'),
      assets: [linked, spare, rack],
      mirroringDisabled: false,
    )..id = 'page-home',
  };
}

// ---------------------------------------------------------------------------
// The container
// ---------------------------------------------------------------------------

class _Wiring {
  _Wiring({
    required this.container,
    required this.sink,
    required this.mcpDb,
    required this.denials,
    required this.mainBlockId,
    required this.configStore,
    required this.configRemote,
  });

  final ProviderContainer container;
  final _RecordingSink sink;
  final ServerDatabase mcpDb;
  final List<AccessDenied> denials;

  /// The database id of the indexed `MAIN` block, which the two block-scoped
  /// call-graph providers are keyed on.
  final int mainBlockId;

  /// The shared configuration store the cleanup rewrites, unguarded, so a
  /// test can seed a layout and read back what the cleanup left.
  final ConfigStore configStore;

  /// The stand-in for Postgres behind [configStore], for the `config_change`
  /// rows a cleanup wrote — one per asset that actually moved is the claim
  /// SC-1 makes, and it cannot be read off the snapshot.
  final AppDatabase configRemote;

  /// The asset items the store holds right now, by id.
  Map<String, ConfigItem> get assetsById => {
        for (final item in configStore.itemsOf(const {ConfigKind.asset}))
          item.id: item,
      };

  /// The `config_change` rows written since the store was seeded.
  Future<List<String>> changedAssetIds() async {
    final rows = await configRemote.select(configRemote.configChangeTable).get();
    return [
      for (final row in rows)
        if (row.kind == ConfigKind.asset.wireName &&
            row.actionId != _kSeedAction)
          row.entityId,
    ]..sort();
  }

  /// Denials reach `accessDenialsProvider` through a broadcast stream, which
  /// delivers asynchronously. Every assertion on [denials] has to let the
  /// microtask queue drain first.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  AccessSessionController get session =>
      container.read(accessSessionProvider.notifier);

  Future<void> signIn() async {
    await container.read(accessSessionProvider.future);
    final result = await session.signIn('jon', 'correct horse');
    expect(result, AccessSignInResult.ok);
  }
}

/// A container with the real knowledge providers, an in-memory MCP database
/// carrying a genuinely indexed asset, and no Postgres.
Future<_Wiring> _wiring({
  bool indexFixture = true,
  Map<String, AssetPage>? layout,
  bool configOnline = true,
}) async {
  final accessDb = AppDatabase.inMemoryForTest();
  addTearDown(accessDb.close);
  // Force the migration, so the four seeded roles exist.
  await accessDb.customSelect('SELECT 1').getSingle();
  final repository = AccessRepository(accessDb);

  final mcpDb = ServerDatabase.inMemory();
  addTearDown(mcpDb.close);
  await mcpDb.customStatement('SELECT 1');

  var mainBlockId = 0;
  if (indexFixture) {
    // Fixture setup goes through the raw index on purpose: what is under test
    // is what the *provider* hands out, not how the rows got there.
    final raw = DriftPlcCodeIndex(mcpDb);
    await raw.indexAsset(_kAsset, _fixtureBlocks());
    final blocks = await raw.getBlocksForAsset(_kAsset);
    mainBlockId = blocks.firstWhere((b) => b.blockName == 'MAIN').id;
  }

  final sink = _RecordingSink();
  // The shared configuration store the page-layout cleanup rewrites. Real
  // store, real codec, in-memory databases: the seam under test is the one
  // production uses, and the only thing standing in is Postgres itself.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final configLocal = AppDatabase.inMemoryForTest();
  final configRemote = AppDatabase.inMemoryForTest();
  addTearDown(configLocal.close);
  addTearDown(configRemote.close);
  final configStore = ConfigStore(
    local: configLocal,
    stationScope: ConfigScope.forStation(_kStation),
    station: _kStation,
  );
  addTearDown(configStore.close);
  await configStore.open();
  configStore.attachRemoteDatabase(configRemote, startSync: false);
  if (layout != null) {
    await configStore.writeItems(
      kinds: const {ConfigKind.page, ConfigKind.asset},
      wanted: pageItems(layout),
      actionId: _kSeedAction,
      who: 'test',
      roleName: 'system',
    );
  }
  if (!configOnline) {
    // A station that seeded its mirror and then lost Postgres: the snapshot
    // still answers, and every shared write is refused.
    configStore.detachRemote();
  }

  final container = ProviderContainer(
    overrides: [
      // The guarded store, wired to this container's own policy, session and
      // audit sink — so a refusal here is the same refusal production gets.
      configStoreProvider.overrideWith((ref) async => GuardedConfigStore(
            inner: configStore,
            policy: ref.read(accessPolicyProvider),
            session: () => sessionInForce(ref),
            audit: RefAuditSink(ref),
            station: _kStation,
            onDenied: (denial) => reportAccessDenial(ref, denial),
          )),
      // No Postgres. The knowledge indexes get their own in-memory database
      // through `mcpDatabaseProvider`, which is the seam the three providers
      // actually read.
      databaseProvider.overrideWith((ref) async => null),
      mcpDatabaseProvider.overrideWithValue(mcpDb),
      accessRepositoryProvider.overrideWith((ref) async => repository),
      authProviderProvider.overrideWith((ref) async => _FakeAuthProvider()),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
    ],
  );
  addTearDown(container.dispose);

  final denials = <AccessDenied>[];
  final sub = container.read(accessDenialsProvider).listen(denials.add);
  addTearDown(sub.cancel);

  return _Wiring(
    container: container,
    sink: sink,
    mcpDb: mcpDb,
    denials: denials,
    mainBlockId: mainBlockId,
    configStore: configStore,
    configRemote: configRemote,
  );
}

// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    SecureStorage.setInstance(_MemorySecrets());
  });

  // -------------------------------------------------------------------------
  // The four call-graph providers — the ones the wrap would have silenced
  // -------------------------------------------------------------------------

  group('the four call-graph providers still answer real data', () {
    test('plcVarRefsForBlockProvider', () async {
      final w = await _wiring();

      final refs = await w.container
          .read(plcVarRefsForBlockProvider(w.mainBlockId).future);

      expect(refs, isNotEmpty,
          reason: 'an empty list here is exactly how this breaks silently');
      expect(
          refs
              .where((r) => r.kind == 'write')
              .map((r) => r.variablePath)
              .toSet(),
          contains('MAIN.running'));
    });

    test('plcFbInstancesProvider', () async {
      final w = await _wiring();

      final instances =
          await w.container.read(plcFbInstancesProvider(_kAsset).future);

      expect(instances, isNotEmpty);
      expect(instances.map((i) => i.instanceName), contains('pump1'));
    });

    test('plcBlockCallsProvider', () async {
      final w = await _wiring();

      final calls =
          await w.container.read(plcBlockCallsProvider(w.mainBlockId).future);

      expect(calls, isNotEmpty);
      expect(calls.map((c) => c.calleeBlockName), contains('pump1'));
    });

    test('plcVarRefsProvider', () async {
      final w = await _wiring();

      final refs =
          await w.container.read(plcVarRefsProvider('pump3_speed').future);

      expect(refs, isNotEmpty);
      expect(refs.first.variablePath, contains('pump3_speed'));
    });

    test('and all four still answer [] when there is no database at all',
        () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => null),
        mcpDatabaseProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);

      expect(await container.read(plcVarRefsForBlockProvider(1).future),
          isEmpty);
      expect(await container.read(plcFbInstancesProvider(_kAsset).future),
          isEmpty);
      expect(await container.read(plcBlockCallsProvider(1).future), isEmpty);
      expect(await container.read(plcVarRefsProvider('x').future), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // What the providers hand out
  // -------------------------------------------------------------------------

  group('the three providers hand out the guards', () {
    test('techDocIndexProvider returns a GuardedTechDocIndex', () async {
      final w = await _wiring();
      expect(w.container.read(techDocIndexProvider),
          isA<GuardedTechDocIndex>());
    });

    test('plcCodeIndexProvider returns a GuardedPlcCodeIndex', () async {
      final w = await _wiring();
      final index = w.container.read(plcCodeIndexProvider);
      expect(index, isA<GuardedPlcCodeIndex>());
      expect(index, isA<PlcCodeIndexExtras>(),
          reason: 'this is what the four call-graph providers type-test for');
    });

    test('drawingIndexProvider returns a GuardedDrawingIndex', () async {
      final w = await _wiring();
      expect(w.container.read(drawingIndexProvider),
          isA<GuardedDrawingIndex>());
    });

    test('drawingUploadServiceProvider is built over the guard', () async {
      final w = await _wiring();
      final service = w.container.read(drawingUploadServiceProvider);
      expect(service, isNotNull);

      // The service holds its index privately, so the proof is behavioural:
      // an anonymous delete must be refused rather than reach the database.
      await expectLater(service!.deleteDrawing('Panel-A Main Wiring'),
          throwsA(isA<AccessDenied>()));
    });

    test('all three answer null when there is no database', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => null),
        mcpDatabaseProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);

      expect(container.read(techDocIndexProvider), isNull);
      expect(container.read(plcCodeIndexProvider), isNull);
      expect(container.read(drawingIndexProvider), isNull);
      expect(container.read(drawingUploadServiceProvider), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The caching the wrap had to preserve
  // -------------------------------------------------------------------------

  group('the database-identity caching survived the wrap', () {
    test('techDocIndexProvider answers the same instance twice', () async {
      final w = await _wiring();
      expect(
          identical(w.container.read(techDocIndexProvider),
              w.container.read(techDocIndexProvider)),
          isTrue);
    });

    test('plcCodeIndexProvider answers the same instance twice', () async {
      final w = await _wiring();
      expect(
          identical(w.container.read(plcCodeIndexProvider),
              w.container.read(plcCodeIndexProvider)),
          isTrue);
    });

    test('a session change does not replace the cached index', () async {
      final w = await _wiring();
      final before = w.container.read(plcCodeIndexProvider);

      await w.signIn();
      await w.session.signOut();

      // A provider that rebuilt here would re-trigger every downstream
      // FutureProvider on the Knowledge Base page on every sign-in.
      expect(identical(before, w.container.read(plcCodeIndexProvider)), isTrue);
    });

    test('the resolving audit sink does not rebuild the index providers',
        () async {
      final w = await _wiring();
      final before = w.container.read(techDocIndexProvider);

      // Resolving the sink is what a station does when Postgres finally opens.
      await w.container.read(auditSinkProvider.future);

      expect(identical(before, w.container.read(techDocIndexProvider)), isTrue);
    });

    test('no provider watches auditSinkProvider — the sink is reached lazily',
        () {
      for (final path in const [
        'lib/providers/tech_doc.dart',
        'lib/providers/plc.dart',
        'lib/providers/drawing.dart',
      ]) {
        final code = File(path).readAsStringSync();
        expect(code.contains('ref.watch(auditSinkProvider'), isFalse,
            reason: '$path would rebuild on every database reconnect');
        expect(code.contains('auditSinkProvider.future'), isFalse,
            reason: '$path is synchronous; awaiting the sink is not available '
                'to it, which is why RefAuditSink exists');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Gating, through the real provider graph
  // -------------------------------------------------------------------------

  group('writes through the wired guards', () {
    test('an anonymous session cannot delete a technical document', () async {
      final w = await _wiring();
      final index = w.container.read(techDocIndexProvider)!;

      await expectLater(
          index.deleteDocument(3), throwsA(isA<AccessDenied>()));

      expect(w.sink.rows.single.allowed, isFalse);
      expect(w.sink.rows.single.station, _kStation);
      await w.settle();
      expect(w.denials, hasLength(1),
          reason: 'the refusal must reach accessDenialsProvider, which is what '
              'puts AccessDeniedPrompt on screen');
    });

    test('an anonymous re-index is refused', () async {
      final w = await _wiring();
      final index = w.container.read(plcCodeIndexProvider)! as PlcCodeIndexExtras;

      await expectLater(
          index.reindexAsset(_kAsset), throwsA(isA<AccessDenied>()));

      expect(w.sink.rows.single.allowed, isFalse);
      expect(w.sink.rows.single.itemKey, 'plc_asset.$_kAsset');
      await w.settle();
      expect(w.denials, hasLength(1));
    });

    test('a configure session re-indexes, and the row says so', () async {
      final w = await _wiring();
      await w.signIn();
      final index = w.container.read(plcCodeIndexProvider)! as PlcCodeIndexExtras;

      final blockCount = await index.reindexAsset(_kAsset);

      expect(blockCount, 2, reason: 'the fixture indexed two blocks');
      final row = w.sink.rows.lastWhere((r) => r.reason == 'reindexAsset');
      expect(row.allowed, isTrue);
      expect(row.who, 'jon');
      await w.settle();
      expect(w.denials, isEmpty);
    });

    test('an anonymous session cannot delete a PLC asset index', () async {
      final w = await _wiring();
      final index = w.container.read(plcCodeIndexProvider)!;

      await expectLater(
          index.deleteAssetIndex(_kAsset), throwsA(isA<AccessDenied>()));

      // And the index is still there.
      expect(await DriftPlcCodeIndex(w.mcpDb).getBlocksForAsset(_kAsset),
          hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  // The page-layout cleanup a document delete runs
  // -------------------------------------------------------------------------

  group('deleteAndCleanAssets through the guarded configuration store', () {
    const int docId = 3;

    Future<void> clean(_Wiring w, {int id = docId}) async =>
        w.container.read(techDocUploadServiceProvider)!.deleteAndCleanAssets(
              docId: id,
              configStore:
                  await w.container.read(configStoreProvider.future),
            );

    test('the fixture is a real page — its assets encode as a List', () {
      final json = _layoutLinkedTo(docId)['/']!.toJson();

      // The pin, and the reason this file no longer hand-writes its layout.
      // The cleanup used to skip any page whose `assets` was not a
      // `Map<String, dynamic>` — which is every page the app can produce, so
      // it never stripped a single `techDocId`. The fixture it was tested
      // against built `assets` as a map, so the test agreed with the bug.
      // If this ever fails, the shape moved and a map-shaped guard could
      // come back unnoticed (D-4).
      expect(json['assets'], isA<List<dynamic>>());
    });

    test('a configure session strips the id from the asset that referenced it',
        () async {
      final w = await _wiring(layout: _layoutLinkedTo(docId));
      await w.signIn();
      final before = w.assetsById;

      await clean(w);

      final after = w.assetsById;
      expect(after['led-linked']!.decode()['techDocId'], isNull);
      expect(after['led-spare']!.payload, before['led-spare']!.payload,
          reason: 'an asset that never referenced the document is not '
              'rewritten, so the diff never sees it and it gets no row');
      expect(await w.changedAssetIds(), ['led-linked', 'rack']);

      final row =
          w.sink.rows.where((r) => r.itemKey == 'page_editor_data').single;
      expect(row.allowed, isTrue);
      expect(row.who, 'jon');
      expect(row.station, _kStation);
      expect(row.reason, contains('$docId'));
    });

    test('a document referenced by a subdevice rewrites the parent row',
        () async {
      final w = await _wiring(layout: _layoutLinkedTo(docId));
      await w.signIn();

      await clean(w);

      // Subdevices are not rows: they live inside their parent's payload, so
      // the whole rack is rewritten to clear one slice's link. That is the
      // documented consequence of top-level-assets-only.
      final rack = w.assetsById['rack']!;
      expect(rack.payload, isNot(contains('"techDocId":$docId')));
      expect((rack.decode()['subdevices'] as List).single['techDocId'], isNull);
      expect(await w.changedAssetIds(), contains('rack'));
    });

    test('a document nothing references writes nothing at all', () async {
      final w = await _wiring(layout: _layoutLinkedTo(docId));
      await w.signIn();
      final before = {
        for (final entry in w.assetsById.entries) entry.key: entry.value.payload
      };

      await clean(w, id: 99);

      expect({
        for (final entry in w.assetsById.entries) entry.key: entry.value.payload
      }, before);
      expect(await w.changedAssetIds(), isEmpty);
      expect(w.sink.rows.where((r) => r.itemKey == 'page_editor_data'), isEmpty,
          reason: 'no write means no audit row either — a trail that records '
              'a save over nothing is a trail nobody can read');
      // And the document itself still goes.
      expect(w.sink.rows.map((r) => r.itemKey), contains('tech_doc.99'));
    });

    test('an anonymous session is refused, and nothing is written', () async {
      final w = await _wiring(layout: _layoutLinkedTo(docId));
      await w.container.read(accessSessionProvider.future);
      final before = w.assetsById['led-linked']!.payload;

      await expectLater(
        clean(w),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'page_editor_data')),
      );

      expect(w.assetsById['led-linked']!.payload, before,
          reason: 'the layout must be untouched by a refused cleanup');
      expect(await w.changedAssetIds(), isEmpty);
      expect(
          w.sink.rows
              .where((r) => r.itemKey == 'page_editor_data')
              .single
              .allowed,
          isFalse);
      await w.settle();
      expect(w.denials.map((d) => d.itemKey), contains('page_editor_data'));
    });

    test('the refusal is not swallowed, so the document is not deleted either',
        () async {
      final w = await _wiring(layout: _layoutLinkedTo(docId));
      await w.container.read(accessSessionProvider.future);

      await expectLater(clean(w), throwsA(isA<AccessDenied>()));

      // `deleteAndCleanAssets` catches a layout it cannot decode. Without an
      // `on AccessDenied { rethrow; }` arm that catch eats the refusal and
      // the delete carries on -- the row would then say `tech_doc.3`.
      expect(w.sink.rows.map((r) => r.itemKey), isNot(contains('tech_doc.3')));
    });

    test('offline, the cleanup fails and the document survives with it',
        () async {
      final w = await _wiring(
          layout: _layoutLinkedTo(docId), configOnline: false);
      await w.signIn();

      await expectLater(
          clean(w), throwsA(isA<ConfigStoreOfflineException>()));

      // The layout was not cleaned, so the document must still be there:
      // a delete that reported success over a failed cleanup is exactly the
      // dangling reference this method exists to prevent.
      expect(w.sink.rows.map((r) => r.itemKey), isNot(contains('tech_doc.3')));
    });
  });

  // -------------------------------------------------------------------------
  // The concrete-type tests are gone from lib/
  // -------------------------------------------------------------------------

  test('no source file type-tests for the concrete DriftPlcCodeIndex', () {
    final hits = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final code = entity.readAsStringSync();
      if (code.contains('is! DriftPlcCodeIndex') ||
          code.contains('is DriftPlcCodeIndex')) {
        hits.add(entity.path);
      }
    }
    expect(hits, isEmpty,
        reason: 'a concrete-type test against a wrapped provider is a feature '
            'that silently stops working');
  });
}
