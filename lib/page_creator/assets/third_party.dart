import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/converter/color_converter.dart';
import 'package:tfc/theme.dart' show HmiColorRole, HmiStateColors;

import '../../providers/state_man.dart';
import '../../widgets/panes/color_picker_dialog.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'package:tfc/widgets/number_slider.dart';
import 'common.dart';
import 'conveyor.dart' show ConveyorConfig;
import 'led.dart' show LEDPainter, LEDType;
import 'package:tfc_dart/core/collector.dart' show CollectEntry, Collector;
import 'package:tfc_dart/core/database.dart' show TimeseriesData;
import '../../providers/collector.dart';
import '../../widgets/graph.dart';
import 'graph.dart' show GraphAssetConfig;
import 'sensor.dart' show SensorConfig;
import 'number.dart' show NumberConfig, NumberWidget, showNumberGraphDialog;
import 'ratio_number.dart'
    show
        RatioNumberConfig,
        RatioNumberWidget,
        ratioIntervalChips,
        showRatioAnalysisDialog;
import '../../widgets/duration_field.dart';
import 'registry.dart';

import 'third_party_painter.dart';

part 'third_party.g.dart';

/// The piece of third-party equipment this asset stands for.
///
/// Drives painter dispatch — one simplified top view per kind. Adding a value
/// here is a compile error in `_createPainter` until a painter is wired up,
/// which is deliberate.
@JsonEnum()
enum ThirdPartyEquipmentKind {
  multivac,
  speedBatcher,

  /// TODO(product-name): the make/model of the box erector on the line has not
  /// been identified yet. Rename this value (and its label + painter) once it
  /// is — every other kind is named after its manufacturer.
  boxErector,

  strappingLine,

  /// The vodlari — Icelandic for the fish aligning buffer. Stored under an
  /// English-ish identifier because the persisted JSON should not depend on
  /// non-ASCII. It is still called the vodlari on the plant floor, but the
  /// operator-facing label reads "Batch aligner"; the floor name survives as a
  /// search keyword on [ThirdPartyEquipmentConfig.searchKeywords].
  fishAligner,

  /// The Optimar robotic palletising stations for white boxes — Ph-1.
  ///
  /// Named after the supplier like every other kind whose make we know:
  /// Optimar drawing 10-N1230-1 is the source for the layout, and that
  /// drawing's own notice block reads "Find us at optimar.no". The 6-axis arm
  /// standing on the pad is somebody else's machine and the foundation
  /// drawing does not name it — a gap in what we know about the ARM, not
  /// about the station, so it is recorded on the painter rather than as a
  /// TODO here.
  optimarPalletiser,
}

/// Operator-facing metadata for each kind. Kept out of the enum so the
/// persisted JSON stays a stable identifier while the display text can change
/// freely.
extension ThirdPartyEquipmentKindInfo on ThirdPartyEquipmentKind {
  /// Name shown in the kind dropdown and as the details-dialog title.
  String get label {
    switch (this) {
      case ThirdPartyEquipmentKind.multivac:
        return 'Multivac thermoformer';
      case ThirdPartyEquipmentKind.speedBatcher:
        return 'Marel SpeedBatcher';
      case ThirdPartyEquipmentKind.boxErector:
        return 'Box erector';
      case ThirdPartyEquipmentKind.strappingLine:
        return 'Afak / StrapX strapping line';
      case ThirdPartyEquipmentKind.fishAligner:
        return 'Batch aligner';
      case ThirdPartyEquipmentKind.optimarPalletiser:
        return 'Optimar palletising station';
    }
  }

  /// Label including the model variant, where a unit count picks a real model
  /// number or tells the cells apart. Used for the side-pane title.
  String labelFor({int strapMachines = 3, int robotStations = 2}) {
    switch (this) {
      case ThirdPartyEquipmentKind.strappingLine:
        return 'Strapping line — ${strapMachines.clamp(1, 3)} x StrapX';
      case ThirdPartyEquipmentKind.optimarPalletiser:
        final n = robotStations.clamp(1, 3);
        return 'Optimar palletising — $n '
            '${n == 1 ? 'station' : 'stations'}';
      default:
        return label;
    }
  }

  /// Real machine footprint, shown in the side pane. See the source notes at
  /// the top of `third_party_painter.dart` for where each figure comes from.
  ///
  /// [strapMachines] only affects the strapping line, [robotStations] only
  /// the palletising robot.
  String footprint({int strapMachines = 3, int robotStations = 2}) {
    switch (this) {
      case ThirdPartyEquipmentKind.multivac:
        return '~5437 x 1002 mm (R 245)';
      case ThirdPartyEquipmentKind.speedBatcher:
        return 'station layout — per site sketch';
      case ThirdPartyEquipmentKind.boxErector:
        return 'tall and narrow — per site CAD';
      case ThirdPartyEquipmentKind.fishAligner:
        return 'near square — per site CAD';
      case ThirdPartyEquipmentKind.optimarPalletiser:
        // Off Optimar drawing 10-N1230-1. The 3500 mm pitch is EXACT — it is
        // the dimension chain between the three Ph-1 robot centres — so
        // unlike the strapping line's shortened variants this figure is not
        // guesswork at any station count. The depth is not dimensioned on the
        // drawing and is scaled off that pitch, so the total reads as
        // approximate.
        final n = robotStations.clamp(1, 3);
        return '~${kPalletiserWidthMm(n)} x $kPalletiserDepthMm mm '
            '($n ${n == 1 ? 'station' : 'stations'} at '
            '$kPalletiserPitchMm mm pitch)';
      case ThirdPartyEquipmentKind.strappingLine:
        // Only the 3-strapper line length is published. A shorter line is the
        // same line with strappers removed, so its length is estimated at one
        // strapper pitch each and labelled as such rather than quoted as
        // fact.
        if (strapMachines >= 3) return '~2665 x 1815 mm (3 strappers)';
        final estimated = 2665 - (3 - strapMachines) * 640;
        return '~$estimated x 1815 mm '
            '($strapMachines strappers, length estimated)';
    }
  }

  /// Aspect ratio of the drawing as authored — **width divided by height**,
  /// matching the real machine's plan proportions.
  ///
  /// Note the SpeedBatcher is the odd one out at under 1.0: it is drawn
  /// PORTRAIT, because product runs up the page through it rather than left
  /// to right.
  ///
  /// Sizing an asset well away from its kind's ratio squashes the layout — the
  /// Multivac especially, at 5.4:1. Used for the editor preview.
  double aspectRatio({int strapMachines = 3, int robotStations = 2}) {
    switch (this) {
      case ThirdPartyEquipmentKind.multivac:
        return 5437 / 1002;
      case ThirdPartyEquipmentKind.speedBatcher:
        // From the site sketch: roughly twice as long as it is wide, running
        // up the page.
        return 0.53;
      case ThirdPartyEquipmentKind.boxErector:
        // Portrait, and markedly so — the site CAD shows a long narrow
        // machine with the blank magazine running most of its length.
        return 0.35;
      case ThirdPartyEquipmentKind.strappingLine:
        return (2665 - (3 - strapMachines.clamp(1, 3)) * 640) / 1815;
      case ThirdPartyEquipmentKind.fishAligner:
        // Close to square in the site CAD.
        return 0.93;
      case ThirdPartyEquipmentKind.optimarPalletiser:
        // Portrait at one station, landscape from two — the row grows
        // sideways as stations are added, exactly like the strapping line
        // grows with strappers.
        return kPalletiserWidthMm(robotStations.clamp(1, 3)) /
            kPalletiserDepthMm;
    }
  }

  /// Whether the head-count control applies to this kind.
  bool get hasStrapMachines => this == ThirdPartyEquipmentKind.strappingLine;

  /// Whether the station-count control applies to this kind.
  bool get hasRobotStations =>
      this == ThirdPartyEquipmentKind.optimarPalletiser;
}

/// Pitch between palletising stations, in mm.
///
/// EXACT: Optimar drawing 10-N1230-1 dimensions the three Ph-1 robot centres
/// at 5210, 8710 and 12210 off the building datum — 3500 mm apart.
const int kPalletiserPitchMm = 3500;

/// Front-to-back depth of the palletising area, in mm.
///
/// APPROXIMATE. The drawing does not dimension this axis, so it is scaled off
/// the exact [kPalletiserPitchMm] pitch: the ~3.9 m pallet lane, which is what
/// the guarded row is. Scaling the same way reproduces the robot base plate at
/// ~1300 mm against its labelled Ø1250, so this is good to a few percent and
/// no better.
///
/// The drawing's transfer rail and pallet magazine are NOT counted: they are
/// hall-wide, they sit outside the guarding, and the asset does not draw them.
const int kPalletiserDepthMm = 4000;

/// Width of the palletising area for [stations] stations, in mm.
///
/// One pitch per station — each station's cabinet stands within its own pitch,
/// so the row adds nothing on the end.
int kPalletiserWidthMm(int stations) => kPalletiserPitchMm * stations;

// ---------------------------------------------------------------------------
// Child assets inside the box
// ---------------------------------------------------------------------------

/// Deserialise a polymorphic child asset for a [ThirdPartyChildEntry].
///
/// Same envelope trick as `elevator.dart:_childFromJson` — wrapping the child
/// JSON in a single-key Map makes [AssetRegistry.parse]'s tree crawl find
/// exactly one asset without bare-Map ambiguity, and any registered asset type
/// works without a switch here.
///
/// FAIL-LOUD: an unregistered `asset_name` throws rather than silently
/// dropping the child, so a saved page cannot quietly lose the conveyor an
/// operator relies on.
BaseAsset _childFromJson(Map<String, dynamic> json) {
  final assets = AssetRegistry.parse(<String, dynamic>{'wrapped_child': json});
  if (assets.isEmpty) {
    throw FormatException(
      'ThirdPartyChildEntry.child JSON did not match any registered '
      'asset_name in AssetRegistry: ${json[constAssetName]}',
    );
  }
  return assets.first as BaseAsset;
}

Map<String, dynamic> _childToJson(BaseAsset child) => child.toJson();

List<ThirdPartyChildEntry> _childrenFromJson(List<dynamic>? json) {
  if (json == null) return <ThirdPartyChildEntry>[];
  return json
      .map(
          (item) => ThirdPartyChildEntry.fromJson(item as Map<String, dynamic>))
      .toList();
}

List<Map<String, dynamic>> _childrenToJson(List<ThirdPartyChildEntry> list) =>
    list.map((e) => e.toJson()).toList();

/// Monotonic suffix for entry ids. Windows clock resolution (~15 ms) can make
/// back-to-back `DateTime.now()` calls return the same microseconds; the
/// suffix guarantees uniqueness regardless. Mirrors `elevator.dart`.
int _nextThirdPartyChildIdSuffix = 0;

/// A live asset placed inside the dotted box.
///
/// The point is that the parts of a third-party machine we CAN see — a
/// conveyor whose drive frequency we read, a sensor on the infeed — get their
/// real assets rather than a painted approximation. Drop a `ConveyorConfig`
/// onto the SpeedBatcher's infeed lane and it animates from the actual
/// frequency while the surrounding station stays a drawing.
///
/// Positions are fractions of the machine area (the rect the plan view is
/// drawn into), NOT of the whole asset rect — so a child stays on its lane
/// when the LED header changes height.
@JsonSerializable(explicitToJson: true)
class ThirdPartyChildEntry {
  /// Stable identity, used as a `ValueKey` so the child keeps its State (and
  /// its subscription) when the list is reordered.
  String id;

  /// Centre X within the machine area: 0.0 = left edge, 1.0 = right edge.
  double offsetX;

  /// Centre Y within the machine area: 0.0 = top edge, 1.0 = bottom edge.
  double offsetY;

  /// Keep this child level on screen no matter how the parent is rotated.
  ///
  /// Readouts want this — a weight you have to tilt your head to read is
  /// useless, and the machine gets rotated to match the plant layout, not to
  /// suit the numbers. Machinery (conveyors, sensors) wants the opposite: it
  /// must turn with the machine it belongs to.
  @JsonKey(defaultValue: false)
  bool keepUpright;

  /// Polymorphic child asset. Its own `size` is resolved against the machine
  /// area rather than the screen, so it scales with the parent.
  @JsonKey(fromJson: _childFromJson, toJson: _childToJson)
  BaseAsset child;

  ThirdPartyChildEntry({
    String? id,
    this.offsetX = 0.5,
    this.offsetY = 0.5,
    this.keepUpright = false,
    required this.child,
  }) : id = id ??
            '${DateTime.now().microsecondsSinceEpoch}-'
                '${_nextThirdPartyChildIdSuffix++}';

  factory ThirdPartyChildEntry.fromJson(Map<String, dynamic> json) =>
      _$ThirdPartyChildEntryFromJson(json);

  Map<String, dynamic> toJson() => _$ThirdPartyChildEntryToJson(this);
}

/// A piece of equipment we do NOT control, shown on the line overview so the
/// operator can see the handshake between our PLC and the neighbouring
/// machine.
///
/// Renders a simplified top view of the selected machine inside a dotted
/// boundary box — the dotted line is the visual convention for "outside our
/// scope of supply". One LED in the top-left corner reports run status; tap
/// anywhere in the box for the details dialog.
///
/// Scope note: run status is the only live signal on the MIMIC. The
/// SpeedBatcher additionally reads its `p_stat_*` handshake struct via
/// [statusKey], surfaced as diodes in the side pane — richer state stays off
/// the drawing so the box reads the same across kinds.
@JsonSerializable(explicitToJson: true)
class ThirdPartyEquipmentConfig extends BaseAsset {
  @override
  String get displayName => '3rd Party Equipment';

  @override
  String get category => 'Third Party';

