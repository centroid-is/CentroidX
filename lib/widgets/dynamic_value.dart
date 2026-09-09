import 'dart:io' show stderr;

import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

class DynamicValueWidget extends StatelessWidget {
  final DynamicValue _value;
  final Function(DynamicValue)? onSubmitted;

  DynamicValueWidget({
    super.key,
    required DynamicValue value,
    this.onSubmitted,
  }) : _value = DynamicValue.from(value);

  @override
  Widget build(BuildContext context) {
    return _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    if (_value.isNull) {
      return const Text('null');
    }

    if (_value.isObject) {
      return _buildObjectWidget(context);
    }

    if (_value.isArray) {
      return _buildArrayWidget(context);
    }

    if (_value.isString) {
      return _buildStringWidget(context);
    }

    if (_value.isBoolean) {
      return _buildBooleanWidget(context);
    }

    if (_value.isInteger) {
      return _buildIntegerWidget(context);
    }

    if (_value.isDouble) {
      return _buildDoubleWidget(context);
    }

    return Text('Unknown type: ${_value.toString()}');
  }

  Widget _buildObjectWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_value.displayName != null)
          Text(
            _value.displayName!.value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        if (_value.description != null)
          Text(
            _value.description!.value,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        ..._value.asObject.entries.map((entry) {
          final label = _prettifyLabel(entry.key);
          final desc = entry.value.description?.value;
          final title = (desc != null && desc.isNotEmpty)
              ? '$label ($desc)'
              : label;

          // Clear description/displayName on child so the leaf widget
          // doesn't duplicate what we already show in the title.
          final childValue = DynamicValue.from(entry.value);
          childValue.description = null;
          childValue.displayName = null;

          return Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                DynamicValueWidget(
                  value: childValue,
                  onSubmitted: onSubmitted != null
                      ? (newValue) {
                          final copy = DynamicValue.from(_value);
                          copy[entry.key] = newValue;
                          onSubmitted!(copy);
                        }
                      : null,
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildArrayWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_value.displayName != null)
          Text(
            _value.displayName!.value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        if (_value.description != null)
          Text(
            _value.description!.value,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        ..._value.asArray.asMap().entries.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Item ${entry.key}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                DynamicValueWidget(
                  value: entry.value,
                  onSubmitted: onSubmitted != null
                      ? (newValue) {
                          final copy = DynamicValue.from(_value);
                          copy[entry.key] = newValue;
                          onSubmitted!(copy);
                        }
                      : null,
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildStringWidget(BuildContext context) {
    return _ValueTextField(
      text: _value.asString,
      onSubmitted: onSubmitted != null
          ? (newValue) {
              onSubmitted!(DynamicValue.from(_value)..value = newValue);
            }
          : null,
      decoration: InputDecoration(
        labelText: _value.displayName?.value,
        helperText: _value.description?.value,
      ),
    );
  }

  Widget _buildBooleanWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (_value.displayName != null)
              Text(
                _value.displayName!.value,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            Switch(
              value: _value.asBool,
              onChanged: onSubmitted != null
                  ? (newValue) {
                      onSubmitted!(DynamicValue.from(_value)..value = newValue);
                    }
                  : null,
            ),
          ],
        ),
        if (_value.description != null)
          Text(
            _value.description!.value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
      ],
    );
  }

  Widget _buildIntegerWidget(BuildContext context) {
    if (_value.enumFields != null) {
      try {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<int>(
              key: ValueKey(_value.asInt),
              value: _value.asInt,
              items: _value.enumFields!.entries
                  .map((entry) => DropdownMenuItem<int>(
                      value: entry.key,
                      child: Text(entry.value.displayName.value)))
                  .toList(),
              onChanged: onSubmitted != null
                  ? (newValue) {
                      onSubmitted!(DynamicValue.from(_value)..value = newValue);
                    }
                  : null,
            ),
            if (_value.description != null)
              Text(
                _value.description!.value,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        );
      } catch (e) {
        stderr.writeln("Error building enum dropdown: $e");
      }
    }

    return _ValueTextField(
      text: _value.asInt.toString(),
      keyboardType: TextInputType.number,
      onSubmitted: onSubmitted != null
          ? (newValue) {
              final intValue = int.tryParse(newValue);
              if (intValue != null) {
                onSubmitted!(DynamicValue.from(_value)..value = intValue);
              }
            }
          : null,
      decoration: InputDecoration(
        labelText: _value.displayName?.value,
        helperText: _value.description?.value,
      ),
    );
  }

  Widget _buildDoubleWidget(BuildContext context) {
    return _ValueTextField(
      text: _value.asDouble.toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onSubmitted: onSubmitted != null
          ? (newValue) {
              final doubleValue = double.tryParse(newValue);
              if (doubleValue != null) {
                onSubmitted!(DynamicValue.from(_value)..value = doubleValue);
              }
            }
          : null,
      decoration: InputDecoration(
        labelText: _value.displayName?.value ?? '',
        helperText: _value.description?.value,
      ),
    );
  }

  String _prettifyLabel(String label) {
    // Convert snake_case to spaces and capitalize
    String withSpaces = label.replaceAllMapped(
      RegExp(r'(_)|([A-Z])'),
      (match) {
        if (match.group(1) != null) return ' ';
        if (match.group(2) != null) return ' ${match.group(2)}';
        return '';
      },
    );
    // Remove leading space if any, and capitalize first letter
    withSpaces = withSpaces.trimLeft();
    if (withSpaces.isEmpty) return '';
    return withSpaces[0].toUpperCase() + withSpaces.substring(1);
  }
}

/// A text field that keeps its controller across rebuilds.
///
/// The string, int and double editors used to build
/// `TextField(controller: TextEditingController(text: ...))` inline: a new
/// controller -- and with it a new, empty selection -- on every rebuild. The
/// recipes dialog rebuilds on every PLC tick and on every keystroke, so the
/// cursor jumped, backspace ate the wrong character, and select-all could
/// not survive a frame; the controllers were never disposed either. The
/// controller lives here now; the PLC's value is followed only while the
/// operator is not editing.
class _ValueTextField extends StatefulWidget {
  const _ValueTextField({
    required this.text,
    required this.decoration,
    this.onSubmitted,
    this.keyboardType,
  });

  final String text;
  final InputDecoration decoration;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;

  @override
  State<_ValueTextField> createState() => _ValueTextFieldState();
}

class _ValueTextFieldState extends State<_ValueTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _ValueTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text && !_focus.hasFocus) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      onSubmitted: widget.onSubmitted,
      readOnly: widget.onSubmitted == null,
      decoration: widget.decoration,
    );
  }
}
