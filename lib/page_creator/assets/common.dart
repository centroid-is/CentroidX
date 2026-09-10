import 'dart:ui' show Size;
import 'dart:math' as math;

import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/material.dart';
import 'package:tfc/widgets/hit_boundary.dart' show AssetHitShape;
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show SidePaneSubject;
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:tfc_dart/core/fuzzy_match.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
// RetentionPolicy only, from its own pure file. `core/database.dart` re-exports
// it but also carries the drift-backed runtime, and every HMI asset imports
// this file — so that one convenience import put `dart:ffi` in the closure of
// the entire page editor.
import 'package:tfc_dart/core/retention_policy.dart';
import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import '../../providers/state_man.dart';
import '../../providers/preferences.dart';
import '../../widgets/boolean_expression.dart';
import '../../widgets/bit_mask_grid.dart';
import '../../widgets/key_mapping_sections.dart';
import 'bulk_property.dart';

// The `Asset.bulkProperties` contract is declared here, so every asset file
// that implements it gets the descriptor types along with `Asset` itself.
export 'bulk_property.dart';

part 'common.g.dart';

const String constAssetName = "asset_name";

@JsonEnum()
enum TextPos {
  above,
  below,
  left,
  right,
  inside,
}

@JsonSerializable()
class Coordinates {
  double x; // 0.0 to 1.0
  double y; // 0.0 to 1.0
  double? angle;

  Coordinates({
    required this.x,
    required this.y,
    this.angle,
  });

  factory Coordinates.fromJson(Map<String, dynamic> json) =>
      _$CoordinatesFromJson(json);
  Map<String, dynamic> toJson() => _$CoordinatesToJson(this);
}

@JsonSerializable()
class RelativeSize {
  final double width; // 0.0 to 1.0
  final double height; // 0.0 to 1.0

  const RelativeSize({
    required this.width,
    required this.height,
  });

  factory RelativeSize.fromJson(Map<String, dynamic> json) =>
      _$RelativeSizeFromJson(json);
  Map<String, dynamic> toJson() => _$RelativeSizeToJson(this);

  Size toSize(Size containerSize) {
    return Size(
      containerSize.width * width,
      containerSize.height * height,
    );
  }

  static RelativeSize fromSize(Size size, Size containerSize) {
    return RelativeSize(
      width: size.width / containerSize.width,
      height: size.height / containerSize.height,
    );
  }
}

/// Mints the handles assets are referred to by — see [Asset.id].
///
/// Not a UUID, and no new dependency for one: 96 bits from a secure generator
/// is orders of magnitude past anything a page full of assets could collide
/// on, and a short hex string keeps the page JSON readable when somebody has
/// to diff two versions of it by eye.
String newAssetId() {
  final r = _idRandom;
  final b = StringBuffer();
  for (var i = 0; i < 24; i++) {
    b.write('0123456789abcdef'[r.nextInt(16)]);
  }
  return b.toString();
}

/// Gives every asset in [copies] that carried an id a fresh one, and rewrites
/// the references between them to match.
///
/// This is what a paste (or any other duplication) owes the page. Two assets
/// sharing an id makes every reference to it ambiguous, so a copy cannot keep
/// the original's. References *inside* the group follow the copies: duplicate
/// a coupler, a box and the cable between them and you get a second cable
/// running between the second pair, not one that reaches back to the
/// originals. References *out* of the group are deliberately left alone — a
/// cable copied on its own still runs where it ran.
void reidentifyAssets(List<Asset> copies) {
  final idMap = <String, String>{};
  for (final asset in copies) {
    final old = asset.id;
    if (old != null) idMap[old] = asset.assignNewId();
  }
  if (idMap.isEmpty) return;
  for (final asset in copies) {
    asset.remapAssetIds(idMap);
  }
}

math.Random? _idRandomCache;

/// Built on first use rather than at import: `Random.secure` reaches for a
/// platform entropy source, and a top-level initialiser doing that would run
/// on every import of this library including in environments that have none.
math.Random get _idRandom => _idRandomCache ??= _makeIdRandom();

math.Random _makeIdRandom() {
  try {
    return math.Random.secure();
  } catch (_) {
    // No secure source here. Ids only have to be unique within a page, and
    // the fallback still is — this is not a security boundary.
    return math.Random();
  }
}

abstract class Asset {
  String get assetName;
  String get displayName;

  /// A stable handle other assets can refer to this one by, or null.
  ///
  /// Assets are otherwise identified by object identity, which does not
  /// survive a save: a page serialises as a bare list and nothing in it names
  /// anything else. That was fine while no asset referred to another. A cable
  /// does — both its ends and any pinned corner name the asset they belong to
  /// — so it needs a handle that outlives a reload.
  ///
  /// Null by default and stays null: an asset earns an id the first time
  /// something points at it ([ensureId]), so a page nothing links across is
  /// saved exactly as it was before ids existed.
  String? get id;
  set id(String? id);

  /// This asset's [id], minting one if it has none yet.
  String ensureId();

  /// Replaces this asset's [id] with a fresh one, and returns it.
  ///
  /// Paste and duplicate call this: two assets carrying one id makes every
  /// reference to it ambiguous, and the copy is a different piece of
  /// equipment even when it is identical in every other respect.
  String assignNewId();

  /// The page-relative box this asset occupies, when that is not the one
  /// [coordinates] and [size] already describe.
  ///
  /// Null for every asset whose position is simply where it was dropped, which
  /// is all of them but one. A run is the exception: its box is wherever the
  /// assets it plugs into happen to be, so it can only be known once the page
  /// is known.
  ///
  /// Handed back rather than written into [coordinates] on purpose.
  /// `AssetStack` builds from a config that lives for the whole mount and
  /// must not edit it in place — deriving the box into a local is how a run
  /// gets positioned without breaking that.
  Rect? boxOn(List<Asset> page, Size canvas);

  /// Whether a pointer at [local] — in this asset's own unrotated box, of
  /// [boxSize] pixels — is on the asset rather than merely inside its
  /// rectangle.
  ///
  /// True for the whole box by default, which is right for everything drawn
  /// to fill its rectangle. A run is the exception and the reason this
  /// exists: its box is the span between two devices and is almost entirely
  /// empty, so an opaque rectangle over it would swallow taps meant for every
  /// device it passes and stop a marquee from being started anywhere near it.
  bool hitTestBox(Offset local, Size boxSize, List<Asset> page, Size canvas);

  /// Rewrites references this asset holds to *other* assets' ids.
  ///
  /// Called after a paste with a map from each copied asset's old id to its
  /// new one. An id missing from the map is deliberately left alone: it names
  /// something outside the pasted group, and a cable copied on its own should
  /// still run between the two devices it ran between before.
  void remapAssetIds(Map<String, String> idMap);

  String get category;
  String? get text;
  set text(String? text);
  TextPos? get textPos;
  set textPos(TextPos? textPos);
  Coordinates get coordinates;
  set coordinates(Coordinates coordinates);
  RelativeSize get size;
  set size(RelativeSize size);

  /// Optional override for the painted label color.
  ///
  /// When non-null, `AssetStack` paints the asset's label using this
  /// color via `DefaultTextStyle.style.copyWith(color: ...)`. When null,
  /// the label inherits the surrounding `DefaultTextStyle` color
  /// (the historic, pre-field behaviour).
  ///
  /// Concrete `Asset` implementations are expected to extend
  /// `BaseAsset`, which provides a `null` default so per-asset opt-in
  /// is additive: only assets that want a configurable label color need
  /// to override this getter (currently only `ButtonConfig.textColor`).
  Color? get labelColor;

