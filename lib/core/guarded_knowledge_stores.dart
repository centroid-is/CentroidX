/// The knowledge base's write guards — the **fifth** bypass class, closed at
/// the controls.
///
/// `docs/access-control-write-path-sweep.md` §3.1: `DriftTechDocIndex`,
/// `DriftPlcCodeIndex` and `DriftDrawingIndex` live in
/// `packages/tfc_mcp_server/lib/src/services/` and write Drift directly —
/// twenty-six statements between them. They were built for the MCP server, but
/// all three are wired into the Flutter app through providers
/// (`lib/providers/tech_doc.dart`, `lib/providers/plc.dart`,
/// `lib/providers/drawing.dart`) and their write methods are called from
/// `lib/tech_docs/tech_doc_upload_service.dart`,
/// `lib/tech_docs/tech_doc_library_section.dart` and
/// `lib/drawings/drawing_upload_service.dart`. None of it passed
/// `StateMan.write` or `PreferencesApi.set*`, so neither `GuardedStateMan` nor
/// `GuardedPreferences` could ever see it. An anonymous session at the panel
/// could delete a technical document and delete a PLC asset's index.
///
/// ## The decorator idiom, and why it fits here
///
/// All three Drift classes implement abstract interfaces, and every app-side
/// consumer is typed against the *interface* — `TechDocUploadService` holds a
/// `TechDocIndex`, `DrawingUploadService` holds a `DrawingIndex`. So wrapping
/// the three providers changes no call site at all, and the index classes
/// themselves are not touched: they are shared with the MCP server and this is
/// entirely app-side.
///
/// **Except for [PlcCodeIndexExtras]** — see its doc comment. That is the whole
/// risk of the change and the reason this file declares an interface as well as
/// three decorators.
///
/// ## Every member is forwarded by hand
///
/// There is no catch-all dispatch in this file, and
/// `test/core/guarded_knowledge_stores_test.dart` greps for it. Every member of
/// every interface is forwarded explicitly. Thirty forwards is tedious and the
/// tedium is the point: a catch-all decorator answers a member somebody forgot
/// to wire by throwing at runtime, on a plant, the first time it is called —
/// and the compiler, which would otherwise have refused the class outright,
/// says nothing. The same rule, for the same reason, as
/// `packages/tfc_dart/lib/core/access/guarded_state_man.dart`.
///
/// ## Why the group is declared here rather than looked up
///
/// These classes consult no policy table. The group is [kKnowledgeWriteGroup],
/// a constant in this file — the route-style declaration spec §7 uses for a
/// surface whose items are not preference keys, the same shape plan 03-10's
/// `HistoryViewStore` uses. A `tech_doc.` rule in `kPrefAccessRules` would be a
/// *second* source for one answer and the two would drift. If you are here to
/// change what is gated, change the constant below; do not add a rule
/// elsewhere.
///
/// ## The route is the other half
///
/// `/advanced/knowledge-base` is raised by plan 03-14. Neither half is
/// sufficient: the route gate keeps an anonymous session off the page, and
/// these guards are what refuse the write if any other path ever reaches them.
library;

import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import '../tech_docs/tech_doc_upload_service.dart' show PrefsReader;

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// The permission every knowledge-base write requires.
///
/// `configure`, because this is authored content — the same concern as the page
/// editor and the key mappings, and the same group `page_editor_data` already
/// resolves to. A technical manual, a PLC asset's indexed source and an
/// electrical drawing are all things somebody uploaded on purpose; destroying
/// one from an anonymous panel session is the defect §3.1 found.
///
/// This is the only place the answer lives. Changing it here changes all eleven
/// writes and the page-layout cleanup at once, and the deny tests in
/// `test/core/guarded_knowledge_stores_test.dart` are what report exactly what
/// moved. Do **not** add a `tech_doc.` / `plc_asset.` / `drawing.` rule to
/// `kPrefAccessRules`: the guards below never read it, so such a rule would
/// look authoritative and do nothing.
const AccessGroup kKnowledgeWriteGroup = AccessGroup.configure;

