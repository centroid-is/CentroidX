/// Golden images of the proposal banner's action labels, for design review
/// and PR descriptions.
///
/// Two frames: a single delete proposal (the row where accepting destroys
/// something, labelled in the same red as Reject), and an expanded batch
/// where each row carries its own CREATE / EDIT / DELETE chip and the
/// collapsed header sums them up.
///
/// To update: flutter test test/proposal/proposal_banner_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/widgets/proposal_banner.dart';

/// Wide enough for the header row (count, summary, batch buttons) to stay on
/// one line; tall enough for the expanded drawer.
const Size _viewport = Size(860, 320);

PendingProposal _proposal(int id, String type, String title, String op) =>
    PendingProposal(
      id: id,
      proposalType: type,
      title: title,
      proposalJson: '{"_op":"$op","key":"$title"}',
      operatorId: 'op',
      createdAt: DateTime(2026, 8, 20),
    );

Future<void> _pumpBanner(
    WidgetTester tester, List<PendingProposal> proposals) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        proposalStateProvider.overrideWith((ref) {
          final notifier = ProposalStateNotifier();
          for (final p in proposals) {
            notifier.addProposal(p);
          }
          return notifier;
        }),
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Stack(children: [ProposalBanner()]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

// ---------------------------------------------------------------------------
// Fonts — same best-effort loading as key_repository_add_key_golden_test.dart;
// without this every label is an Ahem block and every icon a tofu box.
// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/dejavu-sans/DejaVuSans.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('single proposal — a delete says so before it is accepted',
      (tester) async {
    await _pumpBanner(tester, [
      _proposal(1, 'key_mapping', 'CN04.M2400.SUB01', 'delete'),
    ]);
    await _expectGolden(tester, 'banner_single_delete.png');
  });

  testWidgets('expanded batch — each row labelled create, edit or delete',
      (tester) async {
    await _pumpBanner(tester, [
      _proposal(1, 'key_mapping', 'CN21.CONV.SPEED', 'create'),
      _proposal(2, 'alarm', 'Freezer door open too long', 'update'),
      _proposal(3, 'asset_update', 'Packing hall: relabel Afak SL-15-3',
          'update'),
      _proposal(4, 'key_mapping', 'CN04.M2400.SUB01', 'delete'),
    ]);

    await tester.tap(find.textContaining('4 AI Proposals'));
    await tester.pumpAndSettle();
    await _expectGolden(tester, 'banner_batch_expanded.png');
  });
}