  /// Whether `AssetStack` paints [text] beside the asset on the page.
  ///
  /// A name is not always only a caption: an asset that opens a side pane
  /// titles the pane with the same string, so "has no name" and "does not
  /// show its name on the mimic" are two different things and cannot share
  /// one empty field. `BaseAsset` answers `true`, which keeps this additive —
  /// only an asset that offers the choice (`SectionButtonConfig.showName`)
  /// overrides it.
  bool get showLabel;

  /// Extra terms the palette's search box matches besides [displayName].
  ///
  /// An asset that stands for several concrete things (the 3rd-party
  /// equipment asset covers the Multivac, the SpeedBatcher, …) lists them
  /// here so an operator searching for the machine they can see on the
  /// floor still finds the tile.
  List<String> get searchKeywords;

  /// Whether the page-wide mirror (`AssetStackConfig`) flips this asset's
  /// glyph even when it is unrotated.
  ///
  /// `AssetStack` normally skips the mirror transform for a null angle so
  /// text-bearing faces (buttons, analog boxes) stay readable on mirrored
  /// stations — position mirrors, the glyph does not. That is wrong for a
  /// chiral glyph: a conveyor's turn must bend the other way or the mirrored
  /// page shows a belt that does not exist on the floor. Such assets return
  /// true here and counter-mirror any text they paint themselves (see
  /// [AssetMirrorScope]).
  bool get mirrorsWithPage;

  /// Assets drawn inside this asset's own box — a rack head's slices.
  ///
  /// `AssetStack` registers each of these under its parent's frame, so a
  /// side pane opened from one slice of a composite asset can be marked on
  /// that slice alone (see [SubdeviceSubject]) instead of on the whole
  /// block. An asset that is one piece of equipment returns the empty list.
  List<Asset> get childAssets;

  /// The settings the page editor may change on several assets at once.
  ///
  /// [configure] is a hand-written form per asset type and can only edit one
  /// asset, so selecting four drives and widening them all needs a second,
  /// narrower description of what an asset holds. `BaseAsset` supplies the
  /// settings every asset has — position, size, angle, label — and an asset
  /// adds its own by appending to `super.bulkProperties`. Anything left out
  /// simply does not appear in the multi-select editor; the per-asset form
  /// remains the complete one.
  ///
  /// See `bulk_property.dart` for the descriptor types and how a selection is
  /// reduced to the settings its assets have in common.
  List<BulkProperty> get bulkProperties;

  Widget build(BuildContext context);
  Widget configure(BuildContext context);
  Map<String, dynamic> toJson();
}

@JsonSerializable(createFactory: false, explicitToJson: true)
abstract class BaseAsset implements Asset {
  @override
  String get assetName => variant;
  @JsonKey(name: constAssetName)
  String variant =
      'unknown'; // fromJson will set this during deserialization, otherwise it will be set to the runtime type

  BaseAsset() {
    if (variant == 'unknown') {
      variant = runtimeType.toString();
    }
  }

  @override
  String get displayName => _humanize(runtimeType.toString());

  @override
  String get category => 'General';

  // Excluded like `allKeys`: getters serialize by default and this is
  // palette metadata, not page state.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get searchKeywords => const [];

  // Excluded for the same reason: behaviour, not page state.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool get mirrorsWithPage => false;

  // Excluded like `searchKeywords`: composition metadata, not page state —
  // a composite asset serializes its subdevice list as its own field.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<Asset> get childAssets => const [];

  static String _humanize(String typeName) {
    String name = typeName;
    if (name.endsWith('Config')) {
      name = name.substring(0, name.length - 6);
    }
    final buffer = StringBuffer();
    for (int i = 0; i < name.length; i++) {
      final ch = name[i];
      if (i > 0 && ch.toUpperCase() == ch && ch.toLowerCase() != ch) {
        final prev = name[i - 1];
        final nextIsLower = i + 1 < name.length &&
            name[i + 1].toLowerCase() == name[i + 1] &&
            name[i + 1].toUpperCase() != name[i + 1];
        if (prev.toLowerCase() == prev && prev.toUpperCase() != prev) {
          buffer.write(' ');
        } else if (nextIsLower && prev.toUpperCase() == prev) {
          buffer.write(' ');
        }
      }
      buffer.write(ch);
    }
    return buffer.toString();
  }

  /// See [Asset.id].
  ///
  /// Public, and a field rather than a getter over a private one: every
  /// concrete asset's `toJson`/`fromJson` is generated from the members
  /// json_serializable can see on this class, and it cannot see a private
  /// field. `includeIfNull: false` is what keeps the change additive — an
  /// asset nothing points at serialises without the key at all, so a page
  /// saved before ids existed round-trips byte for byte.
  @JsonKey(name: 'id', includeIfNull: false)
  @override
  String? id;

  @override
  String ensureId() => id ??= newAssetId();

  @override
  String assignNewId() => id = newAssetId();

  /// Most assets refer to nothing, so the default is to have nothing to
  /// rewrite. Assets that hold ids (the cable's ends and pinned corners)
  /// override this.
  @override
  void remapAssetIds(Map<String, String> idMap) {}

  /// An asset sits where it was dropped; see [Asset.boxOn] for the exception.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  Rect? boxOn(List<Asset> page, Size canvas) => null;

  /// An asset fills its box; see [Asset.hitTestBox] for the exception.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool hitTestBox(Offset local, Size boxSize, List<Asset> page, Size canvas) =>
      true;

  @JsonKey(name: 'coordinates')
  Coordinates _coordinates = Coordinates(x: 0.0, y: 0.0);

  @override
  Coordinates get coordinates => _coordinates;

  @override
  set coordinates(Coordinates coordinates) {
    _coordinates = coordinates;
  }

  @JsonKey(name: 'size')
  RelativeSize _size = const RelativeSize(width: 0.03, height: 0.03);

  @override
  RelativeSize get size => _size;

  @override
  set size(RelativeSize size) {
    _size = size;
  }

  @JsonKey(name: 'text')
  String? _text;

  @override
  String? get text => _text;

  @override
  set text(String? text) {
    _text = text;
  }

  @JsonKey(name: 'text_pos')
  TextPos? _textPos;

  @override
  TextPos? get textPos => _textPos;

  @override
  set textPos(TextPos? textPos) {
    _textPos = textPos;
  }

