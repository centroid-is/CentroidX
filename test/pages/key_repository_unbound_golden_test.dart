/// One golden: the key repository with the unbound count on screen and the
/// `Unbound only` filter switched on.
///
/// `key_repository_unbound.png` — spec §7b is deliberately fail-open. An
/// unbound key is unrestricted and **nothing enforces that somebody
/// remembered**, so enforcement is replaced by visibility: a sentence saying
/// how many of this station's keys no template governs, and a chip that
/// narrows the list to exactly those. 04-08 built both and re-recorded no
/// golden — the three key-repository baselines beside this file all run with
/// no reachable template store, and in that state the count row and the chip
/// are deliberately absent. This is the first image of the surface itself.
///
/// **What the image is supposed to show**, so a later reader can check the
/// file rather than a memory:
///
///  * `No template governs 3 of the 4 keys here.` — a sentence, not a bare
///    number, and phrased as information rather than as an alarm. Muted
///    `onSurfaceVariant`; nothing on this row is a fault colour,
///  * the `Unbound only` chip **selected**, and the list narrowed from four
///    keys to three,
///  * a mix inside that three: `ST101.CN02` and `ST101.CN04` carry the plain
///    `Unbound` badge, and `ST101.CN03` carries `Binding missing` — a key
///    bound to a template that no longer exists. It is unbound by the guard's
///    own definition (`TagBindingResolver.unboundKeys`) and it is in the list
///    for that reason, but it is not the same gap and does not read the same,
///  * `ST101.CN01`, bound to `conveyor`, filtered **out**.
///
/// **The count and the filter come from one definition.** Both are
/// `unboundKeys`, the method the guard itself consults, so the chip cannot
/// show a key the guard treats as bound. That is asserted in
/// `key_repository_binding_test.dart`; here it is what makes the picture
/// worth trusting.
///
/// **Fonts are loaded here, twice, deliberately.** `test/pages/` uses
/// `test/flutter_test_config.dart`, which registers **no font at all**, and
/// `lib/theme.dart:349` names `'roboto-mono'` as the theme's family. Without
/// both registrations every badge and every line of copy captures as Ahem
/// rectangles.
///
/// **The themed app**, or `HmiStateColors` falls back to `solarizedLight` and
/// a picture whose subject is "this must not read as an alarm" acquires
/// violet.
///
/// **Pinned**: `withClock`, an overridden `accessSessionProvider`, and a
/// snapshot already in the resolver.
///
/// **Every fixture is this file's own** — no import from `test_helpers.dart`
/// or from a neighbouring test. Importing another test file executes its
/// top-level state and makes a baseline nobody can reproduce.
///
/// To update: flutter test test/pages/key_repository_unbound_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/key_mapping_sections.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/golden_tolerance.dart';
import '../helpers/golden_platform.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

const String _station = 'SVN-NES-OT-CL02';

/// Four keys: one bound, one dangling, two plainly unbound.
const String _bound = 'ST101.CN01';
const String _unboundA = 'ST101.CN02';
const String _dangling = 'ST101.CN03';
const String _unboundB = 'ST101.CN04';

/// The instant this image is frozen at.
final DateTime _frozen = DateTime.utc(2026, 8, 30, 9, 0);

/// The one template that exists.
AccessTemplate _conveyor() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        'p_cfg_ManualFreq': AccessGroup.setpoints,
        'p_cmd_JogFwd': AccessGroup.operate,
      },
    );

/// The snapshot behind both the count and the chip.
///
/// `_dangling` names `recipes`, which is **not** in `templates` — the row a
/// template deletion in `psql`, or a rename nothing followed, leaves behind.
/// `unboundKeys` counts it, because a key naming a template with no rules is
/// as unrestricted as one naming nothing at all.
TagBindingResolver _resolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {
      _bound: 'conveyor',
      _dangling: 'recipes',
    },
    templates: {'conveyor': _conveyor()},
  );

/// The engineer who opens this page. `/advanced/key-repository` is behind
/// `configure`; binding is behind `users`, and the control is live either way.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

/// A session that answers one fixed value without standing up the real
/// controller chain (database, preferences, audit sink, inactivity monitor).
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// Swallows the rows a write would produce. This image drives no write.
class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

/// In-memory secure storage, so `StateManConfig` reads without a keychain.
class _FakeSecureStorage implements MySecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async =>
      _store[key] = value;

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async => _store.remove(key);
}

/// A handle that is merely **not null**, so the page's red "no database"
/// banner stays down.
///
/// The banner is not this image's subject and it is painted in raw
/// `Colors.red` — a saturated block at the top of a picture whose whole claim
/// is that the unbound surface does not read as an alarm would drown it.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;
}

/// The four keys, all on one OPC UA server the config below knows about — a
/// card whose server dropdown holds a value with no matching item asserts
/// before anything is painted.
KeyMappings _keys() => KeyMappings(nodes: {
      for (final name in const [_bound, _unboundA, _dangling, _unboundB])
        name: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'GVL.$name')
            ..serverAlias = 'main_server',
        ),
    });

StateManConfig _stateManConfig() => StateManConfig(opcua: [
      OpcUAConfig()
        ..endpoint = 'opc.tcp://localhost:4840'
        ..serverAlias = 'main_server',
    ]);

