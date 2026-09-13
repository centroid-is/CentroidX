import 'package:flutter/material.dart';

/// A disabled stand-in for the real picker.
///
/// It keeps [selectedDocId] and reports nothing through [onChanged]: an asset
/// that already names a document keeps naming it, because this build cannot
/// offer a list to change it from, and silently clearing the field would edit
/// the plant's configuration as a side effect of opening a page.
class TechDocPicker extends StatelessWidget {
  const TechDocPicker({
    super.key,
    required this.selectedDocId,
    required this.onChanged,
    this.enabled = true,
  });

  final int? selectedDocId;
  final ValueChanged<int?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Technical document',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: Text(
        selectedDocId == null
            ? 'Not available in the browser'
            : 'Document #$selectedDocId — not editable in the browser',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
