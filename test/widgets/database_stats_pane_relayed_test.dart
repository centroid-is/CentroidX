/// The connection-census pane's two "nothing to count" sentences.
///
/// The pane has one branch — `databaseProvider` answered null — and that
/// branch had one sentence: "This database is local storage, not a Postgres
/// server." On a station reading a local file that is true. On a **relayed**
/// panel it is false twice: the plant's database is a Postgres, and the
/// reason there are no connections here is that this panel is not the machine
/// holding them. `databaseProvider` answers null for both
/// (`lib/providers/database.dart:50-52`), so the two facts wore the same
/// flag.
///
/// Both arms are here, because a test for the new sentence alone would pass
/// against a pane that had simply stopped saying the old one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/widgets/panes/database_stats_pane.dart';

const String _localStorage =
    'This database is local storage, not a Postgres server, so there are no '
    'connections to count.';

Future<void> _pump(WidgetTester tester, {required bool relayed}) async {
  await tester.binding.setSurfaceSize(const Size(520, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // Null on both transports: in gateway mode by design, and in direct
      // mode when the station has no Postgres configured.
      databaseProvider.overrideWith((ref) async => null),
      gatewayConfigProvider.overrideWith((ref) async => relayed
          ? const GatewayConfig(
              mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443')
          : const GatewayConfig(mode: TransportMode.direct, url: '')),
    ],
    child: const MaterialApp(home: Scaffold(body: DatabaseStatsPane())),
  ));
  // The refresh is a real future; pump until it has landed.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a direct station with no Postgres says local storage',
      (tester) async {
    await _pump(tester, relayed: false);
    expect(find.text(_localStorage), findsOneWidget);
  });

  testWidgets('a relayed panel says the connections are counted elsewhere',
      (tester) async {
    await _pump(tester, relayed: true);
    expect(find.text(_localStorage), findsNothing,
        reason: 'the plant\'s database IS a Postgres; saying otherwise on a '
            'relayed panel is a wrong answer that looks like a right one');
    expect(find.textContaining('opens no database connection of its own'),
        findsOneWidget);
    expect(find.textContaining('behind the gateway'), findsOneWidget);
  });
}
