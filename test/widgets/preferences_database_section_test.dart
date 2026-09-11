/// What the Preferences page's database section claims, decided by transport.
///
/// The owner opened Preferences on a gateway-mode panel and read
/// "Status: Connected" under Database Configuration. Both halves of that were
/// defects: the panel held a Postgres connection the transport says it must
/// not, and the screen asserted it as healthy. This milestone's core value is
/// that the screen never lies — a status line is shown when it describes
/// something real (direct mode), and is absent when there is nothing real to
/// describe (gateway mode), never red-"Disconnected" as though a working
/// station were faulty.
///
/// What the transport does NOT decide is whether the settings can be seen and
/// changed. The card spent one revision as a placard in gateway mode, and the
/// owner overruled that at the rig — "i dont see a reason why we cannot
/// change or see database config" — because the row is this station's own,
/// device-local, and is what it runs on the moment the transport goes back to
/// Direct. So the gateway arm below now pairs the missing CLAIM with the
/// present FIELDS: dropping either half is a different defect.
///
/// The gateway arm runs with `databaseProvider` overridden to THROW and a
/// touch recorder (17-12's technique): the section must render without ever
/// reaching for it. The direct arm is the live control — a station in direct
/// mode with a connected database must still say "Status: Connected", or the
/// fix has broken the mode half the plant runs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/widgets/preferences.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';

/// A database whose health stream reports connected — the direct arm's
/// stand-in for a working plant connection. `Stream.multi`, exactly as the
/// real `Database.connectionState`, because the section holds one
/// `StreamBuilder` in the subtitle and another in the expanded body.
final class _ConnectedDatabase extends Fake implements Database {
  @override
  Stream<bool> get connectionState =>
      Stream<bool>.multi((controller) => controller.add(true));
}

Future<PreferencesApi> _gatewayLocal() async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    const GatewayConfig(mode: TransportMode.gateway, url: 'ws://127.0.0.1:1'),
  );
  return local;
}

Widget _host(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: DatabaseConfigWidget())),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  testWidgets(
      'gateway mode: the section is editable, claims no status, '
      'and never touches the database provider', (tester) async {
    var touched = false;
    final local = await _gatewayLocal();

    await tester.pumpWidget(_host([
      localPreferencesProvider.overrideWithValue(local),
      // Throwing, not null: the real preferencesProvider builds underneath
      // this widget, and a provider can be null-safe while still propagating
      // an exception from a watch it did not need.
      databaseProvider.overrideWith((_) {
        touched = true;
        throw StateError('postgres unreachable: connection refused');
      }),
    ]));
    await tester.pumpAndSettle();

    // The card is still there — the operator can find where the setting
    // lives — and it carries the honest sentence instead of a claim.
    expect(find.text('Database Configuration'), findsOneWidget);
    expect(find.textContaining('the backend owns the database'),
        findsOneWidget);

    // And the settings themselves are reachable and editable, which is the
    // half the owner's ruling added. A card that said the honest thing and
    // showed nothing would pass every other assertion in this arm.
    await tester.tap(find.text('Database Configuration'));
    await tester.pumpAndSettle();
    for (final label in const ['Host', 'Port', 'Database', 'Username']) {
      expect(find.widgetWithText(TextField, label), findsOneWidget);
    }
    expect(find.text('Save Database Config'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Host'), '10.104.29.60');
    await tester.pumpAndSettle();
    expect(find.text('10.104.29.60'), findsOneWidget);

    // "Connected" must be true or absent. In gateway mode there is no
    // station-side connection to describe, so no status line at all — and
    // not "Disconnected" either, which reads as a fault on a healthy panel.
    expect(find.textContaining('Status:'), findsNothing);
    expect(find.textContaining('Connected'), findsNothing);

    // The connection-census button reads the station's own pool; there is
    // none to census.
    expect(find.byTooltip('Connection statistics'), findsNothing);

    expect(touched, isFalse,
        reason: 'opening Preferences on a gateway panel must not initiate '
            'any database connection — the owner watched it do exactly that');
  });

  testWidgets(
      'direct mode: the status line is still there and still true — '
      'the live control', (tester) async {
    await tester.pumpWidget(_host([
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      // Constructed directly rather than through createTestPreferences: the
      // helper seeds key_mappings through the store, which upserts into the
      // database — and this fake is a health stream, not a query engine.
      preferencesProvider.overrideWith((ref) async => Preferences(
          database: _ConnectedDatabase(), secureStorage: FakeSecureStorage())),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Status: Connected'), findsOneWidget,
        reason: 'direct mode owns a real connection and must keep reporting '
            'it; hiding the claim in both modes would be the vacuous fix');
    expect(find.textContaining('the backend owns the database'), findsNothing);
    expect(find.byTooltip('Connection statistics'), findsOneWidget);
  });
}
