/// The Transport card as a *control*, and the database card as an editable
/// one in both transports.
///
/// Two owner rulings, both given standing at the rig with the page open:
///
///   * "the transport card text is way too bloated — one line", and "the
///     toggle and the gateway address belong on the same row";
///   * "i dont see a reason why we cannot change or see database config".
///
/// The arms below are geometric where the ruling is geometric (one row is a
/// fact about rectangles, not about widget nesting) and textual where the
/// ruling is textual. The database arms pair "editable" with "dials nothing"
/// deliberately: making the card editable is worthless if it costs the panel
/// a Postgres connection it must not open, and asserting only the absence of
/// the connection would pass on a card that shows nothing at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:riverpod/riverpod.dart' show Ref;
import 'package:tfc/providers/database.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc/widgets/preferences.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';

/// A station already switched to the gateway, as its device-local row.
Future<PreferencesApi> _gatewayStation() async {
  final prefs = InMemoryPreferences();
  await writeGatewayConfig(
    prefs,
    GatewayConfig(
      mode: TransportMode.gateway,
      url: 'wss://centroidx-backend:9443',
      caPem: '-----BEGIN CERTIFICATE-----\n'
          'dGhlIHBsYW50IENBLCBhcyBhcHByb3ZlZCBieSB0aGUgb3BlcmF0b3I=\n'
          '-----END CERTIFICATE-----\n',
    ),
  );
  return prefs;
}

/// Whether the station's Postgres pool was ever asked for.
///
/// A refusal (`overrideWith` that throws) does NOT catch this: `databaseProvider`
/// is a `FutureProvider`, so a stray `ref.watch` on it yields an `AsyncError`
/// that the watcher is free to ignore, and the arm goes green while the panel
/// dials. Recording the build is the only thing that sees it — verified by
/// sabotage: `ref.watch(databaseProvider)` added to the card's build passes
/// the throwing override and fails this one.
class _PoolProbe {
  bool built = false;

  Future<Database?> record(Ref ref) async {
    built = true;
    return null;
  }
}

Finder get _toggle => find.byType(SegmentedButton<TransportMode>);
Finder get _addressField =>
    find.widgetWithText(TextField, 'Gateway address and port');

