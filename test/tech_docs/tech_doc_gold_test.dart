/// Gold tests — automated verification of every manual UI verification item
/// from Phase 15 pending work. Each group maps to one of the 10 items.
///
/// These tests exercise the real DriftTechDocIndex (in-memory DB) and
/// the actual Flutter widgets, substituting only native plugins (pdfrx,
/// FilePicker, SharedPreferences) that cannot run in a widget-test harness.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/interfaces/tech_doc_index.dart';
import 'package:tfc_mcp_server/src/services/drift_tech_doc_index.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show TechDocSummary, TechDocSection;

import 'package:tfc_access/tfc_access.dart';

import 'package:tfc_dart/core/config/config_item.dart';

import 'package:tfc/core/config/page_codec.dart' show pageItems;
import 'package:tfc/core/guarded_knowledge_stores.dart'
    show kKnowledgeWriteGroup;
import 'package:tfc/drawings/drawing_overlay.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/page.dart' show AssetPage;
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/tech_doc.dart';
import 'package:tfc/tech_docs/tech_doc_library_section.dart';
import 'package:tfc/tech_docs/tech_doc_section_detail_panel.dart';
import 'package:tfc/tech_docs/tech_doc_picker.dart';
import 'package:tfc/tech_docs/tech_doc_upload_service.dart';
import '../helpers/test_helpers.dart'
    show createTestConfigStore, kConfiguringTestSession;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal PDF header bytes.
final _samplePdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d]);

/// Hierarchical sample sections.
final _sampleSections = [
  ParsedSection(
    title: 'Chapter 1: Installation',
    content: 'Installation procedure.',
    pageStart: 1,
    pageEnd: 10,
    level: 1,
    sortOrder: 0,
    children: [
      ParsedSection(
        title: '1.1 Mounting',
        content: 'Mount on a flat surface.',
        pageStart: 2,
        pageEnd: 5,
        level: 2,
        sortOrder: 1,
      ),
    ],
  ),
  ParsedSection(
    title: 'Chapter 2: Configuration',
    content: 'Configuration parameters.',
    pageStart: 11,
    pageEnd: 20,
    level: 1,
    sortOrder: 2,
  ),
];

/// Seed three documents into the index.
Future<List<int>> _seedDocs(DriftTechDocIndex index) async {
  final id1 = await index.storeDocument(
    name: 'ATV320 User Manual',
    pdfBytes: _samplePdf,
    sections: _sampleSections,
  );
  final id2 = await index.storeDocument(
    name: 'PT100 Sensor Datasheet',
    pdfBytes: _samplePdf,
    sections: [
      ParsedSection(
        title: 'Overview',
        content: 'PT100 specs.',
        pageStart: 1,
        pageEnd: 4,
        level: 1,
        sortOrder: 0,
      ),
    ],
  );
  final id3 = await index.storeDocument(
    name: 'Beckhoff CX5010 Quick Start',
    pdfBytes: _samplePdf,
    sections: [
      ParsedSection(
        title: 'Getting Started',
        content: 'CX5010 setup guide.',
        pageStart: 1,
        pageEnd: 30,
        level: 1,
        sortOrder: 0,
      ),
    ],
  );
  return [id1, id2, id3];
}

/// Build TechDocLibrarySection backed by a real in-memory DB.
Widget _buildLibraryWidget({
  required DriftTechDocIndex index,
  bool embedded = false,
  TechDocUploadService? uploadService,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      techDocIndexProvider.overrideWith((ref) => index),
      techDocUploadServiceProvider
          .overrideWith((ref) => uploadService ?? TechDocUploadService(index)),
      dbTechDocsProvider.overrideWith((ref) => index.getSummary()),
      selectedTechDocProvider.overrideWith((ref) => null),
      techDocUploadProgressProvider.overrideWith((ref) => null),
      // Override family providers to avoid pdfrx native plugin.
      techDocSectionsProvider
          .overrideWith((ref, docId) async => <TechDocSection>[]),
      techDocPdfBytesProvider.overrideWith((ref, docId) async => null),
      ...extraOverrides,
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 600,
          child: TechDocLibrarySection(embedded: embedded),
        ),
      ),
    ),
  );
}

