/// The rows the configuration history goldens and widget tests are pictures of.
///
/// ## Inert on purpose
///
/// No `setUp`, no `setUpAll`, no top-level mutable state, and no
/// `DateTime.now()` anywhere — `audit_trail_fixture.dart` is the shape this
/// copies, for the same reason: a fixture file is *imported* by a golden file,
/// so anything it runs at import time runs before the golden's own `setUpAll`
/// and would be a baseline nobody could reproduce from reading the test. Every
/// instant is a `DateTime.utc` literal, so `formatTimestamp` renders the same
/// string in Reykjavík and in Auckland.
///
/// ## The entity strings are the real encoding
///
/// A change row holds `ConfigItem.encodeEntity()` on each side — the payload
/// **plus its position**, which is `{parent_id, sort_index, payload}` and
/// nothing else. [configGoldenEntity] builds exactly that shape, so the field
/// paths these fixtures produce (`payload.coordinates.x`, `parent_id`,
/// `sort_index`) are the paths a real row produces rather than paths invented
/// to make a picture.
///
/// ## What each set is for
///
/// | Set | What it proves |
/// |---|---|
/// | [configGoldenPopulatedChanges] | one save read as one action — three assets under one line — beside a **parentless** action, flagged and open |
/// | [configGoldenFieldDiffChanges] | the three shapes of an update in one frame: a payload value, a `parent_id` move, a `sort_index` reorder |
/// | [configGoldenInsertDeleteChanges] | an insert renders one `noBaseline` row and a delete renders an old side only — asymmetric on purpose |
///
/// Everything below is invented. No username, station, page or asset id here
/// came off a plant.
library;

import 'dart:convert';

import 'package:tfc/core/config_change_store.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// The instant the newest row in every fixture happened.
final DateTime kConfigGoldenBase = DateTime.utc(2026, 9, 3, 11, 42, 17);

/// The action every populated fixture's ordinary save shares, in the 32-hex
/// shape `newActionId()` produces.
const String kConfigGoldenActionId = 'a71c3fd0925e4b18ac6d3f0b5e2719d4';

/// The action whose `audit_entry` header never landed.
///
/// The orphan window: the store commits its `config_change` rows and writes the
/// header afterwards, so a crash between the two leaves change rows on an
/// `action_id` with no header. Nothing in the fixture's audit rows carries this
/// id, which is how the picture gets a parentless action without a special case
/// anywhere in the page.
const String kConfigGoldenOrphanActionId =
    'f0b93a4c6d1e47528b0c9df2a3617e85';

/// The action the insert/delete fixture uses.
const String kConfigGoldenInsertDeleteActionId =
    '3e5d81b0c9a2476fa14e7b6d208c5f39';

/// One entity, encoded the way a change row holds it.
///
/// `{parent_id, sort_index, payload}` — `ConfigItem.toEntityJson()`'s shape,
/// spelled here rather than built through a `ConfigItem` so a fixture can hold
/// a payload without also supplying the four storage-managed fields a
/// `ConfigItem` requires and the diff never sees.
String configGoldenEntity({
  String? parentId,
  int? sortIndex,
  Map<String, Object?> payload = const {},
}) =>
    jsonEncode(<String, Object?>{
      'parent_id': parentId,
      'sort_index': sortIndex,
      'payload': payload,
    });

/// One `config_change` row, with every column defaulted to the ordinary case so
/// a fixture names only the columns it is about.
ConfigChangeRecord configGoldenChange({
  required int id,
  Duration? ago,
  String who = 'jon',
  String station = 'ST101',
  String roleName = 'engineer',
  ConfigKind kind = ConfigKind.asset,
  String entityId = '/roe/CN04',
  ConfigScope? scope,
  ConfigChangeOp op = ConfigChangeOp.update,
  String? oldValue,
  String? newValue,
  String actionId = kConfigGoldenActionId,
  String? reason,
}) =>
    ConfigChangeRecord(
      id: id,
      change: ConfigChange(
        at: kConfigGoldenBase.subtract(ago ?? Duration(seconds: id)),
        actionId: actionId,
        who: who,
        station: station,
        roleName: roleName,
        kind: kind,
        entityId: entityId,
        scope: scope ?? ConfigScope.shared,
        op: op,
        oldValue: oldValue,
        newValue: newValue,
        reason: reason,
      ),
    );

/// One `audit_entry` header, in the shape `groupHistoryRows` merges beside the
/// change rows.
AuditEntryData configGoldenHeader({
  required int id,
  Duration? ago,
  String who = 'jon',
  String station = 'ST101',
  String roleName = 'engineer',
  String itemKey = 'page.save',
  String? oldValue,
  String? newValue = '/roe',
  String groupRequired = 'configure',
  String actionId = kConfigGoldenActionId,
}) =>
    AuditEntryData(
      id: id,
      at: kConfigGoldenBase.subtract(ago ?? Duration(seconds: id)),
      who: who,
      station: station,
      roleName: roleName,
      surface: 'config',
      itemKey: itemKey,
      member: null,
      oldValue: oldValue,
      newValue: newValue,
      groupRequired: groupRequired,
      allowed: true,
      origin: 'operator',
      actionId: actionId,
      reason: null,
    );

// ---------------------------------------------------------------------------
// The populated set: one ordinary save, and one orphan
// ---------------------------------------------------------------------------