  /// Position, size, angle and label — the settings every asset has, and so
  /// the ones a mixed selection is left with. An asset adds its own on top:
  ///
  /// ```dart
  /// @JsonKey(includeFromJson: false, includeToJson: false)
  /// @override
  /// List<BulkProperty> get bulkProperties => [
  ///       ...super.bulkProperties,
  ///       NumberBulkProperty(id: 'FooConfig.bar', ...),
  ///     ];
  /// ```
  ///
  /// Coordinates and sizes are canvas fractions on the wire but percentages
  /// in the pane: `0.08` is not a width anyone reads off a drawing, and every
  /// asset on a page is measured against the same canvas, so the conversion
  /// is a fixed ×100 rather than a per-asset one.
  ///
  /// The setters rebuild [Coordinates] rather than mutating it because the
  /// editor's undo history compares serialized snapshots, and an angle that
  /// travels on the same object as x/y has to survive an x-only edit.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        NumberBulkProperty(
          id: 'x',
          label: 'X',
          group: bulkGeometryGroup,
          unit: '%',
          min: 0,
          max: 100,
          read: () => coordinates.x * 100,
          apply: (value) => coordinates = Coordinates(
            x: (value ?? 0) / 100,
            y: coordinates.y,
            angle: coordinates.angle,
          ),
        ),
        NumberBulkProperty(
          id: 'y',
          label: 'Y',
          group: bulkGeometryGroup,
          unit: '%',
          min: 0,
          max: 100,
          read: () => coordinates.y * 100,
          apply: (value) => coordinates = Coordinates(
            x: coordinates.x,
            y: (value ?? 0) / 100,
            angle: coordinates.angle,
          ),
        ),
        NumberBulkProperty(
          id: 'width',
          label: 'Width',
          group: bulkGeometryGroup,
          unit: '%',
          // The same floor the editor's grow/shrink buttons clamp to: an
          // asset scaled to nothing cannot be found again to fix it.
          min: 1,
          max: 100,
          read: () => size.width * 100,
          apply: (value) => size = RelativeSize(
            width: (value ?? 0) / 100,
            height: size.height,
          ),
        ),
        NumberBulkProperty(
          id: 'height',
          label: 'Height',
          group: bulkGeometryGroup,
          unit: '%',
          min: 1,
          max: 100,
          read: () => size.height * 100,
          apply: (value) => size = RelativeSize(
            width: size.width,
            height: (value ?? 0) / 100,
          ),
        ),
        NumberBulkProperty(
          id: 'angle',
          label: 'Angle',
          group: bulkGeometryGroup,
          unit: '°',
          decimals: 0,
          // Null is "unrotated" for an asset that has never been turned, and
          // clearing the field is how a selection gets back to it — the
          // mirror logic in `AssetStack` treats a null angle differently
          // from a zero one, so the two are not interchangeable.
          nullable: true,
          read: () => coordinates.angle,
          apply: (value) => coordinates = Coordinates(
            x: coordinates.x,
            y: coordinates.y,
            angle: value?.toDouble(),
          ),
        ),
        TextBulkProperty(
          id: 'label.text',
          label: 'Text',
          group: bulkLabelGroup,
          read: () => text,
          apply: (value) => text = value,
        ),
        ChoiceBulkProperty<TextPos>(
          id: 'label.position',
          label: 'Position',
          group: bulkLabelGroup,
          options: TextPos.values,
          optionLabel: (value) => bulkEnumLabel(value.name),
          // A null position renders in the asset's default spot. The dropdown
          // has no entry for it, so an asset that has never had one set shows
          // as `below` until the row is touched — reading the default rather
          // than inventing a sixth option nobody would recognise.
          read: () => textPos ?? TextPos.below,
          apply: (value) => textPos = value,
        ),
      ];

  /// Section headings for the settings on this class. Assets reuse these for
  /// their own geometry- or label-shaped fields so that a row lands under the
  /// heading an operator would look for it under, not under the asset name.
  static const String bulkGeometryGroup = 'Geometry';
  static const String bulkLabelGroup = 'Label';

  /// An enum constant's name as a dropdown entry: `disableWhenTrue` reads
  /// "Disable when true". [_humanize] is the wrong tool — it is built for
  /// `FooBarConfig` type names and leaves a leading lowercase word alone.
  static String bulkEnumLabel(String name) {
    final spaced = _humanize(name).toLowerCase();
    if (spaced.isEmpty) return spaced;
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  /// The ID of the linked technical document, or null if none linked.
  ///
  /// Many assets can reference the same document (many-to-one).
  /// Stored in asset JSON and used by the LLM to find relevant
  /// manufacturer documentation when diagnosing equipment.
  @JsonKey(name: 'techDocId')
  int? techDocId;

  /// The asset key of the linked PLC code index entry, or null if none linked.
  ///
  /// Many assets can reference the same PLC asset (many-to-one).
  /// Stored in asset JSON and used by the LLM to find relevant
  /// PLC code blocks and variables when diagnosing equipment.
  @JsonKey(name: 'plcAssetKey')
  String? plcAssetKey;

  /// Default label-color override is `null` — meaning the label inherits
  /// the ambient `DefaultTextStyle` color in `AssetStack`. Subclasses
  /// such as `ButtonConfig` override this getter to expose a
  /// configurable color (`ButtonConfig.textColor`). Keeping the default
  /// here means existing assets do not need any modification when this
  /// feature lands.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  Color? get labelColor => null;

  /// Labels are painted by default; see [Asset.showLabel]. Overriding this is
  /// how an asset hides its name on the page while keeping it for whatever
  /// else the name is for.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool get showLabel => true;

  /// Returns all PLC/OPC-UA tag keys referenced by this asset.
  ///
  /// The default implementation introspects the `toJson()` map and extracts
  /// string values whose JSON field name matches common key-field patterns:
  ///   - `key` (exact)
  ///   - `key1`, `key2`, etc. (numbered)
  ///   - `*Key` (camelCase suffix, e.g. `batchesKey`, `frequencyKey`)
  ///   - `*_key` (snake_case suffix, e.g. `analog_key`, `error_key`)
  ///
  /// Excludes `plcAssetKey` (a reference ID, not a tag key) and `asset_name`.
  /// Returns deduplicated, non-empty strings.
  ///
  /// Complex asset types with keys in nested structures (lists, sub-objects)
  /// should override this getter.
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get allKeys => _extractKeysFromJson(toJson());

  /// JSON key-name pattern for tag-key fields.
  ///
  /// Matches:  key | key1 | key2 | fooKey | foo_key
  static final RegExp _keyFieldPattern =
      RegExp(r'^key$|^keys$|^key\d+$|Key$|Keys$|_key$|_keys$');

  /// JSON field names that match [_keyFieldPattern] but are NOT tag keys.
  static const Set<String> _excludedFields = {
    'plcAssetKey',
    'asset_name',
  };

  static List<String> _extractKeysFromJson(Map<String, dynamic> json) {
    final keys = <String>{};
    for (final entry in json.entries) {
      if (_excludedFields.contains(entry.key)) continue;
      if (!_keyFieldPattern.hasMatch(entry.key)) continue;
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        keys.add(value);
      } else if (value is List) {
        // A key field may hold a list -- RecipesConfig.keys carries one node
        // per line. Without this the asset reports using no keys at all, and
        // anything asking which keys a page depends on (unused-key cleanup,
        // for one) would be told they are free to delete.
        for (final entry in value) {
          if (entry is String && entry.isNotEmpty) keys.add(entry);
        }
      }
    }
    return keys.toList();
  }
}

/// Scopes the side-pane subject — and the dashed open-pane mark — to one
/// subdevice of a composite asset.
///
/// A rack head (a Beckhoff CX, an EK1100) draws its slices inside its own
/// box, so a pane opened by tapping one slice used to inherit the whole
/// rack's [SidePaneSubject] and the plant view ringed the entire block.
/// Wrapping each slice in one of these does three things:
///
///  - names the slice as the pane's subject, so `_OpenPaneMark` looks the
///    slice up rather than the rack (the rack registers the slice under its
///    own frame via [Asset.childAssets]);
///  - hangs `ObjectKey(slice)` on the subtree, which is the handle the
///    plant view's shape probe searches the canvas for;
///  - publishes the slice's own rectangle as its [AssetHitShape], so the
///    ring is traced around that slice and nothing else.
///
/// The shape is read lazily off the slice's render box (through a
/// [GlobalObjectKey], resolved only when a pane opens), so the rect is
/// whatever the slice laid out to — in its native scale; the probe maps it
/// through the rack's `FittedBox` into canvas coordinates.
class SubdeviceSubject extends StatelessWidget {
  /// The slice's long-lived config object — compared by identity everywhere
  /// (frames, subject, keys), so it must be the object the page holds, not a
  /// per-build value.
  final Asset subdevice;
  final Widget child;

