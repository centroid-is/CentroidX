import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';

import 'common.dart';
import '../../providers/state_man.dart';
import 'package:tfc/converter/color_converter.dart';

part 'text.g.dart';

@JsonSerializable(explicitToJson: true)
class TextAssetConfig extends BaseAsset {
  @override
  String get displayName => 'Text';
  @override
  String get category => 'Text & Numbers';

  /// The text content to display with variable substitution support
  /// Example: "Temperature is: $temp and pressure is $press"
  String textContent;

  /// Text color
  @OptionalColorConverter()
  Color? textColor;

  /// Whether to enable variable substitution
  bool enableVariableSubstitution;

  /// Number of decimal places for numeric values
  int decimalPlaces;

  /// List of variables used in the text (auto-detected)
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get detectedVariables {
    if (!enableVariableSubstitution) return [];

    // Updated regex to capture variables with dots: $Baader9.ConveyorBufferHeight
    final regex = RegExp(r'\$([a-zA-Z_][a-zA-Z0-9_.]*)');
    final matches = regex.allMatches(textContent);
    return matches.map((match) => match.group(1)!).toSet().toList();
  }

  TextAssetConfig({
    required this.textContent,
    this.textColor,
    this.enableVariableSubstitution = true,
    this.decimalPlaces = 2,
  });

  @override
  Widget build(BuildContext context) {
    return TextAssetWidget(this);
  }

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 400,
          minHeight: 300,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _ConfigContent(config: this),
            ),
          ),
        ),
      ),
    );
  }

  static const previewStr = 'Text Asset preview';

  TextAssetConfig.preview()
      : textContent = 'Temperature: \$temp°C\nPressure: \$press bar',
        textColor = null,
        enableVariableSubstitution = false,
        decimalPlaces = 2 {
    textPos = TextPos.inside;
    size = const RelativeSize(width: 0.15, height: 0.08);
  }

  /// The whole asset is its text, so [textContent] is bulk-editable here in a
  /// way an OPC UA key is not — the substitution syntax makes one string work
  /// across a row of them (`"$CN$i speed"` is still per-asset, but a shared
  /// caption is a common thing to want).
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        TextBulkProperty(
          id: 'TextAssetConfig.textContent',
          label: 'Content',
          group: _bulkGroup,
          nullable: false,
          read: () => textContent,
          apply: (value) => textContent = value ?? '',
        ),
        BoolBulkProperty(
          id: 'TextAssetConfig.enableVariableSubstitution',
          label: 'Substitute variables',
          group: _bulkGroup,
          read: () => enableVariableSubstitution,
          apply: (value) => enableVariableSubstitution = value,
        ),
        NumberBulkProperty(
          id: 'TextAssetConfig.decimalPlaces',
          label: 'Decimal places',
          group: _bulkGroup,
          isInt: true,
          decimals: 0,
          min: 0,
          max: 6,
          read: () => decimalPlaces,
          apply: (value) => decimalPlaces = (value ?? decimalPlaces).round(),
        ),
        ColorBulkProperty(
          id: 'TextAssetConfig.textColor',
          label: 'Text colour',
          group: _bulkGroup,
          // Null means the ambient theme colour, which is the state every
          // text asset starts in — the picker keeps a way back to it.
          nullable: true,
          read: () => textColor,
          apply: (value) => textColor = value,
        ),
      ];

  static const String _bulkGroup = 'Text';

  factory TextAssetConfig.fromJson(Map<String, dynamic> json) =>
      _$TextAssetConfigFromJson(json);
  Map<String, dynamic> toJson() => _$TextAssetConfigToJson(this);
}


/// The colour a text asset paints with.
///
/// Plain black is read as "the theme's text colour", not as black: the
/// preview default used to be a literal black and 72 text assets on the
/// plant pages carry it, so in the dark scheme every label was black on deep
/// teal. A black that was actually chosen is indistinguishable from that
/// default, and nobody wants black on dark -- so black follows the theme and
/// every other colour is honoured as set.
Color? textAssetColor(BuildContext context, Color? configured) {
  final themeColor = Theme.of(context).textTheme.bodyLarge?.color;
  if (configured == null) return themeColor;
  if (configured.toARGB32() == Colors.black.toARGB32()) return themeColor;
  return configured;
}

class TextAssetWidget extends ConsumerStatefulWidget {
  final TextAssetConfig config;

  const TextAssetWidget(this.config, {super.key});

  @override
  ConsumerState<TextAssetWidget> createState() => _TextAssetWidgetState();
}

class _TextAssetWidgetState extends ConsumerState<TextAssetWidget> {
  Map<String, String> _variableValues = {};
  bool _hasError = false;
  String _errorMessage = '';

  @override
  Widget build(BuildContext context) {
    if (!widget.config.enableVariableSubstitution) {
      return _buildStaticText();
    }

    // Build multiple StreamBuilders for each variable
    return _buildMultiVariableStream();
  }