Future<Preferences> _preferences() async {
  Preferences.clearSecretCache();
  DatabaseConfig.clearPrefsCache();
  final secureStorage = _FakeSecureStorage();
  final prefs = Preferences(database: null, secureStorage: secureStorage);
  await prefs.setString('key_mappings', jsonEncode(_keys().toJson()));
  await secureStorage.write(
    key: StateManConfig.configKey,
    value: jsonEncode(_stateManConfig().toJson()),
  );
  return prefs;
}

/// The on-disk root of [package], read out of the package config.
///
/// Font Awesome ships its faces inside the package rather than in this repo,
/// so the path has to be discovered rather than written down.
String? _packageRoot(String package) {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final packages = (jsonDecode(config.readAsStringSync())
      as Map<String, dynamic>)['packages'] as List<dynamic>;
  for (final entry in packages.cast<Map<String, dynamic>>()) {
    if (entry['name'] == package) {
      return Uri.parse(entry['rootUri'] as String).toFilePath();
    }
  }
  return null;
}

/// Loads the two text families the theme needs, plus **both** icon fonts.
///
/// Font Awesome is not optional here and the first pass of this image is the
/// argument: with only `MaterialIcons` loaded, every key card rendered its
/// drag handle, its key glyph, its duplicate, its delete and its expander as
/// hollow tofu boxes — four squares per card, in an image whose subject is
/// whether a badge reads as information or as an alarm. The page mixes the two
/// icon sets (Material for the search field, the filter chip and the templates
/// card; Font Awesome for the key cards and the import/export card), so
/// loading one and not the other produces a picture that is half real.
Future<void> _loadRealFonts() async {
  Future<void> loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }

  final faRoot = _packageRoot('font_awesome_flutter');
  if (faRoot != null) {
    await loadFont('packages/font_awesome_flutter/FontAwesomeSolid',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Solid-900.otf');
    await loadFont('packages/font_awesome_flutter/FontAwesomeRegular',
        '$faRoot/lib/fonts/Font-Awesome-7-Free-Regular-400.otf');
  }
}

void main() {
  final (light, _) = muted();

  useTolerantGoldenComparator();

  group('key repository unbound-surface golden',
      skip: goldenSkip, () {
    setUpAll(_loadRealFonts);

    late AppDatabase db;

    setUp(() async {
      // Without this the page's own preferences read throws and the frame
      // captures an error string instead of a page.
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.inMemoryForTest();
      await db.customSelect('SELECT 1').getSingle();
    });

    tearDown(() async {
      await db.close();
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    testWidgets('the unbound count, the filter on, and one dangling binding',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
        view.devicePixelRatio = 1.0;
        // Above `kKeyRepositoryChromeHeight + kKeyRepositoryMinKeyListHeight`
        // (780), so the page lays out directly rather than through its
        // whole-page scroll fallback — which is what a 1080p panel does and
        // what this image should therefore show.
        view.physicalSize = const Size(900, 1000);

        final prefs = await _preferences();

        await tester.pumpWidget(ProviderScope(
          overrides: [
            preferencesProvider.overrideWith((ref) async => prefs),
            databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
            // Thrown, not answered: the page treats it as "nothing to probe",
            // which is the state of a station whose PLC is unreachable and is
            // the only state a golden can be honest about.
            stateManProvider
                .overrideWith((ref) => throw StateError('No StateMan in tests')),
            // A real store over an in-memory database, because the count row
            // and the chip are deliberately absent when this resolves null.
            accessTemplateStoreProvider.overrideWith((ref) async =>
                AccessTemplateStore(
                    db: db,
                    session: _configureOnly,
                    audit: _NullSink(),
                    station: _station)),
            accessTemplatesProvider.overrideWith((ref) async => [_conveyor()]),
            tagBindingResolverProvider.overrideWith((ref) => _resolver()),
            accessSessionProvider
                .overrideWith(() => _FixedSession(_configureOnly())),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light,
            home: const Scaffold(body: KeyRepositoryContent()),
          ),
        ));
        await tester.pumpAndSettle();

        // The count is on screen before the filter is touched: it is the
        // station-wide statement, and the chip only narrows the list.
        expect(find.byKey(kUnboundKeysCountKey), findsOneWidget);
        expect(find.text(kUnboundKeysCount(3, 4)), findsOneWidget);

        await tester.tap(find.byKey(kUnboundKeysFilterKey));
        await tester.pumpAndSettle();

        // The claims the image is supposed to make, asserted before the pixels
        // are compared. An eye can see three cards; it cannot see that the
        // three are exactly `unboundKeys`' answer.
        expect(_resolver().unboundKeys(const [
          _bound,
          _unboundA,
          _dangling,
          _unboundB,
        ]).toSet(), {_unboundA, _dangling, _unboundB},
            reason: 'the guard\'s own definition is what the chip filters on');
        expect(find.text(_bound), findsNothing,
            reason: 'the bound key is filtered out');
        for (final key in const [_unboundA, _dangling, _unboundB]) {
          expect(find.text(key), findsOneWidget);
        }
        expect(find.byKey(kKeyBindingBadgeKey(_dangling)), findsOneWidget);
        expect(find.text(kKeyBindingMissingBadge), findsOneWidget,
            reason: 'a dangling binding is a different gap and says so');
        expect(find.text(kKeyBindingUnboundBadge), findsNWidgets(2));
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/key_repository_unbound.png'),
        );
      });
    });
  });
}