  const SubdeviceSubject({
    super.key,
    required this.subdevice,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final boxKey = GlobalObjectKey(subdevice);
    return KeyedSubtree(
      key: ObjectKey(subdevice),
      child: AssetHitShape(
        shape: () {
          final box = boxKey.currentContext?.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            return Path()..addRect(Offset.zero & box.size);
          }
          // Nothing laid out to trace — an empty path draws no ring rather
          // than a wrong one.
          return Path();
        },
        child: KeyedSubtree(
          key: boxKey,
          child: SidePaneSubject(subject: subdevice, child: child),
        ),
      ),
    );
  }
}

/// Marks a subtree as living on the page-editor canvas.
///
/// `AssetStack` (in `lib/pages/page_view.dart`) wraps asset builds in this
/// scope when it runs in editor mode (`absorb: true`). Assets whose runtime
/// rendering can be invisible (e.g. an alarm beacon with no active alarm)
/// check [isEditing] to draw a placeholder so they stay findable and
/// selectable in the editor.
///
/// Lives here rather than in `page_view.dart` so assets can depend on it
/// without importing the page machinery (which imports the asset registry —
/// an import cycle).
class AssetEditModeScope extends InheritedWidget {
  const AssetEditModeScope({super.key, required super.child});

  /// Whether [context] is inside the page editor's canvas.
  static bool isEditing(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AssetEditModeScope>() != null;

  @override
  bool updateShouldNotify(AssetEditModeScope oldWidget) => false;
}

/// The page-wide mirror in effect for the assets below (`AssetStackConfig`,
/// minus a page's `mirroringDisabled`).
///
/// `AssetStack` applies the mirror as a `Transform` around each asset's
/// visual, which flips *everything* the asset paints — including text the
/// asset draws on its own canvas. Assets that paint such text (the conveyor's
/// frequency figure) read the flags here and counter-mirror those glyphs the
/// same way they already counter-rotate them against `coordinates.angle`.
///
/// Lives here rather than in `page_view.dart` for the same import-cycle
/// reason as [AssetEditModeScope].
class AssetMirrorScope extends InheritedWidget {
  final bool xMirror;
  final bool yMirror;

  const AssetMirrorScope({
    super.key,
    required this.xMirror,
    required this.yMirror,
    required super.child,
  });

  /// The scope above [context], or null outside an `AssetStack` (previews,
  /// palettes) — treat null as no mirroring.
  static AssetMirrorScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AssetMirrorScope>();

  @override
  bool updateShouldNotify(AssetMirrorScope oldWidget) =>
      xMirror != oldWidget.xMirror || yMirror != oldWidget.yMirror;
}

class KeyField extends ConsumerStatefulWidget {
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final String label;

  /// If the key maps to a fixed-size OPC UA array, pass its size here
  /// so the "add key" dialog can offer a dropdown for the index.
  final int? arraySize;

  const KeyField({
    super.key,
    this.initialValue,
    this.onChanged,
    this.label = 'Key',
    this.arraySize,
  });

  @override
  ConsumerState<KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends ConsumerState<KeyField> {
  late TextEditingController _controller;
  List<String> _allKeys = [];
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      setState(() {});
    }
  }

  void _openSearchDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => KeySearchDialog(
        allKeys: _allKeys,
        initialQuery: _controller.text,
      ),
    );
    if (result != null) {
      _controller.text = result;
      widget.onChanged?.call(result);
      setState(() {});
    }
  }

  void _openKeyMappingDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => KeyMappingEntryDialog(
        initialKey: _controller.text,
        initialKeyMappingEntry: KeyMappingEntry(),
        arraySize: widget.arraySize,
      ),
    );

    if (result != null) {
      final key = result['key'] as String;
      final entry = result['entry'] as KeyMappingEntry;

      final keyMappings = (await ref.read(stateManProvider.future)).keyMappings;
      keyMappings.nodes[key] = entry;
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setString('key_mappings', jsonEncode(keyMappings.toJson()));

      _controller.text = key;
      widget.onChanged?.call(key);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StateMan>(
      future: ref.watch(stateManProvider.future),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _allKeys = snapshot.data!.keys.toList();
        }
        return TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _openSearchDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _openKeyMappingDialog,
                ),
              ],
            ),
          ),
          onChanged: widget.onChanged,
          onSubmitted: widget.onChanged,
        );
      },
    );
  }
}

class KeySearchDialog extends ConsumerStatefulWidget {
  final List<String>?
      allKeys; // can be omitted, then the keys are fetched from the state manager
  final String initialQuery;

  const KeySearchDialog({
    super.key,
    this.allKeys,
    required this.initialQuery,
  });

  @override
  ConsumerState<KeySearchDialog> createState() => _KeySearchDialogState();
}