  /// Every kind's label, so searching for the machine on the floor —
  /// "multivac", "speedbatcher", "afak" — surfaces this tile even though the
  /// palette shows the umbrella name. "vodlari" is listed on top of the labels
  /// because the batch aligner's label no longer carries its floor name, and
  /// the floor name is what an operator will type.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get searchKeywords => [
        for (final kind in ThirdPartyEquipmentKind.values) kind.label,
        'vodlari',
      ];

  /// Which machine this asset represents.
  @JsonKey(unknownEnumValue: ThirdPartyEquipmentKind.multivac)
  ThirdPartyEquipmentKind kind;

  /// State key carrying the machine's run status as a bool.
  ///
  /// Empty key, no value yet, or a stream error all render the LED grey with
  /// the `!` glyph (`LEDPainter`'s unknown state) rather than claiming the
  /// machine is stopped.
  String runKey;

  /// When true the visual run state is the inverse of the raw bool — for
  /// equipment that hands us a "stopped" contact rather than a "running" one.
  bool invertRunPolarity;

  /// For a kind in [kStructStatusBits], the struct node carrying that
  /// machine's `p_stat_*` handshake bits — `SB1` mapping to
  /// `SPB01.speedBatcher.hmi`, `STM01` to `STM01.STM01.hmi`, `SPB01.Multivac`
  /// to `SPB01.multivac.hmi`, `SPB01.Aligner` to `SPB01.packing.hmi`. One
  /// subscription feeds every diode in the side pane's Status section.
  ///
  /// For the remaining kinds this is a key PREFIX rather than a struct node:
  /// `BER02`. The pane appends the suffixes in [kEquipmentStatusBits] to it,
  /// one subscription each.
  ///
  /// A bit the PLC does not expose renders as the unknown LED rather than
  /// claiming "off".
  String statusKey;

  /// LED colour while the machine is running.
  ///
  /// An [AssetColor] rather than a bare [Color] so it can hold a scheme ROLE.
  /// A literal is frozen at the moment the picker was used and ignores a later
  /// scheme switch -- every one of these assets was storing Material's
  /// `#4CAF50`, which is why the running LED stayed a saturated green while
  /// the muted scheme drew everything around it in `#8DA28A`. Literals still
  /// load: [AssetColorConverter] reads both shapes.
  @AssetColorConverter()
  AssetColor runningColor;

  /// LED colour while the machine is stopped.
  @AssetColorConverter()
  AssetColor stoppedColor;

  /// Outline colour of the machine drawing. The dotted boundary uses the same
  /// colour at reduced opacity.
  @AssetColorConverter()
  AssetColor outlineColor;

  /// Outline stroke width in logical pixels.
  double strokeWidth;

  /// Optional human-readable label (e.g. `"MV-01"`).
  String? tag;

  /// Paint [tag] on the page next to the drawing.
  ///
  /// Off by default: `AssetStack` scales the label font with the asset's
  /// bounding box, and these machines are big, so the tag comes out huge on
  /// the mimic. The side pane titles itself with the tag either way, so
  /// nothing is lost by leaving this off.
  @JsonKey(defaultValue: false)
  bool showTag;

  /// Free-text notes surfaced in the side pane — supplier contact, line
  /// position, interlock quirks, whatever the operator needs at 03:00.
  String? notes;

  /// StrapX arches on the strapping line — the `-N` in SL-15-N. Ignored by
  /// the other kinds.
  int strapMachines;

  /// Flip the machine drawing left-to-right.
  ///
  /// Every kind is chiral, and a hall that runs the other way needs the glyph
  /// to run the other way. Rotating 180° is NOT the same thing — that turns
  /// the machine upside down too, putting a cabinet at the front and a
  /// discharge at the back.
  ///
  /// Per instance, not per page: this is a property of how the machine is
  /// installed, and two of the same kind on one page can be handed
  /// differently. Independent of the page-wide mirror in `AssetStackConfig`,
  /// which mirrors a whole station's layout.
  @JsonKey(defaultValue: false)
  bool mirrorX;

  /// Flip the machine drawing front-to-back. See [mirrorX].
  @JsonKey(defaultValue: false)
  bool mirrorY;

  /// Palletising stations standing in the Optimar row — Ph-1 is three.
  /// Ignored by the other kinds.
  ///
  /// Its own field rather than sharing [strapMachines]: the two counts mean
  /// different things on different machines, and a page carrying both a
  /// strapping line and a palletiser must be able to set them apart.
  int robotStations;

  /// Live assets placed inside the dotted box (conveyors driven by real drive
  /// frequencies, sensors, readouts, and so on).
  @JsonKey(fromJson: _childrenFromJson, toJson: _childrenToJson)
  List<ThirdPartyChildEntry> children;

  /// Extra loose status diodes this instance declares, each reading its OWN
  /// full HMI key, rendered after the kind's normal (struct or prefix) diodes
  /// in the side pane's Status section.
  ///
  /// The escape hatch for a permit that is NOT a member of the kind's
  /// handshake struct and NOT a suffix under [statusKey]. The Multivac is
  /// struct-backed off `SPB0n.multivac.hmi` (an `SP_Packing_HMI`), but its
  /// outfeed permit is a separate global — `MVC0n.PermitOutfeed`, mapped to
  /// `ns=4;s=MVC0n.xPermitOutfeed`, a different namespace from the struct — so
  /// there is otherwise no way to display it. Each entry names a COMPLETE key,
  /// read directly rather than appended to anything.
  ///
  /// Per-asset, not per-kind: the operator points each Multivac instance at its
  /// own line's `MVC01`/`MVC02`/`MVC03`. Empty — the default — renders exactly
  /// as before. When the PLC folds `p_stat_OutfeedPermitted` into
  /// `SP_Packing_HMI`, the struct path in [kStructStatusBits] is the tidier
  /// home; this mechanism is for loose/separate-device permits.
  @JsonKey(defaultValue: [])
  List<ExtraStatusBit> extraBits;

  /// Extra rotation, in degrees, for every child marked
  /// [ThirdPartyChildEntry.keepUpright].
  ///
  /// One angle for the lot, because the readouts inside a machine are always
  /// read from the same place. Zero — the default — means level on screen
  /// whatever `coordinates.angle` the machine is placed at: the parent's
  /// rotation is cancelled out first, then this is applied on top. Use it to
  /// tilt the whole set when the operator reads the panel from an angle.
  double childTextAngle;

  /// Averaging window, in minutes, behind the accept-rate readout.
  ///
  /// The accept rate is a rolling figure, not an instant one, and a bare
  /// percentage invites being read as "right now". The scaffold folds this
  /// number into the readout's units — `% / 30 min` — so the window travels
  /// with the value instead of living in someone's head.
  int acceptWindowMinutes;

  /// Whether the accept/reject chart's bars sit on clock boundaries.
  ///
  /// True — the default — buckets a 10-minute interval at :00, :10, :20 and so
  /// on, which is how the figure gets compared against a shift clock or a
  /// production log. False buckets backwards from "now", so every refresh
  /// slides the bars and two operators looking at the same chart a minute
  /// apart are reading different windows.
  ///
  /// Lives on the station rather than on each readout because it is applied to
  /// both of them on load: the two checkweighers must bucket alike or their
  /// accept rates cannot be read side by side.
  @JsonKey(defaultValue: true)
  bool acceptBarsClockAligned;

  /// `Asset.text` is what `AssetStack` (in `lib/pages/page_view.dart`) reads to
  /// paint the label OUTSIDE the asset's rotated subtree. Aliasing `text` onto
  /// `tag` — the same trick `SensorConfig` uses — keeps the label upright
  /// regardless of `Coordinates.angle`.
  ///
  /// Gated on [showTag]: with it off, `AssetStack` sees no label and paints
  /// nothing. [tag] itself is untouched — it still names the pane and is
  /// persisted under its own JSON key.
  @override
  String? get text => showTag ? tag : null;

  /// Non-null writes only. The generated `fromJson` assigns `..text =` AFTER
  /// the constructor has set `tag`; adopting a null `text` from a legacy page
  /// would wipe a perfectly good tag. Mirrors `SensorConfig.text`.
  @override
  set text(String? value) {
    if (value != null) tag = value;
  }

  ThirdPartyEquipmentConfig({
    this.kind = ThirdPartyEquipmentKind.multivac,
    this.runKey = '',
    this.invertRunPolarity = false,
    this.statusKey = '',
    AssetColor? runningColor,
    AssetColor? stoppedColor,
    AssetColor? outlineColor,
    this.strokeWidth = 2.0,
    this.tag,
    this.showTag = false,
    this.notes,
    this.strapMachines = 3,
    this.robotStations = 2,
    this.mirrorX = false,
    this.mirrorY = false,
    this.childTextAngle = 0.0,
    this.acceptWindowMinutes = 30,
    this.acceptBarsClockAligned = true,
    List<ThirdPartyChildEntry>? children,
    List<ExtraStatusBit>? extraBits,
  })  : children =
            children != null ? List<ThirdPartyChildEntry>.of(children) : [],
        extraBits =
            extraBits != null ? List<ExtraStatusBit>.of(extraBits) : [],
        runningColor = runningColor ?? AssetColor.green,
        // Grey, not red: stopped is a normal state on this line, and red is
        // reserved for something actually being wrong. The unknown state stays
        // tellable from stopped by the `!` glyph LEDPainter adds.
        stoppedColor = stoppedColor ?? AssetColor.grey,
        outlineColor = outlineColor ?? AssetColor.secondary {
    textPos = TextPos.below;
    // These machines are wide; the BaseAsset 3%×3% default would squash the
    // top view into an unreadable stamp. `fromJson` assigns `..size` after the
    // constructor, so persisted sizes still win.
    size = const RelativeSize(width: 0.16, height: 0.10);
  }

  /// Palette preview. Multivac by default, so no children are built — a
  /// SpeedBatcher picked from the dropdown gets its station scaffolded there.
  ThirdPartyEquipmentConfig.preview() : this();

  /// A SpeedBatcher complete with its two conveyors and their readouts.
  ///
  /// The station is only meaningful with them: each checkweigher IS a
  /// conveyor, and the weight and accept rate are why it is on the mimic at
  /// all. Keys start empty for the operator to fill in.
  factory ThirdPartyEquipmentConfig.speedBatcherStation({
    int acceptWindowMinutes = 30,
    bool acceptBarsClockAligned = true,
  }) {
    final config = ThirdPartyEquipmentConfig(
      kind: ThirdPartyEquipmentKind.speedBatcher,
      acceptWindowMinutes: acceptWindowMinutes,
      acceptBarsClockAligned: acceptBarsClockAligned,
    );
    config.children.addAll(buildSpeedBatcherStationChildren(
      acceptWindowMinutes: acceptWindowMinutes,
      acceptBarsClockAligned: acceptBarsClockAligned,
    ));
    return config;
  }

  factory ThirdPartyEquipmentConfig.fromJson(Map<String, dynamic> json) =>
      _$ThirdPartyEquipmentConfigFromJson(json)..applyAcceptReadoutSettings();

  /// Pushes the station's accept-rate settings down onto its readouts.
  ///
  /// Stations placed before the presets fix persisted the RatioNumber default
  /// ([1, 5, 10, 60, 240]), which does not contain 30 — so the chart opened on
  /// a window none of its toggles could show. Repaired on load rather than by
  /// a migration script: the parent owns these children, and "the window the
  /// figure is quoted over is offerable" is an invariant of the station, not a
  /// one-off data fix. Only ADDS the window; a preset list someone widened by
  /// hand is left alone otherwise.
  ///
  /// [acceptBarsClockAligned] is pushed down the same way, which is why it is
  /// a station setting: editing it on one checkweigher's readout would be
  /// overwritten here on the next load, and the two must match anyway.
  void applyAcceptReadoutSettings() {
    for (final entry in children) {
      final child = entry.child;
      if (child is! RatioNumberConfig) continue;
      child.barsClockAligned = acceptBarsClockAligned;
      // Not a station setting: a count is a whole number on every machine.
      child.integersOnly = true;
      if (acceptWindowMinutes <= 0) continue;
      if (child.intervalPresets.contains(acceptWindowMinutes)) continue;
      child.intervalPresets = [...child.intervalPresets, acceptWindowMinutes]
        ..sort();
    }
  }

  @override
  Map<String, dynamic> toJson() => _$ThirdPartyEquipmentConfigToJson(this);

  /// Own run key plus every key reachable through the children.
  ///
  /// `BaseAsset.allKeys` introspects `toJson()` and would only see the nested
  /// children as opaque maps, so a conveyor placed inside the box would be
  /// invisible to key discovery. Insertion order is preserved: parent first,
  /// then children in declaration order.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get allKeys => <String>{
        ...super.allKeys,
        if (statusKey.isNotEmpty) ...[
          for (final bit in kEquipmentStatusBits[kind] ?? const [])
            '$statusKey.${bit.suffix}',
          // Subscribed but never DRAWN, so they appear in no bit list -- and a
          // key that is not discoverable here is a key an unused-key sweep
          // offers to delete out from under a live pane.
          if (kind == ThirdPartyEquipmentKind.boxErector) ...[
            '$statusKey.$kBoxErectorRunSuffix',
            '$statusKey.$kBoxErectorCommsSuffix',
          ],
        ],
        // The extra loose diodes read complete keys of their own, so they are
        // discoverable directly rather than through a prefix.
        for (final bit in extraBits)
          if (bit.key.isNotEmpty) bit.key,
        for (final key in children.expand((e) => e.child.allKeys)) key,
      }.toList();

  @override
  Widget build(BuildContext context) => ThirdPartyEquipment(config: this);

  @override
  Widget configure(BuildContext context) =>
      _ThirdPartyEquipmentConfigEditor(config: this);
}

/// Apply polarity inversion to a raw run bool.
///
/// `isRunning = invertRunPolarity ? !rawBool : rawBool`. Mirrors
/// `sensorIsActive` in `sensor.dart`.
bool thirdPartyIsRunning({
  required bool rawBool,
  required bool invertRunPolarity,
}) {
  return invertRunPolarity ? !rawBool : rawBool;
}

// ---------------------------------------------------------------------------
// Struct-backed status diodes
// ---------------------------------------------------------------------------

/// One diode of a machine whose handshake arrives as a single published
/// struct: which member feeds it and how it is presented.
///
/// Fills a `{m}` label template with the machine name and sentence-cases it.
///
/// The one copy of the rule for all three bit types ([StructStatusBit],
/// [EquipmentStatusBit], [ExtraStatusBit]) so a row reads the same wherever it
/// came from — the Multivac's outfeed permit is the SAME sentence as the box
/// erector's, and it stays that way because both render the same template
/// through here rather than each carrying its own prose.
///
/// The names are stored the way they read MID-sentence — "box erector",
/// "batch aligner", but "Multivac", which is a make and capitalised wherever it
/// falls. Some rows start with the name and some do not, so the first letter of
/// the FINISHED label is what gets capitalised, not the name. A template with
/// no `{m}` is returned as written, which is why the SpeedBatcher's labels are
/// unaffected.
String fillMachineLabel(String label, String machine) {
  final filled = label.replaceAll('{m}', machine);
  if (filled.isEmpty) return filled;
  return filled[0].toUpperCase() + filled.substring(1);
}

/// The counterpart to [EquipmentStatusBit], which addresses a bit by appending
/// a suffix to a key PREFIX. Which of the two a kind uses is decided by
/// [kStructStatusBits] and is a property of the PLC, not of the HMI: a machine
/// wrapped in a function block with an `hmi` struct member publishes one node
/// carrying every bit, while a machine whose permits are plain globals needs
/// one key each.
class StructStatusBit {
  /// Member name inside the [ThirdPartyEquipmentConfig.statusKey] struct.
  final String member;

  /// Label template beside the diode. `{m}` is replaced with the machine's
  /// name, exactly as in [EquipmentStatusBit.label], so the two kinds of bit
  /// read identically down a pane.
  final String label;

  /// Diode colour when the bit is true, as a SCHEME ROLE rather than a literal.
  ///
  /// The app ships two colour schemes and `AppColorScheme.muted` follows
  /// ISA-101's gray-first guidance; a hardcoded `Colors.green` ignores the
  /// operator's choice and paints a saturated Material green next to muted
  /// everything-else. Resolved per build through [HmiColorRole.resolve], the
  /// same way `sensor.dart` resolves its active/inactive colours.
  final HmiColorRole onRole;

  const StructStatusBit(this.member, this.label, this.onRole);

  /// [label] with the machine name filled in, sentence-cased — see
  /// [fillMachineLabel], which every bit type shares.
  String labelFor(String machine) => fillMachineLabel(label, machine);
}

/// An extra loose status diode an asset instance declares, read from a COMPLETE
/// HMI key of its own rather than a struct member or a suffix under
/// [ThirdPartyEquipmentConfig.statusKey].
///
/// Unlike [StructStatusBit] and [EquipmentStatusBit], this is per-asset config
/// (it lives on the instance, not in a per-kind table) and its [key] is a whole
/// key read directly — the Multivac's outfeed permit is `MVC0n.PermitOutfeed`,
/// a different namespace from its struct `statusKey` (`SPB0n.multivac`), so it
/// cannot be reached by appending a suffix.
///
/// The KEY is the only genuinely new thing here. The [label] is the same `{m}`
/// template the other two bit types carry, rendered through the same
/// [fillMachineLabel] — so the Multivac's outfeed permit is written
/// `'{m} may send boxes on'`, character-for-character the box erector's entry in
/// [kEquipmentStatusBits] and the strapping line's `p_stat_OutfeedPermitted`,
/// and comes out "Multivac may send boxes on".
/// Deliberately NOT free prose: this label is typed once per line (MVC01,
/// MVC02, MVC03), so free text is three chances to misspell an operator-facing
/// sentence and three places that go stale if the shared wording is ever
/// reworded.
@JsonSerializable()
class ExtraStatusBit {
  /// The full HMI key to read, e.g. `"MVC02.PermitOutfeed"`. A complete key,
  /// NOT a suffix of [ThirdPartyEquipmentConfig.statusKey].
  final String key;

  /// Label template beside the diode, e.g. `'{m} may send boxes on'`. `{m}`
  /// is replaced with the machine's name exactly as in [EquipmentStatusBit] and
  /// [StructStatusBit], so an extra row reads identically to the kind's own.
  final String label;

  /// Diode colour when the bit is true, as a scheme ROLE. See
  /// [StructStatusBit.onRole] for why this is a role and not a literal.
  ///
  /// GREEN by default, because that is what a permit is across this file: the
  /// strapping line's `p_stat_InfeedPermitted` and `p_stat_OutfeedPermitted`
  /// and the box erector's `PermitInfeed`/`PermitOutfeed` are all green. Red is
  /// reserved for `WaitingFrustration`, and yellow/blue mark the Multivac's
  /// handshake PROGRESSION (waiting to drop, drop complete) rather than
  /// permission.
  ///
  /// YELLOW is what the box erector's two carton-chute rows use — "waiting on
  /// something; the cycle is stalled but healthy", the same yellow a belt in
  /// manual gets. They are extra bits rather than kind rows because only BER01
  /// has those sensors; see [kEquipmentStatusBits].
  @JsonKey(unknownEnumValue: HmiColorRole.green)
  final HmiColorRole onRole;

  const ExtraStatusBit({
    required this.key,
    required this.label,
    this.onRole = HmiColorRole.green,
  });

  /// [label] with the machine name filled in, sentence-cased — see
  /// [fillMachineLabel], which every bit type shares.
  String labelFor(String machine) => fillMachineLabel(label, machine);

  factory ExtraStatusBit.fromJson(Map<String, dynamic> json) =>
      _$ExtraStatusBitFromJson(json);

  Map<String, dynamic> toJson() => _$ExtraStatusBitToJson(this);
}

/// The five handshake bits, in display order. Same members and colours as the
/// retired flat SpeedBatcher asset (`speedbatcher.dart`); two labels reworded
/// to match the other machines' panes -- "Drop Ok from PLC" was the
/// engineer's phrase for the same bit the Multivac pane calls "ready for
/// fish", and "Dropped Batch" sat beside "Batch ready" as a dangling fragment.
/// Blue for Cleaning, green for the rest.
const List<StructStatusBit> speedBatcherStatusBits = [
  // No `p_stat_Running` row. The header badge directly above it is built from
  // that same member by [speedBatcherPaneStatus], and the machine on the page
  // carries the run LED -- so the pane stated one bit three times. Dropped for
  // the same reason the box erector's `Running` row was; leaving it here would
  // have fixed one machine and left the duplication on the one beside it.
  //
  // The member is NOT unsubscribed. This kind reads its whole handshake from
  // one struct node, so the badge keeps reading `p_stat_Running` at no cost.
  //
  // `Cleaning` STAYS. It is a mode, not a run state: it says WHY the machine is
  // not producing, and it is the row that separates a deliberate stop from a
  // fault.
  StructStatusBit('p_stat_Cleaning', 'Cleaning', HmiColorRole.blue),
  StructStatusBit('p_stat_BatchReady', 'Batch ready', HmiColorRole.green),
  StructStatusBit('p_stat_DropOk', 'Conveyor may drop', HmiColorRole.green),
  StructStatusBit('p_stat_Dropped', 'Batch dropped', HmiColorRole.green),
];

