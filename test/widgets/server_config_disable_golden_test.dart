/// Golden image of the per-server enable/disable toggle, for design review.
///
/// Renders the whole Server Configuration page with two servers per protocol
/// — the first enabled, the second disabled. What is under review is that
/// "switched off on purpose" reads differently from "the PLC is down": a grey
/// Disabled chip, a grey power icon and a greyed-out title, never the red
/// Disconnected chip an actual outage produces.
///
/// The enabled servers show "Not active" because the test harness has no
/// StateMan — there is no live connection to report in a widget test.
///
/// To update: flutter test test/widgets/server_config_disable_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';
import '../helpers/golden_platform.dart';

/// Tall enough that the whole page is laid out and painted at once — the
/// sections live in a SingleChildScrollView, and anything below the fold
/// would capture as blank.
const Size _surface = Size(760, 1300);

StateManConfig _configWithOneOfEach() => StateManConfig(
      opcua: [
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.20.11:4840'
          ..serverAlias = 'ST101',
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.20.13:4840'
          ..serverAlias = 'ST301'
          ..enabled = false,
      ],
      jbtm: [
        M2400Config(host: '10.104.29.71')..serverAlias = 'W01',
        M2400Config(host: '10.104.29.78', enabled: false)..serverAlias = 'W08',
      ],
      modbus: [
        ModbusConfig(host: '10.104.20.30', serverAlias: 'BAADER'),
        ModbusConfig(
            host: '10.104.20.31', serverAlias: 'MULTIVAC', enabled: false),
      ],
    );

/// Resolves a package's root directory from the pub package config, so the
/// font paths below survive a dependency bump.
String? _packageRoot(String package) {
  final file = File('.dart_tool/package_config.json');
  if (!file.existsSync()) return null;
  final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  for (final entry in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    if (entry['name'] != package) continue;
    return Uri.parse(entry['rootUri'] as String).toFilePath();
  }
  return null;
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer))))
      .load();
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());

    // The Import/Export card at the bottom of the page reads PackageInfo in
    // initState. Unmocked it throws MissingPluginException mid-capture and
    // fails the golden.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc',
        'packageName': 'is.centroid.tfc',
        'version': '0.0.0',
        'buildNumber': '0',
      },
    );
  });

  // The server cards are built almost entirely out of FontAwesome and
  // Material icons — the power toggle being the whole point of this golden —
  // and the test environment registers neither. Without this the image comes
  // out as rows of tofu boxes.
  setUpAll(() async {
    final faRoot = _packageRoot('font_awesome_flutter');
    final faFonts = faRoot == null
        ? const <File>[]
        : (Directory('$faRoot/lib/fonts')..existsSync())
            .listSync()
            .whereType<File>()
            .toList();
    for (final font in faFonts) {
      final name = font.path.toLowerCase();
      // Icons are spread across the three FA families — the power toggle is
      // Solid, the save icon is Regular — so register whatever ships.
      final family = name.contains('brands')
          ? 'FontAwesomeBrands'
          : name.contains('solid')
              ? 'FontAwesomeSolid'
              : name.contains('regular')
                  ? 'FontAwesomeRegular'
                  : null;
      if (family == null) continue;
      // FaIcon's IconData carries fontPackage: 'font_awesome_flutter', so
      // the family Flutter actually looks up is namespaced. Loading it as
      // plain 'FontAwesomeSolid' silently does nothing.
      await _loadFont('packages/font_awesome_flutter/$family', font.path);
    }

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await _loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  group('server enable/disable golden',
      skip: goldenSkip, () {
    testWidgets('one enabled and one disabled server per protocol',
        (tester) async {
      await tester.binding.setSurfaceSize(_surface);
      // 1:1 pixels — this golden is for reading in a PR, not pixel
      // archaeology, and a 3x capture would be needlessly large.
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpAndLoad(
        tester,
        buildTestableServerConfig(stateManConfig: _configWithOneOfEach()),
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/server_config_disable.png'),
      );
    });
  });
}