/// Three assets moved by one save, plus two rows of an action whose header
/// never landed.
///
/// Newest first, which is the order `ConfigChangeStore.changes` returns and the
/// order `groupHistoryRows` merges on.
List<ConfigChangeRecord> configGoldenPopulatedChanges() => <ConfigChangeRecord>[
      configGoldenChange(
        id: 1,
        entityId: '/roe/CN04',
        oldValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 3,
          payload: {'coordinates': {'x': 0.31, 'y': 0.62}, 'label': 'CN04'},
        ),
        newValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 3,
          payload: {'coordinates': {'x': 0.42, 'y': 0.62}, 'label': 'CN04'},
        ),
      ),
      configGoldenChange(
        id: 2,
        entityId: '/roe/CN05',
        oldValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 4,
          payload: {'coordinates': {'x': 0.55, 'y': 0.62}, 'label': 'CN05'},
        ),
        newValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 4,
          payload: {'coordinates': {'x': 0.55, 'y': 0.71}, 'label': 'CN05'},
        ),
      ),
      configGoldenChange(
        id: 3,
        entityId: '/roe/CN06',
        oldValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 5,
          payload: {'coordinates': {'x': 0.68, 'y': 0.62}, 'label': 'CN06'},
        ),
        newValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 5,
          payload: {'coordinates': {'x': 0.68, 'y': 0.62}, 'label': 'CN06 out'},
        ),
      ),
      // The orphan: two rows, an `action_id` no header carries, and a different
      // author — a parentless action is still fully attributable, because both
      // tables carry `who` and `at`.
      configGoldenChange(
        id: 4,
        ago: const Duration(minutes: 6),
        who: 'kari',
        actionId: kConfigGoldenOrphanActionId,
        kind: ConfigKind.keyMapping,
        entityId: 'ST101.CN04.p_par_SpeedRef',
        oldValue: configGoldenEntity(payload: {'node': 'ns=4;s=SpeedRef'}),
        newValue: configGoldenEntity(payload: {'node': 'ns=4;s=SpeedRef2'}),
      ),
      configGoldenChange(
        id: 5,
        ago: const Duration(minutes: 6, seconds: 1),
        who: 'kari',
        actionId: kConfigGoldenOrphanActionId,
        kind: ConfigKind.keyMapping,
        entityId: 'ST101.CN05.p_par_SpeedRef',
        oldValue: configGoldenEntity(payload: {'node': 'ns=4;s=SpeedRef'}),
        newValue: configGoldenEntity(payload: {'node': 'ns=4;s=SpeedRef3'}),
      ),
    ];

/// The one header the populated set has. Nothing carries
/// [kConfigGoldenOrphanActionId], which is the whole point.
List<AuditEntryData> configGoldenPopulatedHeaders() => <AuditEntryData>[
      configGoldenHeader(id: 1),
    ];

// ---------------------------------------------------------------------------
// The field-diff set
// ---------------------------------------------------------------------------

/// One asset that moved page, moved in the paint order and moved on the canvas,
/// beside one that only moved on the canvas.
///
/// The first row is what makes `parent_id` and `sort_index` top-level field
/// rows beside `payload.*` visible in one frame: they are part of the entity
/// encoding precisely because moving an asset to another page changes nothing
/// else, and a history that recorded payloads alone would show two identical
/// sides.
List<ConfigChangeRecord> configGoldenFieldDiffChanges() =>
    <ConfigChangeRecord>[
      configGoldenChange(
        id: 1,
        entityId: '/baader/CN21',
        oldValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 3,
          payload: {'coordinates': {'x': 0.31, 'y': 0.62}, 'label': 'CN21'},
        ),
        newValue: configGoldenEntity(
          parentId: '/baader',
          sortIndex: 7,
          payload: {'coordinates': {'x': 0.42, 'y': 0.62}, 'label': 'CN21'},
        ),
      ),
      configGoldenChange(
        id: 2,
        entityId: '/baader/CN22',
        oldValue: configGoldenEntity(
          parentId: '/baader',
          sortIndex: 8,
          payload: {'coordinates': {'x': 0.55, 'y': 0.20}, 'label': 'CN22'},
        ),
        newValue: configGoldenEntity(
          parentId: '/baader',
          sortIndex: 8,
          payload: {'coordinates': {'x': 0.55, 'y': 0.34}, 'label': 'CN22'},
        ),
      ),
    ];

/// The header for the field-diff action.
List<AuditEntryData> configGoldenFieldDiffHeaders() => <AuditEntryData>[
      configGoldenHeader(id: 1, newValue: '/baader'),
    ];

// ---------------------------------------------------------------------------
// The insert/delete set
// ---------------------------------------------------------------------------

/// An entity that did not exist before, and one that is gone.
///
/// `ConfigChange.insert` carries no `oldValue` and `ConfigChange.delete` no
/// `newValue`, which is what makes `diffConfigEntities` answer one whole-entity
/// row in each case rather than a field list.
List<ConfigChangeRecord> configGoldenInsertDeleteChanges() =>
    <ConfigChangeRecord>[
      configGoldenChange(
        id: 1,
        actionId: kConfigGoldenInsertDeleteActionId,
        op: ConfigChangeOp.insert,
        entityId: '/roe/CN07',
        newValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 6,
          payload: {'coordinates': {'x': 0.80, 'y': 0.62}, 'label': 'CN07'},
        ),
      ),
      configGoldenChange(
        id: 2,
        actionId: kConfigGoldenInsertDeleteActionId,
        op: ConfigChangeOp.delete,
        entityId: '/roe/CN03',
        oldValue: configGoldenEntity(
          parentId: '/roe',
          sortIndex: 2,
          payload: {'coordinates': {'x': 0.18, 'y': 0.62}, 'label': 'CN03'},
        ),
      ),
    ];

/// The header for the insert/delete action.
List<AuditEntryData> configGoldenInsertDeleteHeaders() => <AuditEntryData>[
      configGoldenHeader(
        id: 1,
        itemKey: 'page.save',
        actionId: kConfigGoldenInsertDeleteActionId,
      ),
    ];