  Widget _buildStaticText() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth * 0.7,
          height: constraints.maxHeight * 0.7,
          // AutoSizedText, not FittedBox: the content is laid out at the font
          // size that fits, so the glyphs are rasterised at the size they are
          // drawn instead of being scaled there. See common.dart.
          child: AutoSizedText(
            widget.config.textContent,
            alignment: Alignment.topLeft,
            style: TextStyle(
              color: textAssetColor(context, widget.config.textColor),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDynamicText() {
    if (_hasError) {
      return Text(
        'Error: $_errorMessage',
        style: TextStyle(
          color: Colors.red,
          fontSize: 12,
        ),
        textAlign: TextAlign.left,
      );
    }

    final processedText = _processTextWithSubstitutions();

    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth * 0.7,
          height: constraints.maxHeight * 0.7,
          // See _buildStaticText: laid out at its final size, not scaled to it.
          child: AutoSizedText(
            processedText,
            alignment: Alignment.topLeft,
            textAlign: TextAlign.left,
            style: TextStyle(
              color: textAssetColor(context, widget.config.textColor),
            ),
          ),
        );
      },
    );
  }

  String _processTextWithSubstitutions() {
    String result = widget.config.textContent;

    for (final variable in widget.config.detectedVariables) {
      final value = _variableValues[variable];
      if (value != null && value != '---') {
        result = result.replaceAll('\$$variable', value);
      } else {
        result = result.replaceAll('\$$variable', '---'); // Show loading state
      }
    }

    return result;
  }

  Widget _buildMultiVariableStream() {
    final variables = widget.config.detectedVariables;

    if (variables.isEmpty) {
      return _buildStaticText();
    }

    // Create a combined stream from all variables
    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _createCombinedStream(variables),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _hasError = true;
          _errorMessage = snapshot.error.toString();
          return _buildDynamicText();
        }

        if (snapshot.hasData) {
          _hasError = false;
          _updateVariableValues(snapshot.data!);
        }

        return _buildDynamicText();
      },
    );
  }

  Stream<Map<String, DynamicValue>> _createCombinedStream(
      List<String> variables) {
    // Create individual streams for each variable
    final streams = variables.map((variable) {
      return ref
          .watch(keyStreamProvider(variable))
          .map((value) => MapEntry(variable, value))
          .startWith(MapEntry(variable,
              DynamicValue(value: '---', typeId: null))); // Initial value
    });

    // Merge streams so we get values as they arrive
    return Rx.merge(streams).scan<Map<String, DynamicValue>>(
      (Map<String, DynamicValue> acc, MapEntry<String, DynamicValue> entry,
          int index) {
        acc[entry.key] = entry.value;
        return acc; // Return the same map instance
      },
      <String, DynamicValue>{},
    );
  }

  void _updateVariableValues(Map<String, DynamicValue> values) {
    for (final entry in values.entries) {
      final variable = entry.key;
      final value = entry.value;

      if (value.isDouble) {
        _variableValues[variable] =
            value.asDouble.toStringAsFixed(widget.config.decimalPlaces);
      } else {
        _variableValues[variable] = value.asString;
      }
    }
  }
}

class _ConfigContent extends StatefulWidget {
  final TextAssetConfig config;

  const _ConfigContent({required this.config});

  @override
  State<_ConfigContent> createState() => _ConfigContentState();
}

