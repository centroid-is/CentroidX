import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logger/logger.dart';
import 'common.dart';
import 'led.dart';
import 'button.dart';
import 'conveyor.dart';
import 'arrow.dart';
import 'led_column.dart';
import 'drawn_box.dart';
import 'number.dart';
import 'graph.dart';
import 'ratio_number.dart';
import 'baader.dart';
import 'analog_box.dart';
import 'option_variable.dart';
import 'text.dart';
import 'beckhoff.dart';
import 'advantys_stb.dart';
import 'festo.dart';
import 'schneider.dart';
import 'icon.dart';
import 'image.dart';
import 'table.dart';
import 'start_stop_button.dart';
import 'section_button.dart';
import 'aircab.dart';
import 'checklists.dart';
import 'elcab.dart';
import 'recipes.dart';
import 'bpm.dart';
import 'rate_value.dart';
import 'speedbatcher.dart';
import 'conveyor_gate.dart';
import 'elevator.dart';
import 'sensor.dart';
import '../../core/feature_flags.dart';
import 'connection_info.dart';
import 'ethercat_link.dart';
import 'ethercat_devices.dart';
import 'drawing_viewer.dart';
import 'third_party.dart';
import 'alarm_visibility.dart';
import 'rtsp_camera.dart';
import 'web_view.dart';

class AssetRegistry {
  static final Logger _log = Logger();

  static final Map<Type, Asset Function(Map<String, dynamic>)>
      _fromJsonFactories = {
    LEDConfig: LEDConfig.fromJson,
    ButtonConfig: ButtonConfig.fromJson,
    ConveyorConfig: ConveyorConfig.fromJson,
    RollerConveyorConfig: RollerConveyorConfig.fromJson,
    ConveyorGateConfig: ConveyorGateConfig.fromJson,
    SensorConfig: SensorConfig.fromJson,
    ConnectionInfoConfig: ConnectionInfoConfig.fromJson,
    EtherCatLinkConfig: EtherCatLinkConfig.fromJson,
    EtherCatDeviceTableConfig: EtherCatDeviceTableConfig.fromJson,
    ElevatorConfig: ElevatorConfig.fromJson,
    ConveyorColorPaletteConfig: ConveyorColorPaletteConfig.fromJson,
    ArrowConfig: ArrowConfig.fromJson,
    LEDColumnConfig: LEDColumnConfig.fromJson,
    DrawnBoxConfig: DrawnBoxConfig.fromJson,
    NumberConfig: NumberConfig.fromJson,
    GraphAssetConfig: GraphAssetConfig.fromJson,
    RatioNumberConfig: RatioNumberConfig.fromJson,
    BpmConfig: BpmConfig.fromJson,
    RateValueConfig: RateValueConfig.fromJson,
    Baader221Config: Baader221Config.fromJson,
    AnalogBoxConfig: AnalogBoxConfig.fromJson,
    OptionVariableConfig: OptionVariableConfig.fromJson,
    TextAssetConfig: TextAssetConfig.fromJson,
    BeckhoffCX5010Config: BeckhoffCX5010Config.fromJson,
    BeckhoffCX5340Config: BeckhoffCX5340Config.fromJson,
    BeckhoffEL1008Config: BeckhoffEL1008Config.fromJson,
    BeckhoffEL2008Config: BeckhoffEL2008Config.fromJson,
    BeckhoffEL9222Config: BeckhoffEL9222Config.fromJson,
    BeckhoffEL9186Config: BeckhoffEL9186Config.fromJson,
    BeckhoffEL9187Config: BeckhoffEL9187Config.fromJson,
    BeckhoffEK1100Config: BeckhoffEK1100Config.fromJson,
    BeckhoffEL3054Config: BeckhoffEL3054Config.fromJson,
    BeckhoffEL2912Config: BeckhoffEL2912Config.fromJson,
    BeckhoffEL6070Config: BeckhoffEL6070Config.fromJson,
    BeckhoffEK1110Config: BeckhoffEK1110Config.fromJson,
    BeckhoffPS2001Config: BeckhoffPS2001Config.fromJson,
    BeckhoffCU2508Config: BeckhoffCU2508Config.fromJson,
    BeckhoffEPBoxConfig: BeckhoffEPBoxConfig.fromJson,
    FestoVTUGConfig: FestoVTUGConfig.fromJson,
    STBDDI3725Config: STBDDI3725Config.fromJson,
    STBDDO3705Config: STBDDO3705Config.fromJson,
    STBNIP2311Config: STBNIP2311Config.fromJson,
    STBPDT3100Config: STBPDT3100Config.fromJson,
    SchneiderATV320Config: SchneiderATV320Config.fromJson,
    IconConfig: IconConfig.fromJson,
    ImageConfig: ImageConfig.fromJson,
    TableAssetConfig: TableAssetConfig.fromJson,
    StartStopPillButtonConfig: StartStopPillButtonConfig.fromJson,
    SectionButtonConfig: SectionButtonConfig.fromJson,
    AirCabConfig: AirCabConfig.fromJson,
    ChecklistsConfig: ChecklistsConfig.fromJson,
    ElCabConfig: ElCabConfig.fromJson,
    RecipesConfig: RecipesConfig.fromJson,
    SpeedBatcherConfig: SpeedBatcherConfig.fromJson,
    GateStatusConfig: GateStatusConfig.fromJson,
    DrawingViewerConfig: DrawingViewerConfig.fromJson,
    ThirdPartyEquipmentConfig: ThirdPartyEquipmentConfig.fromJson,
    AlarmVisibilityConfig: AlarmVisibilityConfig.fromJson,
    RtspCameraConfig: RtspCameraConfig.fromJson,
    WebViewAssetConfig: WebViewAssetConfig.fromJson,
  };

