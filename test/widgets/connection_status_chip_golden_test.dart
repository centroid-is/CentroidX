/// Golden image of every [ConnectionStatusChip] state, for design review.
///
/// What is under review is the new deep-orange "No data" pill
/// (`EffectiveDeviceStatus.opcuaUnhealthy`, the frozen-session fix): it has
/// to read as its own failure — "link claims up, values frozen" — next to
/// green Connected, orange Connecting..., red Disconnected and amber
/// UMAS error, in both themes. Rendered with the app's real Solarized theme
/// so the goldens carry the colours the plant actually shows.
///
/// To update: flutter test test/widgets/connection_status_chip_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/connection_status_chip.dart';
import 'package:tfc_dart/core/state_man.dart'
    show ConnectionStatus, EffectiveDeviceStatus;
import '../helpers/golden_platform.dart';

const _stripKey = Key('connection_status_chip_golden');

/// Every state the chip can render, labelled the way the code paths are
/// distinguished: the EffectiveDeviceStatus rows are what OPC UA and UMAS
/// cards show, the legacy rows are the pure-TCP fallback.
Widget buildStrip({bool dark = false}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;

  Widget row(String label, ConnectionStatusChip chip) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 260, child: Text(label)),
            chip,
          ],
        ),
      );

  return MaterialApp(
    theme: theme,
    home: Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: RepaintBoundary(
          key: _stripKey,
          child: Container(
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                  'effective: connected',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.connected,
                    effectiveStatus: EffectiveDeviceStatus.connected,
                  ),
                ),
                row(
                  'effective: connecting',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.connecting,
                    effectiveStatus: EffectiveDeviceStatus.connecting,
                  ),
                ),
                row(
                  'effective: disconnected',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.disconnected,
                    effectiveStatus: EffectiveDeviceStatus.disconnected,
                  ),
                ),
                row(
                  'effective: umasUnhealthy',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.connected,
                    effectiveStatus: EffectiveDeviceStatus.umasUnhealthy,
                  ),
                ),
                row(
                  'effective: opcuaUnhealthy',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.connected,
                    effectiveStatus: EffectiveDeviceStatus.opcuaUnhealthy,
                  ),
                ),
                const Divider(height: 24),
                row(
                  'legacy: connected',
                  const ConnectionStatusChip(status: ConnectionStatus.connected),
                ),
                row(
                  'legacy: null + loading',
                  const ConnectionStatusChip(status: null, stateManLoading: true),
                ),
                row(
                  'legacy: null (not active)',
                  const ConnectionStatusChip(status: null),
                ),
                row(
                  'disabled server',
                  const ConnectionStatusChip(
                    status: ConnectionStatus.connected,
                    disabled: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Real glyphs — without this the tests render the block placeholder font,
/// and a chip that is nothing but text captures as unreadable boxes.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
}

void main() {
  setUpAll(_loadFonts);

  group('connection status chip golden',
      skip: goldenSkip, () {
    testWidgets('all states, light', (tester) async {
      await tester.pumpWidget(buildStrip());
      await expectLater(
        find.byKey(_stripKey),
        matchesGoldenFile('goldens/connection_status_chip_states.png'),
      );
    });

    testWidgets('all states, dark', (tester) async {
      await tester.pumpWidget(buildStrip(dark: true));
      await expectLater(
        find.byKey(_stripKey),
        matchesGoldenFile('goldens/connection_status_chip_states_dark.png'),
      );
    });
  });
}