/// The strapping line's handshake, as published by `FB_StrappingLine` in
/// `ST_StrappingLine_HMI` (PLC commit "Strapping lina kominn inn").
///
/// Member names are the struct's, not the old `PermitInfeed`/`PermitOutfeed`
/// suffixes this kind used while its permits were plain globals -- the FB
/// spells them `p_stat_InfeedPermitted`/`p_stat_OutfeedPermitted`. The
/// vocabulary and colours are deliberately unchanged from that suffix list, so
/// a strapper pane reads the same as before against the new source.
///
/// `p_stat_WaitingFrustration` is new and has no prefix-era equivalent: the FB
/// raises it once the line has been running with a clear way out but a blocked
/// infeed for 15 s. Red and first -- it is the one bit that says something is
/// wrong rather than reporting where in the cycle the machine sits.
///
/// Its label names the STRAPPER as the cause, not a place product is being
/// released TO. The two readings invert who is at fault, and this one is the
/// operator's: everything upstream is ready and the machine is what is holding
/// the line up. The Multivac now takes the SAME reading: [multivacStatusBits]
/// reuses its `p_stat_WaitingFrustration` member with this exact "{m} is
/// stopping the line" wording, and the PLC is being changed so that bit is
/// raised when the Multivac ITSELF is the holdup (matching the strapper),
/// retiring the old "Waiting too long to release to Multivac" reading that
/// blamed the upstream release.
///
/// Short on purpose. It sits above four rows that each name the machine and a
/// condition, and a red row that has to be read to the end before it says
/// anything is wrong is a red row doing half its job.
///
/// The two heads come out of the same subscription: `p_stat_StrappingMachines`
/// is an `ARRAY [1..2] OF ST_StrapX`, and the path syntax indexes into it. The
/// labels count from 1 for the operator even though the Dart list is 0-based --
/// see [structMemberPath].
///
/// Each head also carries `p_stat_Err`, which is the same signal latched after
/// 15 s not-ready. It is deliberately NOT drawn: four rows saying almost the
/// same thing is the redundancy this pane just lost, and the ready bit already
/// tells the operator which head is holding the line. Adding it later is one
/// line, with no new key.
///
/// The struct carries more still -- the last sensor's full `FB_Sensor` and a
/// TIME since infeed was last permitted -- likewise free to add.
const List<StructStatusBit> strappingLineStatusBits = [
  StructStatusBit('p_stat_WaitingFrustration', '{m} is stopping the line',
      HmiColorRole.red),
  StructStatusBit('p_stat_StrappingMachines[0].p_stat_Rdy', 'StrapX 1 ready',
      HmiColorRole.green),
  StructStatusBit('p_stat_StrappingMachines[1].p_stat_Rdy', 'StrapX 2 ready',
      HmiColorRole.green),
  StructStatusBit(
      'p_stat_InfeedPermitted', '{m} is ready for box', HmiColorRole.green),
  // "{m} may send boxes on" -- and this is now the ONE sentence for this bit
  // everywhere: the box erector's `PermitOutfeed` and any instance-level outfeed
  // key (the Multivac's `MVC0n.PermitOutfeed`) say the same thing, because it is
  // the same bit under three different PLC names.
  //
  // Deliberately not "way out is clear": that reads as an observation about
  // physical clearance, and the bit is a PERMISSION -- one travelling the
  // opposite way to the row above it. Infeed is the machine telling us it can
  // take a box; outfeed is us telling the machine it may pass one on, wired
  // straight out to ECT.ST101_RM01.O2. Naming both after the machine keeps the
  // pair readable as the two questions an operator actually has: can it take
  // one, can it pass one on.
  StructStatusBit(
      'p_stat_OutfeedPermitted', '{m} may send boxes on', HmiColorRole.green),
];

/// The Multivac's handshake, as published by the `hmi` member the PLC now
/// wraps it in: `SPB0n.multivac.hmi` is an `SP_Packing_HMI` (the same FB the
/// packing station uses), carrying `p_stat_Run`, `p_stat_DropRequest`,
/// `p_stat_DropRequestFeedback`, `p_stat_DropOk`, `p_stat_DropFinished` and
/// `p_stat_WaitingFrustration`. This is the same move the strapping line made
/// with `ST_StrappingLine_HMI`: the permits that used to be separate globals
/// (read via the prefix-plus-suffix list this kind carried in
/// [kEquipmentStatusBits]) now arrive as one struct node, at one subscription.
///
/// Ordered to mirror [strappingLineStatusBits]: the red "stopping the line" bit
/// first, then ready -> in-progress -> done. Only four of the six members are
/// drawn -- `p_stat_Run` feeds the run LED/badge, and `p_stat_DropRequest` is
/// the raw upstream ask whose acknowledged form (`p_stat_DropRequestFeedback`)
/// is the one worth a diode.
///
/// `p_stat_WaitingFrustration` is deliberately REUSED for the stopping-line row
/// (Option A): its old prefix-era label blamed the upstream release ("Waiting
/// too long to release to Multivac"); it is relabelled here to name the
/// Multivac itself as the holdup, matching the strapper. The PLC is being
/// updated so the bit is raised on that new meaning -- see the note on
/// [strappingLineStatusBits].
const List<StructStatusBit> multivacStatusBits = [
  StructStatusBit(
      'p_stat_WaitingFrustration', '{m} is stopping the line', HmiColorRole.red),
  StructStatusBit('p_stat_DropOk', '{m} is ready for fish', HmiColorRole.green),
  StructStatusBit('p_stat_DropRequestFeedback', 'Fish waiting to drop to {m}',
      HmiColorRole.yellow),
  StructStatusBit(
      'p_stat_DropFinished', 'Drop to {m} is complete', HmiColorRole.green),
];

/// The batch aligner's (vodlari) handshake, published exactly like the
/// Multivac's: the PLC exposes it as an `hmi` member — `SPB0n.packing.hmi`, an
/// `SP_Packing_HMI` struct (the same FB the packing station and the Multivac
/// use), carrying `p_stat_Run`, `p_stat_DropRequest`,
/// `p_stat_DropRequestFeedback`, `p_stat_DropOk`, `p_stat_DropFinished` and
/// `p_stat_WaitingFrustration`. So the aligner makes the SAME move the Multivac
/// and the strapping line made: the permits that used to be separate globals
/// (read via the prefix-plus-suffix list this kind carried in
/// [kEquipmentStatusBits]) now arrive as one struct node, at one subscription.
///
/// Identical in shape/order to [multivacStatusBits] — the two read the same
/// `SP_Packing_HMI` struct — with the red "stopping the line" bit first, then
/// ready -> in-progress -> done. Only four of the six members are drawn:
/// `p_stat_Run` feeds the run LED/badge, and `p_stat_DropRequest` is the raw
/// upstream ask whose acknowledged form (`p_stat_DropRequestFeedback`) is the
/// one worth a diode.
///
/// `p_stat_WaitingFrustration` is deliberately REUSED for the stopping-line row
/// (Option A): its old prefix-era label blamed the upstream release ("Waiting
/// too long to release to batch aligner"); it is relabelled here to name the
/// aligner itself as the holdup, matching the strapper and the Multivac. The
/// PLC is being updated so the bit is raised on that new meaning -- see the
/// note on [strappingLineStatusBits].
const List<StructStatusBit> fishAlignerStatusBits = [
  StructStatusBit(
      'p_stat_WaitingFrustration', '{m} is stopping the line', HmiColorRole.red),
  StructStatusBit('p_stat_DropOk', '{m} is ready for fish', HmiColorRole.green),
  StructStatusBit('p_stat_DropRequestFeedback', 'Fish waiting to drop to {m}',
      HmiColorRole.yellow),
  StructStatusBit(
      'p_stat_DropFinished', 'Drop to {m} is complete', HmiColorRole.green),
];

/// The kinds whose [ThirdPartyEquipmentConfig.statusKey] names a struct node
/// rather than a key prefix, and the members each draws.
///
/// A kind belongs in exactly one of this map and [kEquipmentStatusBits];
/// membership here means one subscription for the whole handshake instead of
/// one per bit.
/// Whether the box erector's Modbus link to the Saia machine is healthy.
///
/// Reads [kBoxErectorCommsSuffix] out of the per-bit value map the pane already
/// keeps — the same map the diodes read, so the gate costs one more key off the
/// same prefix and no new subscription machinery.
///
/// `null` when the key is absent — BER02/BER03, whose `ModbusHealthy` is not
/// mapped, or nothing received yet — which must NOT gate anything: an unknown
/// link is not a failed one.
///
/// This bit is the validity of every other row on the pane. `FB_BER01ScadaPoll`
/// polls a Saia PCD3.M3160 over Modbus TCP and decodes its alarm word (R998)
/// and process word (R1000) UNCONDITIONALLY:
///
///     p_stat_xAlmEstop   := p_stat_dwAlarmWord.1;
///     p_stat_xModeManual := p_stat_dwProcessWord.1;
///
/// Those words are only written on a successful read, so when the link drops
/// every decoded bit FREEZES at its last value. Nothing upstream notices:
/// `p_stat_xComOk` falls after a 2 s TOF and our own OPC UA subscription to
/// ST101 stays perfectly healthy, so the pane would keep receiving values and
/// keep showing a confident "Running" for a machine we have lost contact with.
/// Hence the gate — the same "unknown beats a stale latch" rule the run stream
/// already follows.
bool? boxErectorCommsOf(Map<String, bool?> statusBits) =>
    statusBits[kBoxErectorCommsSuffix];

/// Series name for the box erector's throughput trend, fixed so the pane
/// preview and the floating chart read as the same chart — mirrors
/// `kSensorTrendSeries` / `kConveyorFreqSeries`.
const String kBoxErectorBpmSeries = 'Cartons/min';

/// `Colors.blue`, and NOT `SolarizedColors.blue`, which this used to be.
///
/// Every other trend on this HMI draws its primary trace in `Colors.blue` --
/// `conveyorTrendColors[kConveyorFreqSeries]`, `sensorTrendColors`, the analog
/// box's `{seriesLabel: Colors.blue}`. A second, darker blue for this one chart
/// is the kind of near-match that reads as a different product when two panes
/// are open side by side, which is exactly what was reported.
const Map<String, Color> boxErectorBpmColors = {
  kBoxErectorBpmSeries: Colors.blue,
};

/// Whether the throughput trend can be drawn — i.e. whether the cartons-per-
/// minute key is being COLLECTED.
///
/// A diode's history is nobody's business, but a rate's is the whole point, and
/// history only exists if the collector was told to store this key. Without an
/// entry the table has no rows at all, so the pane offers no Trend section
/// rather than an empty chart.
///
/// One [CollectEntry] for the key is enough now. It used to also have to carry
/// [kBoxErectorBpmMember] in `sample_members`, because the number lived three
/// levels inside the status struct; a plain numeric key needs no pick.
bool boxErectorBpmTrendAvailable(CollectEntry? collect) => collect != null;

/// The y axis every cartons-per-minute plot is drawn on.
///
/// Extracted rather than spelled inline so the two decisions it encodes have
/// somewhere to be asserted: the axis labels are painted onto the chart canvas,
/// not into `Text` widgets, so a widget test cannot read them back and a golden
/// is the only other witness.
///
/// `min: 0` — this is a rate, and a chart that rescales its baseline turns a
/// small dip into an apparent stoppage.
///
/// `decimals: 0` — cartons come out one at a time, so "12.8 cartons/min" on a
/// gridline is a precision the machine does not have, and in the compact tile
/// those two extra characters are the widest thing in the left gutter. Only the
/// LABELS are rounded; the trace still carries its fractional value, and so does
/// the tooltip.
///
/// NOT `integersOnly`, which is the other way to ask for this and is wrong here.
/// That one moves the GRIDLINES onto whole numbers, and our y ticks are spread
/// evenly across the data range rather than snapped to round numbers — so the
/// 15-minute preview, short enough to get only two of them, had a rounded step
/// wider than the range itself and dropped its top label. The axis came back
/// reading `0` and nothing else.
///
/// [compact] drops the unit, because the pane tile's header names the chart and
/// the preview has no width to spend on repeating it.
GraphAxisConfig boxErectorBpmYAxis({required bool compact}) => GraphAxisConfig(
      unit: compact ? '' : 'Cartons/min',
      min: 0,
      decimals: 0,
    );

/// The box erector's throughput over time, off the collector's stored rows.
///
/// Numeric rather than the sensor trend's boolean axis: this is a rate, so the
/// y axis carries a unit and starts at zero — a cartons/min plot that autoscales
/// its floor makes a small dip look like a stoppage.
class BoxErectorBpmGraph extends ConsumerWidget {
  final Collector? collector;
  final String keyName;

  /// Pan/zoom/now buttons. Off in the pane preview, on in the floating chart.
  final bool showButtons;

  final Duration xSpan;

  /// Drops the axis units/labels — the small pane preview has no room and the
  /// tile caption names the chart instead.
  final bool compact;

  /// A FIXED x window, replacing the rolling one [xSpan] describes.
  ///
  /// Null in production, and meant to stay that way: a live trend belongs on a
  /// window that ends now, and [Graph] builds that from `DateTime.now()` on
  /// every rebuild.
  ///
  /// That wall clock is exactly what a golden cannot have. The chart prints
  /// absolute times along the bottom, so two runs a second apart produce
  /// different pixels and the image churns forever — the failure mode this repo
  /// has already been bitten by. Handing in a fixed range is the smallest seam
  /// that makes the trace goldenable; [Graph] already prefers `xRange` over
  /// `xSpan`, so nothing new had to be taught to read it.
  @visibleForTesting
  final DateTimeRange? xRange;

  const BoxErectorBpmGraph({
    required this.collector,
    required this.keyName,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 15),
    this.compact = false,
    this.xRange,
    super.key,
  });

  /// One stored row → one point. The key is a plain numeric one, so the value
  /// IS the rate; it crosses the collector boundary as a num or as a numeric
  /// string depending on the column type. Mirrors `_pointOf` in `sensor.dart`
  /// — same boundary, same shapes.
  ///
  /// Anything else is DROPPED rather than coerced. `asDouble` would turn a
  /// non-numeric row into 0.0, and 0 on this chart is a real reading meaning
  /// the line has stopped.
  num? _pointOf(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<TimeseriesData<dynamic>>>(
      stream: collector?.collectStream(keyName, since: const Duration(hours: 2)),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No data'));
        }

        final data = <Map<String, dynamic>>[
          for (final sample in snapshot.data!)
            if (_pointOf(sample.value) case final num y)
              {
                'x': sample.time.millisecondsSinceEpoch.toDouble(),
                'y': y,
                's': kBoxErectorBpmSeries,
              },
        ];
        if (data.isEmpty) {
          // Rows exist but none parsed as a number — the key is collected but
          // is not the rate we think it is. Say so rather than draw an empty
          // frame, which reads as "the line has stopped".
          return const Center(child: Text('Not collected'));
        }

        final graphConfig = GraphConfig(
          type: GraphType.timeseries,
          xAxis: GraphAxisConfig(unit: compact ? '' : 'Time'),
          yAxis: boxErectorBpmYAxis(compact: compact),
          // A fixed [xRange] wins over the rolling span — see the field.
          xSpan: xRange == null ? xSpan : null,
          xRange: xRange,
          // Off in the tile -- the [PaneGraphTile] header names the series
          // instead, which costs a text row rather than a column of the plot's
          // width -- and ON in the floating chart, where there is room for it.
          // Exactly what `ConveyorStatsGraph`, `SensorTrendGraph` and the
          // analog box's trend all do; this one alone said a flat `false`, so
          // the expanded chart was the only trend on the HMI with no legend.
          legend: !compact,
        );

        // The single-axis compact gutters, shared with the analog box's numeric
        // trend. This used to borrow the SENSOR's `kSensorTrendCompactPadding`,
        // whose 48 px left gutter exists to fit the words "False" and "True";
        // a cartons/min axis prints bare numbers, so the plot was indented
        // 14 px further than the conveyor's for no reason a reader could see.
        final theme = compact
            ? (Theme.of(context).brightness == Brightness.dark
                ? darkChartTheme(padding: kCompactChartPaddingSingleAxis)
                : lightChartTheme(padding: kCompactChartPaddingSingleAxis))
            : ref.watch(chartThemeNotifierProvider);

        return Graph(
          config: graphConfig,
          data: data,
          showButtons: showButtons,
          categoryColors: boxErectorBpmColors,
          chartTheme: theme,
          redraw: () {},
        ).build(context);
      },
    );
  }
}

/// Resolves the collector for [BoxErectorBpmGraph] — mirrors
/// `SensorTrendGraphLoader`.
class BoxErectorBpmGraphLoader extends ConsumerWidget {
  final String keyName;
  final bool showButtons;
  final Duration xSpan;
  final bool compact;

  const BoxErectorBpmGraphLoader({
    required this.keyName,
    this.showButtons = true,
    this.xSpan = const Duration(minutes: 15),
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Collector?>(
      future: ref.watch(collectorProvider.future),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return BoxErectorBpmGraph(
          collector: snapshot.data,
          keyName: keyName,
          showButtons: showButtons,
          xSpan: xSpan,
          compact: compact,
        );
      },
    );
  }
}