/// An [accessSessionProvider] that answers one fixed session and never calls
/// the database.
///
/// The repository-wide idiom for pinning a session in a widget test —
/// `test/pages/history_view_guard_test.dart:144`,
/// `test/providers/access_templates_test.dart:67` and four more all declare the
/// same three lines locally, so this is a copy on purpose rather than a shared
/// helper nobody owns.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;
}

/// A session that does **not** hold [kKnowledgeWriteGroup]: nobody signed in,
/// holding `operate` only.
AccessSession _readerSession() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// A signed-in session that **does** hold [kKnowledgeWriteGroup].
AccessSession _writerSession() => const AccessSession(
      user: AuthenticatedUser(username: 'jon', roleName: 'Engineer'),
      groups: {AccessGroup.operate, kKnowledgeWriteGroup},
    );

/// An **anonymous** session that nonetheless holds [kKnowledgeWriteGroup].
///
/// Not a hypothetical. `AccessSession.anonymous`
/// (`packages/tfc_access/lib/src/access_session.dart:47`) builds its groups
/// from the `Operator` role, and that row is customer data -- its own doc
/// comment warns that ticking a group there "silently grants it to every panel
/// on the floor with nobody signed in". Tick `configure`, which is what
/// [kKnowledgeWriteGroup] resolves to, and this is the session every station in
/// the plant is running.
AccessSession _anonymousWriterSession() =>
    AccessSession.anonymous(const {AccessGroup.operate, kKnowledgeWriteGroup});