/// The five public members the app uses on [DriftPlcCodeIndex] that
/// [PlcCodeIndex] does not declare.
///
/// **This interface exists because of five type tests.** Before plan 03-13,
/// `plcCodeIndexProvider` returned the concrete `DriftPlcCodeIndex` and five
/// places in the app checked for it by name:
///
/// | Site | What a wrapper without this interface does to it |
/// |---|---|
/// | `plcVarRefsForBlockProvider` | silently returns `[]` |
/// | `plcFbInstancesProvider` | silently returns `[]` |
/// | `plcBlockCallsProvider` | silently returns `[]` |
/// | `plcVarRefsProvider` | silently returns `[]` |
/// | `_reindexPlcAsset` in `tech_doc_library_section.dart` | shows "Re-index unavailable — database not connected", which would be a lie |
///
/// The first four are **reads** feeding the PLC detail panel, and they fail by
/// returning an empty list rather than by throwing. Wrapping the provider
/// without this interface turns the panel blank with no error anywhere — the
/// exact silent-breakage shape this phase exists to prevent, arriving through
/// the phase's own change. So the five type tests moved onto this interface and
/// the four providers have tests that were watched failing in between.
///
/// **[DriftPlcCodeIndex] does not implement this interface.** Dart is nominal:
/// declaring the same five signatures does not make the Drift class a
/// `PlcCodeIndexExtras`. [GuardedPlcCodeIndex] is the only implementer, and
/// after plan 03-13 the provider always returns the guard, so `is
/// PlcCodeIndexExtras` and "the app's PLC index" mean the same thing. That is
/// the property the five moved type tests rely on, stated where they can find
/// it. If some future code hands the raw Drift index to those providers again,
/// the type test fails and the panel goes blank — which is why
/// `knowledge_guard_wiring_test.dart` asserts what the provider returns.
///
/// `DriftPlcCodeIndex.getCallers` is a sixth extra member and is deliberately
/// **not** here: no app code calls it. Add it the day something does.
///
/// **It `implements PlcCodeIndex`** so that `is! PlcCodeIndexExtras` at the
/// four providers *promotes*. Dart only promotes a variable to a subtype of its
/// declared type, and those providers hold a `PlcCodeIndex?`; against a
/// standalone interface the check would compile to nothing usable and every
/// call after it would need a cast. Five members are declared here — the
/// eight below them are `PlcCodeIndex`'s, unchanged.
abstract interface class PlcCodeIndexExtras implements PlcCodeIndex {
  /// Re-parses an asset's stored source and rebuilds its index. A **write**,
  /// however the name reads — see [GuardedPlcCodeIndex.reindexAsset].
  Future<int> reindexAsset(String assetKey);

  /// Variable references originating from one block. Read.
  Future<List<PlcVarRefTableData>> getVarRefsForBlock(int blockId);

  /// Function-block instance declarations. Read.
  ///
  /// The optional filters are carried through from [DriftPlcCodeIndex] rather
  /// than dropped: the app calls this with no arguments today, and narrowing
  /// the interface would quietly remove a capability the class has.
  Future<List<PlcFbInstanceTableData>> getFbInstances({
    String? fbTypeName,
    String? instanceName,
  });

  /// Block-to-block call edges originating from one block. Read.
  Future<List<PlcBlockCallTableData>> getBlockCalls(int blockId);

  /// Variable references matching a path suffix. Read.
  Future<List<PlcVarRefTableData>> getVarRefs(String variablePath);
}

// ---------------------------------------------------------------------------
// The one implementation of the rule
// ---------------------------------------------------------------------------

