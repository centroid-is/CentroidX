/// Golden images of the sentence that names which machine a page acts on —
/// under the real station themes, in both brightnesses.
///
/// One frame, shot twice. The dark half is not decoration: the notice's colour
/// is `onSurface` with alpha precisely because neither Solarized scheme sets
/// `colorScheme.outline` (project memory `solarized-outline-is-invisible`),
/// and only a dark image can show that both the border and the sentence
/// survive on base03. The same reason the database card next door is
/// photographed twice, and the same colour for the same reason.
///
/// The text is long enough to wrap at this width, which is the point of
/// capturing it at all: an operator meets this above a page full of network
/// cards, and a sentence that overflows its box there would be the thing they
/// see first.
///
/// To update: derive the failing set first by running without the flag, then
/// `flutter test test/widgets/this_panel_notice_golden_test.dart
/// --update-goldens`.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/widgets/this_panel_notice.dart';

import '../helpers/themed_golden_host.dart';

const Size _surface = Size(720, 160);

void main() {
  setUpAll(loadThemedGoldenFonts);

  Future<void> pump(WidgetTester tester, {required bool dark}) async {
    await tester.binding.setSurfaceSize(_surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        gatewayConfigProvider.overrideWith((ref) async => const GatewayConfig(
            mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443')),
        // A fixed name, never the host's: a golden that renders whichever
        // machine built it is not a golden.
        panelHostnameProvider.overrideWithValue('svn-panel-02'),
      ],
      child: themedGoldenHost(
        const SizedBox(
            width: 680,
            child: ThisPanelNotice(subject: 'network configuration')),
        dark: dark,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the this-panel notice, light', (tester) async {
    await pump(tester, dark: false);
    expect(find.byKey(kThisPanelNoticeKey), findsOneWidget,
        reason: 'an empty image would still match an empty golden');
    await expectLater(
      find.byType(ThisPanelNotice),
      matchesGoldenFile('goldens/this_panel_notice_light.png'),
    );
  });

  testWidgets('the this-panel notice, dark', (tester) async {
    await pump(tester, dark: true);
    expect(find.byKey(kThisPanelNoticeKey), findsOneWidget);
    await expectLater(
      find.byType(ThisPanelNotice),
      matchesGoldenFile('goldens/this_panel_notice_dark.png'),
    );
  });
}
