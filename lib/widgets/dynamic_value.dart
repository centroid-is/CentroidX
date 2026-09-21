
import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

class DynamicValueWidget extends StatelessWidget {
  final DynamicValue _value;
  final Function(DynamicValue)? onSubmitted;

  /// Whether leaving a text field commits what was typed, as well as Enter.
  ///
  /// **Off by default, and that is the safe way round.** Most editors built
  /// from this widget write a PLC tag on submit, where a stray tap that moved
  /// focus would become an unintended setpoint — so those keep Enter as the
  /// only commit. A surface that edits a *document* rather than the plant —
  /// the recipes table — turns it on: there, Enter-or-nothing silently threw
  /// the operator's edit away whenever they tapped the next field instead,
  /// which on a touchscreen is the ordinary gesture.
  final bool commitOnFocusLoss;

  DynamicValueWidget({
    super.key,
    required DynamicValue value,
    this.onSubmitted,
    this.commitOnFocusLoss = false,
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
      commitOnFocusLoss: commitOnFocusLoss,
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
        // `debugPrint`, not `dart:io`'s `stderr`, which throws in a browser.
        debugPrint("Error building enum dropdown: $e");
      }
    }

    return _ValueTextField(
      text: _value.asInt.toString(),
      keyboardType: TextInputType.number,
      commitOnFocusLoss: commitOnFocusLoss,
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
      commitOnFocusLoss: commitOnFocusLoss,
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
    this.commitOnFocusLoss = false,
  });

  final String text;
  final InputDecoration decoration;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;

  /// See [DynamicValueWidget.commitOnFocusLoss].
  final bool commitOnFocusLoss;

  @override
  State<_ValueTextField> createState() => _ValueTextFieldState();
}

class _ValueTextFieldState extends State<_ValueTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);
  final FocusNode _focus = FocusNode();

  /// The text last handed to [_ValueTextField.onSubmitted], so leaving a field
  /// twice does not report the same edit twice — and so a field the operator
  /// only looked at reports nothing at all.
  late String _committed = widget.text;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  /// Commits what was typed when focus leaves, for the surfaces that asked
  /// for it.
  ///
  /// Enter used to be the only way to commit, so typing a value and tapping
  /// the next field — the ordinary gesture on a station's touchscreen —
  /// silently discarded the edit, while the typed text stayed on screen
  /// because [didUpdateWidget] only refreshes a field nobody is in. That is
  /// the "sometimes it does not save" this fixes.
  void _onFocusChanged() {
    if (!widget.commitOnFocusLoss || _focus.hasFocus) return;
    final submit = widget.onSubmitted;
    if (submit == null) return;
    final typed = _controller.text;
    if (typed == _committed) return;
    _committed = typed;
    submit(typed);
  }

  @override
  void didUpdateWidget(covariant _ValueTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text && !_focus.hasFocus) {
      _controller.text = widget.text;
      _committed = widget.text;
    }
  }

  @override
  void dispose() {
    // Deliberately NOT committing here. A field disposed while it still holds
    // focus does lose its last edit, but the alternative is worse: the
    // callback calls setState on the surface that owns the value, and a
    // dispose usually means that surface is going away too — so committing
    // here trades a lost edit for "setState() called after dispose()". The
    // caller closes that gap by dropping focus (which fires the listener
    // while everything is still alive) before it acts; TextField's own
    // tap-outside handling does the same for a tap anywhere else.
    _focus.removeListener(_onFocusChanged);
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
