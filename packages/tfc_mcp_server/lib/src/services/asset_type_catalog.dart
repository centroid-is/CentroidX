/// Static catalog of all HMI asset types available in the AssetRegistry.
///
/// This catalog mirrors the Flutter-side `AssetRegistry` (which depends on
/// Flutter widgets) as a pure-Dart data structure suitable for the MCP server.
/// It provides the LLM with a complete inventory of asset types, their
/// categories, descriptions, and configurable properties so it can create
/// accurate proposals without guessing.
///
/// **Maintenance:** When a new asset type is added to the Flutter-side
/// `AssetRegistry` (in `lib/page_creator/assets/registry.dart`), a
/// corresponding entry must be added here. The app-layer test
/// `test/mcp/asset_type_sync_test.dart` fails when the two diverge.
/// `kValidAssetTypes` (used in the propose_asset/propose_page schemas)
/// is derived from this catalog.
library;

/// Metadata for a single configurable property of an asset type.
class AssetPropertyInfo {
  /// The JSON key name for this property.
  final String name;

  /// The data type (e.g., "String", "Color", "bool", "int", "double").
  final String type;

  /// Human-readable description of what this property controls.
  final String description;

  /// Whether this property is required when creating the asset.
  final bool required;

  const AssetPropertyInfo({
    required this.name,
    required this.type,
    required this.description,
    this.required = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'description': description,
        'required': required,
      };
}

/// Metadata for a single asset type in the HMI system.
class AssetTypeInfo {
  /// The Dart class name used as the `asset_name` key in JSON configs.
  /// Example: "LEDConfig", "ButtonConfig".
  final String assetName;

  /// Human-readable display name shown in the page editor UI.
  final String displayName;

  /// Category for grouping in the editor palette.
  final String category;

  /// Description of what this asset does, for the LLM's context.
  final String description;

  /// Configurable properties beyond the base properties
  /// (coordinates, size, text, textPos) that all assets share.
  final List<AssetPropertyInfo> properties;

  const AssetTypeInfo({
    required this.assetName,
    required this.displayName,
    required this.category,
    required this.description,
    this.properties = const [],
  });

  Map<String, dynamic> toJson() => {
        'assetName': assetName,
        'displayName': displayName,
        'category': category,
        'description': description,
        'properties': properties.map((p) => p.toJson()).toList(),
      };
}

/// The complete catalog of asset types available in the TFC HMI.
///
/// Use [AssetTypeCatalog.all] for the full list, [AssetTypeCatalog.categories]
/// for distinct category names, or [AssetTypeCatalog.byCategory] to filter.
class AssetTypeCatalog {
  AssetTypeCatalog._();