class _KeySearchDialogState extends ConsumerState<KeySearchDialog> {
  late TextEditingController _searchController;
  List<String> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _performSearch(widget.initialQuery);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _performSearch(String query) async {
    List<String> allKeys = widget.allKeys ??
        await ref
            .read(stateManProvider.future)
            .then((stateMan) => stateMan.keys);
    setState(() {
      _searchResults = fuzzyFilter(allKeys, query, [(key) => key]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Search keys',
      icon: Icons.search,
      child: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _performSearch,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final key = _searchResults[index];
                  return ListTile(
                    dense: true,
                    title: Text(key),
                    onTap: () => Navigator.of(context).pop(key),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyFieldDialog extends StatefulWidget {
  final String? initialValue;

  const _KeyFieldDialog({this.initialValue});

  @override
  State<_KeyFieldDialog> createState() => _KeyFieldDialogState();
}

class _KeyFieldDialogState extends State<_KeyFieldDialog> {
  late TextEditingController _namespaceController;
  late TextEditingController _identifierController;

  @override
  void initState() {
    super.initState();
    int ns = 0;
    String id = '';
    // Try to parse initial value if present
    final regex = RegExp(r'ns=(\d+);s=(.+)');
    if (widget.initialValue != null) {
      final match = regex.firstMatch(widget.initialValue!);
      if (match != null) {
        ns = int.tryParse(match.group(1) ?? '0') ?? 0;
        id = match.group(2) ?? '';
      }
    }
    _namespaceController = TextEditingController(text: ns.toString());
    _identifierController = TextEditingController(text: id);
  }

  @override
  void dispose() {
    _namespaceController.dispose();
    _identifierController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Format OPC UA NodeId',
      icon: Icons.tag,
      actions: [
        PaneAction.primary(
          label: 'OK',
          onPressed: () {
            final ns = int.tryParse(_namespaceController.text) ?? 0;
            final id = _identifierController.text;
            final isInt = int.tryParse(id) != null;
            final nodeId = isInt ? 'ns=$ns;i=$id' : 'ns=$ns;s=$id';
            Navigator.of(context).pop(nodeId);
          },
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _namespaceController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Namespace'),
          ),
          TextField(
            controller: _identifierController,
            decoration: const InputDecoration(labelText: 'Identifier'),
          ),
        ],
      ),
    );
  }
}

class SizeField extends StatefulWidget {
  final RelativeSize initialValue;
  final ValueChanged<RelativeSize>? onChanged;
  final bool useSingleSize;

  /// Labels for the two fields. An asset whose box has a natural orientation
  /// can name them for what they mean on that asset — a conveyor's box width
  /// is the belt's length, and its height is the belt's width.
  final String widthLabel;
  final String heightLabel;

  const SizeField({
    super.key,
    required this.initialValue,
    this.onChanged,
    this.useSingleSize = false, // Default to false for backward compatibility
    this.widthLabel = 'Width %',
    this.heightLabel = 'Height %',
  });

  @override
  State<SizeField> createState() => _SizeFieldState();
}

class _SizeFieldState extends State<SizeField> {
  late TextEditingController _widthController;
  late TextEditingController _heightController;

  @override
  void initState() {
    super.initState();
    _widthController = TextEditingController(
        text: (widget.initialValue.width * 100).toStringAsFixed(2));
    _heightController = TextEditingController(
        text: (widget.initialValue.height * 100).toStringAsFixed(2));
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (widget.useSingleSize) {
      final size = double.tryParse(_widthController.text) ?? 3.0;
      final relSize = RelativeSize(width: size / 100, height: size / 100);
      widget.onChanged?.call(relSize);
    } else {
      final width = double.tryParse(_widthController.text) ?? 3.0;
      final height = double.tryParse(_heightController.text) ?? 3.0;
      final relSize = RelativeSize(width: width / 100, height: height / 100);
      widget.onChanged?.call(relSize);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.useSingleSize) {
      return Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _widthController,
              decoration: const InputDecoration(
                labelText: 'Size %',
                suffixText: '%',
                isDense: true,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _onChanged(),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: _widthController,
            decoration: InputDecoration(labelText: widget.widthLabel),
            keyboardType: TextInputType.number,
            onChanged: (_) => _onChanged(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: _heightController,
            decoration: InputDecoration(labelText: widget.heightLabel),
            keyboardType: TextInputType.number,
            onChanged: (_) => _onChanged(),
          ),
        ),
      ],
    );
  }
}

class CoordinatesField extends StatefulWidget {
  final Coordinates initialValue;
  final ValueChanged<Coordinates>? onChanged;
  final bool enableAngle;

  const CoordinatesField({
    super.key,
    required this.initialValue,
    this.onChanged,
    this.enableAngle = false, // Default to false for backward compatibility
  });

  @override
  State<CoordinatesField> createState() => _CoordinatesFieldState();
}

class _CoordinatesFieldState extends State<CoordinatesField> {
  late TextEditingController _xController;
  late TextEditingController _yController;
  late TextEditingController _angleController;

  @override
  void initState() {
    super.initState();
    _xController = TextEditingController(
        text: (widget.initialValue.x * 100).toStringAsFixed(2));
    _yController = TextEditingController(
        text: (widget.initialValue.y * 100).toStringAsFixed(2));
    _angleController = TextEditingController(
        text: widget.initialValue.angle?.toStringAsFixed(2) ?? '');
  }

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    _angleController.dispose();
    super.dispose();
  }

  void _onChanged() {
    final x = double.tryParse(_xController.text) ?? 0.0;
    final y = double.tryParse(_yController.text) ?? 0.0;
    final angle =
        widget.enableAngle ? double.tryParse(_angleController.text) : null;

    final coordinates = Coordinates(
      x: x / 100, // Convert from percentage to 0.0-1.0 range
      y: y / 100,
      angle: angle,
    );
    widget.onChanged?.call(coordinates);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _xController,
                decoration: const InputDecoration(
                  labelText: 'X 0-100%',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _onChanged(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _yController,
                decoration: const InputDecoration(
                  labelText: 'Y 0-100%',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _onChanged(),
              ),
            ),
          ],
        ),
        if (widget.enableAngle) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _angleController,
            decoration: InputDecoration(
              labelText: 'Angle (°)',
              suffixIcon: IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () {
                  showStandardDialog<void>(
                    context: context,
                    title: 'Angle and mirroring',
                    builder: (context) => const Text(
                      'When an angle is specified, the asset will be mirrored. '
                      'Positive angles rotate clockwise, negative angles '
                      'rotate counterclockwise.',
                    ),
                  );
                },
              ),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _onChanged(),
          ),
        ],
      ],
    );
  }
}

class KeyMappingEntryDialog extends ConsumerStatefulWidget {
  final String? initialKey;
  final KeyMappingEntry? initialKeyMappingEntry;

  /// Known array size for the target node. When set, the array-index field
  /// shows a dropdown (0-based) instead of a free-text box.
  final int? arraySize;

  const KeyMappingEntryDialog({
    super.key,
    this.initialKey,
    this.initialKeyMappingEntry,
    this.arraySize,
  });

  @override
  ConsumerState<KeyMappingEntryDialog> createState() =>
      _KeyMappingEntryDialogState();
}

/// Protocol type for the dialog's server selection.
enum _DialogProtocol { opcua, modbus, m2400 }

class _KeyMappingEntryDialogState extends ConsumerState<KeyMappingEntryDialog> {
  late TextEditingController _keyController;
  // The current entry being edited — updated by section widget callbacks.
  late KeyMappingEntry _entry;
  // Common state
  String? _selectedServerAlias;
  _DialogProtocol _protocol = _DialogProtocol.opcua;
  bool _isCollecting = false;
  ExpressionConfig? _sampleExpression;
  bool _useSampleExpression = false;
  // Config loaded from preferences
  StateManConfig? _config;
  bool _configLoading = true;