  static final Map<Type, Asset Function()> defaultFactories = {
    LEDConfig: LEDConfig.preview,
    LEDColumnConfig: LEDColumnConfig.preview,
    ButtonConfig: ButtonConfig.preview,
    ArrowConfig: ArrowConfig.preview,
    ConveyorConfig: ConveyorConfig.preview,
    RollerConveyorConfig: RollerConveyorConfig.preview,
    ConveyorGateConfig: ConveyorGateConfig.preview,
    SensorConfig: SensorConfig.preview,
    EtherCatLinkConfig: EtherCatLinkConfig.preview,
    EtherCatDeviceTableConfig: EtherCatDeviceTableConfig.preview,
    ConnectionInfoConfig: ConnectionInfoConfig.preview,
    ElevatorConfig: ElevatorConfig.preview,
    ConveyorColorPaletteConfig: ConveyorColorPaletteConfig.preview,
    NumberConfig: NumberConfig.preview,
    RatioNumberConfig: RatioNumberConfig.preview,
    BpmConfig: BpmConfig.preview,
    RateValueConfig: RateValueConfig.preview,
    TableAssetConfig: TableAssetConfig.preview,
    GraphAssetConfig: GraphAssetConfig.preview,
    Baader221Config: Baader221Config.preview,
    AnalogBoxConfig: AnalogBoxConfig.preview,
    OptionVariableConfig: OptionVariableConfig.preview,
    TextAssetConfig: TextAssetConfig.preview,
    BeckhoffCX5010Config: BeckhoffCX5010Config.preview,
    BeckhoffCX5340Config: BeckhoffCX5340Config.preview,
    BeckhoffEL1008Config: BeckhoffEL1008Config.preview,
    BeckhoffEL2008Config: BeckhoffEL2008Config.preview,
    BeckhoffEL9222Config: BeckhoffEL9222Config.preview,
    BeckhoffEL9186Config: BeckhoffEL9186Config.preview,
    BeckhoffEL9187Config: BeckhoffEL9187Config.preview,
    BeckhoffEK1100Config: BeckhoffEK1100Config.preview,
    BeckhoffEL3054Config: BeckhoffEL3054Config.preview,
    BeckhoffEL2912Config: BeckhoffEL2912Config.preview,
    BeckhoffEL6070Config: BeckhoffEL6070Config.preview,
    BeckhoffEK1110Config: BeckhoffEK1110Config.preview,
    BeckhoffPS2001Config: BeckhoffPS2001Config.preview,
    BeckhoffCU2508Config: BeckhoffCU2508Config.preview,
    BeckhoffEPBoxConfig: BeckhoffEPBoxConfig.preview,
    FestoVTUGConfig: FestoVTUGConfig.preview,
    STBDDI3725Config: STBDDI3725Config.preview,
    STBDDO3705Config: STBDDO3705Config.preview,
    STBNIP2311Config: STBNIP2311Config.preview,
    STBPDT3100Config: STBPDT3100Config.preview,
    SchneiderATV320Config: SchneiderATV320Config.preview,
    IconConfig: IconConfig.preview,
    ImageConfig: ImageConfig.preview,
    DrawnBoxConfig: DrawnBoxConfig.preview,
    StartStopPillButtonConfig: StartStopPillButtonConfig.preview,
    SectionButtonConfig: SectionButtonConfig.preview,
    AirCabConfig: AirCabConfig.preview,
    ChecklistsConfig: ChecklistsConfig.preview,
    ElCabConfig: ElCabConfig.preview,
    RecipesConfig: RecipesConfig.preview,
    SpeedBatcherConfig: SpeedBatcherConfig.preview,
    GateStatusConfig: GateStatusConfig.preview,
    // Palette entry only — the fromJson factory above stays registered
    // regardless of the flag so saved pages containing a DrawingViewer
    // round-trip instead of silently losing the asset on the next save.
    if (kKnowledgeEnabled) DrawingViewerConfig: DrawingViewerConfig.preview,
    ThirdPartyEquipmentConfig: ThirdPartyEquipmentConfig.preview,
    AlarmVisibilityConfig: AlarmVisibilityConfig.preview,
    RtspCameraConfig: RtspCameraConfig.preview,
    if (kWebViewEnabled) WebViewAssetConfig: WebViewAssetConfig.preview,
  };