/// The box erector's Trend tile -- the SAME tile the conveyor's drive pane
/// draws, with a different trace in it.
///
/// Extracted from `_trendSection` so there is one object a test can compare
/// against [conveyorTrendTile] field by field. The report this answers is that
/// the two panes did not look like the same product, and a pair of tiles
/// hand-tuned in two files to resemble each other is how that happens again in
/// six months: every presentation decision here is either a shared constant
/// ([kPaneTrendTileHeight], [kPaneTrendDialogSize]) or spelled the same way in
/// [conveyorTrendTile], and `pane_trend_parity_test.dart` fails if one of them
/// drifts.
///
/// The one difference that is NOT drift is the span. The conveyor's preview
/// shows five minutes because a drive's frequency changes second to second;
/// this key is a one-minute rolling average of finished cartons, so five
/// minutes is five points and reads as a scribble. Fifteen is what makes the
/// same SHAPE of chart legible for this quantity -- the window is a fact about
/// the data, not about the drawing.
PaneGraphTile boxErectorBpmTrendTile({required String keyName}) =>
    PaneGraphTile(
      // The trace is named in the tile header, where naming it costs a text
      // row instead of a column of the plot's width. The conveyor's tile has
      // done this since #384; this one had an EMPTY header -- a caption row
      // holding nothing but the size-up glyph -- which was the most visible
      // half of "the look is not the same".
      legend: boxErectorBpmColors,
      height: kPaneTrendTileHeight,
      preview: BoxErectorBpmGraphLoader(
        keyName: keyName,
        showButtons: false,
        compact: true,
        xSpan: const Duration(minutes: 15),
      ),
      expandedTitle: 'Cartons per minute',
      expandedSize: kPaneTrendDialogSize,
      expandedBuilder: (context) => BoxErectorBpmGraphLoader(
        keyName: keyName,
        xSpan: const Duration(hours: 1),
      ),
    );

/// One colour vocabulary across every machine, so a glance down any Status
/// column means the same thing:
///
///   RED    -- something is wrong. Reserved for the frustration/fault rows.
///   YELLOW -- waiting on something; the cycle is stalled but healthy.
///   GREEN  -- yes, now. Every PERMIT is green, on every machine.
///   BLUE   -- a deliberate non-production state. Cleaning, and only that.
///
/// GREEN covers the whole "this is fine, it happened" side: a permit, a machine
/// running, and a hand-over that completed. `p_stat_DropFinished` was blue for a
/// while on the reading that a finished drop is its own kind of event; it is
/// simply good news, and good news is green.
///
/// The green rule is the load-bearing one and was arrived at the hard way: the
/// box erector's outfeed permit used to be blue, on a "blue the outfeed side"
/// comment that the code never actually kept (the strapping line's
/// `p_stat_OutfeedPermitted` was already green), so the column did NOT read the
/// same across machines -- the only thing that rule was for. See #382.
const Map<ThirdPartyEquipmentKind, List<StructStatusBit>> kStructStatusBits = {
  ThirdPartyEquipmentKind.multivac: multivacStatusBits,
  ThirdPartyEquipmentKind.speedBatcher: speedBatcherStatusBits,
  ThirdPartyEquipmentKind.strappingLine: strappingLineStatusBits,
  ThirdPartyEquipmentKind.fishAligner: fishAlignerStatusBits,
};

/// Whether this kind reads its whole handshake from one struct node. The
/// routing question everywhere except the Status section itself.
bool isStructBacked(ThirdPartyEquipmentKind kind) =>
    kStructStatusBits.containsKey(kind);

/// Whether this kind publishes ANY handshake the Status section can read —
/// struct or prefix.
///
/// False for a machine the PLC does not talk to at all. The Optimar
/// palletising row is the first of those: it is on the mimic so the operator
/// can see it, and the run LED is fed by whatever contact the row offers, but
/// there is no permit vocabulary to point a status key at. A false here means
/// the editor offers no status key — a field feeding nothing is worse than no
/// field — and the pane draws no Status section unless the instance declares
/// its own [ExtraStatusBit]s, which read complete keys of their own.
bool hasStatusTable(ThirdPartyEquipmentKind kind) =>
    isStructBacked(kind) || kEquipmentStatusBits.containsKey(kind);

/// Every member this kind's Status section reads, in display order — for the
/// editor's help text and for tests.
///
/// Empty for a prefix-backed kind, which has no members: the box erector reads
/// one key per signal, and the editor names its SUFFIXES instead.
List<String> structMembersOf(ThirdPartyEquipmentKind kind) => [
      for (final b in kStructStatusBits[kind] ?? const <StructStatusBit>[])
        b.member,
    ];

/// The machine's name as it reads inside a diode label.
///
/// Shorter than [ThirdPartyEquipmentKindInfo.label], which carries the make
/// ("Afak / StrapX strapping line") -- a row saying "Fish waiting to drop to
/// Afak / StrapX strapping line" is worse than useless.
String equipmentShortName(ThirdPartyEquipmentKind kind) => switch (kind) {
      ThirdPartyEquipmentKind.multivac => 'Multivac',
      ThirdPartyEquipmentKind.speedBatcher => 'SpeedBatcher',
      ThirdPartyEquipmentKind.boxErector => 'box erector',
      ThirdPartyEquipmentKind.strappingLine => 'strapping machine',
      ThirdPartyEquipmentKind.fishAligner => 'batch aligner',
      ThirdPartyEquipmentKind.optimarPalletiser => 'palletising station',
    };

/// One diode in a non-SpeedBatcher machine's Status section.
///
/// [suffix] is appended to the asset's [ThirdPartyEquipmentConfig.statusKey],
/// which for these kinds holds a key PREFIX rather than a struct node. A kind
/// can read members out of one struct only once the PLC wraps it in a function
/// block with an `hmi` member — the SpeedBatcher's `SP_HMI`, the strapper's
/// `ST_StrappingLine_HMI`. The machines still here expose their permits as
/// separate global bools (`BER02.PermitOutfeed`), so the prefix plus a fixed
/// suffix list is the closest equivalent, at one subscription per bit. Moving
/// one of them across is a PLC change first, then a line in
/// [kStructStatusBits].
class EquipmentStatusBit {
  final String suffix;

  /// Label template. `{m}` is replaced with the machine's name, so a row reads
  /// "Fish waiting to drop to Multivac" rather than "Fish waiting to drop" --
  /// the pane is one of several open at once and a bare label leaves the
  /// operator working out which machine it belongs to.
  final String label;

  /// Diode colour when the bit is true, as a scheme role. See
  /// [StructStatusBit.onRole] for why this is not a literal.
  final HmiColorRole onRole;
  const EquipmentStatusBit(this.suffix, this.label, this.onRole);

  /// [label] with the machine name filled in, sentence-cased — see
  /// [fillMachineLabel], which every bit type shares.
  String labelFor(String machine) => fillMachineLabel(label, machine);
}

/// The prefix-backed kinds and the diodes each shows, in display order.
///
/// The box erector is the one entry, and deliberately so. Every other machine
/// on the site is wrapped in a function block that publishes its whole
/// handshake as one struct node, so they read out of [kStructStatusBits] at one
/// subscription each. The erector reads ONE KEY PER PLC MEMBER instead: the
/// four suffixes below are appended to [ThirdPartyEquipmentConfig.statusKey],
/// giving `BER01.Running`, `BER01.WaitingFrustration` and the two permits.
///
/// Four keys instead of one is a real cost, paid for a real thing: each is a
/// mapping an engineer can point at, rename and collect on its own, and adding
/// a fifth signal is a mapping rather than a change to this file. The struct
/// route bought one subscription and charged for it in coupling -- every member
/// name pinned here against a `.TcPOU`, and a rename in the PLC rendering a
/// grey `!` that is indistinguishable from "not rolled out yet".
///
/// Suffixes are the HMI's vocabulary, not the PLC's: `Running`, not
/// `p_stat_xRunning`. They continue the naming this kind used before the struct
/// FB (`BERnn.PermitOutfeed`, `BERnn.WaitingFrustration`), so the mappings that
/// already exist keep reading.
///
/// THREE rows now, not four: `Running` moved to [kBoxErectorRunSuffix] --
/// still subscribed, still discoverable, no longer a diode, because the pane
/// header and the machine's run LED already say it.
///
/// Three rows, not six. The two carton-chute rows are per-instance
/// [ExtraStatusBit]s rather than entries here -- see
/// [ThirdPartyEquipmentConfig.extraBits]. They belong there because they are
/// not a property of the KIND: BER01's chutes are sensed, BER02/BER03's are
/// not, and a kind-level row would draw two permanently grey diodes on two of
/// the three machines. Declared per instance, they appear only where they are
/// wired, and the editor already offers key, `{m}` label template and colour.
///
/// THREE more suffixes ride this same prefix without being diodes:
/// [kBoxErectorRunSuffix] feeds the header badge and the run LED,
/// [kBoxErectorCommsSuffix] gates the pane, and [kBoxErectorBpmSuffix] feeds
/// the trend.
///
/// Wording is shared, not reinvented. `PermitOutfeed` carries the exact
/// sentence the strapper's `p_stat_OutfeedPermitted` and the Multivac's loose
/// `MVC0n.PermitOutfeed` carry -- it is the same handshake under a third name.
/// The infeed row says "product", not "box": what the Multivac hands the
/// erector is bagged product, and the cartons are what the erector MAKES.
const Map<ThirdPartyEquipmentKind, List<EquipmentStatusBit>>
    kEquipmentStatusBits = {
  ThirdPartyEquipmentKind.boxErector: [
    // No `Running` row. It said what the pane's own header badge and the
    // machine's run LED on the page already say, and this pane was cut to six
    // rows on purpose -- a duplicate is the cheapest of the six to lose. The
    // KEY is untouched: still subscribed, still in [allKeys], still feeding the
    // badge, through [kBoxErectorRunSuffix] below.
    //
    // The same reading the struct-backed kinds already take -- see
    // [multivacStatusBits] and [fishAlignerStatusBits], whose `p_stat_Run` is
    // deliberately not drawn because it "feeds the run LED/badge".
    EquipmentStatusBit(
        'WaitingFrustration', '{m} is stopping the line', HmiColorRole.red),
    EquipmentStatusBit(
        'PermitInfeed', '{m} is ready for product', HmiColorRole.green),
    EquipmentStatusBit(
        'PermitOutfeed', '{m} may send boxes on', HmiColorRole.green),
  ],
};

/// The suffix carrying whether the machine is going: `BER01.Running`.
///
/// Subscribed, in [ThirdPartyEquipmentConfig.allKeys], and NOT drawn as a
/// diode. It used to be the first row of [kEquipmentStatusBits]; the row went
/// because it repeated the pane header and the machine's run LED, and the key
/// stayed because it is what those two are made of.
///
/// Moving it here rather than simply deleting the entry is the point. `allKeys`
/// composes the diode suffixes onto the prefix, so dropping the bit would have
/// dropped `BER01.Running` out of key discovery -- and an unused-key sweep
/// would then have offered to delete a live mapping. It rides the same
/// subscription map and the same teardown as [kBoxErectorCommsSuffix], at no
/// new machinery.
///
/// It also gives the header badge a source of its own -- see
/// [boxErectorPaneStatus]. Normally `runKey` names exactly this node and the
/// two agree; when it is unset, the pane now reads the machine anyway instead
/// of printing "No key" beside a signal it is already holding.
const String kBoxErectorRunSuffix = 'Running';

/// The suffix carrying whether the Saia is still answering, appended to the
/// same prefix as the diodes: `BER01.ModbusHealthy`.
///
/// Subscribed but never DRAWN. It is not a thing an operator acts on; it
/// decides whether anything else on the pane may be believed, so it is spent on
/// the banner and the header badge instead of a fifth lamp — see
/// [boxErectorCommsOf].
const String kBoxErectorCommsSuffix = 'ModbusHealthy';

/// The suffix carrying finished cartons per minute: `BER01.CartonsPerMinute`.
///
/// A plain numeric key off the same prefix, charted exactly like the conveyor's
/// frequency trend. It replaces a `sample_members` pick out of the status
/// struct (`bpmCartonsOut.hmi.avgBPM1Minute`, three levels into an `FB_BPM`
/// instance) — the collector now stores a number under a key, which is the
/// shape every other trend on this HMI already has.
const String kBoxErectorBpmSuffix = 'CartonsPerMinute';

/// The Status section body for the non-SpeedBatcher kinds.
///
/// A plain [StatelessWidget] fed a value per bit, exactly like
/// [StructStatusDiodes] -- NOT a ConsumerWidget reading
/// `keyStreamProvider` itself. The side pane is built into an overlay through
/// `showSidePane`, and a widget that reaches for `ref` from there is not on
/// the page's tree; the subscriptions belong to the parent state, which
/// outlives the pane and already owns the machine's other streams.
class EquipmentStatusDiodes extends StatelessWidget {
  const EquipmentStatusDiodes({
    super.key,
    required this.bits,
    required this.values,
    required this.machine,
  });

  final List<EquipmentStatusBit> bits;

  /// Name filled into each label's `{m}`.
  final String machine;

  /// Latest value per suffix. A missing entry renders unknown -- the same grey
  /// `!` a missing struct member gets on the SpeedBatcher.
  final Map<String, bool?> values;

