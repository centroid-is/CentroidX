import 'package:flutter/material.dart';

import 'answers.dart';
import 'theme.dart';

/// A full-bleed step with a title, a scrolling body and a fixed action row.
///
/// The body parameter is `body`, not `children`: `sort_child_properties_last`
/// would otherwise demand it come after `primary`/`secondary` at every call
/// site, which reads worse than naming it for what it is.
///
/// The body scrolls and the actions sit above [keyboardReserve] so that the
/// on-screen keyboard never covers the button the operator is reaching for.
class SetupStep extends StatelessWidget {
  const SetupStep({
    super.key,
    required this.title,
    required this.body,
    required this.primary,
    this.subtitle,
    this.secondary,
  });

  final String title;
  final String? subtitle;
  final List<Widget> body;
  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: t.textTheme.headlineMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            )),
          ],
          // 24 less the label overhang the scroll view now carries as padding,
          // so the gap under the subtitle is unchanged.
          const SizedBox(height: 24 - labelOverhang),
          Expanded(
            child: SingleChildScrollView(
              // The top padding is not spacing: a scroll view clips at its own
              // edge, and the first field's floating label is painted above
              // that edge. See [labelOverhang].
              padding: const EdgeInsets.only(
                  top: labelOverhang, bottom: keyboardReserve),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: body,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (secondary != null) ...[secondary!, const SizedBox(width: 16)],
              primary,
            ],
          ),
        ],
      ),
    );
  }
}

/// A password field with a Generate action.
///
/// Typing four passwords and their confirmations on an on-screen keyboard is
/// nine fields of glass typing, and most of these values are only ever read by
/// containers on this machine. Generate fills one in and reveals it, so the
/// operator types only what they intend to remember.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.label,
    required this.helper,
    required this.initial,
    required this.onChanged,
  });

  final String label;
  final String helper;
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  bool _obscure = true;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _generate() {
    final v = generatePassword();
    _c.text = v;
    setState(() => _obscure = false); // shown once, so it can be written down
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: fieldGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              controller: _c,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: widget.label,
                helperText: widget.helper,
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  iconSize: 28,
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show' : 'Hide',
                ),
              ),
              validator: validatePassword,
              onChanged: widget.onChanged,
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton(onPressed: _generate, child: const Text('Generate')),
          ),
        ],
      ),
    );
  }
}

/// One choice out of a few, as a row of full-height buttons. A dropdown would
/// cost a second tap and a scroll, and a radio dot is a poor finger target;
/// three buttons the operator can read from a metre away are neither.
class ChoiceField extends StatelessWidget {
  const ChoiceField({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.helper,
  });

  final String label;

  /// Code to display name, in the order the buttons appear.
  final Map<String, String> options;
  final String value;
  final ValueChanged<String> onChanged;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final entries = options.entries.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: fieldGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.inputDecorationTheme.labelStyle),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  child: entries[i].key == value
                      ? FilledButton(
                          onPressed: () => onChanged(entries[i].key),
                          child: Text(entries[i].value),
                        )
                      : OutlinedButton(
                          onPressed: () => onChanged(entries[i].key),
                          child: Text(entries[i].value),
                        ),
                ),
              ],
            ],
          ),
          if (helper != null) ...[
            const SizedBox(height: 8),
            Text(helper!, style: t.inputDecorationTheme.helperStyle),
          ],
        ],
      ),
    );
  }
}

/// A plain text field sized for touch.
class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.helper,
    this.validator,
  });

  final String label;
  final String? helper;
  final String initial;
  final ValueChanged<String> onChanged;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: fieldGap),
      child: TextFormField(
        initialValue: initial,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
        ),
        validator: validator,
        onChanged: onChanged,
      ),
    );
  }
}