/// Check, record, then write — the ordering `GuardedStateMan` established and
/// plan 03-10's `HistoryViewStore` reused. Held once here rather than eleven
/// times across three classes.
///
/// The row comes **before** the inner call on both paths. On the permitted path
/// that means a write which then fails at the database leaves a row for an
/// action that was authorized, which is the lesser loss: spec §2's reasoning is
/// that an absent audit row is the defect nobody notices. On the deny path the
/// row is the only evidence the guard fired and must exist even though the
/// exception is about to be thrown.
abstract class _KnowledgeGuard {
  _KnowledgeGuard({
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;

  /// This guard's own diagnostic logger, for the audit-sink failures it
  /// swallows. Nothing else logs here.
  final Logger _logger;

  /// The surface every row carries, by its wire name rather than a `'pref'`
  /// literal.
  ///
  /// A manual, an indexed PLC project and a drawing are station configuration,
  /// so they belong on the existing `pref` surface; spec §2's `surface`
  /// vocabulary is three write values and adding a fourth for one page would
  /// make a year of rows read differently. The `tech_doc.`, `plc_asset.` and
  /// `drawing.` `itemKey` prefixes are what let the Phase 5 viewer group them
  /// without that.
  static final String _surface = AccessSurface.pref.wireName;

  /// Gate [write] on [kKnowledgeWriteGroup], record it either way.
  Future<T> _guard<T>({
    required String itemKey,
    required String reason,
    required Future<T> Function() write,
    String? newValue,
  }) async {
    // One id per call, so a row correlates with the action that made it and two
    // actions never collide.
    final actionId = newActionId();
    final session = _session();

    if (!session.can(kKnowledgeWriteGroup)) {
      await _record(_row(
        session: session,
        itemKey: itemKey,
        newValue: newValue,
        allowed: false,
        reason: reason,
        actionId: actionId,
      ));

      final denial = AccessDenied(itemKey, kKnowledgeWriteGroup);
      try {
        _onDenied?.call(denial);
      } on Object catch (error, stack) {
        // A listener's bug must not change what the caller sees. The refusal is
        // this guard's answer; a broken prompt is cosmetic beside it.
        _logger.e('onDenied listener threw for "$itemKey"',
            error: error, stackTrace: stack);
      }
      throw denial;
    }

    await _record(_row(
      session: session,
      itemKey: itemKey,
      newValue: newValue,
      allowed: true,
      reason: reason,
      actionId: actionId,
    ));
    return write();
  }

  AuditRecord _row({
    required AccessSession session,
    required String itemKey,
    required String? newValue,
    required bool allowed,
    required String reason,
    required String actionId,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleLabel,
        surface: _surface,
        itemKey: itemKey,
        newValue: newValue,
        groupRequired: kKnowledgeWriteGroup.name,
        allowed: allowed,
        // Which of the eleven it was. A delete carries no old and no new value
        // — the row would otherwise say only that *something* happened to a
        // document.
        reason: reason,
        actionId: actionId,
      );

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// [AuditSink]'s non-throwing contract lives in a doc comment and nothing
  /// enforces it, and the consequences of trusting it differ by path. On the
  /// permitted path an escaping sink exception would fail a write the session
  /// was allowed to make. On the deny path it would replace [AccessDenied] with
  /// something no caller catches, skip `onDenied`, and leave the operator with
  /// a control that did nothing and no explanation for it. Neither is
  /// acceptable, and this is the same rule in the same words as plans 03-04,
  /// 03-05 and 03-10.
  ///
  /// The price is that a lost row is only a log line, so the line names the row
  /// it lost.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Technical documents
// ---------------------------------------------------------------------------

/// [TechDocIndex] with its five writes gated on [kKnowledgeWriteGroup] and
/// recorded, and its seven reads forwarded untouched.
///
/// The five writes are reached from `TechDocUploadService` — upload, replace,
/// rename and `deleteAndCleanAssets` — which holds a `TechDocIndex`, so
/// wrapping `techDocIndexProvider` changes nothing at that call site.
class GuardedTechDocIndex extends _KnowledgeGuard implements TechDocIndex {
  /// [session] is a **callback, not a value**, for the reason `GuardedStateMan`
  /// gives at its own constructor: the guard is built once per database and
  /// outlives any one session, and a captured [AccessSession] would keep
  /// granting whatever the operator held when the provider was built, after the
  /// inactivity monitor had already dropped them back to anonymous.
  ///
  /// [onDenied] fires **before** the [AccessDenied] is thrown, so the shared
  /// prompt (`lib/widgets/access_denied_prompt.dart`) appears even at a call
  /// site that swallows the exception.
  GuardedTechDocIndex({
    required TechDocIndex inner,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
    super.logger,
  }) : _inner = inner;

  final TechDocIndex _inner;

  /// The `itemKey` of a document. The prefix is what the Phase 5 viewer filters
  /// on.
  static String _itemKey(int docId) => 'tech_doc.$docId';

  // --- writes --------------------------------------------------------------

  /// The row's `itemKey` is `tech_doc.new`, not `tech_doc.<id>`: the row is
  /// written before the insert (see [_KnowledgeGuard._guard]), so there is no
  /// id yet. The name is in `newValue`, and the prefix a reader filters on is
  /// intact. Same convention as `HistoryViewStore.createHistoryView`.
  @override
  Future<int> storeDocument({
    required String name,
    required Uint8List pdfBytes,
    required List<ParsedSection> sections,
    int? pageCount,
  }) =>
      _guard(
        itemKey: 'tech_doc.new',
        reason: 'storeDocument',
        newValue: name,
        write: () => _inner.storeDocument(
          name: name,
          pdfBytes: pdfBytes,
          sections: sections,
          pageCount: pageCount,
        ),
      );

  @override
  Future<void> updateSections(int docId, List<ParsedSection> sections,
          {int? pageCount}) =>
      _guard(
        itemKey: _itemKey(docId),
        reason: 'updateSections',
        write: () =>
            _inner.updateSections(docId, sections, pageCount: pageCount),
      );

  @override
  Future<void> renameDocument(int docId, String newName) => _guard(
        itemKey: _itemKey(docId),
        reason: 'renameDocument',
        newValue: newName,
        write: () => _inner.renameDocument(docId, newName),
      );

  @override
  Future<void> deleteDocument(int docId) => _guard(
        itemKey: _itemKey(docId),
        reason: 'deleteDocument',
        write: () => _inner.deleteDocument(docId),
      );

  @override
  Future<void> updatePdfBytes(int docId, Uint8List pdfBytes) => _guard(
        itemKey: _itemKey(docId),
        reason: 'updatePdfBytes',
        write: () => _inner.updatePdfBytes(docId, pdfBytes),
      );

  // --- reads: ungated and unaudited, per spec §11 --------------------------

  @override
  Future<List<TechDocSearchResult>> search(String query, {int limit = 20}) =>
      _inner.search(query, limit: limit);

  @override
  Future<TechDocSection?> getSection(int sectionId) =>
      _inner.getSection(sectionId);

  @override
  Future<List<TechDocSummary>> getSummary() => _inner.getSummary();

  @override
  Future<bool> get isEmpty => _inner.isEmpty;

  @override
  Future<Uint8List?> getPdfBytes(int docId) => _inner.getPdfBytes(docId);

  @override
  Future<List<TechDocSection>> getSectionsForDoc(int docId) =>
      _inner.getSectionsForDoc(docId);

  @override
  Future<List<TechDocLink>> getLinkedAssets(int docId) =>
      _inner.getLinkedAssets(docId);
}

// ---------------------------------------------------------------------------
// PLC code
// ---------------------------------------------------------------------------

/// [PlcCodeIndex] plus [PlcCodeIndexExtras], with its four writes gated on
/// [kKnowledgeWriteGroup] and recorded.
///
/// The constructor takes the **concrete** [DriftPlcCodeIndex] rather than the
/// [PlcCodeIndex] interface, because the five extras exist only there. That
/// makes "a guard over an index that cannot answer the call-graph getters" a
/// compile-time impossibility rather than a runtime surprise on the PLC detail
/// panel.
class GuardedPlcCodeIndex extends _KnowledgeGuard
    implements PlcCodeIndex, PlcCodeIndexExtras {
  /// See [GuardedTechDocIndex] for why [session] is a callback.
  GuardedPlcCodeIndex({
    required DriftPlcCodeIndex inner,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
    super.logger,
  }) : _inner = inner;

  final DriftPlcCodeIndex _inner;

  /// The `itemKey` of an indexed asset. A distinct prefix from the document and
  /// drawing keys, so filtering for one does not drag in the others.
  static String _itemKey(String assetKey) => 'plc_asset.$assetKey';

  // --- writes --------------------------------------------------------------

  @override
  Future<void> indexAsset(
    String assetKey,
    List<ParsedCodeBlock> blocks, {
    String? vendorType,
    String? serverAlias,
  }) =>
      _guard(
        itemKey: _itemKey(assetKey),
        reason: 'indexAsset',
        write: () => _inner.indexAsset(assetKey, blocks,
            vendorType: vendorType, serverAlias: serverAlias),
      );

  @override
  Future<void> deleteAssetIndex(String assetKey) => _guard(
        itemKey: _itemKey(assetKey),
        reason: 'deleteAssetIndex',
        write: () => _inner.deleteAssetIndex(assetKey),
      );

  @override
  Future<void> renameAsset(String oldAssetKey, String newAssetKey) => _guard(
        itemKey: _itemKey(oldAssetKey),
        reason: 'renameAsset',
        newValue: newAssetKey,
        write: () => _inner.renameAsset(oldAssetKey, newAssetKey),
      );

  /// Gated like the rest. It reads like a refresh, but it deletes the asset's
  /// whole index and re-inserts it from the stored source — a write on every
  /// row of every block, and one that destroys the old index on the way.
  @override
  Future<int> reindexAsset(String assetKey) => _guard(
        itemKey: _itemKey(assetKey),
        reason: 'reindexAsset',
        write: () => _inner.reindexAsset(assetKey),
      );

  // --- reads: ungated and unaudited, per spec §11 --------------------------

  @override
  Future<List<PlcCodeSearchResult>> search(
    String query, {
    String mode = 'text',
    String? assetFilter,
    String? serverAlias,
    int limit = 20,
  }) =>
      _inner.search(query,
          mode: mode,
          assetFilter: assetFilter,
          serverAlias: serverAlias,
          limit: limit);

  @override
  Future<PlcCodeBlock?> getBlock(int blockId) => _inner.getBlock(blockId);

  @override
  Future<List<PlcAssetSummary>> getIndexSummary() => _inner.getIndexSummary();

  /// A plain `bool`, not a `Future<bool>` — unlike [TechDocIndex.isEmpty] and
  /// [DrawingIndex.isEmpty]. `DriftPlcCodeIndex` caches it synchronously.
  @override
  bool get isEmpty => _inner.isEmpty;

  @override
  Future<List<PlcCodeBlock>> getBlocksForAsset(String assetKey) =>
      _inner.getBlocksForAsset(assetKey);

  // --- the four call-graph reads the PLC detail panel needs ----------------

  @override
  Future<List<PlcVarRefTableData>> getVarRefsForBlock(int blockId) =>
      _inner.getVarRefsForBlock(blockId);

  @override
  Future<List<PlcFbInstanceTableData>> getFbInstances({
    String? fbTypeName,
    String? instanceName,
  }) =>
      _inner.getFbInstances(
          fbTypeName: fbTypeName, instanceName: instanceName);

  @override
  Future<List<PlcBlockCallTableData>> getBlockCalls(int blockId) =>
      _inner.getBlockCalls(blockId);

  @override
  Future<List<PlcVarRefTableData>> getVarRefs(String variablePath) =>
      _inner.getVarRefs(variablePath);
}

// ---------------------------------------------------------------------------
// Drawings
// ---------------------------------------------------------------------------

/// [DrawingIndex] with its two writes gated on [kKnowledgeWriteGroup] and
/// recorded, and its three reads forwarded untouched.
///
/// `DrawingUploadDialog` has no caller in the tree today, so these two writes
/// are reachable in principle and unwired in fact. They are guarded anyway: the
/// day somebody mounts that dialog, the guard is already in front of it.
class GuardedDrawingIndex extends _KnowledgeGuard implements DrawingIndex {
  /// See [GuardedTechDocIndex] for why [session] is a callback.
  GuardedDrawingIndex({
    required DrawingIndex inner,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
    super.logger,
  }) : _inner = inner;

  final DrawingIndex _inner;

  /// The `itemKey` of a drawing. Drawings are keyed by name, not by id — that
  /// is [DrawingIndex.deleteDrawing]'s parameter.
  static String _itemKey(String drawingName) => 'drawing.$drawingName';

  // --- writes --------------------------------------------------------------

  @override
  Future<void> storeDrawing({
    required String assetKey,
    required String drawingName,
    required String filePath,
    required List<DrawingPageText> pageTexts,
  }) =>
      _guard(
        itemKey: _itemKey(drawingName),
        reason: 'storeDrawing',
        newValue: assetKey,
        write: () => _inner.storeDrawing(
          assetKey: assetKey,
          drawingName: drawingName,
          filePath: filePath,
          pageTexts: pageTexts,
        ),
      );

  @override
  Future<void> deleteDrawing(String drawingName) => _guard(
        itemKey: _itemKey(drawingName),
        reason: 'deleteDrawing',
        write: () => _inner.deleteDrawing(drawingName),
      );

  // --- reads: ungated and unaudited, per spec §11 --------------------------

  @override
  Future<List<DrawingSearchResult>> search(String query,
          {String? assetFilter}) =>
      _inner.search(query, assetFilter: assetFilter);

  @override
  Future<bool> get isEmpty => _inner.isEmpty;

  @override
  Future<List<DrawingSummary>> getDrawingSummary() =>
      _inner.getDrawingSummary();
}

// ---------------------------------------------------------------------------
// The page-layout cleanup a document delete runs
// ---------------------------------------------------------------------------

/// [PrefsReader] with `setString` gated on [kKnowledgeWriteGroup] and recorded.
///
/// `TechDocUploadService.deleteAndCleanAssets` reads `page_editor_data`, strips
/// `techDocId` from every asset that referenced the document being deleted, and
/// writes it back. That is a page-editor key written from the document library,
/// and before this it was written by whoever was standing at the panel.
///
/// **The guard sits at the reader, not at the store.** The reader
/// `tech_doc_library_section.dart` hands in is backed by
/// `createDeviceLocalPreferences()`, so the key it rewrites is the
/// **device-local** `page_editor_data` — not the shared config row
/// `pageManagerProvider` reads, which is the layout the plant actually sees.
/// Two keys of one name in two stores, one of which nothing reads. That is a
/// pre-existing oddity recorded in `.planning/phases/03-the-guards/
/// 03-13-SUMMARY.md` and **deliberately not fixed here**: changing which store
/// the cleanup writes would propagate a tech-doc delete into the plant-wide
/// layout on every station, which is a wider blast radius than a guard change
/// should take on unasked. Wrapping the reader leaves that question exactly
/// where it was.
class GuardedPrefsReader extends _KnowledgeGuard implements PrefsReader {
  /// See [GuardedTechDocIndex] for why [session] is a callback.
  GuardedPrefsReader({
    required PrefsReader inner,
    required super.session,
    required super.audit,
    required super.station,
    super.onDenied,
    super.logger,
  }) : _inner = inner;

  final PrefsReader _inner;

  /// Reading the layout is not gated: the cleanup has to look before it can
  /// know whether there is anything to write.
  @override
  Future<String?> getString(String key) => _inner.getString(key);

  /// The `itemKey` is the preference key itself — `page_editor_data` — because
  /// this row belongs beside the page editor's own rows in the trail, not under
  /// a `tech_doc.` prefix. The `reason` is what says a document delete is what
  /// caused it.
  @override
  Future<void> setString(String key, String value) => _guard(
        itemKey: key,
        reason: 'deleteAndCleanAssets',
        write: () => _inner.setString(key, value),
      );
}