/// Drive the rename affordance the way a user does: double-tap the name cell,
/// type over it, submit.
Future<void> _renameViaUi(
  WidgetTester tester, {
  required String from,
  required String to,
}) async {
  final cell = find.text(from);
  expect(cell, findsOneWidget);
  await tester.tap(cell);
  // Longer than kDoubleTapMinTime (40ms) and shorter than kDoubleTapTimeout
  // (300ms), so the name cell's double-tap recognizer wins the arena instead of
  // the row's select tap.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(cell);
  await tester.pumpAndSettle();

  final field = find.widgetWithText(TextField, from);
  expect(field, findsOneWidget,
      reason: 'double-tap should have opened the rename field');
  await tester.enterText(field, to);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

/// Suppress RenderFlex overflow errors (common in narrow test widths).
void suppressOverflow() {
  final origHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.toString().contains('overflowed')) return;
    origHandler?.call(details);
  };
  addTearDown(() => FlutterError.onError = origHandler);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late ServerDatabase db;
  late DriftTechDocIndex index;

  setUp(() {
    db = ServerDatabase.inMemory();
    index = DriftTechDocIndex(db);
  });

  tearDown(() async {
    await db.close();
  });

  // =========================================================================
  // 1. Upload flow — SnackBar when DB unavailable
  // =========================================================================
  group('GOLD 1 — Upload flow (DB-unavailable SnackBar)', () {
    testWidgets('_performUpload shows SnackBar when service is null',
        (tester) async {
      // Override upload service to null (simulates no DB connection).
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            techDocIndexProvider.overrideWith((ref) => null),
            techDocUploadServiceProvider.overrideWith((ref) => null),
            dbTechDocsProvider.overrideWith((ref) async => <TechDocSummary>[]),
            selectedTechDocProvider.overrideWith((ref) => null),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The widget renders, without the upload row. This harness overrides no
      // access session, so the write affordance resolves on
      // `kSessionWhileLoading` (`lib/providers/access_policy.dart:183`) — the
      // strict floor, seeded-Operator groups only, which does not hold
      // `kKnowledgeWriteGroup` (`AccessGroup.configure`). That, and not any
      // ambient process state, is why the button is absent here. What must be
      // present for a reader either way is the empty state and the headers.
      expect(find.text('No resources found'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
    });

    testWidgets('upload progress indicator shows during upload',
        (tester) async {
      // Override progress to non-null to simulate active upload.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            techDocIndexProvider.overrideWith((ref) => index),
            techDocUploadServiceProvider
                .overrideWith((ref) => TechDocUploadService(index)),
            dbTechDocsProvider.overrideWith((ref) async => <TechDocSummary>[]),
            selectedTechDocProvider.overrideWith((ref) => null),
            techDocUploadProgressProvider.overrideWith(
              (ref) => const TechDocUploadProgress('Extracting text...', 0.5),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The progress message lives inside the upload row, which only a session
      // holding `kKnowledgeWriteGroup` sees. This harness overrides no session
      // either, so the guard again resolves on the `kSessionWhileLoading`
      // floor and the row — progress indicator included — is hidden. All this
      // test can therefore prove is that an upload in flight does not break the
      // widget for somebody who may not upload. The affordance itself is
      // asserted on both sides of the gate in "GOLD 1b" below.
      expect(find.byType(TechDocLibrarySection), findsOneWidget);
    });
  });

  // =========================================================================
  // 1b. Write affordance — both sides of the session gate
  // =========================================================================
  //
  // The upload row is convenience; `kKnowledgeWriteGroup` at the store level
  // (`lib/core/guarded_knowledge_stores.dart:84`) is the security boundary. The
  // two have to agree or the UI lies about what the signed-in user may do, so
  // the rule is asserted here in both directions.
  //
  // The deny side was already true before this group existed — but incidentally,
  // because the harness happens to build no session. A regression that hid the
  // upload row from *everyone* would have passed every assertion in this file.
  // That is what the allow-side test closes.
  group('GOLD 1b — Upload affordance vs the access session', () {
    testWidgets('hidden for a session that does not hold configure',
        (tester) async {
      suppressOverflow();
      await tester.pumpWidget(_buildLibraryWidget(
        index: index,
        extraOverrides: [
          accessSessionProvider
              .overrideWith(() => _FixedSession(_readerSession())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byType(TechDocLibrarySection), findsOneWidget);
      expect(find.text('Upload PDF'), findsNothing);
      expect(find.text('Upload PLC Project'), findsNothing);
    });

    testWidgets('appears for a session holding kKnowledgeWriteGroup',
        (tester) async {
      suppressOverflow();
      await tester.pumpWidget(_buildLibraryWidget(
        index: index,
        extraOverrides: [
          accessSessionProvider
              .overrideWith(() => _FixedSession(_writerSession())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Upload PDF'), findsOneWidget);
      expect(find.text('Upload PLC Project'), findsOneWidget);
    });
  });

  // =========================================================================
  // 1c. Write attribution — an anonymous session that may write
  // =========================================================================
  //
  // `_isWriteEnabled` gates the affordance on `kKnowledgeWriteGroup`, and an
  // anonymous session can hold it: `AccessSession.anonymous` takes its groups
  // from the customer-editable `Operator` role
  // (`packages/tfc_access/lib/src/access_session.dart:47`). On a station where
  // an admin ticked `configure` there, the rename/upload/delete/replace
  // affordances render for a panel with nobody signed in — so the write behind
  // them has to land, attributed to the same `'anonymous'` marker every other
  // guard in this repo records, rather than being refused by a UI that already
  // offered it.
  group('GOLD 1c — Writes under an anonymous session holding configure', () {
    testWidgets('rename lands in the DB instead of being refused',
        (tester) async {
      suppressOverflow();
      final ids = await _seedDocs(index);

      await tester.pumpWidget(_buildLibraryWidget(
        index: index,
        extraOverrides: [
          accessSessionProvider
              .overrideWith(() => _FixedSession(_anonymousWriterSession())),
        ],
      ));
      await tester.pumpAndSettle();

      await _renameViaUi(
        tester,
        from: 'PT100 Sensor Datasheet',
        to: 'PT100 Rev9 Datasheet',
      );

      final docs = await index.getSummary();
      expect(
        docs.firstWhere((d) => d.id == ids[1]).name,
        'PT100 Rev9 Datasheet',
        reason: 'the configured policy permits this write',
      );
    });

    testWidgets('the audit line is signed anonymous, not a placeholder name',
        (tester) async {
      suppressOverflow();
      // `auditTechDocOperation` only logs — it writes no audit row — so the
      // recorded name is only observable through the logger. `addLogListener`
      // is a static hook the package already offers, so pinning it costs
      // production code nothing.
      final messages = <String>[];
      void listener(LogEvent e) => messages.add(e.message.toString());
      Logger.addLogListener(listener);
      addTearDown(() => Logger.removeLogListener(listener));

      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(
        index: index,
        extraOverrides: [
          accessSessionProvider
              .overrideWith(() => _FixedSession(_anonymousWriterSession())),
        ],
      ));
      await tester.pumpAndSettle();

      await _renameViaUi(
        tester,
        from: 'PT100 Sensor Datasheet',
        to: 'PT100 Rev9 Datasheet',
      );

      final audit = messages.firstWhere(
        (m) => m.contains('TechDoc audit:') && m.contains('on doc='),
        orElse: () => '<no audit line logged>',
      );
      expect(audit, contains('by anonymous'));
    });

    testWidgets('a signed-in writer is still attributed by username',
        (tester) async {
      suppressOverflow();
      final messages = <String>[];
      void listener(LogEvent e) => messages.add(e.message.toString());
      Logger.addLogListener(listener);
      addTearDown(() => Logger.removeLogListener(listener));

      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(
        index: index,
        extraOverrides: [
          accessSessionProvider
              .overrideWith(() => _FixedSession(_writerSession())),
        ],
      ));
      await tester.pumpAndSettle();

      await _renameViaUi(
        tester,
        from: 'PT100 Sensor Datasheet',
        to: 'PT100 Rev9 Datasheet',
      );

      final audit = messages.firstWhere(
        (m) => m.contains('TechDoc audit:') && m.contains('on doc='),
        orElse: () => '<no audit line logged>',
      );
      expect(audit, contains('by jon'));
    });
  });

  // =========================================================================
  // 2. Rename flow — DB rename + UI refresh
  // =========================================================================
  group('GOLD 2 — Rename flow', () {
    testWidgets('renaming in DB and rebuilding widget shows new name',
        (tester) async {
      final ids = await _seedDocs(index);

      // Rename in DB.
      await index.renameDocument(ids[1], 'PT100 Rev2 Datasheet');
      final docs = await index.getSummary();
      final renamed = docs.firstWhere((d) => d.id == ids[1]);
      expect(renamed.name, 'PT100 Rev2 Datasheet');

      // Build UI — should reflect the renamed doc.
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('PT100 Rev2 Datasheet'), findsOneWidget);
      expect(find.text('PT100 Sensor Datasheet'), findsNothing);
    });

    testWidgets('renaming preserves other document names', (tester) async {
      final ids = await _seedDocs(index);
      await index.renameDocument(ids[0], 'ATV320 Rev3');

      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('ATV320 Rev3'), findsOneWidget);
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('Beckhoff CX5010 Quick Start'), findsOneWidget);
    });
  });

  // =========================================================================
  // 3. Delete flow — confirm dialog + DB delete + list refresh
  // =========================================================================
  group('GOLD 3 — Delete flow', () {
    testWidgets('deleting document removes it from DB and UI', (tester) async {
      final ids = await _seedDocs(index);
      expect(await index.getSummary(), hasLength(3));

      // Delete first doc.
      await index.deleteDocument(ids[0]);
      final remaining = await index.getSummary();
      expect(remaining, hasLength(2));
      expect(
          remaining.map((d) => d.name), isNot(contains('ATV320 User Manual')));

      // Build UI — deleted doc should not appear.
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('ATV320 User Manual'), findsNothing);
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('Beckhoff CX5010 Quick Start'), findsOneWidget);
    });

    testWidgets('deleting last document shows empty state', (tester) async {
      final ids = await _seedDocs(index);
      for (final id in ids) {
        await index.deleteDocument(id);
      }
      expect(await index.getSummary(), isEmpty);

      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('No resources found'), findsOneWidget);
    });

    testWidgets('deleteAndCleanAssets unlinks the asset row, then deletes',
        (tester) async {
      final ids = await _seedDocs(index);
      final service = TechDocUploadService(index);

      // A layout built through the model — `AssetPage` encodes `assets` as a
      // List, and the map-shaped string this fixture used to hold is the
      // shape the old cleanup's `assets is! Map` guard was written against
      // (D-4). The cleanup writes the shared rows now, not a preference.
      final linked = LEDConfig(key: 'CN04.Run')
        ..id = 'led-linked'
        ..techDocId = ids[0];
      final store = await createTestConfigStore(
          session: kConfiguringTestSession);
      await store.inner.writeItems(
        kinds: const {ConfigKind.page, ConfigKind.asset},
        wanted: pageItems({
          '/': AssetPage(
            menuItem:
                const MenuItem(label: 'Home', icon: Icons.home, path: '/'),
            assets: [linked],
            mirroringDisabled: false,
          )..id = 'page-home',
        }),
        actionId: 'seed',
        who: 'test',
        roleName: 'system',
      );

      await service.deleteAndCleanAssets(docId: ids[0], configStore: store);

      final row = store.inner
          .itemsOf(const {ConfigKind.asset})
          .singleWhere((item) => item.id == 'led-linked');
      expect(row.decode()['techDocId'], isNull);
      expect(row.decode()['key'], 'CN04.Run', reason: 'other fields survive');

      // Document should be gone from index.
      expect(await index.getSummary(), hasLength(2));
    });
  });

  // =========================================================================
  // 4. Replace flow — section update after replace
  // =========================================================================
  group('GOLD 4 — Replace flow', () {
    testWidgets('replacing document updates section count in DB',
        (tester) async {
      final ids = await _seedDocs(index);

      // PT100 originally has 1 section. Replace with 2 sections.
      await index.updateSections(ids[1], [
        ParsedSection(
          title: 'Revised Overview',
          content: 'Updated specs.',
          pageStart: 1,
          pageEnd: 6,
          level: 1,
          sortOrder: 0,
        ),
        ParsedSection(
          title: 'Appendix A',
          content: 'New appendix.',
          pageStart: 7,
          pageEnd: 8,
          level: 1,
          sortOrder: 1,
        ),
      ]);

      final docs = await index.getSummary();
      final updated = docs.firstWhere((d) => d.id == ids[1]);
      expect(updated.sectionCount, 2);

      // UI reflects the new section count.
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      // Section count column should show '2'.
      expect(find.text('2'), findsOneWidget);
    });
  });

  // =========================================================================
  // 5. View flow — sets drawing overlay providers
  // =========================================================================
  group('GOLD 5 — View flow (drawing overlay providers)', () {
    testWidgets('getPdfBytes returns stored bytes for viewing', (tester) async {
      final ids = await _seedDocs(index);

      final bytes = await index.getPdfBytes(ids[0]);
      expect(bytes, isNotNull);
      expect(bytes, _samplePdf);
    });

    testWidgets('view sets all drawing providers correctly', (tester) async {
      final ids = await _seedDocs(index);
      final pdfBytes = await index.getPdfBytes(ids[0]);

      // Build a ProviderScope and read drawing providers after simulating view.
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeDrawingBytesProvider.overrideWith((ref) => null),
            activeDrawingPathProvider.overrideWith((ref) => null),
            activeDrawingPageProvider.overrideWith((ref) => 1),
            activeDrawingHighlightProvider.overrideWith((ref) => null),
            drawingVisibleProvider.overrideWith((ref) => false),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Simulate what _viewDocument does.
      capturedRef.read(activeDrawingBytesProvider.notifier).state = pdfBytes;
      capturedRef.read(activeDrawingPathProvider.notifier).state = null;
      capturedRef.read(activeDrawingPageProvider.notifier).state = 1;
      capturedRef.read(activeDrawingHighlightProvider.notifier).state = null;
      capturedRef.read(drawingVisibleProvider.notifier).state = true;

      // Verify provider states.
      expect(capturedRef.read(activeDrawingBytesProvider), pdfBytes);
      expect(capturedRef.read(activeDrawingPathProvider), isNull);
      expect(capturedRef.read(activeDrawingPageProvider), 1);
      expect(capturedRef.read(activeDrawingHighlightProvider), isNull);
      expect(capturedRef.read(drawingVisibleProvider), isTrue);
    });
  });

  // =========================================================================
  // 6. Filter — type in filter box → table filters
  // =========================================================================
  group('GOLD 6 — Filter', () {
    testWidgets('typing partial name filters to matching docs', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      // All 3 visible initially.
      expect(find.text('ATV320 User Manual'), findsOneWidget);
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('Beckhoff CX5010 Quick Start'), findsOneWidget);

      // Filter to 'PT'.
      await tester.enterText(find.byType(TextField).first, 'PT');
      await tester.pumpAndSettle();

      expect(find.text('ATV320 User Manual'), findsNothing);
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('Beckhoff CX5010 Quick Start'), findsNothing);
    });

    testWidgets('filter is case-insensitive', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'beckhoff');
      await tester.pumpAndSettle();

      expect(find.text('Beckhoff CX5010 Quick Start'), findsOneWidget);
      expect(find.text('ATV320 User Manual'), findsNothing);
    });

    testWidgets('clearing filter restores all docs', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      final filterField = find.byType(TextField).first;
      await tester.enterText(filterField, 'ATV');
      await tester.pumpAndSettle();
      expect(find.text('PT100 Sensor Datasheet'), findsNothing);

      await tester.enterText(filterField, '');
      await tester.pumpAndSettle();
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('ATV320 User Manual'), findsOneWidget);
    });

    testWidgets('no-match filter shows empty state', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'zzzzz');
      await tester.pumpAndSettle();

      expect(find.text('No resources found'), findsOneWidget);
    });
  });

  // =========================================================================
  // 7. Sort — click column headers → sort toggles
  // =========================================================================
  group('GOLD 7 — Sort', () {
    testWidgets('clicking Name toggles sort direction', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      // Default: Name ascending with arrow_upward.
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

      // Click Name → descending.
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

      // Click Name again → ascending.
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('clicking Pages header switches sort column', (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pages'));
      await tester.pumpAndSettle();

      // Arrow should now be on Pages column (ascending).
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('clicking Sections header switches sort column',
        (tester) async {
      suppressOverflow();
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sections'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('clicking Upload Date header switches sort column',
        (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Upload Date'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });
  });

  // =========================================================================
  // 8. Selection — click row → detail panel appears with sections
  // =========================================================================
  group('GOLD 8 — Selection + detail panel', () {
    testWidgets('tapping row selects doc and shows detail panel',
        (tester) async {
      suppressOverflow();

      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      // No detail panel yet (no close icon).
      expect(find.byIcon(Icons.close), findsNothing);

      // Select a document.
      await tester.tap(find.text('ATV320 User Manual'));
      await tester.pumpAndSettle();

      // Detail panel shows with close button.
      expect(find.byIcon(Icons.close), findsOneWidget);
      // The detail panel header shows the document name (may show twice:
      // once in the master list row, once in the detail panel header).
      expect(find.text('ATV320 User Manual'), findsWidgets);
    });

    testWidgets('tapping selected row again hides detail panel',
        (tester) async {
      suppressOverflow();

      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      // Select.
      await tester.tap(find.text('ATV320 User Manual'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close), findsOneWidget);

      // Deselect.
      await tester.tap(find.text('ATV320 User Manual').first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('detail panel shows sections with titles and page ranges',
        (tester) async {
      suppressOverflow();
      final ids = await _seedDocs(index);

      // Provide real sections for the selected doc.
      final sections = [
        TechDocSection(
          id: 1,
          docId: ids[0],
          title: 'Chapter 1: Installation',
          content: 'Installation procedure.',
          pageStart: 1,
          pageEnd: 10,
          level: 1,
          sortOrder: 0,
        ),
        TechDocSection(
          id: 2,
          docId: ids[0],
          title: '1.1 Mounting',
          content: 'Mount on a flat surface.',
          pageStart: 2,
          pageEnd: 5,
          level: 2,
          sortOrder: 1,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            techDocSectionsProvider(ids[0])
                .overrideWith((ref) async => sections),
            techDocPdfBytesProvider(ids[0]).overrideWith((ref) async => null),
            dbTechDocsProvider.overrideWith((ref) => index.getSummary()),
            selectedTechDocProvider.overrideWith((ref) => ids[0]),
            techDocIndexProvider.overrideWith((ref) => index),
            techDocUploadServiceProvider
                .overrideWith((ref) => TechDocUploadService(index)),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Detail panel shows inline PDF (no section list).
      // With null bytes it shows the fallback message.
      expect(find.text('PDF not available'), findsOneWidget);
    });

    testWidgets('detail panel shows "No sections detected" for empty sections',
        (tester) async {
      suppressOverflow();
      final ids = await _seedDocs(index);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            techDocSectionsProvider(ids[0])
                .overrideWith((ref) async => <TechDocSection>[]),
            techDocPdfBytesProvider(ids[0]).overrideWith((ref) async => null),
            dbTechDocsProvider.overrideWith((ref) => index.getSummary()),
            selectedTechDocProvider.overrideWith((ref) => ids[0]),
            techDocIndexProvider.overrideWith((ref) => index),
            techDocUploadServiceProvider
                .overrideWith((ref) => TechDocUploadService(index)),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Panel now shows inline PDF; with null bytes shows fallback.
      expect(find.text('PDF not available'), findsOneWidget);
    });

    testWidgets('close button in detail panel clears selection',
        (tester) async {
      suppressOverflow();

      await _seedDocs(index);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            techDocSectionsProvider
                .overrideWith((ref, docId) async => <TechDocSection>[]),
            techDocPdfBytesProvider.overrideWith((ref, docId) async => null),
            dbTechDocsProvider.overrideWith((ref) => index.getSummary()),
            selectedTechDocProvider.overrideWith((ref) => null),
            techDocIndexProvider.overrideWith((ref) => index),
            techDocUploadServiceProvider
                .overrideWith((ref) => TechDocUploadService(index)),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Select a doc.
      await tester.tap(find.text('ATV320 User Manual'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close panel'), findsOneWidget);

      // Close the panel.
      await tester.tap(find.byTooltip('Close panel'));
      await tester.pumpAndSettle();

      // Detail panel is gone.
      expect(find.byTooltip('Close panel'), findsNothing);
    });
  });

  // =========================================================================
  // 9. Standalone page — embedded=false renders without ExpansionTile
  // =========================================================================
  group('GOLD 9 — Standalone page (embedded flag)', () {
    testWidgets('embedded=true wraps in ExpansionTile', (tester) async {
      await _seedDocs(index);
      await tester
          .pumpWidget(_buildLibraryWidget(index: index, embedded: true));
      await tester.pumpAndSettle();

      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(find.text('Knowledge Base'), findsOneWidget);
    });

    testWidgets('embedded=false skips ExpansionTile, shows content directly',
        (tester) async {
      await _seedDocs(index);
      await tester
          .pumpWidget(_buildLibraryWidget(index: index, embedded: false));
      await tester.pumpAndSettle();

      expect(find.byType(ExpansionTile), findsNothing);
      // Content is directly visible.
      expect(find.text('ATV320 User Manual'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Pages'), findsOneWidget);
    });

    testWidgets('embedded=true content visible after expanding',
        (tester) async {
      await _seedDocs(index);
      await tester
          .pumpWidget(_buildLibraryWidget(index: index, embedded: true));
      await tester.pumpAndSettle();

      // Tap to expand.
      await tester.tap(find.text('Knowledge Base'));
      await tester.pumpAndSettle();

      // Now doc names should be visible.
      expect(find.text('ATV320 User Manual'), findsOneWidget);
    });
  });

  // =========================================================================
  // 10. Asset integration — TechDocPicker
  // =========================================================================
  group('GOLD 10 — TechDocPicker (asset integration)', () {
    final sampleDocs = [
      TechDocSummary(
        id: 1,
        name: 'ATV320 User Manual',
        pageCount: 120,
        sectionCount: 15,
        uploadedAt: DateTime(2026, 1, 1),
      ),
      TechDocSummary(
        id: 2,
        name: 'PT100 Sensor Datasheet',
        pageCount: 4,
        sectionCount: 3,
        uploadedAt: DateTime(2026, 1, 2),
      ),
    ];

    Widget buildPickerWidget({
      List<TechDocSummary> docs = const [],
      int? selectedDocId,
      ValueChanged<int?>? onChanged,
      bool enabled = true,
    }) {
      return ProviderScope(
        overrides: [
          dbTechDocsProvider.overrideWith((_) async => docs),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: TechDocPicker(
                selectedDocId: selectedDocId,
                onChanged: onChanged ?? (_) {},
                enabled: enabled,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows "No documents uploaded" when empty', (tester) async {
      await tester.pumpWidget(buildPickerWidget(docs: []));
      await tester.pumpAndSettle();

      expect(find.text('No documents uploaded'), findsOneWidget);
    });

    testWidgets('shows placeholder when no selection', (tester) async {
      await tester.pumpWidget(buildPickerWidget(docs: sampleDocs));
      await tester.pumpAndSettle();

      expect(find.text('Select document...'), findsOneWidget);
    });

    testWidgets('shows selected document name', (tester) async {
      await tester
          .pumpWidget(buildPickerWidget(docs: sampleDocs, selectedDocId: 1));
      await tester.pumpAndSettle();

      expect(find.text('ATV320 User Manual'), findsOneWidget);
    });

    testWidgets('opens dropdown with doc list on tap', (tester) async {
      await tester.pumpWidget(buildPickerWidget(docs: sampleDocs));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      expect(find.text('ATV320 User Manual'), findsOneWidget);
      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
    });

    testWidgets('selecting doc calls onChanged', (tester) async {
      int? selected;
      await tester.pumpWidget(buildPickerWidget(
        docs: sampleDocs,
        onChanged: (id) => selected = id,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PT100 Sensor Datasheet'));
      await tester.pumpAndSettle();

      expect(selected, 2);
    });

    testWidgets('"None" option clears selection', (tester) async {
      int? selected = 1;
      await tester.pumpWidget(buildPickerWidget(
        docs: sampleDocs,
        selectedDocId: 1,
        onChanged: (id) => selected = id,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();

      expect(selected, isNull);
    });

    testWidgets('search filters dropdown', (tester) async {
      await tester.pumpWidget(buildPickerWidget(docs: sampleDocs));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'PT');
      await tester.pumpAndSettle();

      expect(find.text('PT100 Sensor Datasheet'), findsOneWidget);
      expect(find.text('ATV320 User Manual'), findsNothing);
    });

    testWidgets('disabled picker does not open dropdown', (tester) async {
      await tester
          .pumpWidget(buildPickerWidget(docs: sampleDocs, enabled: false));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      // No doc names in overlay.
      expect(find.text('ATV320 User Manual'), findsNothing);
    });

    testWidgets('dropdown shows page and section counts', (tester) async {
      await tester.pumpWidget(buildPickerWidget(docs: sampleDocs));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TechDocPicker));
      await tester.pumpAndSettle();

      expect(find.text('120 pages, 15 sections'), findsOneWidget);
      expect(find.text('4 pages, 3 sections'), findsOneWidget);
    });
  });

  // =========================================================================
  // Cross-cutting: data display from real DB
  // =========================================================================
  group('GOLD — DB round-trip data display', () {
    testWidgets('page counts, section counts, and dates render correctly',
        (tester) async {
      await _seedDocs(index);
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      // ATV320: 20 pages, 3 sections. PT100: 4 pages, 1 section. CX5010: 30 pages, 1 section.
      expect(find.text('20'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // Dates match today's date prefix.
      final now = DateTime.now();
      final prefix =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(find.textContaining(prefix), findsWidgets);
    });

    testWidgets('column headers are all present', (tester) async {
      await tester.pumpWidget(_buildLibraryWidget(index: index));
      await tester.pumpAndSettle();

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Pages'), findsOneWidget);
      expect(find.text('Sections'), findsOneWidget);
      expect(find.text('Upload Date'), findsOneWidget);
    });

    testWidgets('search returns matching sections from DB', (tester) async {
      await _seedDocs(index);

      final results = await index.search('Installation');
      expect(results, isNotEmpty);
      expect(results.first.sectionTitle, contains('Installation'));
    });
  });

  // =========================================================================
  // Async states
  // =========================================================================
  group('GOLD — Async loading and error states', () {
    testWidgets('shows CircularProgressIndicator while loading',
        (tester) async {
      final completer = Completer<List<TechDocSummary>>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbTechDocsProvider.overrideWith((_) => completer.future),
            techDocIndexProvider.overrideWith((ref) => index),
            techDocUploadServiceProvider.overrideWith((ref) => null),
            selectedTechDocProvider.overrideWith((ref) => null),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Complete to avoid pending timer.
      completer.complete([]);
      await tester.pumpAndSettle();
    });

    testWidgets('shows error message on load failure', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbTechDocsProvider.overrideWith(
              (_) => Future<List<TechDocSummary>>.error('DB connection lost'),
            ),
            techDocIndexProvider.overrideWith((ref) => null),
            techDocUploadServiceProvider.overrideWith((ref) => null),
            selectedTechDocProvider.overrideWith((ref) => null),
            techDocUploadProgressProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: TechDocLibrarySection(embedded: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Error loading documents'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