  /// All registered asset types, ordered by category then display name.
  static const List<AssetTypeInfo> all = [
    // ── Basic Indicators ──────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'LEDConfig',
      displayName: 'LED',
      category: 'Basic Indicators',
      description:
          'A status indicator light (circle or square) that subscribes to '
          'a boolean key. Shows on_color when true, off_color when false.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Boolean tag key to subscribe to',
            required: true),
        AssetPropertyInfo(
            name: 'on_color',
            type: 'Color',
            description: 'Color when the key value is true'),
        AssetPropertyInfo(
            name: 'off_color',
            type: 'Color',
            description: 'Color when the key value is false'),
        AssetPropertyInfo(
            name: 'led_type',
            type: 'LEDType',
            description: 'Shape of the LED: "circle" or "square"'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'LEDColumnConfig',
      displayName: 'LED Column',
      category: 'Basic Indicators',
      description:
          'A vertical stack of LED indicators, each with its own key '
          'and color settings. Useful for multi-channel status displays.',
      properties: [
        AssetPropertyInfo(
            name: 'leds',
            type: 'List<LEDConfig>',
            description: 'Array of LED configurations in the column',
            required: true),
        AssetPropertyInfo(
            name: 'spacing',
            type: 'double',
            description: 'Vertical spacing between LEDs'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ArrowConfig',
      displayName: 'Arrow',
      category: 'Basic Indicators',
      description:
          'A directional arrow indicator bound to a key. Shows flow '
          'direction or state with a label.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key to subscribe to',
            required: true),
        AssetPropertyInfo(
            name: 'label',
            type: 'String',
            description: 'Text label for the arrow',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'DrawnBoxConfig',
      displayName: 'Drawn Box',
      category: 'Basic Indicators',
      description:
          'A decorative box with configurable borders (solid or dashed), '
          'color, and line width. Individual sides can be hidden. Used for '
          'visual grouping on pages.',
      properties: [
        AssetPropertyInfo(
            name: 'color',
            type: 'Color',
            description: 'Border color of the box'),
        AssetPropertyInfo(
            name: 'lineWidth',
            type: 'double',
            description: 'Width of the border lines'),
        AssetPropertyInfo(
            name: 'isDashed',
            type: 'bool',
            description: 'Whether the border is dashed'),
        AssetPropertyInfo(
            name: 'showTop',
            type: 'bool',
            description: 'Whether to draw the top border'),
        AssetPropertyInfo(
            name: 'showRight',
            type: 'bool',
            description: 'Whether to draw the right border'),
        AssetPropertyInfo(
            name: 'showBottom',
            type: 'bool',
            description: 'Whether to draw the bottom border'),
        AssetPropertyInfo(
            name: 'showLeft',
            type: 'bool',
            description: 'Whether to draw the left border'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'IconConfig',
      displayName: 'Icon',
      category: 'Basic Indicators',
      description:
          'A Material Design icon with optional color and conditional '
          'states. Can change icon and color based on boolean expressions '
          'over tag values.',
      properties: [
        AssetPropertyInfo(
            name: 'iconData',
            type: 'IconData',
            description: 'The Material icon to display',
            required: true),
        AssetPropertyInfo(
            name: 'color', type: 'Color', description: 'Icon color'),
        AssetPropertyInfo(
            name: 'conditional_states',
            type: 'List<ConditionalIconState>',
            description:
                'Rules that change icon/color based on boolean expressions'),
      ],
    ),

    // ── Interactive Controls ──────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'ButtonConfig',
      displayName: 'Button',
      category: 'Interactive Controls',
      description:
          'A pressable button (circle or square) that writes to an OPC UA '
          'tag on press/release. Supports toggle mode, feedback indicators, '
          'and optional icon overlay.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key to write to on press',
            required: true),
        AssetPropertyInfo(
            name: 'outward_color',
            type: 'Color',
            description: 'Button color in released state'),
        AssetPropertyInfo(
            name: 'inward_color',
            type: 'Color',
            description: 'Button color in pressed state'),
        AssetPropertyInfo(
            name: 'button_type',
            type: 'ButtonType',
            description: 'Shape: "circle" or "square"'),
        AssetPropertyInfo(
            name: 'is_toggle',
            type: 'bool',
            description: 'Whether the button stays pressed (toggle mode)'),
        AssetPropertyInfo(
            name: 'feedback',
            type: 'FeedbackConfig',
            description:
                'Live feedback indicator (key + color) from a separate tag'),
        AssetPropertyInfo(
            name: 'icon',
            type: 'IconConfig',
            description: 'Optional icon rendered on the button'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'StartStopPillButtonConfig',
      displayName: 'Start/Stop Button',
      category: 'Interactive Controls',
      description:
          'A pill-shaped run/clean/stop button cluster. Writes pulse '
          'signals on press/release and shows live feedback from running/'
          'stopped/cleaning state keys.',
      properties: [
        AssetPropertyInfo(
            name: 'runKey',
            type: 'String',
            description: 'Tag key pulsed to start',
            required: true),
        AssetPropertyInfo(
            name: 'stopKey',
            type: 'String',
            description: 'Tag key pulsed to stop',
            required: true),
        AssetPropertyInfo(
            name: 'cleanKey',
            type: 'String',
            description:
                'Tag key pulsed for clean mode (optional, hides segment if null)'),
        AssetPropertyInfo(
            name: 'runningKey',
            type: 'String',
            description: 'Boolean feedback key for running state',
            required: true),
        AssetPropertyInfo(
            name: 'stoppedKey',
            type: 'String',
            description: 'Boolean feedback key for stopped state',
            required: true),
        AssetPropertyInfo(
            name: 'cleaningKey',
            type: 'String',
            description: 'Boolean feedback key for cleaning state'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'SectionButtonConfig',
      displayName: 'Section Button',
      category: 'Interactive Controls',
      description:
          'A round power button for one or more plant sections (FB_Section '
          'instances). The face takes the section state colour — green in '
          'auto, blue cleaning, grey stopped, yellow when it is not allowed '
          'to start, grey with an exclamation mark when it cannot be read — '
          'and splits along a diagonal when the sections behind it disagree. '
          'A tap opens a pane that starts, cleans and stops them and counts '
          'how long they have been that way.',
      properties: [
        AssetPropertyInfo(
            name: 'sections',
            type: 'List<SectionRef>',
            description:
                'The FB_Section instances this button drives. Each entry has '
                '"key" (the ST_Section_HMI struct, carrying p_cmd_Start / '
                'p_cmd_StartClean / p_cmd_Stop and p_stat_xEnabled / '
                'p_stat_xCleanEnabled / p_stat_xPermissive), an optional '
                '"label" naming it in the pane list (e.g. ST101), and an '
                'optional "hold_reason" shown behind "Allowed to start" '
                'saying what holds that section, in operator words. The same '
                'line on several PLCs belongs behind one button.',
            required: true),
        AssetPropertyInfo(
            name: 'label',
            type: 'String',
            description: 'Button name shown as the pane title'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'OptionVariableConfig',
      displayName: 'Option Variable',
      category: 'Interactive Controls',
      description:
          'A dropdown selector that sets a StateMan variable from a '
          'predefined list of options. Used for mode selection, recipe '
          'picking, or configuration switching.',
      properties: [
        AssetPropertyInfo(
            name: 'variableName',
            type: 'String',
            description: 'The StateMan variable name to set',
            required: true),
        AssetPropertyInfo(
            name: 'options',
            type: 'List<OptionItem>',
            description: 'Available options (value + label + description)',
            required: true),
        AssetPropertyInfo(
            name: 'defaultValue',
            type: 'String',
            description: 'Default selected value'),
        AssetPropertyInfo(
            name: 'showSearch',
            type: 'bool',
            description: 'Whether to show a search/filter field'),
        AssetPropertyInfo(
            name: 'customLabel',
            type: 'String',
            description: 'Custom label for the dropdown'),
      ],
    ),

    // ── Text & Numbers ────────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'NumberConfig',
      displayName: 'Number',
      category: 'Text & Numbers',
      description:
          'Displays a live numeric value from a tag key. Configurable '
          'decimal places, units, scale factor, color, and optional '
          'inline graph. Can be made writable for operator input.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key to subscribe to',
            required: true),
        AssetPropertyInfo(
            name: 'showDecimalPoint',
            type: 'bool',
            description: 'Whether to show decimal point'),
        AssetPropertyInfo(
            name: 'decimalPlaces',
            type: 'int',
            description: 'Number of decimal places to display'),
        AssetPropertyInfo(
            name: 'scale',
            type: 'double',
            description: 'Scale factor applied to the raw value'),
        AssetPropertyInfo(
            name: 'units',
            type: 'String',
            description: 'Unit suffix displayed after the number'),
        AssetPropertyInfo(
            name: 'textColor',
            type: 'Color',
            description: 'Color of the displayed text'),
        AssetPropertyInfo(
            name: 'writable',
            type: 'bool',
            description: 'Whether the operator can tap to edit the value'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'TextAssetConfig',
      displayName: 'Text',
      category: 'Text & Numbers',
      description:
          'A static or dynamic text label. Supports variable substitution '
          'using \$key syntax (e.g., "Temp: \$pump3.temp") where keys are '
          'resolved from live tag values.',
      properties: [
        AssetPropertyInfo(
            name: 'textContent',
            type: 'String',
            description: 'Text content, optionally with \$variable placeholders',
            required: true),
        AssetPropertyInfo(
            name: 'textColor',
            type: 'Color',
            description: 'Text color'),
        AssetPropertyInfo(
            name: 'enableVariableSubstitution',
            type: 'bool',
            description: 'Enable \$key variable substitution in text'),
        AssetPropertyInfo(
            name: 'decimalPlaces',
            type: 'int',
            description: 'Decimal places for substituted numeric values'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'AnalogBoxConfig',
      displayName: 'Analog Box',
      category: 'Text & Numbers',
      description:
          'A compact analog value display with bar indicator, setpoints, '
          'hysteresis bands, and error state. Shows live analog value with '
          'min/max range and optional setpoint controls.',
      properties: [
        AssetPropertyInfo(
            name: 'analog_key',
            type: 'String',
            description: 'Tag key for the live analog value',
            required: true),
        AssetPropertyInfo(
            name: 'setpoint1_key',
            type: 'String',
            description: 'Tag key for first setpoint (writable)'),
        AssetPropertyInfo(
            name: 'setpoint1_hysteresis_key',
            type: 'String',
            description: 'Tag key for setpoint 1 hysteresis'),
        AssetPropertyInfo(
            name: 'setpoint2_key',
            type: 'String',
            description: 'Tag key for second setpoint'),
        AssetPropertyInfo(
            name: 'error_key',
            type: 'String',
            description: 'Tag key for error indicator'),
        AssetPropertyInfo(
            name: 'min_value',
            type: 'double',
            description: 'Minimum scale value'),
        AssetPropertyInfo(
            name: 'max_value',
            type: 'double',
            description: 'Maximum scale value'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'RatioNumberConfig',
      displayName: 'Ratio Number',
      category: 'Text & Numbers',
      description:
          'Displays the ratio between two timeseries values (key1/key2) '
          'with an interactive bar chart over configurable time windows.',
      properties: [
        AssetPropertyInfo(
            name: 'key1',
            type: 'String',
            description: 'Numerator tag key',
            required: true),
        AssetPropertyInfo(
            name: 'key2',
            type: 'String',
            description: 'Denominator tag key',
            required: true),
        AssetPropertyInfo(
            name: 'key1_label',
            type: 'String',
            description: 'Label for the numerator',
            required: true),
        AssetPropertyInfo(
            name: 'key2_label',
            type: 'String',
            description: 'Label for the denominator',
            required: true),
        AssetPropertyInfo(
            name: 'text_color',
            type: 'Color',
            description: 'Text color'),
        AssetPropertyInfo(
            name: 'how_many',
            type: 'int',
            description: 'Number of time windows to display'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BpmConfig',
      displayName: 'BPM Counter',
      category: 'Text & Numbers',
      description:
          'Counts events per minute from a timeseries key with a bar '
          'chart. Configurable time window, poll interval, and presets. '
          'Can also show events per hour.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Timeseries key to count events from',
            required: true),
        AssetPropertyInfo(
            name: 'text_color',
            type: 'Color',
            description: 'Text color'),
        AssetPropertyInfo(
            name: 'default_interval',
            type: 'int',
            description: 'Default time window in minutes'),
        AssetPropertyInfo(
            name: 'how_many',
            type: 'int',
            description: 'Number of bars in the chart'),
        AssetPropertyInfo(
            name: 'unit',
            type: 'String',
            description: 'Unit label (e.g., "bpm")'),
        AssetPropertyInfo(
            name: 'show_bph',
            type: 'bool',
            description: 'Whether to show beats per hour'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'RateValueConfig',
      displayName: 'Rate Value',
      category: 'Text & Numbers',
      description:
          'Computes and displays the rate (per minute or per hour) from '
          'a cumulative timeseries value with a bar chart history.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Timeseries key to compute rate from',
            required: true),
        AssetPropertyInfo(
            name: 'text_color',
            type: 'Color',
            description: 'Text color'),
        AssetPropertyInfo(
            name: 'default_interval',
            type: 'int',
            description: 'Default time window in minutes'),
        AssetPropertyInfo(
            name: 'how_many',
            type: 'int',
            description: 'Number of bars in the chart'),
        AssetPropertyInfo(
            name: 'unit',
            type: 'String',
            description: 'Unit label (e.g., "kg/min")'),
        AssetPropertyInfo(
            name: 'show_per_hour',
            type: 'bool',
            description: 'Show rate per hour instead of per minute'),
      ],
    ),

    // ── Visualization ─────────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'ImageConfig',
      displayName: 'Image',
      category: 'Visualization',
      description:
          'A static image (PNG, JPEG, BMP or SVG). The bytes are stored '
          'under a separate preference key (page_editor_image:<id>) and the '
          'asset references them by content-hash id; images are added '
          'through the page editor (file picker or clipboard paste), not '
          'via MCP.',
      properties: [
        AssetPropertyInfo(
            name: 'image_id',
            type: 'String',
            description:
                'Content-hash id of the stored image bytes; null shows a '
                'placeholder'),
        AssetPropertyInfo(
            name: 'source_name',
            type: 'String',
            description: 'Original file name, informational only'),
        AssetPropertyInfo(
            name: 'fit',
            type: 'BoxFit',
            description:
                'How the image fills the asset box: "contain" (default), '
                '"cover", "fill", "fitWidth", "fitHeight", "scaleDown", '
                '"none"'),
        AssetPropertyInfo(
            name: 'opacity',
            type: 'double',
            description: 'Opacity 0.0-1.0, default 1.0'),
        AssetPropertyInfo(
            name: 'natural_aspect',
            type: 'double',
            description: 'Width/height ratio of the source image'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ConveyorConfig',
      displayName: 'Conveyor',
      category: 'Visualization',
      description:
          'An animated conveyor belt/auger visualization bound to a '
          'running state key. Shows motion when the key is true. Supports '
          'angle rotation and configurable appearance.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Boolean tag key indicating running state',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'RollerConveyorConfig',
      displayName: 'Roller Conveyor',
      category: 'Visualization',
      description:
          'A conveyor drawn as shaded rollers instead of a solid band. '
          'Same bindings and behaviour as ConveyorConfig (drive state '
          'colours, batches, turns, gates, wagon-on-rails); only the '
          'painter differs.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Drive struct or boolean tag key for the belt',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ConveyorColorPaletteConfig',
      displayName: 'Conveyor Palette',
      category: 'Visualization',
      description:
          'A color-coded conveyor visualization that changes appearance '
          'based on status. Used alongside regular conveyors for visual '
          'differentiation.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'AlarmVisibilityConfig',
      displayName: 'Alarm',
      category: 'Visualization',
      description:
          'A beacon placed where an alarm condition physically lives on '
          'the mimic. Pulses expanding rings in the linked alarm\'s own '
          'colours (highest active level wins); tapping opens the alarm '
          'details and acknowledge button in the side pane. Idle it '
          'renders nothing unless the idle marker is enabled.',
      properties: [
        AssetPropertyInfo(
            name: 'alarm_uids',
            type: 'List<String>',
            description: 'Uids of the AlarmMan alarm configs this beacon '
                'represents. Empty means it reacts to every alarm.'),
        AssetPropertyInfo(
            name: 'show_when_inactive',
            type: 'bool',
            description: 'Show a faint tappable marker at runtime while no '
                'bound alarm is active (default off: invisible when idle)'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'RtspCameraConfig',
      displayName: 'RTSP camera',
      category: 'Visualization',
      description:
          'A live IP-camera tile playing an RTSP stream (media_kit/libmpv). '
          'Shows a LIVE badge while frames decode, retries a dropped stream '
          'automatically, and degrades to a placeholder on platforms without '
          'video playback.',
      properties: [
        AssetPropertyInfo(
            name: 'url',
            type: 'String',
            description:
                'Stream URL, e.g. rtsp://user:pass@10.0.0.5:554/stream1. '
                'Empty renders an unconfigured placeholder.'),
        AssetPropertyInfo(
            name: 'fit',
            type: 'BoxFit',
            description: 'How the video fills the tile (cover/contain/fill)'),
        AssetPropertyInfo(
            name: 'muted',
            type: 'bool',
            description: 'Suppress stream audio (default true)'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'WebViewAssetConfig',
      displayName: 'Web page',
      category: 'Visualization',
      description:
          'A live web page rendered by a real browser (WKWebView via '
          'webview_flutter). Available on macOS only — the eLinux stations, '
          'Linux desktop and Windows have no browser engine, and show a '
          'placeholder naming the reason instead. For a dashboard that must '
          'render everywhere, use GrafanaPanelConfig, which is a server-side '
          'PNG.',
      properties: [
        AssetPropertyInfo(
            name: 'url',
            type: 'String',
            description:
                'Address to show, e.g. https://grafana.plant/d/abc/line-1. '
                'Only http and https are accepted; anything else renders the '
                'unconfigured placeholder.'),
        AssetPropertyInfo(
            name: 'reloadSeconds',
            type: 'int',
            description:
                'Seconds between reloads; 0 means never. A reload '
                're-navigates to the configured address, so a tile that '
                'wandered comes home. Offered values: 0, 30, 60, 300, 900.'),
        AssetPropertyInfo(
            name: 'interactive',
            type: 'bool',
            description:
                'Let operators click and scroll (default false). Leave off '
                'for wall-mounted stations: a tap on a link cannot be undone '
                'from the floor.'),
        AssetPropertyInfo(
            name: 'themeParam',
            type: 'String?',
            description:
                'Optional query parameter that makes the page follow the '
                "HMI's dark/light theme, e.g. \"theme\" for Grafana (which "
                'honours ?theme=dark|light, public dashboards included). When '
                'set, the loaded address carries <themeParam>=<value for the '
                'current theme>, replacing any existing parameter of that name '
                'in url, and the page reloads when the HMI theme flips. Omit or '
                'leave empty (the default) to load url exactly as written. '
                'Brightness only; there is no arbitrary-colour parameter.'),
        AssetPropertyInfo(
            name: 'themeDarkValue',
            type: 'String?',
            description:
                'Value sent in themeParam while the HMI is dark. Omit for '
                'the default "dark".'),
        AssetPropertyInfo(
            name: 'themeLightValue',
            type: 'String?',
            description:
                'Value sent in themeParam while the HMI is light. Omit for '
                'the default "light".'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'GraphAssetConfig',
      displayName: 'Graph',
      category: 'Visualization',
      description:
          'A real-time or historical line/bar/area chart displaying one '
          'or more timeseries. Supports dual Y axes (primary + secondary '
          'series), configurable time range, aggregation, and live mode.',
      properties: [
        AssetPropertyInfo(
            name: 'graph_type',
            type: 'GraphType',
            description: 'Chart type: line, bar, etc.',
            required: true),
        AssetPropertyInfo(
            name: 'primary_series',
            type: 'List<GraphSeriesConfig>',
            description: 'Primary Y-axis series (key + label + color)',
            required: true),
        AssetPropertyInfo(
            name: 'secondary_series',
            type: 'List<GraphSeriesConfig>',
            description: 'Secondary Y-axis series'),
        AssetPropertyInfo(
            name: 'x_axis',
            type: 'GraphAxisConfig',
            description: 'X-axis (time) configuration'),
        AssetPropertyInfo(
            name: 'y_axis',
            type: 'GraphAxisConfig',
            description: 'Primary Y-axis configuration'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'TableAssetConfig',
      displayName: 'Table',
      category: 'Visualization',
      description:
          'A data table showing the most recent N entries from a collected '
          'timeseries key. Configurable row count, colors, and header.',
      properties: [
        AssetPropertyInfo(
            name: 'entryKey',
            type: 'String',
            description: 'Timeseries key to display',
            required: true),
        AssetPropertyInfo(
            name: 'entryCount',
            type: 'int',
            description: 'Number of rows to display'),
        AssetPropertyInfo(
            name: 'headerText',
            type: 'String',
            description: 'Table header text'),
        AssetPropertyInfo(
            name: 'showTimestamps',
            type: 'bool',
            description: 'Whether to show timestamp column'),
        AssetPropertyInfo(
            name: 'text_color',
            type: 'Color',
            description: 'Text color'),
        AssetPropertyInfo(
            name: 'background_color',
            type: 'Color',
            description: 'Background color'),
      ],
    ),

    AssetTypeInfo(
      assetName: 'ConveyorGateConfig',
      displayName: 'Conveyor Gate',
      category: 'Visualization',
      description:
          'An animated gate (pneumatic flap or slider variant) on a '
          'conveyor, bound to a boolean open/closed state key. Supports '
          'force-open/force-close commands with feedback keys.',
      properties: [
        AssetPropertyInfo(
            name: 'stateKey',
            type: 'String',
            description: 'Boolean tag key indicating the gate is open',
            required: true),
        AssetPropertyInfo(
            name: 'gateVariant',
            type: 'String',
            description: 'Gate mechanism: "pneumatic" or "slider"'),
        AssetPropertyInfo(
            name: 'forceOpenKey',
            type: 'String',
            description: 'Tag key to write a force-open command'),
        AssetPropertyInfo(
            name: 'forceCloseKey',
            type: 'String',
            description: 'Tag key to write a force-close command'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'SensorConfig',
      displayName: 'Sensor',
      category: 'Visualization',
      description:
          'A sensor glyph (photo-eye, proximity, etc.) bound to a boolean '
          'detection key. Preferred binding is the HMI member of an '
          'FB_Sensor instance, which also unlocks live debounce editing; '
          'a plain BOOL node is accepted as the raw detection bit.',
      properties: [
        AssetPropertyInfo(
            name: 'detectionKey',
            type: 'String',
            description: 'Tag key for the detection state '
                '(FB_Sensor HMI struct or plain BOOL)',
            required: true),
        AssetPropertyInfo(
            name: 'invertActivePolarity',
            type: 'bool',
            description: 'Invert the visual active state'),
        AssetPropertyInfo(
            name: 'tag',
            type: 'String',
            description: 'Human-readable label (e.g. "PE-101A")'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'EtherCatLinkConfig',
      displayName: 'EtherCAT Link',
      category: 'Beckhoff',
      description:
          'One EtherCAT cable, drawn as a run between two devices\' ports '
          'rather than placed as a box. Its ends belong to the assets it '
          'plugs into, so moving a terminal moves the cable; corners are '
          'dragged on the canvas, not typed. Bound to an '
          'ST_EtherCATLink_HMI struct it also reports how long the link has '
          'held, how many times it has reconnected, and whether it is '
          'erroring while still up.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key of the ST_EtherCATLink_HMI struct. Leave '
                'empty to draw the cable without diagnostics.'),
        AssetPropertyInfo(
            name: 'run',
            type: 'Object',
            description: 'The run: {from, to} endpoints as '
                '{assetId, port, x, y}, a list of waypoints, and a radius. '
                'Endpoints name other assets by id.'),
        AssetPropertyInfo(
            name: 'thickness',
            type: 'double',
            description: 'Stroke width as a fraction of the canvas shortest '
                'side'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ElevatorConfig',
      displayName: 'Elevator',
      category: 'Visualization',
      description:
          'An elevator platform visualization animated by a 0-100% '
          'position value from the PLC. Child assets can ride the '
          'platform.',
      properties: [
        AssetPropertyInfo(
            name: 'positionKey',
            type: 'String',
            description: 'Tag key emitting the raw 0..100% position float',
            required: true),
        AssetPropertyInfo(
            name: 'travelRange',
            type: 'double',
            description:
                'Fraction of bounding-box height the platform travels '
                '(0.0-1.0)'),
      ],
    ),

    // ── Beckhoff Devices ──────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'BeckhoffCX5010Config',
      displayName: 'Beckhoff CX5010',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff CX5010 embedded PC with power and '
          'TwinCAT status LEDs. Can contain subdevices (EL terminals) '
          'displayed in a rack layout.',
      properties: [
        AssetPropertyInfo(
            name: 'subdevices',
            type: 'List<Asset>',
            description:
                'Attached I/O terminals (EL1008, EL2008, EL3054, etc.)'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffCX5340Config',
      displayName: 'Beckhoff CX5340',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff CX5340 embedded PC — the CX5010 asset '
          'with the CX5340 label. Same drawing, same subdevice rack; pick it '
          'over BeckhoffCX5010Config when the station really runs a CX5340.',
      properties: [
        AssetPropertyInfo(
            name: 'subdevices',
            type: 'List<Asset>',
            description:
                'Attached I/O terminals (EL1008, EL2008, EL3054, etc.)'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEK1100Config',
      displayName: 'Beckhoff EK1100',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EK1100 EtherCAT coupler. Shows '
          'run/error status LEDs and can contain attached subdevices.',
      properties: [
        AssetPropertyInfo(
            name: 'subdevices',
            type: 'List<Asset>',
            description: 'Attached I/O terminals'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL1008Config',
      displayName: 'Beckhoff EL1008',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EL1008 8-channel digital input '
          'terminal. Each channel shows live status from mapped keys.',
      properties: [
        AssetPropertyInfo(
            name: 'keys',
            type: 'List<String>',
            description: 'Tag keys for each of the 8 digital input channels'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL2008Config',
      displayName: 'Beckhoff EL2008',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EL2008 8-channel digital output '
          'terminal. Each channel shows live status from mapped keys.',
      properties: [
        AssetPropertyInfo(
            name: 'keys',
            type: 'List<String>',
            description: 'Tag keys for each of the 8 digital output channels'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL3054Config',
      displayName: 'Beckhoff EL3054',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EL3054 4-channel analog input '
          'terminal (4-20mA). Shows live values with optional inline graphs.',
      properties: [
        AssetPropertyInfo(
            name: 'keys',
            type: 'List<String>',
            description:
                'Tag keys for each of the 4 analog input channels'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL9222Config',
      displayName: 'Beckhoff EL9222',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff EL9222 2-channel overcurrent protection terminal. The '
          'face shows which channel has tripped and a tap opens a pane that '
          'resets it. Without stateKey it is only a drawing.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Terminal name shown on the pane, e.g. ST101.A1.02'),
        AssetPropertyInfo(
            name: 'stateKey',
            type: 'String?',
            description:
                "Key of the terminal's ST_EL9222_5500 struct — the 16 status "
                'bits and 4 command bits for both channels. Required for any '
                'live state or reset'),
        AssetPropertyInfo(
            name: 'descriptionsKey',
            type: 'String?',
            description:
                'Optional array of what each channel feeds, one entry per '
                'channel, named in the pane'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL9186Config',
      displayName: 'Beckhoff EL9186',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EL9186 potential distribution '
          'terminal (0V). Shows connection status.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL9187Config',
      displayName: 'Beckhoff EL9187',
      category: 'Beckhoff Devices',
      description:
          'Visualization of a Beckhoff EL9187 potential distribution '
          'terminal (24V). Shows connection status.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL2912Config',
      displayName: 'Beckhoff EL2912',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff EL2912 TwinSAFE 2-channel output terminal, drawn in the '
          'safety yellow of the real part. Its two fail-safe outputs are '
          'driven over FSoE by TwinSAFE Logic and never reach the standard '
          'PLC, so the asset shows only what the EtherCAT GVL links out: the '
          'two field-voltage diagnostic bits. Those come as two loose BOOLs, '
          'not a struct, which is why there are two keys.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Terminal name shown on the pane, e.g. ST301.A1.09'),
        AssetPropertyInfo(
            name: 'underrangeKey',
            type: 'String?',
            description:
                "Key of the terminal's Fieldvoltage Underrange bit, off "
                'Module 3 (DEVICEIO)'),
        AssetPropertyInfo(
            name: 'overrangeKey',
            type: 'String?',
            description:
                "Key of the terminal's Fieldvoltage Overrange bit, likewise"),
        AssetPropertyInfo(
            name: 'descriptionKey',
            type: 'String?',
            description:
                'Optional string naming what the safety outputs hold, shown '
                'in the pane'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffPS2001Config',
      displayName: 'Beckhoff PS2001',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff PS2001-2410 power supply, 24 V DC / 10 A. The only '
          'cabinet infrastructure asset that measures anything: its pane '
          'shows the output volts and amps and how much of the 10 A rating '
          'is spare. Without stateKey it is only a drawing.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Unit tag shown on the face and pane, e.g. ST301.T1'),
        AssetPropertyInfo(
            name: 'stateKey',
            type: 'String?',
            description:
                "Key of the unit's ST_PS2001_2410 struct — DC OK, warning, "
                'error, input undervoltage, and the measured output voltage '
                'and current. Required for any live state'),
        AssetPropertyInfo(
            name: 'descriptionKey',
            type: 'String?',
            description:
                'Optional string naming which rail this unit feeds, shown in '
                'the pane'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEPBoxConfig',
      displayName: 'Beckhoff EtherCAT Box (EP2338 / EP1918)',
      category: 'Beckhoff Devices',
      description:
          'An IP67 EtherCAT Box out on the machines, in either variant this '
          'plant fits. EP2338 is an 8-channel digital combi and is live off '
          'an ST_EP2338_0002 struct; EP1918 is TwinSAFE, publishes no '
          'process data at all, and is drawn dark in safety yellow. Set '
          'variantModel to choose.',
      properties: [
        AssetPropertyInfo(
            name: 'variantModel',
            type: 'String',
            description: "Which box: 'ep2338' or 'ep1918'"),
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Box tag shown on the face and pane, e.g. ST301.RM05'),
        AssetPropertyInfo(
            name: 'stateKey',
            type: 'String?',
            description:
                "Key of the box's ST_EP2338_0002 struct — I0..I7 and O0..O7. "
                'Meaningless on an EP1918, which publishes nothing'),
        AssetPropertyInfo(
            name: 'descriptionsKey',
            type: 'String?',
            description:
                'Optional array naming what each of the eight channels is '
                'wired to, one entry per channel, in the order plug 1 A, '
                'plug 1 B, plug 2 A, ... — the four M12 plugs carry two '
                'channels each'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffCU2508Config',
      displayName: 'Beckhoff CU2508',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff CU2508 real-time Ethernet port multiplier: one gigabit '
          'uplink fanned out to eight independent EtherCAT segments. It '
          'publishes no process data, so this is a drawing for a topology '
          'page — the name is what makes it useful.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description:
                'Printed on the housing. A page with three of these wants to '
                'say which network each one splits'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEK1110Config',
      displayName: 'Beckhoff EK1110',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff EK1110 EtherCAT extension — the RJ45 that ends a '
          'terminal block and carries the bus on to the next one. No process '
          'data, so it is a drawing.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'BeckhoffEL6070Config',
      displayName: 'Beckhoff EL6070',
      category: 'Beckhoff Devices',
      description:
          'Beckhoff EL6070 TwinCAT 3 licence key terminal. No process data '
          'and no field wiring, so it is a drawing with its terminal points '
          'left unlabelled rather than given invented signal names.',
      properties: [],
    ),

    // ── Schneider Devices ─────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'SchneiderATV320Config',
      displayName: 'Schneider ATV320',
      category: 'Schneider Devices',
      description:
          'Visualization of a Schneider Electric ATV320 variable frequency '
          'drive (VFD). Shows HMIS status, frequency, and configuration '
          'from mapped OPC UA keys.',
      properties: [
        AssetPropertyInfo(
            name: 'label',
            type: 'String',
            description: 'Display label drawn on the drive body. At most two '
                'lines of 14 characters are shown; a newline breaks the label '
                'explicitly (e.g. "CN01\\nFD01" stacks CN01 over FD01), '
                'otherwise it is wrapped on spaces.'),
        AssetPropertyInfo(
            name: 'hmisKey',
            type: 'String',
            description: 'Tag key for HMIS (status word)'),
        AssetPropertyInfo(
            name: 'freqKey',
            type: 'String',
            description: 'Tag key for output frequency'),
        AssetPropertyInfo(
            name: 'configKey',
            type: 'String',
            description: 'Tag key for drive configuration'),
      ],
    ),

    // ── Advantys STB Devices ──────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'STBNIP2311Config',
      displayName: 'STBNIP2311 (Ethernet Head)',
      category: 'Advantys STB Devices',
      description:
          'Visualization of a Schneider Advantys STB NIP2311 Ethernet '
          'network head module. Hosts subdevice modules on its island bus.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Island name or node id'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'STBDDI3725Config',
      displayName: 'STBDDI3725 (16-Ch DI)',
      category: 'Advantys STB Devices',
      description:
          'Visualization of an Advantys STB DDI3725 16-channel digital '
          'input module with live channel status, forcing, and per-channel '
          'on/off filters.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Module name or node id'),
        AssetPropertyInfo(
            name: 'rawStateKey',
            type: 'String',
            description: 'Tag key for the raw channel states'),
        AssetPropertyInfo(
            name: 'forceValuesKey',
            type: 'String',
            description: 'Tag key for channel force values'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'FestoVTUGConfig',
      displayName: 'Festo VTUG-14 (8 valves)',
      category: 'Festo Devices',
      description:
          'Festo VTUG-14 valve terminal with a CTEU-EC bus node: eight valve '
          'positions on a VAEM-L1-S-8-PT interface, up to sixteen solenoid '
          'coils. As ordered it carries five VUVG-B14-M52 (5/2 monostable) '
          'and three VUVG-B14-P53C (5/3 closed centre). The drawing gives '
          'each position a lamp per pilot solenoid; the side pane gives each '
          'one an ISO 1219 schematic showing where the spool is, a latch '
          '(port 4 / centre / port 2) and a momentary push per coil. What is '
          'fitted at each position is set on the page, not read from a key -- '
          'a blanking plate publishes nothing to discover it by.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Terminal name or node id, printed on the end plate'),
        AssetPropertyInfo(
            name: 'stateKey',
            type: 'String',
            description:
                'Tag key for the ST_VTUG_16 struct (p_stat_Coils, '
                'p_stat_Forced, p_cmd_Force, p_cmd_Value)'),
        AssetPropertyInfo(
            name: 'slices',
            type: 'List',
            description:
                'The eight valve positions, position 1 first. Each entry is '
                '{kind, name}, where kind is blank, valve52Mono, '
                'valve52Bistable or valve53Closed. A 5/3 and a bistable 5/2 '
                'both have two coils; only the 5/3 has a commandable centre.'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'STBDDO3705Config',
      displayName: 'STBDDO3705 (16-Ch DO)',
      category: 'Advantys STB Devices',
      description:
          'Visualization of an Advantys STB DDO3705 16-channel digital '
          'output module with live channel status and forcing.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Module name or node id'),
        AssetPropertyInfo(
            name: 'rawStateKey',
            type: 'String',
            description: 'Tag key for the raw channel states'),
        AssetPropertyInfo(
            name: 'forceValuesKey',
            type: 'String',
            description: 'Tag key for channel force values'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'STBPDT3100Config',
      displayName: 'STBPDT3100 (24 VDC PDM)',
      category: 'Advantys STB Devices',
      description:
          'Visualization of an Advantys STB PDT3100 24 VDC power '
          'distribution module.',
      properties: [
        AssetPropertyInfo(
            name: 'nameOrId',
            type: 'String',
            description: 'Module name or node id'),
        AssetPropertyInfo(
            name: 'inputOkKey',
            type: 'String',
            description: 'Tag key for the input-power-OK status'),
      ],
    ),

    // ── Industrial Equipment ──────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'Baader221Config',
      displayName: 'Baader 221',
      category: 'Industrial Equipment',
      description:
          'Visualization of a Baader 221 fish processing machine. Shows '
          'operational status from mapped tag keys.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key for machine status',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'AirCabConfig',
      displayName: 'Air Cabinet',
      category: 'Industrial Equipment',
      description:
          'Visualization of a pneumatic air cabinet showing valve '
          'and pressure status from mapped tag keys.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key for cabinet status',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ElCabConfig',
      displayName: 'Electrical Cabinet',
      category: 'Industrial Equipment',
      description:
          'Visualization of an electrical cabinet showing breaker and '
          'component status from mapped tag keys.',
      properties: [
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key for cabinet status',
            required: true),
      ],
    ),

    AssetTypeInfo(
      assetName: 'ThirdPartyEquipmentConfig',
      displayName: '3rd Party Equipment',
      category: 'Industrial Equipment',
      description:
          'A packing-hall machine tile (Multivac, SpeedBatcher, box '
          'erector, strapping line, ...) with a run-status LED bound to a '
          'boolean key. Child entries can bind additional signals.',
      properties: [
        AssetPropertyInfo(
            name: 'kind',
            type: 'String',
            description: 'Which machine this represents, e.g. "multivac", '
                '"speedBatcher", "boxErector", "strappingLine"',
            required: true),
        AssetPropertyInfo(
            name: 'runKey',
            type: 'String',
            description: 'Boolean tag key carrying the run status'),
        AssetPropertyInfo(
            name: 'invertRunPolarity',
            type: 'bool',
            description: 'Invert the raw bool (stopped-contact equipment)'),
      ],
    ),

    // ── Application ───────────────────────────────────────────────────
    AssetTypeInfo(
      assetName: 'ChecklistsConfig',
      displayName: 'Checklists',
      category: 'Application',
      description:
          'An interactive checklist widget for operator task tracking. '
          'Items can be checked off and progress is persisted.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'RecipesConfig',
      displayName: 'Recipes',
      category: 'Application',
      description:
          'A recipe management widget for configuring and applying '
          'predefined parameter sets to the process.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'SpeedBatcherConfig',
      displayName: 'Speed Batcher',
      category: 'Application',
      description:
          'A speed batcher control widget showing batch count and '
          'status with a label. Used for batching/dosing processes.',
      properties: [
        AssetPropertyInfo(
            name: 'label',
            type: 'String',
            description: 'Display label',
            required: true),
        AssetPropertyInfo(
            name: 'key',
            type: 'String',
            description: 'Tag key for batcher data',
            required: true),
      ],
    ),
    AssetTypeInfo(
      assetName: 'ConnectionInfoConfig',
      displayName: 'Connection Info',
      category: 'Application',
      description:
          'A live status card for one PLC/server connection, fed by the '
          '@conn/<serverAlias>/<field> meta-keys: state chip, requests/s, '
          'uptime, reconnects and last error.',
      properties: [
        AssetPropertyInfo(
            name: 'serverAlias',
            type: 'String',
            description: 'The connection alias to display — a configured '
                'serverAlias, or host:port for unnamed servers',
            required: true),
        AssetPropertyInfo(
            name: 'protocol',
            type: 'String',
            description: 'Display hint, "modbus" or "opcua"; the rendered '
                'fields follow the live data'),
      ],
    ),
    AssetTypeInfo(
      assetName: 'GateStatusConfig',
      displayName: 'Gate Status',
      category: 'Application',
      description:
          'A gate status indicator widget showing open/closed state. '
          'Used alongside speed batcher for gate-controlled processes.',
      properties: [],
    ),
    AssetTypeInfo(
      assetName: 'DrawingViewerConfig',
      displayName: 'Drawing Viewer',
      category: 'Application',
      description:
          'A button that opens a PDF technical drawing in the floating '
          'overlay viewer. Configured with drawing name, file path, '
          'and optional start page.',
      properties: [
        AssetPropertyInfo(
            name: 'drawingName',
            type: 'String',
            description: 'Display name for the drawing',
            required: true),
        AssetPropertyInfo(
            name: 'filePath',
            type: 'String',
            description: 'Path to the PDF file',
            required: true),
        AssetPropertyInfo(
            name: 'startPage',
            type: 'int',
            description: 'Initial page number to display (1-based)'),
      ],
    ),
  ];

  /// All distinct category names, sorted alphabetically.
  static List<String> get categories {
    final cats = all.map((e) => e.category).toSet().toList();
    cats.sort();
    return cats;
  }

  /// Filter asset types by category name (exact match).
  static List<AssetTypeInfo> byCategory(String category) {
    return all.where((e) => e.category == category).toList();
  }
}
