/// Pasting images into the page editor, end to end: Ctrl/Cmd+V with an image
/// on the system clipboard drops an ImageConfig on the canvas, its bytes land
/// in the preference store the pages save into, copied assets still win over
/// a stale clipboard image, and saving garbage-collects orphaned blobs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/page_editor.dart' show imageCollectionGrace;

import 'package:tfc/page_creator/assets/editor_clipboard.dart';
import 'package:tfc/page_creator/assets/image.dart';
import 'package:tfc/page_creator/assets/image_store.dart';

import '../helpers/image_fixtures.dart';
import '../helpers/page_editor_harness.dart';

/// A clipboard whose contents the test scripts. [writeText] records what the
/// editor mirrors onto it, exactly like a real clipboard would hold it.
class FakeClipboard extends EditorClipboard {
  Uint8List? image;
  String? text;
  @override
  Future<Uint8List?> readImage() async => image;
  @override
  Future<String?> readText() async => text;
  @override
  Future<void> writeText(String value) async => text = value;
}

Future<void> pressPaste(WidgetTester tester, {Finder? until}) async {
  await tester.sendKeyDownEvent(editorModifier);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(editorModifier);
  // Ingest decodes the image through the engine's codec; that future only
  // completes while real async is allowed to run.
  //
  // How long that takes is a property of the machine, not of the code, so
  // callers expecting something to appear say what it is and this polls for
  // it. A flat delay tuned on a dev machine is a slow-CI failure waiting to
  // happen -- this test passed locally and failed on a loaded macOS runner at
  // the previous 50ms.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    if (until == null || until.evaluate().isNotEmpty) break;
    if (DateTime.now().isAfter(deadline)) break;
  }
}

Future<void> pressCopy(WidgetTester tester) async {
  await tester.sendKeyDownEvent(editorModifier);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(editorModifier);
  await tester.pumpAndSettle();
}

void main() {
  late FakeClipboard clipboard;

  setUp(() {
    setUpEditorEnvironment();
    clipboard = FakeClipboard();
    EditorClipboard.instance = clipboard;
  });

  tearDown(() => EditorClipboard.instance = EditorClipboard());

  testWidgets('Ctrl/Cmd+V with a clipboard image adds an image asset',
      (tester) async {
    final prefs = await pumpEditorWith(tester, []);
    clipboard.image = fixturePngBytes;

    await pressPaste(tester, until: find.byType(PageImage));

    // On the canvas, selected, and shaped like the 48x32 source.
    expect(find.byType(PageImage), findsOneWidget);
    expect(selectedCount(tester), 1);

    // Persisted: the asset carries the content-hash id, the blob sits on its
    // own `page_image` row, not inside the page JSON.
    final saved = await saveAndReadBack(tester, prefs);
    expect(saved, hasLength(1));
    expect(saved.single['asset_name'], 'ImageConfig');
    final id = saved.single['image_id'] as String;
    expect(id, await PageImageStore.imageIdFor(fixturePngBytes));
    expect(await (await imageStoreOf(prefs)).load(id), fixturePngBytes);
    expect(saved.single['natural_aspect'], closeTo(1.5, 0.001));
  });

  testWidgets('an unsupported clipboard payload pastes nothing',
      (tester) async {
    await pumpEditorWith(tester, []);
    clipboard.image = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

    await pressPaste(tester, until: find.byType(SnackBar));

    expect(find.byType(PageImage), findsNothing);
    // The failure surfaces to the operator instead of vanishing.
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('an empty clipboard pastes nothing', (tester) async {
    await pumpEditorWith(tester, []);
    await pressPaste(tester);
    expect(find.byType(PageImage), findsNothing);
  });

  testWidgets('copied assets outrank a stale clipboard image', (tester) async {
    await pumpEditorWith(tester, [editorBox(0.3, 0.3)]);
    // An image copied some time ago...
    clipboard.image = fixturePngBytes;

    // ...then the user copies an asset in the editor, which mirrors the asset
    // JSON onto the clipboard as the most recent copy.
    await tapAsset(tester, 0.3, 0.3);
    await pressCopy(tester);
    expect(clipboard.text, contains('DrawnBoxConfig'));

    await pressPaste(tester);

    expect(find.byType(PageImage), findsNothing,
        reason: 'the asset copy is newer than the image');
    expect(selectedCount(tester), 1, reason: 'the pasted box is selected');
  });

  testWidgets('clipboard asset JSON pastes even with no in-memory copy buffer',
      (tester) async {
    // Simulates copy in one editor window, paste in another: only the system
    // clipboard carries the assets.
    final other = editorBox(0.4, 0.4);
    clipboard.text = '{"assets": [${jsonOf(other)}]}';

    await pumpEditorWith(tester, []);
    await pressPaste(tester);

    expect(selectedCount(tester), 1);
  });

  testWidgets('saving deletes orphaned image blobs but keeps referenced ones',
      (tester) async {
    // The collector spares anything stored in the last day; this test is
    // about what it takes once that grace is over.
    imageCollectionGrace = Duration.zero;
    addTearDown(() => imageCollectionGrace = const Duration(hours: 24));
    final prefs = await pumpEditorWith(tester, []);
    final store = await imageStoreOf(prefs);
    final orphan = await store.save(fixtureJpegBytes);

    clipboard.image = fixturePngBytes;
    await pressPaste(tester);
    final kept = await PageImageStore.imageIdFor(fixturePngBytes);

    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();

    expect(await store.load(kept), fixturePngBytes,
        reason: 'the pasted image is on the saved page');
    expect(await store.load(orphan), null,
        reason: 'nothing references the orphan');
  });
}

/// The persisted JSON of one asset, as _handleCopy would produce it.
String jsonOf(Object asset) {
  // editorBox returns a DrawnBoxConfig; its toJson nests Coordinates objects,
  // so run it through encode to get plain JSON text.
  return const JsonEncoder().convert((asset as dynamic).toJson());
}