  @override
  void initState() {
    super.initState();

    if (widget.initialKeyMappingEntry != null) {
      final entry = widget.initialKeyMappingEntry!;
      _entry = entry;

      _keyController = TextEditingController(text: widget.initialKey ?? '');

      // Detect protocol from existing entry
      if (entry.modbusNode != null) {
        _protocol = _DialogProtocol.modbus;
        _selectedServerAlias = entry.modbusNode!.serverAlias;
      } else if (entry.m2400Node != null) {
        _protocol = _DialogProtocol.m2400;
        _selectedServerAlias = entry.m2400Node!.serverAlias;
      } else {
        _protocol = _DialogProtocol.opcua;
        _selectedServerAlias = entry.opcuaNode?.serverAlias;
      }

      final collect = entry.collect;
      if (collect != null) {
        _isCollecting = true;
        if (collect.sampleExpression != null) {
          _useSampleExpression = true;
          _sampleExpression = collect.sampleExpression;
        }
      }
    } else {
      _keyController = TextEditingController(text: widget.initialKey ?? '');
      _entry = KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 0, identifier: ''),
      );
    }

    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final config = await StateManConfigStorage.fromPrefs(prefs);
      if (mounted) {
        setState(() {
          _config = config;
          _configLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _configLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  /// Builds the unified server list from all three protocol configs.
  List<({String alias, _DialogProtocol protocol, String label})>
      _buildServerList(StateManConfig config) {
    final servers =
        <({String alias, _DialogProtocol protocol, String label})>[];
    for (final c in config.opcua) {
      final alias = c.serverAlias ?? '__default';
      servers.add((
        alias: alias,
        protocol: _DialogProtocol.opcua,
        label: '$alias (OPC UA)',
      ));
    }
    for (final c in config.modbus) {
      final alias = c.serverAlias ?? c.host;
      servers.add((
        alias: alias,
        protocol: _DialogProtocol.modbus,
        label: '$alias (Modbus)',
      ));
    }
    for (final c in config.jbtm) {
      final alias = c.serverAlias ?? '__default';
      servers.add((
        alias: alias,
        protocol: _DialogProtocol.m2400,
        label: '$alias (M2400)',
      ));
    }
    servers.sort((a, b) => a.label.compareTo(b.label));
    return servers;
  }

  /// Finds the matching server label for the current selection.
  String? _findSelectedLabel(
      List<({String alias, _DialogProtocol protocol, String label})> servers) {
    for (final s in servers) {
      if (s.alias == _selectedServerAlias && s.protocol == _protocol) {
        return s.label;
      }
    }
    return null;
  }

  /// Whether the current entry uses a bit/boolean data type.
  /// When true, the bit mask grid restricts to single-bit selection.
  bool get _isBitType {
    if (_protocol == _DialogProtocol.modbus && _entry.modbusNode != null) {
      final node = _entry.modbusNode!;
      if (node.dataType == ModbusDataType.bit) return true;
      if (node.registerType == ModbusRegisterType.coil ||
          node.registerType == ModbusRegisterType.discreteInput) {
        return true;
      }
    }
    return false;
  }

  /// Returns the number of bits for the current data type.
  int get _bitCountForDataType {
    if (_protocol == _DialogProtocol.modbus && _entry.modbusNode != null) {
      final dt = _entry.modbusNode!.dataType;
      switch (dt) {
        case ModbusDataType.int32:
        case ModbusDataType.uint32:
        case ModbusDataType.float32:
          return 32;
        default:
          return 16;
      }
    }
    return 16;
  }

  @override
  Widget build(BuildContext context) {
    if (_configLoading || _config == null) {
      return const StandardDialogFrame(
        title: 'Configure key mapping',
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final config = _config!;
    final servers = _buildServerList(config);
    final selectedLabel = _findSelectedLabel(servers);

    return StandardDialogFrame(
      title: 'Configure key mapping',
      icon: Icons.link,
      width: 540,
      actions: [PaneAction.primary(label: 'OK', onPressed: _submit)],
      child: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: 'Key',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedLabel,
                decoration: const InputDecoration(
                  labelText: 'Server',
                ),
                items: servers.map((s) {
                  return DropdownMenuItem(
                    value: s.label,
                    child: Text(s.label),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value == null) return;
                  final selected = servers.firstWhere((s) => s.label == value);
                  setState(() {
                    _selectedServerAlias = selected.alias;
                    _protocol = selected.protocol;
                    // Switch entry to new protocol
                    switch (selected.protocol) {
                      case _DialogProtocol.opcua:
                        _entry = KeyMappingEntry(
                          opcuaNode: OpcUANodeConfig(
                            namespace: 0,
                            identifier: '',
                          )..serverAlias = selected.alias,
                          collect: _entry.collect,
                          bitMask: _entry.bitMask,
                          bitShift: _entry.bitShift,
                        );
                      case _DialogProtocol.modbus:
                        _entry = KeyMappingEntry(
                          modbusNode: ModbusNodeConfig(
                            serverAlias: selected.alias,
                            registerType: ModbusRegisterType.holdingRegister,
                            address: 0,
                          ),
                          collect: _entry.collect,
                          bitMask: _entry.bitMask,
                          bitShift: _entry.bitShift,
                        );
                      case _DialogProtocol.m2400:
                        _entry = KeyMappingEntry(
                          m2400Node: M2400NodeConfig(
                            recordType: M2400RecordType.recBatch,
                            serverAlias: selected.alias,
                          ),
                          collect: _entry.collect,
                        );
                    }
                  });
                },
              ),
              const SizedBox(height: 16),
              // Protocol-specific section widgets
              if (_protocol == _DialogProtocol.opcua)
                OpcUaConfigSection(
                  key: ValueKey('opcua-$_selectedServerAlias'),
                  config: _entry.opcuaNode ??
                      OpcUANodeConfig(namespace: 0, identifier: ''),
                  serverAliases: config.opcua
                      .map((c) => c.serverAlias ?? '__default')
                      .toList(),
                  onChanged: (nodeConfig) {
                    setState(() {
                      _entry = _entry.copyWith(opcuaNode: nodeConfig);
                    });
                  },
                )
              else if (_protocol == _DialogProtocol.modbus)
                // TD-010 (v1.1.x): shared widget owns both the node-config
                // edits and the UMAS picker callback. Previously this site
                // and the Key Repository row hand-rolled the same wiring.
                KeyMappingModbusSection(
                  sectionKey: ValueKey('modbus-$_selectedServerAlias'),
                  entry: _entry,
                  modbusServerAliases: config.modbus
                      .map((c) => c.serverAlias ?? c.host)
                      .toList(),
                  modbusConfigs: config.modbus,
                  defaultNodeConfigBuilder: () => ModbusNodeConfig(
                    registerType: ModbusRegisterType.holdingRegister,
                    address: 0,
                  ),
                  onEntryChanged: (newEntry) {
                    setState(() {
                      _entry = newEntry;
                    });
                  },
                )
              else
                M2400ConfigSection(
                  key: ValueKey('m2400-$_selectedServerAlias'),
                  config: _entry.m2400Node ??
                      M2400NodeConfig(recordType: M2400RecordType.recBatch),
                  jbtmServerAliases: config.jbtm
                      .map((c) => c.serverAlias ?? '__default')
                      .toList(),
                  onChanged: (nodeConfig) {
                    setState(() {
                      _entry = _entry.copyWith(m2400Node: nodeConfig);
                    });
                  },
                ),
              // Bit selection -- required for bit types, optional mask for others
              if (_protocol != _DialogProtocol.m2400 && _isBitType) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bit Select (required)',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      BitMaskGrid(
                        bitCount: _bitCountForDataType,
                        currentMask: _entry.bitMask,
                        singleBit: true,
                        onChanged: (result) {
                          setState(() {
                            if (result.mask == null) {
                              _entry = _entry.copyWith(clearBitMask: true);
                            } else {
                              _entry = _entry.copyWith(
                                bitMask: result.mask,
                                bitShift: result.shift,
                              );
                            }
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ] else if (_protocol != _DialogProtocol.m2400) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: const Text('Bit Mask (optional)'),
                  initiallyExpanded: _entry.bitMask != null,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: BitMaskGrid(
                        bitCount: _bitCountForDataType,
                        currentMask: _entry.bitMask,
                        onChanged: (result) {
                          setState(() {
                            if (result.mask == null) {
                              _entry = _entry.copyWith(clearBitMask: true);
                            } else {
                              _entry = _entry.copyWith(
                                bitMask: result.mask,
                                bitShift: result.shift,
                              );
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Collection config
              CollectionConfigSection(
                enabled: _isCollecting,
                collect: _entry.collect,
                keyName: _keyController.text.isNotEmpty
                    ? _keyController.text
                    : 'key',
                onToggle: (enabled) {
                  setState(() {
                    _isCollecting = enabled;
                    if (enabled) {
                      _entry = _entry.copyWith(
                        collect: CollectEntry(
                          key: _keyController.text,
                          retention: RetentionPolicy(
                            dropAfter: const Duration(days: 365),
                          ),
                        ),
                      );
                    } else {
                      _entry = KeyMappingEntry(
                        opcuaNode: _entry.opcuaNode,
                        m2400Node: _entry.m2400Node,
                        modbusNode: _entry.modbusNode,
                        bitMask: _entry.bitMask,
                        bitShift: _entry.bitShift,
                      );
                    }
                  });
                },
                onChanged: (collect) {
                  setState(() {
                    _entry = _entry.copyWith(collect: collect);
                  });
                },
              ),
              // Sample expression (dialog-specific, not in shared widget)
              if (_isCollecting) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Use Sample Expression'),
                    const SizedBox(width: 8),
                    Switch(
                      value: _useSampleExpression,
                      onChanged: (value) {
                        setState(() {
                          _useSampleExpression = value;
                          if (!value) {
                            _sampleExpression = null;
                          }
                        });
                      },
                    ),
                  ],
                ),
                if (_useSampleExpression) ...[
                  const SizedBox(height: 16),
                  ExpressionBuilder(
                    value: _sampleExpression?.value ?? Expression(formula: ''),
                    onChanged: (expression) {
                      setState(() {
                        _sampleExpression = ExpressionConfig(value: expression);
                      });
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the mapping entry and pops it back to the caller.
  void _submit() {
    final key = _keyController.text;
    if (key.isEmpty) return;

    // Build the final collect entry with sample expression
    CollectEntry? collectEntry;
    if (_isCollecting && _entry.collect != null) {
      collectEntry = CollectEntry(
        key: key,
        name: _entry.collect!.name,
        sampleInterval: _entry.collect!.sampleInterval,
        sampleExpression: _useSampleExpression ? _sampleExpression : null,
        sampleMembers: _entry.collect!.sampleMembers,
        retention: _entry.collect!.retention,
      );
    }

    final result = KeyMappingEntry(
      opcuaNode: _protocol == _DialogProtocol.opcua ? _entry.opcuaNode : null,
      modbusNode:
          _protocol == _DialogProtocol.modbus ? _entry.modbusNode : null,
      variableName:
          _protocol == _DialogProtocol.modbus ? _entry.variableName : null,
      m2400Node: _protocol == _DialogProtocol.m2400 ? _entry.m2400Node : null,
      collect: collectEntry,
      bitMask: _protocol != _DialogProtocol.m2400 ? _entry.bitMask : null,
      bitShift: _protocol != _DialogProtocol.m2400 ? _entry.bitShift : null,
    );

    // Validate required fields
    if (_protocol == _DialogProtocol.opcua &&
        (result.opcuaNode?.identifier.isEmpty ?? true)) {
      return;
    }
    // Bit type requires a bit selection
    if (_isBitType && result.bitMask == null) {
      return;
    }

    Navigator.of(context).pop({
      'key': key,
      'entry': result,
    });
  }
}

/// Rotates [child] by [angle] (radians),
/// *and* expands its layout box to the rotated AABB,
/// *and* transforms hit-testing so you get taps anywhere over it.
class LayoutRotatedBox extends SingleChildRenderObjectWidget {
  final double angle;
  const LayoutRotatedBox({
    required this.angle,
    Widget? child,
    Key? key,
  }) : super(key: key, child: child);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderLayoutRotatedBox(angle);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderLayoutRotatedBox renderObject) {
    renderObject.angle = angle;
  }
}

class _RenderLayoutRotatedBox extends RenderProxyBox {
  double _angle;
  _RenderLayoutRotatedBox(this._angle);

  set angle(double value) {
    if (value == _angle) return;
    _angle = value;
    markNeedsLayout();
    markNeedsPaint();
  }

  @override
  void performLayout() {
    if (child == null) {
      size = constraints.smallest;
      return;
    }

    child!.layout(constraints, parentUsesSize: true);

    if (_angle == 0.0) {
      size = constraints.constrain(child!.size);
      return;
    }

    final w = child!.size.width;
    final h = child!.size.height;
    final c = math.cos(_angle).abs();
    final s = math.sin(_angle).abs();
    size = constraints.constrain(Size(w * c + h * s, w * s + h * c));
  }

  Offset _childOffset() {
    return Offset((size.width - child!.size.width) / 2,
        (size.height - child!.size.height) / 2);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;

    if (_angle == 0.0) {
      context.paintChild(child!, offset);
      return;
    }

    final childOffset = _childOffset();
    final transform = Matrix4.identity()
      ..translate(offset.dx + child!.size.width / 2 + childOffset.dx,
          offset.dy + child!.size.height / 2 + childOffset.dy)
      ..rotateZ(_angle)
      ..translate(-child!.size.width / 2, -child!.size.height / 2);

    context.pushTransform(
      needsCompositing,
      Offset.zero,
      transform,
      (innerContext, innerOffset) {
        innerContext.paintChild(child!, innerOffset);
      },
    );
  }

  /// Reports the rotation to everything that asks where the child ended up.
  ///
  /// [paint] pushes a transform and [hitTest] inverts the same one, but
  /// neither is what `getTransformTo`, `localToGlobal` or
  /// `WidgetTester.getRect` consult — those walk `applyPaintTransform`, and
  /// without this one the chain crossed a rotated asset as if it were not
  /// rotated. Everything measuring a rotated asset from the outside was off
  /// by the rotation: the rect `showSidePane` keeps clear of a tapped device,
  /// the page editor's measurement of an asset it is opening a pane for, and
  /// the shape an asset publishes for the mark on the plant view — which is
  /// what noticed (`hit_boundary_drift_test`).
  ///
  /// Deliberately the same matrix [paint] builds, minus the paint offset,
  /// which this method excludes by contract.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_angle == 0.0 || child != this.child) {
      super.applyPaintTransform(child, transform);
      return;
    }
    final childOffset = _childOffset();
    final halfWidth = child.size.width / 2;
    final halfHeight = child.size.height / 2;
    transform
      ..translateByDouble(
          childOffset.dx + halfWidth, childOffset.dy + halfHeight, 0, 1)
      ..rotateZ(_angle)
      ..translateByDouble(-halfWidth, -halfHeight, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (child == null) return false;

    if (_angle == 0.0) {
      // At zero rotation, the rotated box is a no-op proxy: forward the
      // hit test to the child so descendant GestureDetectors receive
      // taps. Without this, any GestureDetector mounted INSIDE a
      // LayoutRotatedBox is unreachable — see Phase 3 Plan 01
      // ELEV-19 / Pitfall 7 lock (children riding the elevator
      // platform must continue receiving taps mid-translation).
      // The child's verdict decides ours: a painter that claims only its
      // painted pixels (ConveyorPainter's belt) must keep the dead corners
      // of the box inert for consumers wrapping us in a deferring
      // GestureDetector, so we only add ourselves when the child was hit.
      if (position.dx >= 0 &&
          position.dx <= child!.size.width &&
          position.dy >= 0 &&
          position.dy <= child!.size.height) {
        // Probe the child first so deeper GestureDetectors record
        // entries in the arena ahead of ours.
        final childHit = child!.hitTest(result, position: position);
        if (childHit) {
          result.add(BoxHitTestEntry(this, position));
        }
        return childHit;
      }
      return false;
    }

    final childOffset = _childOffset();
    final local = position - childOffset;
    final dx = local.dx - child!.size.width / 2;
    final dy = local.dy - child!.size.height / 2;
    final cosA = math.cos(-_angle), sinA = math.sin(-_angle);
    final x0 = cosA * dx - sinA * dy + child!.size.width / 2;
    final y0 = sinA * dx + cosA * dy + child!.size.height / 2;

    if (x0 >= 0 &&
        x0 <= child!.size.width &&
        y0 >= 0 &&
        y0 <= child!.size.height) {
      // Forward the hit to the child in the child's local (un-rotated)
      // coordinate frame. Without this, descendant GestureDetectors
      // would never fire when the rotated box contains tappable
      // children (mirrors the angle=0 fix above). See ELEV-19. As above,
      // the child's verdict decides ours.
      final childHit = child!.hitTest(result, position: Offset(x0, y0));
      if (childHit) {
        result.add(BoxHitTestEntry(this, position));
      }
      return childHit;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Size-aware text
//
// Assets are laid out as fractions of the page, so their labels have to grow
// and shrink with the page. The obvious way to do that -- wrap the `Text` in a
// `FittedBox` -- is the wrong one: `FittedBox` lays the child out at the
// child's own font size and then paints it through a *scale transform*, so the
// glyphs are rasterised for one size and blitted at another. The text goes
// soft, and only sharpens when something forces a re-raster at the size that
// is actually on screen -- which is why zooming the canvas appears to fix it.
//
// The two helpers below do it the other way round: compute a font size for the
// box, then lay the text out AT that size, so the glyphs are rasterised at
// exactly the size they are drawn and there is nothing left to resample.
// ---------------------------------------------------------------------------

/// The largest font size at which [text], styled with [style], still fits in
/// [box].
///
/// Measured the way `FittedBox` measured it -- unbounded width, so the string
/// breaks only where it breaks itself -- but returned as a size to lay the
/// text out at rather than a factor to scale it by.
///
/// [heightFraction] caps the result at that fraction of the box height, for
/// labels that should not swell to fill their whole box. The default of 1.0
/// caps nothing, which reproduces `BoxFit.contain`.
///
/// [angleRadians] fits the text's *rotated* bounding box, for the readouts
/// that turn with `coordinates.angle`.
///
/// Returns the uncapped size when there is nothing to fit to (an empty string,
/// or an unbounded box), and never less than [minFontSize].
double fittedFontSize({
  required String text,
  required TextStyle style,
  required Size box,
  double heightFraction = 1.0,
  double minFontSize = 1.0,
  double? maxFontSize,
  double angleRadians = 0.0,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  double referenceFontSize = 64.0,
}) {
  final fallback = maxFontSize ?? style.fontSize ?? referenceFontSize;
  if (text.isEmpty) return fallback;
  if (!box.width.isFinite || !box.height.isFinite) {
    // There is nothing to fit to, so the size below is a guess. When the style
    // carries a fontSize or the caller passed maxFontSize, that guess is the
    // caller's own number and fine. Otherwise it is [referenceFontSize] --
    // an arbitrary 64pt that will render, look deliberate, and be wrong. That
    // is a bug at the call site, not something to paper over at runtime.
    assert(
      style.fontSize != null || maxFontSize != null,
      'fittedFontSize was handed an unbounded box ($box) with no fontSize on '
      'the style and no maxFontSize, so the text would silently render at '
      '${referenceFontSize}pt. Give it a bounded box -- a SizedBox or a '
      'LayoutBuilder with finite constraints -- or an explicit font size.',
    );
    return fallback;
  }
  if (box.width <= 0 || box.height <= 0) return minFontSize;

  double? cap = maxFontSize;
  if (heightFraction < 1.0) {
    final byHeight = box.height * heightFraction;
    cap = cap == null ? byHeight : math.min(cap, byHeight);
  }

  final cosA = math.cos(angleRadians).abs();
  final sinA = math.sin(angleRadians).abs();

  Size measure(double fontSize) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(fontSize: fontSize)),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final measured = painter.size;
    painter.dispose();
    return measured;
  }

  // What the measured text would have to be scaled by to fit the box, taking
  // the rotated bounding box rather than the upright one.
  double fitScale(Size m) {
    final aabbW = m.width * cosA + m.height * sinA;
    final aabbH = m.width * sinA + m.height * cosA;
    if (aabbW <= 0 || aabbH <= 0) return double.infinity;
    return math.min(box.width / aabbW, box.height / aabbH);
  }

  var candidate = referenceFontSize * fitScale(measure(referenceFontSize));
  if (!candidate.isFinite) return fallback;
  if (cap != null) candidate = math.min(candidate, cap);
  candidate = math.max(candidate, minFontSize);

  // Advance widths are all but exactly linear in font size, so the step above
  // lands on the answer; these passes take up the rounding left over.
  for (var i = 0; i < 3; i++) {
    final scale = fitScale(measure(candidate));
    if (scale >= 1.0) break;
    final next = math.max(candidate * scale, minFontSize);
    if (next >= candidate) break;
    candidate = next;
  }
  return candidate;
}

/// A [Text] laid out at a font size computed from the box it is given.
///
/// The drop-in replacement for `FittedBox(child: Text(...))`: it grows and
/// shrinks with the asset just the same, but the glyphs are rasterised at
/// their final size instead of being scaled there by a transform. See
/// [fittedFontSize].
class AutoSizedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// Where the text sits in the box once it is smaller than the box.
  final AlignmentGeometry alignment;

  /// Taken off the box before the text is fitted to what is left.
  final EdgeInsets padding;

  /// Caps the font size at this fraction of the box height. 1.0 (the default)
  /// caps nothing, and fills the box the way `BoxFit.contain` did.
  final double heightFraction;

  final double minFontSize;
  final double? maxFontSize;

  /// Shrink to fit, but never grow past the style's own font size.
  ///
  /// This is what `FittedBox(fit: BoxFit.scaleDown)` did, and some labels
  /// want it. A button face should grow with the button — that is the whole
  /// point of sizing text to its box. A *legend* should not: the conveyor
  /// colour palette lists five colours with a word beside each, and letting
  /// those words fill their swatches turned a key into five giant captions.
  ///
  /// Only caps the upper end. The text still shrinks when the box is too
  /// small, and is still laid out at its final size rather than scaled there,
  /// so it rasterises just as crisply.
  final bool shrinkOnly;

  /// Turns the text, and fits its rotated bounding box to the box.
  final double angleRadians;

  const AutoSizedText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.alignment = Alignment.center,
    this.padding = EdgeInsets.zero,
    this.heightFraction = 1.0,
    this.minFontSize = 1.0,
    this.maxFontSize,
    this.shrinkOnly = false,
    this.angleRadians = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolved = DefaultTextStyle.of(context).style.merge(style);
        final box = Size(
          math.max(0.0, constraints.maxWidth - padding.horizontal),
          math.max(0.0, constraints.maxHeight - padding.vertical),
        );
        // [shrinkOnly] caps at whatever the style resolved to, which is only
        // knowable here — the call site sees `style`, not what it merged
        // with. An explicit maxFontSize still wins, so the two can be
        // combined and the tighter one applies.
        final cap = shrinkOnly && resolved.fontSize != null
            ? math.min(maxFontSize ?? double.infinity, resolved.fontSize!)
            : maxFontSize;
        final fontSize = fittedFontSize(
          text: text,
          style: resolved,
          box: box,
          heightFraction: heightFraction,
          minFontSize: minFontSize,
          maxFontSize: cap,
          angleRadians: angleRadians,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        );

        Widget child = Text(
          text,
          style: resolved.copyWith(fontSize: fontSize),
          textAlign: textAlign,
          softWrap: false,
          overflow: TextOverflow.visible,
        );
        if (angleRadians != 0.0) {
          child = Transform.rotate(angle: angleRadians, child: child);
        }
        return Padding(
          padding: padding,
          child: Align(alignment: alignment, child: child),
        );
      },
    );
  }
}