class _ConfigContentState extends State<_ConfigContent> {
  late TextEditingController _textController;
  late Color? _textColor;
  late bool _enableVariableSubstitution;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.config.textContent);
    _textColor = widget.config.textColor;
    _enableVariableSubstitution = widget.config.enableVariableSubstitution;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Configure Text Asset',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 20),

        // Variable substitution toggle
        SwitchListTile(
          title: const Text('Enable Variable Substitution'),
          subtitle: const Text('Allow using \$variable syntax in text'),
          value: _enableVariableSubstitution,
          onChanged: (value) {
            setState(() {
              _enableVariableSubstitution = value;
              widget.config.enableVariableSubstitution = value;
            });
          },
        ),

        const SizedBox(height: 20),

        // Text content with key search
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _textController,
              decoration: InputDecoration(
                labelText: 'Text Content',
                hintText: _enableVariableSubstitution
                    ? 'Enter text with variables like: Temperature: \$temp°C\nPressure: \$press bar'
                    : 'Enter your text here...',
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
                suffixIcon: _enableVariableSubstitution
                    ? IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: 'Search and insert OPC UA keys',
                        onPressed: () => _showKeySearchDialog(context),
                      )
                    : null,
              ),
              maxLines: 8,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (value) {
                widget.config.textContent = value;
                setState(() {}); // Trigger rebuild to update detected variables
              },
            ),
            if (_enableVariableSubstitution) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Colors.grey.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Click the search icon to browse and insert available OPC UA keys',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),

        const SizedBox(height: 10),

        // Variable substitution help
        if (_enableVariableSubstitution) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: Colors.blue.shade700, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Variable Substitution',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Use \$variable syntax to insert real-time values. The widget will automatically subscribe to all variables used in the text.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue.shade700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Detected variables display
        if (_enableVariableSubstitution &&
            widget.config.detectedVariables.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Colors.green.shade700, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Detected Variables (${widget.config.detectedVariables.length})',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: widget.config.detectedVariables.map((variable) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green.shade300),
                      ),
                      child: Text(
                        '\$$variable',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.green.shade700,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        // Text color — null means "theme default"; the dialog's Clear
        // action gets back to it.
        ColorPickerRow(
          label: 'Text Color',
          color: _textColor,
          onChanged: (color) {
            setState(() {
              _textColor = color;
              widget.config.textColor = color;
            });
          },
          onCleared: () {
            setState(() {
              _textColor = null;
              widget.config.textColor = null;
            });
          },
        ),

        const SizedBox(height: 20),

        // Size configuration
        Text(
          'Size',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SizeField(
          initialValue: widget.config.size,
          onChanged: (value) {
            widget.config.size = value;
          },
        ),

        const SizedBox(height: 20),

        // Coordinates configuration
        Text(
          'Position',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        CoordinatesField(
          initialValue: widget.config.coordinates,
          onChanged: (value) {
            widget.config.coordinates = value;
          },
        ),

        const SizedBox(height: 20),

        // Text position configuration
        Text(
          'Text Position',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        DropdownButton<TextPos>(
          value: widget.config.textPos,
          isExpanded: true,
          onChanged: (value) {
            widget.config.textPos = value;
          },
          items: TextPos.values
              .map((e) => DropdownMenuItem<TextPos>(
                    value: e,
                    child: Text(e.name[0].toUpperCase() + e.name.substring(1)),
                  ))
              .toList(),
        ),

        const SizedBox(height: 20),

        // Decimal places configuration
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue: widget.config.decimalPlaces.toString(),
                decoration: const InputDecoration(
                  labelText: 'Decimal Places',
                  suffixText: 'places',
                ),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  final places = int.tryParse(value);
                  if (places != null && places >= 0) {
                    widget.config.decimalPlaces = places;
                  }
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Preview
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Preview',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Container(
                width: 300,
                height: 150,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _processTextForPreview(widget.config.textContent),
                    style: TextStyle(
                      color: _textColor ?? Colors.black,
                      fontSize: 12,
                    ),
                    maxLines: null,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _processTextForPreview(String text) {
    if (text.isEmpty) {
      return 'Preview text will appear here...';
    }

    if (!_enableVariableSubstitution) {
      return text;
    }

    // Replace variables with sample values for preview
    String processedText = text;
    for (final variable in widget.config.detectedVariables) {
      processedText = processedText.replaceAll('\$$variable', '123.45');
    }

    return processedText;
  }

  void _showKeySearchDialog(BuildContext context) {
    showDialog<String>(
      context: context,
      builder: (context) => _KeyInsertionDialog(
        onKeySelected: (key) {
          // Insert the selected key at the current cursor position
          final currentText = _textController.text;
          final selection = _textController.selection;
          final before = currentText.substring(0, selection.start);
          final after = currentText.substring(selection.end);
          final newText = '$before\$$key$after';

          _textController.text = newText;

          // Set cursor position after the inserted key
          final newPosition = selection.start + key.length + 1; // +1 for the $
          _textController.selection =
              TextSelection.collapsed(offset: newPosition);

          // Update the config
          widget.config.textContent = newText;
          setState(() {}); // Trigger rebuild to update detected variables
        },
      ),
    );
  }
}

// Custom dialog for key insertion in text assets
class _KeyInsertionDialog extends ConsumerStatefulWidget {
  final Function(String) onKeySelected;

  const _KeyInsertionDialog({required this.onKeySelected});

  @override
  ConsumerState<_KeyInsertionDialog> createState() =>
      _KeyInsertionDialogState();
}

class _KeyInsertionDialogState extends ConsumerState<_KeyInsertionDialog> {
  late TextEditingController _searchController;
  List<String> _searchResults = [];
  List<String> _allKeys = [];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _loadKeys();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    try {
      final stateMan = await ref.read(stateManProvider.future);
      setState(() {
        _allKeys = stateMan.keys.toList()..sort();
        _searchResults = _allKeys;
      });
    } catch (e) {
      setState(() {
        _allKeys = [];
        _searchResults = [];
      });
    }
  }

  void _performSearch(String query) {
    setState(() {
      _searchResults = fuzzyFilter(_allKeys, query, [(key) => key]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Insert OPC UA key',
      icon: Icons.link,
      width: 540,
      child: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search Keys',
                prefixIcon: Icon(Icons.search),
                hintText: 'Type to search available keys...',
              ),
              onChanged: _performSearch,
              autofocus: true,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _searchResults.isEmpty
                  ? const Center(
                      child: Text('No keys found'),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final key = _searchResults[index];
                        return ListTile(
                          dense: true,
                          title: Text(key),
                          subtitle: Text('Will be inserted as \$$key'),
                          trailing: IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: 'Insert this key',
                            onPressed: () {
                              widget.onKeySelected(key);
                              Navigator.of(context).pop();
                            },
                          ),
                          onTap: () {
                            widget.onKeySelected(key);
                            Navigator.of(context).pop();
                          },
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