  @override
  Widget build(BuildContext context) {
    // No rules between rows. Every OTHER third-party kind is struct-backed and
    // renders through [StructStatusDiodes], which draws plain rows; a hairline
    // here made the box erector the one machine whose Status section looked
    // different, and once an instance can append [ExtraStatusDiodes] to either
    // kind the split would have shown up INSIDE a single section. One rule for
    // all third-party devices, and the majority already had it.
    return Column(
      children: [
        for (final bit in bits) ...[
          PaneDetailRow(
            // The diode is a fixed 22 px against a label that wraps, so centre
            // it -- top-aligned it hangs off the first line of a two-line row.
            crossAxisAlignment: CrossAxisAlignment.center,
            label: bit.labelFor(machine),
            child: SizedBox(
              // 22 px for the same reason as the SpeedBatcher's: below this the
              // unknown state's `!` blurs into the off state.
              width: 22,
              height: 22,
              child: CustomPaint(
                painter: LEDPainter(
                  color: switch (values[bit.suffix]) {
                    null => null,
                    true => bit.onRole.resolve(context),
                    false => Colors.white,
                  },
                  ledType: LEDType.circle,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The extra loose diodes an instance declares, rendered after the kind's
/// normal Status diodes.
///
/// A plain [StatelessWidget] fed a value per key, exactly like
/// [EquipmentStatusDiodes] and [StructStatusDiodes] — the subscriptions belong
/// to the parent state, which outlives the overlay pane.
///
/// Labels come from [ExtraStatusBit.labelFor], the same `{m}` substitution the
/// other two use, so an extra row is indistinguishable from one of the kind's
/// own — which is the point. The operator is not meant to work out that this
/// bit arrived on a separate subscription in a different namespace.
///
/// Plain rows, no rules — the one style every third-party Status section uses,
/// so an extra row cannot be told from one of the kind's own.
class ExtraStatusDiodes extends StatelessWidget {
  const ExtraStatusDiodes({
    super.key,
    required this.bits,
    required this.values,
    required this.machine,
  });

  final List<ExtraStatusBit> bits;

  /// Name filled into each label's `{m}`.
  final String machine;

  /// Latest value per bit key. A missing entry renders unknown — the same grey
  /// `!` a missing struct member or an errored key gets.
  final Map<String, bool?> values;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final bit in bits) ...[
          PaneDetailRow(
            crossAxisAlignment: CrossAxisAlignment.center,
            label: bit.labelFor(machine),
            child: SizedBox(
              // 22 px for the same reason as the other diodes: below this the
              // unknown state's `!` blurs into the off state.
              width: 22,
              height: 22,
              child: CustomPaint(
                painter: LEDPainter(
                  color: switch (values[bit.key]) {
                    null => null,
                    true => bit.onRole.resolve(context),
                    false => Colors.white,
                  },
                  ledType: LEDType.circle,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Reads one handshake bit out of the status struct, degrading to unknown.
///
/// `null` — the unknown state — covers every way the bit can be absent: no
/// struct received yet, a non-struct value on the key, or a struct without
/// this member. The last one matters because `DynamicValue.operator[]` THROWS
/// on a missing member, and three of the five bits have never been confirmed
/// against the live PLC — a missing bit must render as the grey `!`, not take
/// the pane down.
bool? structStatusBitOf(DynamicValue? status, String member) {
  var cur = status;
  for (final segment in structMemberPath(member)) {
    // `contains` is the guard for both kinds of segment: false for a missing
    // object key, for an out-of-range index, and for an index into something
    // that is not an array. `operator[]` THROWS on every one of those, and a
    // bit the struct does not carry must render as the grey `!` rather than
    // taking the pane down.
    if (cur == null || !cur.contains(segment)) return null;
    cur = cur[segment];
  }
  return cur?.asBool;
}

/// Splits a member path into object keys and array indices.
///
/// `'p_stat_StrappingMachines[0].p_stat_Rdy'` becomes
/// `['p_stat_StrappingMachines', 0, 'p_stat_Rdy']`. The syntax mirrors an OPC
/// UA node id so a path can be checked against `browse_nodes` output by eye.
///
/// **The indices are 0-based, and the PLC's are not.** `ST_StrappingLine_HMI`
/// declares `ARRAY [1..2] OF ST_StrapX`, and the server's browse names keep
/// that: `p_stat_StrappingMachines[1]` is the FIRST head. Reading the struct
/// hands us a plain Dart list, so here the first head is index 0. The labels
/// are written for the operator and count from 1.
@visibleForTesting
Iterable<Object> structMemberPath(String member) sync* {
  for (final part in member.split('.')) {
    final open = part.indexOf('[');
    if (open < 0) {
      yield part;
      continue;
    }
    if (open > 0) yield part.substring(0, open);
    for (final m in RegExp(r'\[(\d+)\]').allMatches(part.substring(open))) {
      yield int.parse(m.group(1)!);
    }
  }
}

/// Resolves the pane's header badge from the handshake struct.
///
/// The run key alone cannot tell "stopped" from "cleaning": during a wash the
/// Running bit drops, and a runKey-only badge would claim Stopped while the
/// machine is busy rinsing — which is exactly the lie the badge existed to
/// avoid. Cleaning outranks Running because the struct can raise both at
/// once mid-cycle. When neither bit is readable — no struct yet, no status
/// key — the caller's runKey-derived [fallback] stands.
PaneStatus speedBatcherPaneStatus(DynamicValue? status, PaneStatus fallback) {
  if (structStatusBitOf(status, 'p_stat_Cleaning') == true) {
    // Blue to match the Cleaning diode below it.
    return const PaneStatus(
      label: 'Cleaning',
      color: Colors.blue,
      icon: Icons.cleaning_services,
    );
  }
  switch (structStatusBitOf(status, 'p_stat_Running')) {
    case true:
      return const PaneStatus.running();
    case false:
      return const PaneStatus.stopped();
    case null:
      return fallback;
  }
}

/// The box erector's header badge, from the run bit off its key prefix.
///
/// The fallback for a machine whose `runKey` is unset or has told us nothing.
/// [kBoxErectorRunSuffix] is already subscribed for exactly this, so a pane
/// holding the run bit should not print "No key" beside it.
///
/// A FALLBACK, deliberately, where [speedBatcherPaneStatus] is an OVERRIDE:
/// there the struct knows something the run key cannot say ("Cleaning"); here
/// the two are the same PLC variable and the run key is the one that carries
/// [ThirdPartyEquipmentConfig.invertRunPolarity]. So the configured key wins
/// whenever it has an answer.
PaneStatus boxErectorPaneStatus(
    Map<String, bool?> statusBits, PaneStatus fallback) {
  switch (statusBits[kBoxErectorRunSuffix]) {
    case true:
      return const PaneStatus.running();
    case false:
      return const PaneStatus.stopped();
    case null:
      return fallback;
  }
}

/// The banner shown above everything when the Modbus link is down.
///
/// Says what is wrong AND what it means for the rest of the pane, because a
/// bare "no link" leaves the operator to work out whether the rows below are
/// live. They are not: see [boxErectorCommsOf] for why every bit freezes rather
/// than going stale. The diodes below are already forced to the grey `!`, so
/// this explains a pane that has visibly gone blank.
///
/// Fault red — the one place this file uses a saturated colour, which is the
/// repo rule (only fault red may be saturated), and this qualifies: the pane is
/// not reporting the machine any more.
///
/// A top-level widget rather than a method on the state, for the same reason
/// [StructStatusDiodes] is one: a golden has to be able to render it without a
/// `StateMan`.
class CommsLostBanner extends StatelessWidget {
  const CommsLostBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final red = HmiStateColors.of(context).red;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.12),
        border: Border.all(color: red),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link_off, size: 18, color: red),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No Modbus link to the machine',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: red, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  'Nothing below is live — the box erector stopped answering '
                  'and these values are the last it sent.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Status section body: one diode row per handshake bit.
///
/// Split out as its own widget — same seam as [ThirdPartyEquipmentBody] — so
/// tests and goldens can render every diode state from a hand-built
/// [DynamicValue] without a `StateMan`.
class StructStatusDiodes extends StatelessWidget {
  const StructStatusDiodes({
    super.key,
    required this.status,
    required this.bits,
    required this.machine,
  });

  /// Latest struct off the wire; `null` renders every diode unknown.
  final DynamicValue? status;

  /// The members to draw, in display order — [kStructStatusBits] for the kind.
  final List<StructStatusBit> bits;

  /// Machine name substituted into each label's `{m}`.
  final String machine;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final bit in bits)
          PaneDetailRow(
            crossAxisAlignment: CrossAxisAlignment.center,
            label: bit.labelFor(machine),
            // 22 px, not smaller: the unknown state is a grey fill with a
            // white `!`, and below this size the glyph blurs out and unknown
            // becomes indistinguishable from off — the exact confusion the
            // unknown state exists to prevent.
            child: SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(
                painter: LEDPainter(
                  color: switch (structStatusBitOf(status, bit.member)) {
                    null => null,
                    true => bit.onRole.resolve(context),
                    false => Colors.white,
                  },
                  ledType: LEDType.circle,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Picks the painter for [kind].
///
/// Exhaustive switch with no `default` — a new [ThirdPartyEquipmentKind] must
/// come with a painter or this stops compiling. Shared by the runtime widget
/// and the config-editor preview so the two can never drift.
ThirdPartyMachinePainter thirdPartyPainterFor(
  ThirdPartyEquipmentKind kind, {
  required Color color,
  required double strokeWidth,
  int strapMachines = 3,
  int robotStations = 2,
  bool mirrorX = false,
  bool mirrorY = false,
}) {
  switch (kind) {
    case ThirdPartyEquipmentKind.multivac:
      return MultivacPainter(
          color: color,
          strokeWidth: strokeWidth,
          mirrorX: mirrorX,
          mirrorY: mirrorY);
    case ThirdPartyEquipmentKind.speedBatcher:
      return SpeedBatcherPainter(
          color: color,
          strokeWidth: strokeWidth,
          mirrorX: mirrorX,
          mirrorY: mirrorY);
    case ThirdPartyEquipmentKind.boxErector:
      return BoxErectorPainter(
          color: color,
          strokeWidth: strokeWidth,
          mirrorX: mirrorX,
          mirrorY: mirrorY);
    case ThirdPartyEquipmentKind.strappingLine:
      return StrappingLinePainter(
        color: color,
        strokeWidth: strokeWidth,
        mirrorX: mirrorX,
        mirrorY: mirrorY,
        machines: strapMachines.clamp(1, StrappingLinePainter.maxMachines),
      );
    case ThirdPartyEquipmentKind.fishAligner:
      return FishAlignerPainter(
          color: color,
          strokeWidth: strokeWidth,
          mirrorX: mirrorX,
          mirrorY: mirrorY);
    case ThirdPartyEquipmentKind.optimarPalletiser:
      return OptimarPalletiserPainter(
        color: color,
        strokeWidth: strokeWidth,
        mirrorX: mirrorX,
        mirrorY: mirrorY,
        stations:
            robotStations.clamp(1, OptimarPalletiserPainter.maxStations),
      );
  }
}

// ---------------------------------------------------------------------------
// Station scaffolding
// ---------------------------------------------------------------------------

/// A conveyor for use inside the box.
///
/// Bidirectional by default: on this station the belts are jogged both ways,
/// and a one-way belt would draw an arrow that contradicts what the operator
/// can see happening. `reverseDirection` stays off — the painter picks the
/// arrow direction from the sign of the live frequency.
ConveyorConfig thirdPartyConveyor({RelativeSize? size, double angleDegrees = 0}) {
  final conveyor = ConveyorConfig(bidirectional: true);
  if (size != null) conveyor.size = size;
  if (angleDegrees != 0) conveyor.coordinates.angle = angleDegrees;
  return conveyor;
}

/// A readout for use inside the box, sized to sit beside a weigh belt.
NumberConfig thirdPartyNumber({
  required String units,
  required int decimalPlaces,
  RelativeSize? size,
}) {
  final number = NumberConfig(
    key: '',
    units: units,
    decimalPlaces: decimalPlaces,
    // No graph: these sit inside another asset's box, and a tap-through to a
    // trend from a nested child is a surprise. The operator gets trends from
    // the number's own page placement.
    graphConfig: null,
  );
  if (size != null) number.size = size;
  return number;
}

/// The accept-rate readout for a checkweigher.
///
/// A `RatioNumberConfig`, not a plain number with a `%` suffix: accept rate is
/// accepted-over-total across a rolling window, which is precisely what this
/// asset models. Its `sinceMinutes` carries the window natively, so the figure
/// cannot be mistaken for an instantaneous reading and nothing has to be
/// smuggled into a units string.
RatioNumberConfig thirdPartyAcceptRatio({
  required int windowMinutes,
  bool clockAlignedBars = true,
  RelativeSize? size,
}) {
  final ratio = RatioNumberConfig(
    // Operator points these at accepted-count and total-count.
    key1: '',
    key2: '',
    key1Label: 'accepted',
    key2Label: 'total',
    sinceMinutes: Duration(minutes: windowMinutes),
    // The chart's interval toggles come from here, and the readout opens that
    // chart on [windowMinutes]. Leaving the RatioNumber default in place
    // ([1, 5, 10, 60, 240]) meant a 30-minute station opened its chart on a
    // window the toggles could not show: none of them lit up, and there was
    // no way back to 30 once another was pressed.
    intervalPresets: acceptWindowPresets(windowMinutes),
    barsClockAligned: clockAlignedBars,
    // The bars count packs. A Y axis offering 2.5 of one is noise, and on a
    // short window — where the counts are single digits — it is most of the
    // axis.
    integersOnly: true,
    decimalPlaces: 1,
  );
  if (size != null) ratio.size = size;
  return ratio;
}

/// The accept-rate window as it reads to an operator — `30 min`, `4 h`, `1 d`.
///
/// The space is non-breaking: this string is dropped into a parenthesis at the
/// end of a pane row label narrow enough to wrap, and the break must fall
/// before the parenthesis, never inside it.
String formatAcceptWindow(int minutes) {
  if (minutes < 60) return '$minutes\u{00A0}min';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440}\u{00A0}d';
  if (minutes % 60 == 0) return '${minutes ~/ 60}\u{00A0}h';
  return '$minutes\u{00A0}min';
}

/// Interval toggles for an accept-rate readout's chart.
///
/// The standard ladder with the station's own averaging window folded in, so
/// the window the figure is quoted over is always one of the offered ones.
List<int> acceptWindowPresets(int windowMinutes) =>
    <int>{1, 5, 10, 30, 60, 240, if (windowMinutes > 0) windowMinutes}.toList()
      ..sort();

/// The windows the side pane offers for the accept-rate readouts.
///
/// The configured [acceptWindowMinutes] plus whatever intervals the readouts
/// themselves were given — the same presets the accept/reject chart's toggles
/// use, so the picker and the chart it opens never disagree about which
/// windows exist. Sorted, de-duplicated, and always containing the configured
/// window so the pane opens on a window it can actually offer.
List<int> thirdPartyAcceptWindowOptions(
  Iterable<RatioNumberConfig> ratios, {
  required int acceptWindowMinutes,
}) {
  final options = <int>{
    acceptWindowMinutes,
    for (final ratio in ratios) ...ratio.intervalPresets,
  }.where((m) => m > 0).toList()
    ..sort();
  return options;
}

/// Builds the standard set of live assets for the SpeedBatcher station.
///
/// One bidirectional conveyor on each checkweigher's weigh belt, with its
/// weight readout to the right and its accept rate to the left — the layout
/// Jón asked for. Keys are left empty on purpose: the scaffold places and
/// sizes everything, then the operator points each child at its tag through
/// the per-child Configure button.
///
/// The two conveyor LANES are not scaffolded: they run up the page, so a
/// conveyor there would need a 90-degree angle and a thickness that depends
/// on the asset's pixel aspect. They stay part of the painted drawing — the
/// SpeedBatcher box is static, and its editor offers no free-form add
/// buttons; this scaffold is everything that lives inside it.
///
/// [acceptWindowMinutes] is folded into the accept readout's units so the
/// averaging window is visible on the mimic rather than assumed.
List<ThirdPartyChildEntry> buildSpeedBatcherStationChildren({
  int acceptWindowMinutes = 30,
  bool acceptBarsClockAligned = true,
}) {
  final entries = <ThirdPartyChildEntry>[];

  void addCheckweigher(String name, Rect frame) {
    final deck = SpeedBatcherPainter.deckOf(frame);
    final accept = SpeedBatcherPainter.acceptAnchorOf(frame);
    final weight = SpeedBatcherPainter.weightAnchorOf(frame);

    entries.add(ThirdPartyChildEntry(
      offsetX: deck.center.dx,
      offsetY: deck.center.dy,
      // Half a revolution: product runs right-to-left across the weigh
      // belts on the real machine, so the belt drawing is turned to make a
      // positive live frequency draw its arrow with the product flow.
      child: thirdPartyConveyor(
        size: RelativeSize(width: deck.width, height: deck.height),
        angleDegrees: 180,
      ),
    ));
    // Readout slots, sitting ON the belt either side of the run-direction
    // arrow. The arrow owns the middle 40% of the belt, so a slot may be at
    // most ~0.28 wide before it collides with the arrowhead.
    //
    // `NumberWidget` scales its text with BoxFit.contain, so slot width sets
    // the font size and a long units string shrinks the number to a smear —
    // which is why the averaging window is NOT spelled out here. `% 30m` is
    // the longest suffix that stays legible; the full wording lives in the
    // side pane, where there is room for it.
    final slot = RelativeSize(width: 0.22, height: frame.height * 0.6);

    entries.add(ThirdPartyChildEntry(
      offsetX: accept.dx,
      offsetY: accept.dy,
      keepUpright: true,
      child: thirdPartyAcceptRatio(
        windowMinutes: acceptWindowMinutes,
        clockAlignedBars: acceptBarsClockAligned,
        size: slot,
      ),
    ));
    entries.add(ThirdPartyChildEntry(
      offsetX: weight.dx,
      offsetY: weight.dy,
      keepUpright: true,
      child: thirdPartyNumber(
        units: '',
        decimalPlaces: 0,
        size: slot,
      ),
    ));
  }

  // Product order: checkweigher 1 first, then 2.
  addCheckweigher('CW1', SpeedBatcherPainter.checkweigher1Frame);
  addCheckweigher('CW2', SpeedBatcherPainter.checkweigher2Frame);
  return entries;
}

// ---------------------------------------------------------------------------
// Runtime widget
// ---------------------------------------------------------------------------

/// Live third-party equipment widget driven by a bool run-status key.
///
/// The stream is hoisted to `initState` and only rebuilt when `runKey` changes
/// — building it in `build()` would create and cancel an OPC UA monitored item
/// every frame. Same lifecycle contract as `Sensor` in `sensor.dart`.
class ThirdPartyEquipment extends ConsumerStatefulWidget {
  final ThirdPartyEquipmentConfig config;
  const ThirdPartyEquipment({super.key, required this.config});

  @override
  ConsumerState<ThirdPartyEquipment> createState() =>
      _ThirdPartyEquipmentState();
}

class _ThirdPartyEquipmentState extends ConsumerState<ThirdPartyEquipment> {
  /// `null` means no stream is needed — the run key is empty.
  Stream<bool>? _runStream;

  /// The single subscription to [_runStream].
  ///
  /// The state is fanned out through [_raw] rather than by letting each
  /// consumer wrap the stream in its own `StreamBuilder`. Two reasons: the
  /// hoisted stream is single-subscription, so a second listener throws
  /// "Stream has already been listened to" the moment an operator opens the
  /// pane on a machine that has a run key; and one subscription means the LED
  /// and the pane can never disagree about what the machine is doing.
  StreamSubscription<bool>? _sub;

  /// Latest RAW value off the wire, before polarity is applied. `null` is the
  /// unknown state — no key, nothing received yet, or the stream errored.
  ///
  /// Polarity is deliberately NOT baked in here: the editor can flip
  /// `invertRunPolarity` without the key changing, and re-hoisting the stream
  /// just to re-map a bool would drop and recreate a PLC subscription.
  final ValueNotifier<bool?> _raw = ValueNotifier<bool?>(null);

  /// The key `_runStream` was built for. Compared against the live config
  /// rather than `oldWidget.config.runKey` because the page editor mutates the
  /// same config instance in place, so both widgets hold the same reference.
  String? _hoistedKey;

  /// `null` means no status stream is needed — not a SpeedBatcher, or the
  /// status key is empty. Same hoisted lifecycle as [_runStream].
  Stream<DynamicValue>? _statusStream;

  /// The single subscription to [_statusStream], fanned out through
  /// [_statusRaw] for the same single-subscription reasons as [_sub].
  StreamSubscription<DynamicValue>? _statusSub;

  /// Latest handshake struct off the wire. `null` renders every diode in the
  /// pane's Status section unknown — nothing received yet, or the stream
  /// errored.
  final ValueNotifier<DynamicValue?> _statusRaw =
      ValueNotifier<DynamicValue?>(null);

  /// The collector settings for the hoisted status key, or null when the key is
  /// not collected. Drives whether the pane offers a Trend section at all —
  /// resolved once per hoist rather than per build, since it comes from the
  /// key mappings and only changes when the key does.
  final ValueNotifier<CollectEntry?> _statusCollect =
      ValueNotifier<CollectEntry?>(null);

  /// Latest value per status-bit suffix, for the kinds whose diodes come from
  /// separate keys rather than one struct. Held here rather than in the pane
  /// because the pane lives in an overlay and is torn down and rebuilt every
  /// time it opens; the subscriptions should not be.
  final ValueNotifier<Map<String, bool?>> _statusBits =
      ValueNotifier<Map<String, bool?>>({});

  /// One subscription per bit, keyed by suffix.
  final Map<String, StreamSubscription<DynamicValue>> _bitSubs = {};

  /// Latest value per extra-bit key. Held here rather than in the pane for the
  /// same reason as [_statusBits]: the pane lives in an overlay that is rebuilt
  /// every time it opens, but the subscriptions must not be.
  final ValueNotifier<Map<String, bool?>> _extraStatusBits =
      ValueNotifier<Map<String, bool?>>({});

  /// One subscription per extra bit, keyed by the bit's full key. Independent
  /// of [_bitSubs] because these are complete keys in their own namespace, not
  /// suffixes appended to [ThirdPartyEquipmentConfig.statusKey].
  final Map<String, StreamSubscription<DynamicValue>> _extraBitSubs = {};

  /// The averaging window the pane's accept-rate readouts are counting over.
  ///
  /// Pane-local and deliberately not written back to the config: widening the
  /// view to see whether a bad minute was a blip is a question, not a page
  /// edit. Reopening the pane comes back on the configured window. Held here
  /// rather than in the pane body because the pane lives in an overlay that is
  /// rebuilt on every open, and it is merged into the pane's listenable so a
  /// pick repaints the rows exactly like a value arriving does.
  late final ValueNotifier<int> _acceptWindow =
      ValueNotifier<int>(widget.config.acceptWindowMinutes);

  /// The key [_statusStream] was built for; compared against [_wantedStatusKey]
  /// so a kind change away from SpeedBatcher drops the subscription too.
  String? _hoistedStatusKey;

  /// The status key this config actually wants a struct subscription for.
  ///
  /// Empty for the prefix kinds — a leftover [ThirdPartyEquipmentConfig.statusKey]
  /// on a config switched to another kind must not hold a PLC subscription
  /// open for a section the pane no longer shows.
  String get _wantedStatusKey =>
      isStructBacked(widget.config.kind)
          ? widget.config.statusKey
          : '';

  bool? get _isRunning {
    final raw = _raw.value;
    if (raw == null) return null;
    return thirdPartyIsRunning(
      rawBool: raw,
      invertRunPolarity: widget.config.invertRunPolarity,
    );
  }

  @override
  void initState() {
    super.initState();
    _hoistStream();
    _hoistStatusStream();
    _hoistStatusBits();
    _hoistExtraBits();
    _hoistBpmCollect();
  }

  /// Subscribe every bit this kind shows, dropping any that no longer apply.
  ///
  /// Re-entrant: called again when the prefix or the kind changes, so a config
  /// edit in the page editor moves the diodes onto the new keys without a
  /// restart, and a kind switch releases the old machine's subscriptions.
  void _hoistStatusBits() {
    // A struct kind reads every bit out of the one node [_hoistStatusStream]
    // holds, so it must open no per-bit subscriptions at all -- otherwise a
    // strapper would cost three keys instead of the struct's one, and the two
    // sections would both try to render.
    final bits = isStructBacked(widget.config.kind)
        ? null
        : kEquipmentStatusBits[widget.config.kind];
    final prefix = widget.config.statusKey;
    final wanted = <String, String>{
      if (bits != null && prefix.isNotEmpty)
        for (final bit in bits) bit.suffix: '$prefix.${bit.suffix}',
      // Subscribed alongside the diodes but never drawn as one: this bit says
      // whether any of the others may be believed. It rides the same map and
      // the same teardown, so the gate costs one key and no new machinery --
      // see [boxErectorCommsOf].
      if (widget.config.kind == ThirdPartyEquipmentKind.boxErector &&
          prefix.isNotEmpty) ...{
        kBoxErectorCommsSuffix: '$prefix.$kBoxErectorCommsSuffix',
        // Likewise subscribed and not drawn: the run bit lost its diode
        // because the header badge above it says the same thing, and this is
        // where that badge gets it from. See [kBoxErectorRunSuffix].
        kBoxErectorRunSuffix: '$prefix.$kBoxErectorRunSuffix',
      },
    };
    for (final suffix in _bitSubs.keys.toList()) {
      if (!wanted.containsKey(suffix)) {
        _bitSubs.remove(suffix)?.cancel();
        _statusBits.value = Map.of(_statusBits.value)..remove(suffix);
      }
    }
    for (final entry in wanted.entries) {
      if (_bitSubs.containsKey(entry.key)) continue;
      // Straight through StateMan like [_hoistStream], NOT through
      // `keyStreamProvider`: that provider is autoDispose, and a bare
      // `ref.read` from here registers no listener, so it is disposed at the
      // end of the frame and closes its subject before the first value can
      // arrive — the diode would sit at unknown forever.
      _bitSubs[entry.key] = ref
          .read(stateManProvider.future)
          .asStream()
          .asyncExpand((sm) => sm.subscribe(entry.value).asStream())
          .asyncExpand((s) => s)
          .listen((v) {
        if (!mounted) return;
        _statusBits.value = Map.of(_statusBits.value)..[entry.key] = v.asBool;
      }, onError: (_) {
        if (!mounted) return;
        // Unknown, not false: a key that errors has told us nothing.
        _statusBits.value = Map.of(_statusBits.value)..[entry.key] = null;
      });
    }
  }

  /// Subscribe every extra loose key this instance declares, dropping any that
  /// no longer apply.
  ///
  /// Re-entrant like [_hoistStatusBits], and independent of the kind: extra
  /// bits ride alongside whichever main diode section the kind shows (struct or
  /// prefix), or on their own. Each key is read straight through StateMan — NOT
  /// through `keyStreamProvider`, for the same autoDispose reason spelled out
  /// in [_hoistStatusBits].
  void _hoistExtraBits() {
    final wanted = <String>{
      for (final bit in widget.config.extraBits)
        if (bit.key.isNotEmpty) bit.key,
    };
    for (final key in _extraBitSubs.keys.toList()) {
      if (!wanted.contains(key)) {
        _extraBitSubs.remove(key)?.cancel();
        _extraStatusBits.value = Map.of(_extraStatusBits.value)..remove(key);
      }
    }
    for (final key in wanted) {
      if (_extraBitSubs.containsKey(key)) continue;
      _extraBitSubs[key] = ref
          .read(stateManProvider.future)
          .asStream()
          .asyncExpand((sm) => sm.subscribe(key).asStream())
          .asyncExpand((s) => s)
          .listen((v) {
        if (!mounted) return;
        _extraStatusBits.value = Map.of(_extraStatusBits.value)
          ..[key] = v.asBool;
      }, onError: (_) {
        if (!mounted) return;
        // Unknown, not false: a key that errors has told us nothing.
        _extraStatusBits.value = Map.of(_extraStatusBits.value)..[key] = null;
      });
    }
  }

  @override
  void didUpdateWidget(covariant ThirdPartyEquipment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_hoistedKey != widget.config.runKey) {
      _hoistStream();
    }
    if (_hoistedStatusKey != _wantedStatusKey) {
      _hoistStatusStream();
    }
    // The prefix or the kind may have changed under us -- the page editor
    // mutates the same config instance in place, so comparing against
    // oldWidget would miss it. _hoistStatusBits is re-entrant and diffs.
    _hoistStatusBits();
    // Same re-entrant diff for the instance's extra loose keys.
    _hoistExtraBits();
    // Cheap: it resolves a map lookup, opens no subscription, and a stale
    // answer here means a Trend section offered for the previous machine.
    _hoistBpmCollect();
  }

  void _hoistStream() {
    final key = widget.config.runKey;
    _hoistedKey = key;
    _sub?.cancel();
    _sub = null;
    _raw.value = null;
    if (key.isEmpty) {
      _runStream = null;
      return;
    }
    _runStream = ref
        .read(stateManProvider.future)
        .asStream()
        .asyncExpand((sm) => sm.subscribe(key).asStream())
        .asyncExpand((s) => s)
        .map((dv) => dv.asBool);
    _sub = _runStream!.listen(
      (value) => _raw.value = value,
      // Fall back to unknown rather than latching the last good value: a
      // stale "running" is worse than an honest "we don't know".
      onError: (Object _) => _raw.value = null,
    );
  }

  /// Hoists the SpeedBatcher status-struct stream, mirroring [_hoistStream].
  /// Unlike the run stream the value stays a [DynamicValue]: the pane reads
  /// individual `p_stat_*` members out of it per diode.
  void _hoistStatusStream() {
    final key = _wantedStatusKey;
    _hoistedStatusKey = key;
    _statusSub?.cancel();
    _statusSub = null;
    _statusRaw.value = null;
    _statusCollect.value = null;
    if (key.isEmpty) {
      _statusStream = null;
      return;
    }
    _statusStream = ref
        .read(stateManProvider.future)
        .asStream()
        .asyncExpand((sm) => sm.subscribe(key).asStream())
        .asyncExpand((s) => s);
    _statusSub = _statusStream!.listen(
      (value) => _statusRaw.value = value,
      // Same honesty rule as the run stream: unknown beats a stale latch.
      onError: (Object _) => _statusRaw.value = null,
    );

  }

  /// Resolves whether the box erector's throughput key is collected, for the
  /// Trend section's availability.
  ///
  /// Its own hoist rather than a tail of [_hoistStatusStream], because the
  /// erector no longer HAS a struct stream: it is prefix-backed, so that method
  /// returns early on an empty key and would never run this. Re-entrant like
  /// [_hoistStatusBits] — a prefix edit in the page editor re-resolves it.
  ///
  /// unawaited + catchError rather than bare: a fire-and-forget future with no
  /// handler takes the zone down if the provider errors, and a pane that cannot
  /// say whether a key is collected should simply offer no trend.
  void _hoistBpmCollect() {
    final key = _bpmKey;
    _statusCollect.value = null;
    if (key.isEmpty) return;
    unawaited(ref
        .read(stateManProvider.future)
        .then((sm) {
          if (!mounted || _bpmKey != key) return;
          _statusCollect.value = sm.keyMappings.nodes[key]?.collect;
        })
        .catchError((Object _) => _statusCollect.value = null));
  }

  /// The throughput key, off the same prefix as the diodes. Empty for every
  /// other kind and for an unconfigured prefix, which is what suppresses the
  /// Trend section.
  String get _bpmKey =>
      widget.config.kind == ThirdPartyEquipmentKind.boxErector &&
              widget.config.statusKey.isNotEmpty
          ? '${widget.config.statusKey}.$kBoxErectorBpmSuffix'
          : '';

  /// Test-only window onto the hoisted stream identity, so the stream
  /// lifecycle can be asserted without a real `StateMan`.
  @visibleForTesting
  Stream<bool>? get debugRunStream => _runStream;

  /// Test-only window onto the hoisted status stream, as [debugRunStream].
  @visibleForTesting
  Stream<DynamicValue>? get debugStatusStream => _statusStream;

  /// Test-only window onto which per-bit keys are subscribed. Empty for a
  /// struct kind — that is the whole point of [kStructStatusBits], and it is
  /// not observable from the rendered tree.
  @visibleForTesting
  Iterable<String> get debugStatusBitKeys => _bitSubs.keys;

  /// Test-only window onto which extra loose keys are subscribed.
  @visibleForTesting
  Iterable<String> get debugExtraBitKeys => _extraBitSubs.keys;

  @override
  void dispose() {
    // A docked pane lives in the root overlay, so it would survive a page
    // change and go on showing a machine that is no longer on screen. Scoped
    // by id so we never close someone else's pane.
    closeSidePane(id: _paneId, immediate: true);
    _sub?.cancel();
    _raw.dispose();
    _statusSub?.cancel();
    _statusRaw.dispose();
    _statusCollect.dispose();
    for (final sub in _bitSubs.values) {
      sub.cancel();
    }
    _bitSubs.clear();
    for (final sub in _extraBitSubs.values) {
      sub.cancel();
    }
    _extraBitSubs.clear();
    // Safe because the closeSidePane above is `immediate` -- the overlay entry
    // is gone in this frame, not gliding out over the next dozen. Without that
    // the pane would still be mounted and rebuilding against this notifier,
    // and disposing it here threw on the next rebuild.
    _statusBits.dispose();
    _extraStatusBits.dispose();
    _acceptWindow.dispose();
    super.dispose();
  }

  /// Opens the read-only side pane — the "more information" behind the tap.
  ///
  /// A [SidePane] rather than a dialog because this is equipment on a running
  /// line: the operator wants to read the handshake while still watching the
  /// mimic, and a modal barrier would hide the very machine they are
  /// diagnosing. The pane rebuilds itself from the run stream, so the status
  /// chip stays live while it is open.
  ///
  /// No writes: we report what the handshake says, we do not command other
  /// people's machines.
  /// Identifies this asset's pane. Tapping the same machine twice toggles its
  /// pane shut; tapping a different one swaps.
  String get _paneId {
    final config = widget.config;
    return 'third-party:${config.tag ?? ''}:${config.runKey}:'
        '${config.kind.name}';
  }

  void _showPane(BuildContext context) {
    // Pane copies of the weight readouts: same key and format as on the
    // mimic, but WITH a trend graph — the tap-through that would be a
    // surprise on a nested child is exactly what the pane exists for.
    // Cloned once per open, not per rebuild, so the graph dialog id and the
    // value subscription stay stable while the pane repaints off the run
    // and status notifiers.
    final weights = <NumberConfig>[];
    for (final entry in widget.config.children) {
      final child = entry.child;
      if (child is! NumberConfig) continue;
      weights.add(NumberConfig(
        key: child.key,
        showDecimalPoint: child.showDecimalPoint,
        decimalPlaces: child.decimalPlaces,
        // The belt readout is unitless — there is no room beside the arrow —
        // but the pane has the room, so the unit goes here: whatever the
        // operator configured on the child, kg otherwise.
        units: (child.units?.isNotEmpty ?? false) ? child.units : 'kg',
        scale: child.scale,
        graphConfig: GraphAssetConfig.preview(
            key: child.key.isEmpty ? null : child.key)
          ..headerText = 'Weight, checkweigher ${weights.length + 1} — trend',
      ));
    }

    showSidePane(
      context: context,
      id: _paneId,
      // Rebuilds off the same notifiers the body uses, so the status chip
      // stays live while the pane is open and always agrees with the LED.
      // Merged rather than nested: the status struct only feeds the pane, so
      // the body's ValueListenableBuilder stays on `_raw` alone.
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge(
            [_raw, _statusRaw, _statusCollect, _statusBits, _extraStatusBits,
              _acceptWindow]),
        builder: (context, _) => _paneFor(context, _isRunning, weights),
      ),
    );
  }

  /// A compact trailing chart button for a pane row.
  ///
  /// The live figure beside it is tappable too — the readouts keep their own
  /// tap-through — but a figure does not LOOK tappable, so the button is the
  /// visible way into the chart.
  Widget _chartButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      onPressed: onPressed,
    );
  }

  /// The pane's Status section: the kind's own diodes (struct or prefix)
  /// followed by any instance-level [ExtraStatusBit] diodes.
  ///
  /// Null when the kind has no diode table and the instance declares no extra
  /// bits, so the section is omitted rather than drawn empty. A struct kind
  /// always shows the section — key configured or not — because grey `!` diodes
  /// tell the operator the section exists and is unconfigured, which a silently
  /// absent section would not. Extra bits, being loose keys, only appear when
  /// declared: an empty [ThirdPartyEquipmentConfig.extraBits] renders exactly
  /// as before.
  PaneBodySection? _statusSection(BuildContext context) {
    final config = widget.config;
    final rows = <Widget>[];
    // A dead Modbus link makes every bit below a stale latch rather than a
    // reading, so they are shown as UNKNOWN. Emptying the value maps does
    // exactly that through the existing degrade-to-`!` path -- no separate
    // "stale" mode to keep in step with the normal one.
    //
    // The EXTRA bits are blanked too. They are loose keys of their own, but on
    // this machine they read the same Saia over the same Modbus link -- the
    // carton-chute sensors freeze exactly as the permits do -- so leaving them
    // live would put two confident diodes under four grey ones.
    final commsDown = boxErectorCommsOf(_statusBits.value) == false;
    final status = commsDown ? null : _statusRaw.value;
    final bitValues = commsDown ? const <String, bool?>{} : _statusBits.value;
    final extraValues =
        commsDown ? const <String, bool?>{} : _extraStatusBits.value;
    if (kStructStatusBits[config.kind] case final structBits?) {
      rows.add(StructStatusDiodes(
        status: status,
        bits: structBits,
        machine: equipmentShortName(config.kind),
      ));
    } else if (kEquipmentStatusBits[config.kind] case final prefixBits?) {
      rows.add(EquipmentStatusDiodes(
        bits: prefixBits,
        values: bitValues,
        machine: equipmentShortName(config.kind),
      ));
    }
    if (config.extraBits.isNotEmpty) {
      rows.add(ExtraStatusDiodes(
        bits: config.extraBits,
        values: extraValues,
        machine: equipmentShortName(config.kind),
      ));
    }
    if (rows.isEmpty) return null;
    return PaneBodySection.status(
      child: rows.length == 1
          ? rows.single
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
    );
  }

  /// The pane's Trend section: the box erector's throughput over time.
  ///
  /// The ONLY place cartons-per-minute appears. It used to be a live figure in
  /// Status as well, on the reading that a rate reads better as a value than as
  /// a lit dot -- true, but the same number twice on one pane, once as an
  /// instant and once as a trace, and the instant is the half that cannot say
  /// whether the line is picking up or dying. The trace answers both.
  ///
  /// Null for every other kind, and null for a box erector whose
  /// [kBoxErectorBpmSuffix] key is not being collected: history has to have
  /// been stored, so an uncollected machine gets no section rather than an
  /// empty chart. That is a REAL loss of the figure rather than a fallback to
  /// the live one -- the collector entry is what makes this pane show
  /// throughput at all.
  ///
  /// Placed after Status by the house section order
  /// (status -> trend -> manual -> setpoints) that [PaneSectionSlot] defines --
  /// this pane composes a [PaneBody] now, so the slot decides where the section
  /// lands rather than where it happens to be written.
  PaneBodySection? _trendSection(BuildContext context) {
    final config = widget.config;
    if (config.kind != ThirdPartyEquipmentKind.boxErector) return null;
    if (config.statusKey.isEmpty) return null;
    if (!boxErectorBpmTrendAvailable(_statusCollect.value)) return null;

    // The throughput key, not the prefix: the chart reads a plain numeric
    // series now, not a member picked out of a status struct.
    final key = _bpmKey;
    return PaneBodySection.trend(child: boxErectorBpmTrendTile(keyName: key));
  }

  Widget _paneFor(
      BuildContext context, bool? isRunning, List<NumberConfig> weights) {
    final config = widget.config;
    PaneStatus status;
    if (config.runKey.isEmpty) {
      status = const PaneStatus.unknown('No key');
    } else if (isRunning == null) {
      status = const PaneStatus.stale();
    } else {
      status =
          isRunning ? const PaneStatus.running() : const PaneStatus.stopped();
    }
    if (config.kind == ThirdPartyEquipmentKind.boxErector &&
        (config.runKey.isEmpty || isRunning == null)) {
      // The run bit off the prefix, when the run key had nothing to say. It is
      // subscribed either way -- see [kBoxErectorRunSuffix] -- and it is the
      // badge that replaced this pane's `Running` diode, so it must not be the
      // weaker of the two readings.
      status = boxErectorPaneStatus(_statusBits.value, status);
    }
    if (config.kind == ThirdPartyEquipmentKind.speedBatcher) {
      // The handshake struct outranks the bare run bool: it can say
      // "Cleaning", which the run key would misreport as Stopped.
      status = speedBatcherPaneStatus(_statusRaw.value, status);
    }
    // A dead Modbus link outranks EVERYTHING, including the run key: that key
    // is a member of the same frozen struct, so "Running" here would be the
    // last thing the machine said before we lost it, not what it is doing.
    final commsDown = boxErectorCommsOf(_statusBits.value) == false;
    if (commsDown) status = const PaneStatus.unknown('No link');

    // The scaffolded accept-rate readouts, in checkweigher order. Surfaced
    // as LIVE figures in the pane — the operator opens it to read the
    // machine, not its wiring, so keys and static wording stay out.
    final acceptRatios = [
      for (final entry in config.children)
        if (entry.child case final RatioNumberConfig ratio) ratio,
    ];
    final acceptOptions = thirdPartyAcceptWindowOptions(acceptRatios,
        acceptWindowMinutes: config.acceptWindowMinutes);
    // A window the options no longer contain — the page was edited while the
    // pane was open — falls back to the configured one rather than leaving the
    // dropdown on a value it has no item for, which asserts.
    final acceptWindow = acceptOptions.contains(_acceptWindow.value)
        ? _acceptWindow.value
        : config.acceptWindowMinutes;

    return SidePane(
      title: config.tag?.isNotEmpty == true
          ? config.tag!
          : config.kind.labelFor(
              strapMachines: config.strapMachines,
              robotStations: config.robotStations),
      subtitle: config.tag?.isNotEmpty == true
          ? config.kind.labelFor(
              strapMachines: config.strapMachines,
              robotStations: config.robotStations)
          : 'Third-party equipment',
      icon: Icons.precision_manufacturing,
      status: status,
      // A [PaneBody], not a hand-rolled Column of [PaneSection]s.
      //
      // This is the reported "missing division line". `PaneBody` draws a
      // hairline `Divider` between consecutive sections; a raw Column draws
      // none, so this pane ran Equipment straight into Status with no rule
      // between them while every pane composed the house way -- the conveyor
      // drive's, the sensor's, the analog box's, the EP box's -- had one. It
      // was missing on all FIVE kinds, not just the box erector: they share
      // this one build method, which is also why the fix is one edit and not
      // five.
      //
      // Equipment takes the `status` slot rather than `details`. It is live
      // figures -- accept rates and weights, read now -- and `details` sorts
      // LAST, which would have thrown the block to the bottom of the pane. Two
      // sections in one slot keep the order they were written in, which is the
      // order this pane already had, so nothing moves; only the rules between
      // the blocks appear.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Above the body and deliberately outside it: a banner about the
          // whole pane is not a section of it, so it takes no rule.
          if (commsDown) const CommsLostBanner(),
          PaneBody(sections: [
            PaneBodySection.status(
              title: 'Equipment',
              child: Column(
                children: [
                  PaneDetailRow(
                    label: 'Machine',
                    value: config.kind
                        .labelFor(
                            strapMachines: config.strapMachines,
                            robotStations: config.robotStations),
                  ),
                  // No separate head-count row: the Machine line above already
                  // ends in "N x StrapX", and the pane read the same number
                  // twice. The count is still editable in the config editor.
                  // Live figures, not key names or static wording — the pane
                  // is for reading the machine, not its wiring. Charts stay
                  // behind a tap so the pane itself does not crowd: the accept
                  // figure opens its accept/reject bar chart (the
                  // RatioNumberWidget's own tap-through), the weight opens its
                  // trend.
                  // The window, stated once for both scales rather than
                  // repeated in each figure's label: a rolling average read
                  // as "right now" is the whole reason this asset carries a
                  // window, and one row directly above the figures says it
                  // without pushing every label onto three lines.
                  //
                  // One picker for both, too — they are the same product stream
                  // a few metres apart, and reading them over different windows
                  // would compare nothing to nothing.
                  //
                  // Nothing to pick between: an empty picker is worse than
                  // none, but the window still has to be on the pane.
                  if (acceptRatios.isNotEmpty && acceptOptions.length == 1)
                    PaneDetailRow(
                      label: 'Accept rate window',
                      value: formatAcceptWindow(acceptWindow),
                    ),
                  if (acceptRatios.isNotEmpty && acceptOptions.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      // Full width, and explicitly so: the section's Column
                      // centres whatever does not stretch, which left this
                      // block floating a few pixels right of every label
                      // beside it.
                      child: SizedBox(
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Accept rate window',
                                style: Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 4),
                            // Literally the chart's picker, one size down.
                            // Full width rather than in a [PaneDetailRow]'s
                            // value column, which is too narrow for a ladder of
                            // chips to reflow in.
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: ratioIntervalChips(
                                options: acceptOptions,
                                selectedMinutes: acceptWindow,
                                onSelected: (m) => _acceptWindow.value = m,
                                dense: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (final (i, ratio) in acceptRatios.indexed)
                    PaneDetailRow(
                      label: 'Accept rate, checkweigher ${i + 1}',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 22,
                            child: RatioNumberWidget(
                              config: ratio,
                              intervalOverride: Duration(minutes: acceptWindow),
                              intervalOptions: acceptOptions,
                            ),
                          ),
                          _chartButton(
                            icon: Icons.bar_chart,
                            tooltip: 'Accept/reject chart',
                            // The chart opens on the window the pane is
                            // showing, not on the configured one — otherwise
                            // tapping through to explain a figure changes the
                            // figure.
                            onPressed: () => showRatioAnalysisDialog(
                                context, ref, ratio,
                                interval: Duration(minutes: acceptWindow)),
                          ),
                        ],
                      ),
                    ),
                  for (final (i, weight) in weights.indexed)
                    PaneDetailRow(
                      label: 'Weight, checkweigher ${i + 1}',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 22,
                            child: NumberWidget(config: weight),
                          ),
                          _chartButton(
                            icon: Icons.show_chart,
                            tooltip: 'Weight trend',
                            onPressed: () =>
                                showNumberGraphDialog(context, weight),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            _statusSection(context),
            _trendSection(context),
            if (config.notes != null && config.notes!.isNotEmpty)
              PaneBodySection.details(
                title: 'Notes',
                child: SelectableText(config.notes!),
              ),
          ]),
        ],
      ),
    );
  }

  /// Machine drawing + dotted boundary + run LED, wrapped in the tap target.
  ///
  /// The `GestureDetector` sits INSIDE `LayoutRotatedBox`, wrapping the
  /// full-size [ThirdPartyEquipmentBody]. `_RenderLayoutRotatedBox.hitTest`
  /// (in `common.dart`) forwards a tap into the child's un-rotated frame and
  /// adopts the child's verdict, so an opaque detector on the whole body makes
  /// the ENTIRE placed box tappable at any rotation. This matches the fixed
  /// arrangement in `Sensor._buildPaint` — see
  /// `test/page_creator/assets/sensor_rotated_hittest_test.dart`.
  ///
  /// It USED to sit OUTSIDE the rotated box. There the detector's own render
  /// box kept the asset's UN-rotated `w x h` size, so once the box was rotated
  /// its opaque hit area (the un-rotated rect) and the visible glyph (the
  /// rotated rect) only overlapped in a central `min(w,h) x min(w,h)` square —
  /// which on a wide box rotated 90 degrees (the multivac) collapsed the live
  /// area to a thin central band, the reported dead top/bottom. The box's
  /// intrinsic `aspectRatio()` never entered into it: the dead margin is purely
  /// the placed box's own `w:h` swapped by the rotation.
  Widget _buildBody(bool? isRunning) {
    final config = widget.config;
    final ledColor = isRunning == null
        ? null
        : (isRunning ? config.runningColor : config.stoppedColor)
            .resolve(context);

    return LayoutRotatedBox(
      angle: (config.coordinates.angle ?? 0.0) * pi / 180,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Prefer the bounded asset rect; fall back to the configured size
          // resolved against the screen for the standalone/preview path.
          final Size paintSize =
              constraints.hasBoundedWidth && constraints.hasBoundedHeight
                  ? Size(constraints.maxWidth, constraints.maxHeight)
                  : config.size.toSize(MediaQuery.of(context).size);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showPane(context),
            child: ThirdPartyEquipmentBody(
              painter: thirdPartyPainterFor(
                config.kind,
                color: config.outlineColor.resolve(context),
                strokeWidth: config.strokeWidth,
                strapMachines: config.strapMachines,
                robotStations: config.robotStations,
                mirrorX: config.mirrorX,
                mirrorY: config.mirrorY,
              ),
              paintSize: paintSize,
              ledColor: ledColor,
              mirrorX: config.mirrorX,
              mirrorY: config.mirrorY,
              children: config.children,
              parentAngleDegrees: config.coordinates.angle ?? 0.0,
              childTextAngle: config.childTextAngle,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // All three stale paths — no key, nothing received yet, stream errored —
    // arrive here as a null `_raw`, and `_isRunning` keeps them null.
    return ValueListenableBuilder<bool?>(
      valueListenable: _raw,
      builder: (context, _, __) => _buildBody(_isRunning),
    );
  }
}

/// The painted body: machine glyph + dotted boundary, with the run LED
/// composited into the top-left header strip.
///
/// The LED is a real [LEDPainter] rather than a circle drawn by the machine
/// painter, so it matches every other LED on the page — including the grey `!`
/// it draws for an unknown value (`ledColor == null`).
///
/// Split out as its own widget so the config-editor preview and the golden
/// tests can render it without a `StateMan`.
class ThirdPartyEquipmentBody extends StatelessWidget {
  const ThirdPartyEquipmentBody({
    super.key,
    required this.painter,
    required this.paintSize,
    required this.ledColor,
    this.children = const [],
    this.parentAngleDegrees = 0.0,
    this.childTextAngle = 0.0,
    this.mirrorX = false,
    this.mirrorY = false,
  });

  final ThirdPartyMachinePainter painter;
  final Size paintSize;

  /// `null` renders the LED's unknown state.
  final Color? ledColor;

  /// Live assets composited over the drawing, inside the machine area.
  final List<ThirdPartyChildEntry> children;

  /// Rotation already applied to this body by the parent's `LayoutRotatedBox`.
  /// Upright children are turned back by this much.
  final double parentAngleDegrees;

  /// Extra rotation for upright children, on top of the counter-rotation.
  final double childTextAngle;

  /// The machine glyph is mirrored, so child POSITIONS mirror with it.
  ///
  /// Without this a mirrored SpeedBatcher keeps its weigh-belt conveyors on
  /// the lanes the unmirrored drawing had, which is now empty floor — the
  /// children would float beside the belts they belong to.
  ///
  /// Positions only. A child's own glyph is not flipped: it is a separate
  /// asset with its own configuration, and a conveyor takes its run direction
  /// from the sign of a live frequency rather than from which way it is drawn.
  final bool mirrorX;
  final bool mirrorY;

  /// Positions one child by its centre within the machine area.
  ///
  /// The child's own `RelativeSize` is resolved against the MACHINE AREA, not
  /// the screen — same convention as `Elevator._buildPositionedChild` — so a
  /// conveyor sized to half a lane stays half a lane at any asset size.
  ///
  /// A child marked [ThirdPartyChildEntry.keepUpright] is counter-rotated out
  /// of the parent's rotation and then turned by [childTextAngle], so
  /// readouts stay level however the machine is placed. The rotation is
  /// visual only — the layout box does not turn — which is what keeps a
  /// readout inside the slot the scaffold gave it.
  Widget _positionedChild(
      BuildContext context, ThirdPartyChildEntry entry, Rect area) {
    final intrinsic = entry.child.size.toSize(area.size);
    final w = intrinsic.width <= 0 ? area.shortestSide / 4 : intrinsic.width;
    final h = intrinsic.height <= 0 ? area.shortestSide / 4 : intrinsic.height;

    // KeyedSubtree on the stable entry id: without it, reordering or editing
    // the list re-creates the child's State and re-subscribes its stream.
    //
    // The MediaQuery override is what makes "the child's size is relative to
    // the machine area" true for EVERY asset. Most resolve their RelativeSize
    // against the incoming constraints, but some — Conveyor among them —
    // resolve it against `MediaQuery.of(context).size`, and would otherwise
    // paint at full-screen scale and spill straight out of the box. Handing
    // them a MediaQuery whose size IS the machine area makes both conventions
    // land on the same pixels.
    Widget built = KeyedSubtree(
      key: ValueKey<String>(entry.id),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(size: area.size),
        child: entry.child.build(context),
      ),
    );
    if (entry.keepUpright) {
      built = Transform.rotate(
        angle: (childTextAngle - parentAngleDegrees) * pi / 180,
        child: built,
      );
    }

    final offsetX = mirrorX ? 1.0 - entry.offsetX : entry.offsetX;
    final offsetY = mirrorY ? 1.0 - entry.offsetY : entry.offsetY;

    return Positioned(
      left: area.left + offsetX * area.width - w / 2,
      top: area.top + offsetY * area.height - h / 2,
      width: w,
      height: h,
      child: built,
    );
  }

  @override
  Widget build(BuildContext context) {
    final boundary = thirdPartyBoundaryRect(paintSize);
    final area = thirdPartyMachineArea(paintSize);
    final led = thirdPartyLedDiameter(paintSize);
    final inset = thirdPartyLedInset(paintSize);

    return SizedBox(
      width: paintSize.width,
      height: paintSize.height,
      // Clip.none so a child that overhangs its lane is visible rather than
      // silently cropped — the editor needs to show the mistake.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: CustomPaint(painter: painter)),
          for (final entry in children) _positionedChild(context, entry, area),
          Positioned(
            left: boundary.left + inset,
            top: boundary.top + inset,
            width: led,
            height: led,
            child: CustomPaint(
              painter: LEDPainter(color: ledColor, ledType: LEDType.circle),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

/// Fits a preview box of [aspect] (width / height) inside the editor column
/// without distorting it. Landscape kinds hit the width limit, the portrait
/// SpeedBatcher hits the height limit.
Size _fitPreview(double aspect, {double maxW = 300, double maxH = 300}) {
  double w = maxW;
  double h = maxW / aspect;
  if (h > maxH) {
    h = maxH;
    w = maxH * aspect;
  }
  return Size(w, h);
}

/// Editor body for [ThirdPartyEquipmentConfig]. Field order follows the
/// house pattern: preview, identity, live keys, colours, label, geometry.
class _ThirdPartyEquipmentConfigEditor extends StatefulWidget {
  final ThirdPartyEquipmentConfig config;
  const _ThirdPartyEquipmentConfigEditor({required this.config});

  @override
  State<_ThirdPartyEquipmentConfigEditor> createState() =>
      _ThirdPartyEquipmentConfigEditorState();
}

class _ThirdPartyEquipmentConfigEditorState
    extends State<_ThirdPartyEquipmentConfigEditor> {
  late TextEditingController _tagController;
  late TextEditingController _notesController;

  // One controller per extra-diode row, index-aligned with
  // `config.extraBits`. Owned here rather than inside each row so they survive
  // the setState rebuilds every edit triggers, and so removing a row shifts
  // its controller out in lockstep with the bit it belongs to.
  late List<TextEditingController> _extraKeyControllers;
  late List<TextEditingController> _extraLabelControllers;

  @override
  void initState() {
    super.initState();
    _tagController = TextEditingController(text: widget.config.tag ?? '');
    _notesController = TextEditingController(text: widget.config.notes ?? '');
    _extraKeyControllers = [
      for (final bit in widget.config.extraBits)
        TextEditingController(text: bit.key),
    ];
    _extraLabelControllers = [
      for (final bit in widget.config.extraBits)
        TextEditingController(text: bit.label),
    ];
  }

  @override
  void dispose() {
    _tagController.dispose();
    _notesController.dispose();
    for (final c in _extraKeyControllers) {
      c.dispose();
    }
    for (final c in _extraLabelControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    // Preview at the machine's TRUE plan aspect ratio, so the layout is
    // undistorted here even if the asset on the page is sized differently.
    // Fitted rather than clamped: the kinds run from a 5.4:1 Multivac strip
    // to a portrait SpeedBatcher, and clamping either axis would squash one
    // of them — which is exactly the distortion this preview exists to avoid.
    final previewSize = _fitPreview(
      config.kind.aspectRatio(
        strapMachines: config.strapMachines,
        robotStations: config.robotStations,
      ),
    );

    return Container(
      width: 360,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: ThirdPartyEquipmentBody(
                painter: thirdPartyPainterFor(
                  config.kind,
                  color: config.outlineColor.resolve(context),
                  strokeWidth: config.strokeWidth,
                  strapMachines: config.strapMachines,
                  robotStations: config.robotStations,
                  mirrorX: config.mirrorX,
                  mirrorY: config.mirrorY,
                ),
                paintSize: previewSize,
                // Preview always shows the running colour — the operator is
                // picking colours here, not reading live state.
                ledColor: config.runningColor.resolve(context),
                // Children are deliberately NOT rendered in the preview: they
                // subscribe to real keys, and the editor should not open live
                // subscriptions just to draw a thumbnail.
              ),
            ),
            const Divider(),

            // -- Equipment kind --
            Text('Equipment', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            DropdownButton<ThirdPartyEquipmentKind>(
              value: config.kind,
              isExpanded: true,
              onChanged: (value) => setState(() {
                config.kind = value!;
                // A SpeedBatcher without its belts and readouts is not a
                // useful asset — the checkweighers ARE conveyors, and the
                // weight and accept rate are the reason the station is on the
                // mimic. Build them on selection so the operator gets a
                // working station and only has to point the keys at tags.
                // Only when empty, so switching away and back cannot discard
                // configured children.
                if (config.kind == ThirdPartyEquipmentKind.speedBatcher &&
                    config.children.isEmpty) {
                  config.children.addAll(buildSpeedBatcherStationChildren(
                    acceptWindowMinutes: config.acceptWindowMinutes,
                    acceptBarsClockAligned: config.acceptBarsClockAligned,
                  ));
                }
              }),
              items: ThirdPartyEquipmentKind.values
                  .map((e) => DropdownMenuItem<ThirdPartyEquipmentKind>(
                        value: e,
                        child: Text(e.label),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),

            // -- Strappers standing on the line --
            if (config.kind.hasStrapMachines) ...[
              Text('Strappers on the line',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                ],
                selected: {config.strapMachines.clamp(1, 3)},
                onSelectionChanged: (selection) =>
                    setState(() => config.strapMachines = selection.first),
              ),
              const SizedBox(height: 16),
            ],

            // -- Palletising stations in the row --
            // Same control as the strapper count, and for the same reason:
            // it changes both what is drawn and the row's proportions, so the
            // preview above redraws as it is turned.
            if (config.kind.hasRobotStations) ...[
              Text('Palletising stations in the row',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                ],
                selected: {config.robotStations.clamp(1, 3)},
                onSelectionChanged: (selection) =>
                    setState(() => config.robotStations = selection.first),
              ),
              const SizedBox(height: 16),
            ],

            // -- Mirroring --
            // Every kind is chiral, so a machine installed the other way round
            // needs the drawing turned over rather than rotated: a 180° turn
            // would put its cabinet at the front and its discharge at the
            // back. Two independent axes, because a hall can be handed either
            // way and the pair covers all four orientations.
            Text('Mirror drawing',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    title: const Text('Left–right'),
                    value: config.mirrorX,
                    onChanged: (v) => setState(() => config.mirrorX = v),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
                Expanded(
                  child: SwitchListTile(
                    title: const Text('Front–back'),
                    value: config.mirrorY,
                    onChanged: (v) => setState(() => config.mirrorY = v),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // -- Run status key --
            KeyField(
              label: 'Run Status Key',
              initialValue: config.runKey,
              onChanged: (v) => setState(() => config.runKey = v),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Invert Run Polarity'),
              subtitle: Text(
                config.invertRunPolarity
                    ? 'Running when state is false'
                    : 'Running when state is true',
              ),
              value: config.invertRunPolarity,
              onChanged: (v) => setState(() => config.invertRunPolarity = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // -- Status key --
            // Every kind with a diode table gets the field — without it those
            // diodes can never leave the unknown state. A struct kind reads
            // members of one node; the prefix kinds read separate bools, so
            // their key is a prefix and the help text spells out the suffixes
            // the pane appends.
            //
            // A kind with NO table — the Optimar palletising row — gets no
            // field. It would feed nothing: the pane draws no Status section
            // for such a kind, and the extra loose diodes below read complete
            // keys of their own rather than anything appended to this one.
            if (hasStatusTable(config.kind)) ...[
              KeyField(
                label: isStructBacked(config.kind)
                    ? 'Status Struct Key'
                    : 'Status Key Prefix',
                initialValue: config.statusKey,
                onChanged: (v) => setState(() => config.statusKey = v),
              ),
              const SizedBox(height: 4),
              Text(
                isStructBacked(config.kind)
                    ? 'Struct with the '
                        '${structMembersOf(config.kind).join(', ')} '
                        'members — one subscription feeds every diode in the side '
                        'pane\'s Status section.'
                    : 'Feeds the diodes in the side pane\'s Status section: '
                        '${(kEquipmentStatusBits[config.kind] ?? const []).map((b) => '.${b.suffix}').join(', ')} '
                        'are appended to this prefix.'
                        // The other three keys off this prefix are named here
                        // or nowhere: none is a diode, so an engineer reading the
                        // list above would never learn they exist, and the
                        // features they carry (the run badge, the link gate, the
                        // trend) would just quietly not appear.
                        '${config.kind == ThirdPartyEquipmentKind.boxErector ? ' Three more ride it without being diodes: '
                            '.$kBoxErectorRunSuffix drives the run lamp and the '
                            'pane header, .$kBoxErectorCommsSuffix greys the pane '
                            'out when the machine stops answering, and '
                            '.$kBoxErectorBpmSuffix draws the throughput trend '
                            'when it is collected.' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
            ],

            // -- Extra loose status diodes --
            // Permits that are neither a member of the kind's handshake struct
            // nor a suffix under the status key: each reads a COMPLETE key of
            // its own (e.g. the Multivac outfeed permit MVC0n.PermitOutfeed, a
            // different namespace from the struct). Rendered after the normal
            // diodes in the side pane's Status section. Empty by default —
            // just the add button shows.
            Text('Extra status diodes',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Loose permit diodes that read a complete key of their own — for '
              'a permit that is not in the status struct, like the Multivac '
              'outfeed permit, which lives on its own MVC0n key. Shown after '
              'the normal diodes in the side pane\'s Status section.\n'
              'Write the label as a template: {m} becomes the machine name, so '
              'reuse the wording the same bit already has elsewhere — an '
              'outfeed permit is "{m} may send boxes on".',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (config.extraBits.isEmpty)
              Text('No extra diodes',
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              for (int i = 0; i < config.extraBits.length; i++)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          controller: _extraKeyControllers[i],
                          decoration: const InputDecoration(
                            labelText: 'Key',
                            hintText: 'e.g. MVC02.PermitOutfeed',
                            isDense: true,
                          ),
                          onChanged: (v) => _updateExtraBit(i, key: v),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _extraLabelControllers[i],
                          decoration: const InputDecoration(
                            labelText: 'Label',
                            // A TEMPLATE, not the finished sentence: `{m}`
                            // becomes the machine's name, so one line reads
                            // right on every instance and matches the wording
                            // the kind's own diodes use.
                            hintText: 'e.g. {m} may send boxes on',
                            helperText: '{m} becomes the machine name',
                            isDense: true,
                          ),
                          onChanged: (v) => _updateExtraBit(i, label: v),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<HmiColorRole>(
                                value: config.extraBits[i].onRole,
                                isExpanded: true,
                                onChanged: (value) {
                                  if (value != null) {
                                    _updateExtraBit(i, onRole: value);
                                  }
                                },
                                items: HmiColorRole.values
                                    .map((e) =>
                                        DropdownMenuItem<HmiColorRole>(
                                          value: e,
                                          child: Text(e.displayName),
                                        ))
                                    .toList(),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _removeExtraBit(i),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _addExtraBit,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add diode'),
              ),
            ),
            const SizedBox(height: 16),

            // -- Colours --
            AssetColorPickerRow(
                label: 'Running Color',
                color: config.runningColor,
                onChanged: (c) => setState(() => config.runningColor = c)),
            const SizedBox(height: 8),
            AssetColorPickerRow(
                label: 'Stopped Color',
                color: config.stoppedColor,
                onChanged: (c) => setState(() => config.stoppedColor = c)),
            const SizedBox(height: 8),
            AssetColorPickerRow(
                label: 'Outline Color',
                color: config.outlineColor,
                onChanged: (c) => setState(() => config.outlineColor = c)),
            const SizedBox(height: 16),

            // -- Stroke width --
            TextFormField(
              initialValue: config.strokeWidth.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Stroke Width'),
              onChanged: (value) {
                final parsed = double.tryParse(value);
                if (parsed != null && parsed > 0.0 && parsed <= 10.0) {
                  setState(() => config.strokeWidth = parsed);
                }
              },
            ),
            const SizedBox(height: 16),

            // -- Tag --
            TextFormField(
              controller: _tagController,
              decoration: const InputDecoration(
                labelText: 'Tag (e.g. MV-01)',
                hintText: 'Optional',
              ),
              onChanged: (v) =>
                  setState(() => config.tag = v.isEmpty ? null : v),
            ),
            // The page label scales its font with the asset's bounding box,
            // and these machines are big — so on the mimic the tag comes out
            // huge. Off keeps it to the side pane, which shows it regardless.
            SwitchListTile(
              title: const Text('Show tag on page'),
              subtitle: const Text(
                  'The side pane shows the tag either way'),
              value: config.showTag,
              onChanged: (v) => setState(() => config.showTag = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // -- Notes (details dialog) --
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Shown in the details dialog',
              ),
              onChanged: (v) =>
                  setState(() => config.notes = v.isEmpty ? null : v),
            ),
            const SizedBox(height: 16),

            // -- Label position --
            // Only meaningful while the tag is painted on the page.
            if (config.showTag) ...[
              Text('Label Position',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              DropdownButton<TextPos>(
                value: config.textPos ?? TextPos.below,
                isExpanded: true,
                onChanged: (value) => setState(() => config.textPos = value!),
                items: TextPos.values
                    .map((e) => DropdownMenuItem<TextPos>(
                        value: e, child: Text(e.name)))
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],

            SizeField(
              initialValue: config.size,
              onChanged: (v) => setState(() => config.size = v),
            ),
            const SizedBox(height: 16),

            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (c) => setState(() => config.coordinates = c),
              enableAngle: true,
            ),
            const SizedBox(height: 16),
            const Divider(),

            // -- Children --
            // The parts of a third-party machine we DO have signals for get
            // their real asset instead of a painted approximation: a conveyor
            // driven by its actual drive frequency, a sensor on the infeed.
            // Positions are fractions of the machine area, so a child stays
            // on its lane at any asset size.
            Text('Inside the box',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              config.kind == ThirdPartyEquipmentKind.speedBatcher
                  ? 'The SpeedBatcher station is fixed: two checkweigher '
                      'belts with weight and accept-rate readouts. Point '
                      'each one at its tag with Configure below.'
                  : 'Place live assets over the drawing — e.g. a Conveyor '
                      'on an infeed lane, driven by its real frequency.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (config.kind == ThirdPartyEquipmentKind.speedBatcher)
                  // The SpeedBatcher station is static: its checkweigher
                  // belts and readouts are the scaffold and nothing else
                  // belongs in the box, so the free-form add buttons are
                  // withheld for this kind. This button only recovers the
                  // scaffold if the children were removed.
                  FilledButton.icon(
                    onPressed: _addStationScaffold,
                    icon: const Icon(Icons.auto_awesome_motion, size: 18),
                    label: const Text('Build checkweighers'),
                  )
                else ...[
                  FilledButton.tonalIcon(
                    onPressed: () => _addChild(
                        thirdPartyNumber(units: '', decimalPlaces: 1),
                        keepUpright: true),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Readout'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _addChild(thirdPartyConveyor()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Conveyor'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _addChild(SensorConfig.preview()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Sensor'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            // One angle for every readout in the box. Zero keeps them level
            // on screen whatever angle the machine is placed at.
            Row(
              children: [
                const Expanded(child: Text('Readout angle')),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: config.childTextAngle.toStringAsFixed(0),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      suffixText: '°',
                      isDense: true,
                      helperText: '0 = level',
                    ),
                    onChanged: (v) {
                      final parsed = double.tryParse(v);
                      if (parsed != null) {
                        setState(() => config.childTextAngle = parsed);
                      }
                    },
                  ),
                ),
              ],
            ),
            if (config.kind == ThirdPartyEquipmentKind.speedBatcher) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(child: Text('Accept rate window')),
                  SizedBox(
                    width: 130,
                    child: DurationField(
                      value: Duration(minutes: config.acceptWindowMinutes),
                      labelText: '',
                      isDense: true,
                      min: const Duration(minutes: 1),
                      max: const Duration(hours: 24),
                      units: const [DurationUnit.minutes, DurationUnit.hours],
                      // The config stores whole minutes.
                      resolution: const Duration(minutes: 1),
                      onChanged: (v) => setState(
                          () => config.acceptWindowMinutes = v.inMinutes),
                    ),
                  ),
                ],
              ),
              Text(
                'Shown in the readout units, so nobody reads a rolling '
                'average as the last pack. Change it before building the '
                'checkweighers.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Clock-aligned accept bars'),
                subtitle: Text(
                  config.acceptBarsClockAligned
                      ? 'Bars sit on the clock — a 10 min interval buckets at '
                          ':00, :10, :20'
                      : 'Bars are measured back from now, so they slide with '
                          'every refresh',
                ),
                value: config.acceptBarsClockAligned,
                onChanged: (v) => setState(() {
                  config.acceptBarsClockAligned = v;
                  config.applyAcceptReadoutSettings();
                }),
              ),
            ],
            const SizedBox(height: 8),
            if (config.children.isEmpty)
              Text('Nothing placed inside',
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              for (int i = 0; i < config.children.length; i++)
                _ChildRow(
                  key: ValueKey(config.children[i].id),
                  entry: config.children[i],
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() => config.children.removeAt(i)),
                ),
          ],
        ),
      ),
    );
  }

  void _addChild(BaseAsset child, {bool keepUpright = false}) {
    setState(() {
      widget.config.children
          .add(ThirdPartyChildEntry(child: child, keepUpright: keepUpright));
    });
  }

  /// Appends an empty loose diode plus its two controllers, keeping the three
  /// lists index-aligned.
  ///
  /// The colour is left to [ExtraStatusBit]'s own default rather than restated
  /// here — green, what a permit is on every machine in this file — so the
  /// editor cannot drift from the type the way a second literal would.
  void _addExtraBit() {
    setState(() {
      widget.config.extraBits.add(const ExtraStatusBit(key: '', label: ''));
      _extraKeyControllers.add(TextEditingController());
      _extraLabelControllers.add(TextEditingController());
    });
  }

  /// Drops row [i] from the bits list and disposes its controllers, so the
  /// three lists stay the same length and aligned.
  void _removeExtraBit(int i) {
    setState(() {
      widget.config.extraBits.removeAt(i);
      _extraKeyControllers.removeAt(i).dispose();
      _extraLabelControllers.removeAt(i).dispose();
    });
  }

  /// Replaces row [i] in place — [ExtraStatusBit] is immutable, so an edit
  /// rebuilds the whole bit, carrying over the fields not being changed.
  void _updateExtraBit(int i, {String? key, String? label, HmiColorRole? onRole}) {
    final bit = widget.config.extraBits[i];
    setState(() {
      widget.config.extraBits[i] = ExtraStatusBit(
        key: key ?? bit.key,
        label: label ?? bit.label,
        onRole: onRole ?? bit.onRole,
      );
    });
  }

  /// Drops in a bidirectional conveyor plus weight and accept-rate readouts
  /// for each checkweigher, positioned on the drawing. Additive — pressing it
  /// twice stacks a second set rather than silently replacing what is there,
  /// so nothing an operator configured gets thrown away by a stray tap.
  void _addStationScaffold() {
    setState(() {
      widget.config.children.addAll(buildSpeedBatcherStationChildren(
        acceptWindowMinutes: widget.config.acceptWindowMinutes,
        acceptBarsClockAligned: widget.config.acceptBarsClockAligned,
      ));
    });
  }
}

/// One row of the children list: what it is, where it sits, and how to
/// configure or remove it.
class _ChildRow extends StatelessWidget {
  const _ChildRow({
    super.key,
    required this.entry,
    required this.onChanged,
    required this.onRemove,
  });

  final ThirdPartyChildEntry entry;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(entry.child.displayName,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Configure',
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: () async {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: SingleChildScrollView(
                          child: entry.child.configure(context),
                        ),
                      ),
                    );
                    onChanged();
                  },
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: onRemove,
                ),
              ],
            ),
            // Position within the machine area, 0..1 on each axis.
            _OffsetSlider(
              label: 'X',
              value: entry.offsetX,
              onChanged: (v) {
                entry.offsetX = v;
                onChanged();
              },
            ),
            _OffsetSlider(
              label: 'Y',
              value: entry.offsetY,
              onChanged: (v) {
                entry.offsetY = v;
                onChanged();
              },
            ),
            // Readouts stay level; machinery turns with the machine.
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Keep level when the machine is rotated'),
              value: entry.keepUpright,
              onChanged: (v) {
                entry.keepUpright = v ?? false;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The x/y pair that places a machine's plan view. A one-character label ('X',
/// 'Y') and a fraction of the bounding box, so it reads as a coordinate rather
/// than a percentage.
class _OffsetSlider extends StatelessWidget {
  const _OffsetSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return NumberSlider(
      label: label,
      labelWidth: 16,
      value: value.clamp(0.0, 1.0),
      min: 0.0,
      max: 1.0,
      divisions: 100,
      decimals: 2,
      onChanged: onChanged,
    );
  }
}
