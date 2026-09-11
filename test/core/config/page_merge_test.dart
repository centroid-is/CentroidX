/// `mergeForSave`: what a page editor's save may replace, decided per page
/// against what the store holds now and what the editor was shown.
///
/// The editor hands over the whole layout it loaded when it opened. Without
/// the merge, a page another station added while the editor was open was
/// deleted on the next Ctrl+S — cleanly, the compare-and-swap matching
/// because this station's snapshot had already reconciled the row — and an
/// edit another station made to a page this operator never touched was
/// overwritten with the copy from an hour ago.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';

final _at = DateTime.utc(2026, 9, 1);

/// A stored page row.
ConfigItem page(String id, String path, {int rev = 1, String label = 'P'}) =>
    ConfigItem.of(
      kind: ConfigKind.page,
      id: id,
      value: {
        'id': id,
        'menu_item': {'path': path, 'label': label},
        'mirroring_disabled': false,
      },
    ).stored(rev: rev, updatedAt: _at, updatedBy: 'x');

/// A stored asset row, at a gapped key.
ConfigItem asset(String id, String pageId, String text,
        {int rev = 1, int key = 1024}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'id': id, 'text': text},
      parentId: pageId,
      sortIndex: key,
    ).stored(rev: rev, updatedAt: _at, updatedBy: 'x');

/// The editor's copy of the same: no revision, ordinals for position.
ConfigItem editedPage(String id, String path, {String label = 'P'}) =>
    ConfigItem.of(
      kind: ConfigKind.page,
      id: id,
      value: {
        'id': id,
        'menu_item': {'path': path, 'label': label},
        'mirroring_disabled': false,
      },
    );

ConfigItem editedAsset(String id, String pageId, String text,
        {int ordinal = 0}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'id': id, 'text': text},
      parentId: pageId,
      sortIndex: ordinal,
    );

Set<String> ids(List<ConfigItem> items) => {for (final i in items) i.id};

String textOf(List<ConfigItem> items, String id) =>
    jsonDecode(items.singleWhere((i) => i.id == id).payload)['text'] as String;

void main() {
  final loaded = [
    page('p1', '/roe'),
    asset('a1', 'p1', 'A1'),
    page('p2', '/baader'),
    asset('a2', 'p2', 'A2'),
  ];
  final editorCopy = [
    editedPage('p1', '/roe'),
    editedAsset('a1', 'p1', 'A1'),
    editedPage('p2', '/baader'),
    editedAsset('a2', 'p2', 'A2'),
  ];

  test('nothing moved anywhere: the editor\'s layout, as it is', () {
    final merged =
        mergeForSave(wanted: editorCopy, stored: loaded, baseline: loaded);
    expect(ids(merged), {'p1', 'a1', 'p2', 'a2'});
    expect(merged.singleWhere((i) => i.id == 'a1').sortIndex, 0,
        reason: 'the editor\'s ordinals are handed on untouched');
  });

  test('a page added on another station is kept, assets and all', () {
    final stored = [...loaded, page('p3', '/new'), asset('a3', 'p3', 'A3')];
    final merged =
        mergeForSave(wanted: editorCopy, stored: stored, baseline: loaded);
    expect(ids(merged), {'p1', 'a1', 'p2', 'a2', 'p3', 'a3'});
    expect(merged.singleWhere((i) => i.id == 'a3').sortIndex, 1024,
        reason: 'kept as stored, so its own page\'s keys stay as they are');
  });

  test('a page changed on another station and untouched here: theirs wins',
      () {
    final stored = [
      page('p1', '/roe'),
      asset('a1', 'p1', 'A1'),
      page('p2', '/baader', rev: 2),
      asset('a2', 'p2', 'THEIRS', rev: 2),
    ];
    final merged =
        mergeForSave(wanted: editorCopy, stored: stored, baseline: loaded);
    expect(textOf(merged, 'a2'), 'THEIRS');
  });

  test('an asset added on another station to a page untouched here is kept',
      () {
    final stored = [...loaded, asset('a9', 'p2', 'LATE')];
    final merged =
        mergeForSave(wanted: editorCopy, stored: stored, baseline: loaded);
    expect(ids(merged), contains('a9'));
  });

  test('a page changed on another station and here too is a conflict, and '
      'names the page', () {
    final stored = [
      page('p1', '/roe'),
      asset('a1', 'p1', 'A1'),
      page('p2', '/baader'),
      asset('a2', 'p2', 'THEIRS', rev: 2),
    ];
    final mine = [
      editedPage('p1', '/roe'),
      editedAsset('a1', 'p1', 'A1'),
      editedPage('p2', '/baader'),
      editedAsset('a2', 'p2', 'MINE'),
    ];
    expect(
        () => mergeForSave(wanted: mine, stored: stored, baseline: loaded),
        throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'p2')));
  });

  test('a page deleted here that moved on another station is a conflict', () {
    final stored = [
      page('p1', '/roe'),
      asset('a1', 'p1', 'A1'),
      page('p2', '/baader', rev: 2),
      asset('a2', 'p2', 'A2'),
    ];
    final mine = [editedPage('p1', '/roe'), editedAsset('a1', 'p1', 'A1')];
    expect(
        () => mergeForSave(wanted: mine, stored: stored, baseline: loaded),
        throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'p2')));
  });

  test('a page deleted on another station and untouched here is dropped', () {
    final stored = [page('p1', '/roe'), asset('a1', 'p1', 'A1')];
    final merged =
        mergeForSave(wanted: editorCopy, stored: stored, baseline: loaded);
    expect(ids(merged), {'p1', 'a1'});
  });

  test('a page deleted on another station and edited here is a conflict', () {
    final stored = [page('p1', '/roe'), asset('a1', 'p1', 'A1')];
    final mine = [
      editedPage('p1', '/roe'),
      editedAsset('a1', 'p1', 'A1'),
      editedPage('p2', '/baader'),
      editedAsset('a2', 'p2', 'MINE'),
    ];
    expect(
        () => mergeForSave(wanted: mine, stored: stored, baseline: loaded),
        throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', 'p2')));
  });

  test('the operator\'s own edits and deletes go through when nothing moved',
      () {
    final mine = [
      editedPage('p1', '/roe'),
      editedAsset('a1', 'p1', 'MINE'),
      editedAsset('a7', 'p1', 'ADDED', ordinal: 1),
      // p2 deleted here.
    ];
    final merged =
        mergeForSave(wanted: mine, stored: loaded, baseline: loaded);
    expect(ids(merged), {'p1', 'a1', 'a7'});
    expect(textOf(merged, 'a1'), 'MINE');
  });

  test('two pages at one path is a conflict naming the path', () {
    final stored = [...loaded, page('p9', '/roe')];
    expect(
        () => mergeForSave(wanted: editorCopy, stored: stored, baseline: loaded),
        throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', '/roe')));
  });

  group('no baseline — an editor opened on a fallback layout', () {
    test('keeps every stored page it does not hold', () {
      final mine = [editedPage('p1', '/roe'), editedAsset('a1', 'p1', 'MINE')];
      final merged =
          mergeForSave(wanted: mine, stored: loaded, baseline: null);
      expect(ids(merged), {'p1', 'a1', 'p2', 'a2'});
      expect(textOf(merged, 'a1'), 'MINE', reason: 'ours wins where ids meet');
    });
  });
}
