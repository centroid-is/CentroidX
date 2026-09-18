import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden_tolerance.dart';

/// Loads a real font so golden tests render readable text instead of Ahem blocks.
///
/// Flutter uses only the nearest `flutter_test_config.dart`, so this shadows
/// `test/flutter_test_config.dart` for everything under `test/widgets/` and
/// has to repeat its golden-tolerance setup.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  useTolerantGoldenComparator();

  final fontFile = File('lib/fonts/dejavu-sans/DejaVuSans.ttf');
  final fontData = fontFile.readAsBytesSync();
  final byteData = ByteData.view(fontData.buffer);

  // Register as 'Roboto' — Material's default font family.
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(byteData));
  await loader.load();

  await testMain();
}
