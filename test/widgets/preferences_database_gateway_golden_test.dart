/// Golden images of the database card on a gateway-mode station — under the
/// real station themes, in both brightnesses.
///
/// One frame, shot twice. The card is the honest replacement for the
/// "Status: Connected" line the owner watched a gateway panel render: a
/// statement in muted `onSurface`, no status stream, no editor, no census
/// button. The dark half is not decoration: the card's muted colour is
/// `onSurface` with alpha precisely because neither Solarized scheme sets
/// `colorScheme.outline` (project memory `solarized-outline-is-invisible`),
/// and only a dark image can show that the sentence is actually legible on
/// base03.
///
/// To update: derive the failing set first by running without the flag, then
/// `flutter test test/widgets/preferences_database_gateway_golden_test.dart
/// --update-goldens`.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/widgets/preferences.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';
import '../helpers/themed_golden_host.dart';

const Size _surface = Size(720, 260);

void main() {
  setUpAll(loadThemedGoldenFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  Future<void> pump(WidgetTester tester, {required bool dark}) async {
    final local = InMemoryPreferences();
    await writeGatewayConfig(
      local,
      const GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443'),
    );

    await tester.binding.setSurfaceSize(_surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [localPreferencesProvider.overrideWithValue(local)],
      child: themedGoldenHost(
        const SizedBox(width: 680, child: DatabaseConfigWidget()),
        dark: dark,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('gateway-mode database card, light', (tester) async {
    await pump(tester, dark: false);
    await expectLater(
      find.byType(DatabaseConfigWidget),
      matchesGoldenFile('goldens/preferences_database_gateway_light.png'),
    );
  });

  testWidgets('gateway-mode database card, dark', (tester) async {
    await pump(tester, dark: true);
    await expectLater(
      find.byType(DatabaseConfigWidget),
      matchesGoldenFile('goldens/preferences_database_gateway_dark.png'),
    );
  });
}