/// Every full sentence the transport card renders, in tree order.
///
/// "Full sentence" is the bloat unit the owner was pointing at — a line that
/// reads as prose rather than as a label on a control. Segment labels, the
/// card title and the save button's three words all end without a full stop
/// and are not counted; a paragraph put back at the top of the card is.
List<String> _proseIn(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
        of: find.byType(TransportModeCard), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .where((s) => s.trimRight().endsWith('.'))
    .toList();

Future<void> _surface(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  group('the transport is one control', () {
    testWidgets('the toggle and the address share a row on a wide panel',
        (tester) async {
      await _surface(tester, const Size(900, 2000));
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      final toggle = tester.getRect(_toggle);
      final address = tester.getRect(_addressField);

      expect(address.left, greaterThan(toggle.right),
          reason: 'the address sits BESIDE the toggle, not under it — the '
              'owner asked for one row, and a field placed below a toggle '
              'that is still on screen is what he was looking at');
      expect(toggle.center.dy, greaterThan(address.top));
      expect(toggle.center.dy, lessThan(address.bottom),
          reason: 'and they are on the same row in the only sense that can '
              'be seen: the toggle\'s middle falls inside the field\'s band');
    });

    testWidgets('and they stack on a narrow panel, in the same order',
        (tester) async {
      // Below the 640 the card breaks at: the toggle is ~345 wide and an
      // address field under ~280 ellipsises `centroidx-backend:9443`, the
      // name this plant dials.
      //
      // 600 rather than the narrowest panel in the plant, and the reason is
      // the test font: widget tests render every glyph as a 14px box, which
      // makes the two segment labels roughly half again as wide as they are
      // in Roboto, so a 480px surface overflows the SEGMENTED BUTTON here
      // and nowhere else. 600 exercises the same stacked branch without
      // measuring the font harness.
      await _surface(tester, const Size(600, 2000));
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      final toggle = tester.getRect(_toggle);
      final address = tester.getRect(_addressField);

      expect(address.top, greaterThanOrEqualTo(toggle.bottom),
          reason: 'a panel too narrow for both gets them stacked rather than '
              'a field squeezed to nothing beside the toggle');
      expect(tester.takeException(), isNull,
          reason: 'and stacked without overflowing — an overflow stripe is '
              'the failure this branch exists to prevent');
    });

    testWidgets('flipping the toggle does not move it', (tester) async {
      await _surface(tester, const Size(900, 2000));
      await pumpAndLoad(tester, buildTestableServerConfig());

      final before = tester.getRect(_toggle);
      expect(_addressField, findsNothing,
          reason: 'a direct station is asked for no address');

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      expect(_addressField, findsOneWidget);
      final after = tester.getRect(_toggle);
      expect((after.top, after.bottom), (before.top, before.bottom),
          reason: 'the row is the field\'s height in BOTH transports, so '
              'revealing the address does not shift the control the '
              'operator has a finger on. (The WIDTH moves by the few pixels '
              'between the two segments\' labels — that is the selection '
              'itself, not the layout.)');
    });

    testWidgets('the card carries one line of prose', (tester) async {
      await _surface(tester, const Size(900, 2000));
      await pumpAndLoad(tester, buildTestableServerConfig());

      expect(
        _proseIn(tester),
        const [
          // Not prose about the control — a property OF it, on the header
          // row, in the muted voice.
          'This station only — never imported or synced.',
          // The one sentence an operator acts on.
          'Changing the transport takes effect when the HMI restarts.',
        ],
        reason: 'the owner\'s ruling, counted: one line the operator acts on, '
            'and one hint on the control itself. The paragraph about export '
            'and sync and the helper under the address field are gone, and '
            'this list is how a third one gets noticed',
      );
    });

    testWidgets('and the address field says what it wants without a helper '
        'line', (tester) async {
      await _surface(tester, const Size(900, 2000));
      await pumpAndLoad(tester, buildTestableServerConfig());
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      final field = tester.widget<TextField>(_addressField);
      expect(field.decoration?.helperText, isNull,
          reason: 'the examples in the hint say it, and the saved value '
              'spells the scheme back');
      expect(field.decoration?.hintText, contains('centroidx-backend:9443'),
          reason: 'and the example is the name this plant actually dials — '
              'an FQDN with a port, not only an IP literal');
    });
  });

  group('the database card is editable in both transports', () {
    /// Opens the database card and returns nothing — the fields only exist
    /// once the tile is expanded.
    Future<void> openDatabase(WidgetTester tester) async {
      await tester.tap(find.text('Database Configuration'));
      await settle(tester);
    }

    testWidgets('a gateway station can see and change the settings',
        (tester) async {
      final dialled = _PoolProbe();
      await _surface(tester, const Size(900, 2400));
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(
          localPreferences: await _gatewayStation(),
          overrides: [databaseProvider.overrideWith(dialled.record)],
        ),
      );

      expect(find.byType(DatabaseConfigWidget), findsOneWidget);
      await openDatabase(tester);

      for (final label in const [
        'Host',
        'Port',
        'Database',
        'Username',
        'Password',
      ]) {
        expect(find.widgetWithText(TextField, label), findsOneWidget,
            reason: 'the owner: "i dont see a reason why we cannot change or '
                'see database config". These are this station\'s own '
                'settings and it runs on them the moment the transport goes '
                'back to Direct');
      }
      expect(find.text('Save Database Config'), findsOneWidget);

      // And it really takes an edit — a disabled field would satisfy the
      // finder above.
      await tester.enterText(
          find.widgetWithText(TextField, 'Host'), '10.104.29.60');
      await settle(tester);
      expect(find.text('10.104.29.60'), findsOneWidget);

      expect(dialled.built, isFalse,
          reason: 'and none of that opened a database. Showing the settings '
              'must not cost the panel the Postgres connection gateway mode '
              'exists to remove — editable, and not dialled');
    });

    testWidgets('and claims no connection state while nothing is dialling',
        (tester) async {
      final dialled = _PoolProbe();
      await _surface(tester, const Size(900, 2400));
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(
          localPreferences: await _gatewayStation(),
          overrides: [databaseProvider.overrideWith(dialled.record)],
        ),
      );
      await openDatabase(tester);

      final card = find.byType(DatabaseConfigWidget);
      for (final claim in const ['Connected', 'Disconnected']) {
        expect(
            find.descendant(of: card, matching: find.textContaining(claim)),
            findsNothing,
            reason: 'a status line must be true or absent: this station '
                'dials nothing in gateway mode, so red "Disconnected" would '
                'read as a fault on a healthy panel and green "Connected" '
                'would be the lie the transport branch exists to remove');
      }
      // Paired with the presence of what replaced it — two absences are also
      // satisfied by a card that renders nothing at all.
      expect(
          find.descendant(
              of: card, matching: find.textContaining('Not dialled')),
          findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching:
                  find.textContaining('No connection from this station')),
          findsOneWidget);
      // The census reads a pool this station does not hold.
      expect(find.descendant(of: card, matching: find.byType(IconButton)),
          findsNothing,
          reason: 'the connection-statistics button is the one control that '
              'genuinely has nothing to act on here');
      expect(dialled.built, isFalse,
          reason: 'and the card said all of that without asking for a pool');
    });

    testWidgets('a direct station still gets the live status it always had',
        (tester) async {
      await _surface(tester, const Size(900, 2400));
      await pumpAndLoad(tester, buildTestableServerConfig());

      final card = find.byType(DatabaseConfigWidget);
      expect(find.descendant(of: card, matching: find.text('Status: Disconnected')),
          findsOneWidget,
          reason: 'the fixture holds no database, and in DIRECT mode that is '
              'a real, reportable state — the gateway branch must not have '
              'muted the transport that actually dials');
    });
  });
}
