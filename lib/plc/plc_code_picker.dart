import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart';

import '../providers/plc.dart';

/// A dropdown widget for selecting a PLC asset key.
///
/// Displays a list of indexed [PlcAssetSummary] assets from
/// [plcAssetSummaryProvider] with block count and variable count details.
/// When no PLC code has been indexed, the picker is disabled with a
/// "No PLC code indexed" hint.
///
/// A "None" option at the top allows clearing the current selection.
class PlcCodePicker extends ConsumerWidget {
  /// The currently selected PLC asset key, or null if none selected.
  final String? selectedAssetKey;

  /// Called when the user selects an asset or clears the selection.
  final ValueChanged<String?> onChanged;

  /// Whether the picker is interactive. When false, taps are ignored.
  final bool enabled;

  const PlcCodePicker({
    required this.selectedAssetKey,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summariesAsync = ref.watch(plcAssetSummaryProvider);

    return summariesAsync.when(
      loading: () => const InputDecorator(
        decoration: InputDecoration(
          labelText: 'PLC Code',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text('Loading...', style: TextStyle(color: Colors.grey)),
      ),
      error: (_, __) => const InputDecorator(
        decoration: InputDecoration(
          labelText: 'PLC Code',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text('Error loading PLC assets',
            style: TextStyle(color: Colors.red)),
      ),
      data: (summaries) {
        if (summaries.isEmpty) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'PLC Code',
              enabled: false,
            ),
            child: Text('No PLC code indexed',
                style: TextStyle(color: Colors.grey)),
          );
        }

        return DropdownButtonFormField<String>(
          value: selectedAssetKey,
          decoration: const InputDecoration(
            labelText: 'PLC Code',
          ),
          isExpanded: true,
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('None', style: TextStyle(fontStyle: FontStyle.italic)),
            ),
            ...summaries.map((s) => DropdownMenuItem<String>(
                  value: s.assetKey,
                  child: Text(
                    '${s.assetKey}  (${s.blockCount} blocks, ${s.variableCount} vars)',
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
          ],
          onChanged: enabled ? (key) => onChanged(key) : null,
        );
      },
    );
  }
}