  static void registerFromJsonFactory<T extends Asset>(
      Asset Function(Map<String, dynamic>) fromJson) {
    _fromJsonFactories[T] = fromJson;
  }

  static void registerDefaultFactory<T extends Asset>(
      Asset Function() preview) {
    defaultFactories[T] = preview;
  }

  /// How many times [parse] has run. Parsing walks every JSON node and
  /// reconstructs every asset, so tests pin that editor gestures (a nudge,
  /// a drag) never trigger it — undo snapshots stay encoded strings.
  @visibleForTesting
  static int debugParses = 0;

  static List<Asset> parse(Map<String, dynamic> json) {
    debugParses++;
    final List<Asset> foundWidgets = [];
    // No per-node or per-asset logging in here: this crawl visits every JSON
    // node of every page and runs on hot paths (page load, undo, paste,
    // proposal staging). A trace record per node means thousands of
    // stack-capturing console prints per call in debug runs, which is
    // seconds of UI stall on a real project. Warnings and errors only.
    void crawlJson(dynamic jsonPart) {
      if (jsonPart is Map<String, dynamic>) {
        if (jsonPart.containsKey(constAssetName)) {
          final assetName = jsonPart[constAssetName] as String;
          for (final factory in _fromJsonFactories.entries) {
            if (factory.key.toString() == assetName) {
              try {
                final asset = factory.value(jsonPart);
                foundWidgets.add(asset);
                return; // Found an asset, don't crawl deeper
              } catch (e, stackTrace) {
                // Never rethrow: one unparseable asset used to propagate up
                // to PageManager.load()'s catch, which resets EVERY page to
                // defaults — a single bad field blanked a whole plant HMI
                // (2026-08-26). Skip the asset and keep the rest of the
                // plant on screen. The cost is the same as an unrecognized
                // asset type: this entry will not render and will be
                // dropped if the page is re-saved by this build.
                _log.e(
                  'Failed to parse asset of type $assetName — skipping it '
                  '(it will not render, and will be dropped if the page is '
                  're-saved by this build)',
                  error: e,
                  stackTrace: stackTrace,
                );
                return;
              }
            }
          }
          // A key under constAssetName that matched no registered factory:
          // the entry will be dropped on the next save. Warn loudly — this
          // is how assets from a build with more features (or a newer
          // version) silently disappear.
          _log.w('Unrecognized asset type "$assetName" in page config — '
              'it will not render and will be dropped if the page is '
              're-saved by this build.');
        }
        // If not an asset, crawl deeper
        jsonPart.values.forEach(crawlJson);
      } else if (jsonPart is List) {
        jsonPart.forEach(crawlJson);
      }
    }

    crawlJson(json);
    return foundWidgets;
  }

  static Asset createDefaultAsset(Type assetType) {
    final factory = defaultFactories[assetType];
    if (factory == null) {
      throw Exception('Unknown asset type');
    }
    return factory();
  }

  /// Creates a default asset by its string name (e.g., "ButtonConfig").
  ///
  /// Returns null if no factory matches the given name. This is used by the
  /// proposal system where asset type names arrive as strings from the MCP
  /// server, and the full JSON for [parse] is not available (missing required
  /// fields like colors, sizes, etc.).
  static Asset? createDefaultAssetByName(String assetName) {
    for (final entry in defaultFactories.entries) {
      if (entry.key.toString() == assetName) {
        return entry.value();
      }
    }
    return null;
  }
}
