import 'package:flutter/material.dart';
import '../core/opcua_sessions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show NodeId, DynamicValue;
import 'package:tfc_dart/core/state_man.dart';
import '../providers/state_man.dart';

/// A field that lets the user select an index within an OPC UA array node.
///
/// Shows a "Detect" button that reads the node from the server to discover
/// the array size, then switches to a dropdown with valid indices.
/// Call [probe] imperatively (via a [GlobalKey]) when the node identity
/// changes outside this widget (e.g. after an OPC UA browse).
class OpcUaArrayIndexField extends ConsumerStatefulWidget {
  final int namespace;
  final String identifier;
  final String? serverAlias;

  /// The currently selected index (controlled from outside).
  final int? value;

  /// Pre-known array size — skips the initial "Detect" step.
  final int? initialArraySize;

  final ValueChanged<int?> onChanged;

  const OpcUaArrayIndexField({
    super.key,
    required this.namespace,
    required this.identifier,
    this.serverAlias,
    this.value,
    this.initialArraySize,
    required this.onChanged,
  });

  @override
  ConsumerState<OpcUaArrayIndexField> createState() =>
      OpcUaArrayIndexFieldState();
}

class OpcUaArrayIndexFieldState extends ConsumerState<OpcUaArrayIndexField> {
  int? _arraySize;
  bool _isProbing = false;
  String? _probeError;

  @override
  void initState() {
    super.initState();
    _arraySize = widget.initialArraySize;
    // Auto-probe when we have a selected index but no known array size,
    // so the dropdown is shown immediately instead of "tap Detect".
    if (widget.value != null && _arraySize == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) probe();
      });
    }
  }

  @override
  void didUpdateWidget(OpcUaArrayIndexField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Invalidate probe result when the node identity changes.
    if (oldWidget.namespace != widget.namespace ||
        oldWidget.identifier != widget.identifier ||
        oldWidget.serverAlias != widget.serverAlias) {
      setState(() {
        _arraySize = null;
        _probeError = null;
      });
    }
  }

  /// Reads the node from the server and, if it is a fixed-size array, switches
  /// to the dropdown UI. Safe to call imperatively via a [GlobalKey].
  Future<void> probe() async {
    final ns = widget.namespace;
    final id = widget.identifier.trim();
    if (id.isEmpty) return;

    setState(() {
      _isProbing = true;
      _probeError = null;
    });

    try {
      final stateMan = ref.read(stateManProvider).valueOrNull;
      if (stateMan == null) throw Exception('Server connections not ready');

      ClientWrapper? wrapper;
      for (final w in opcUaSessionsOf(stateMan)) {
        if (w.config.serverAlias == widget.serverAlias) {
          wrapper = w;
          break;
        }
      }
      wrapper ??= opcUaSessionsOf(stateMan).isEmpty ? null : opcUaSessionsOf(stateMan).first;
      if (wrapper == null) throw Exception('No OPC UA client available');

      final nodeId = int.tryParse(id) != null
          ? NodeId.fromNumeric(ns, int.parse(id))
          : NodeId.fromString(ns, id);

      final DynamicValue value =
          await wrapper.client.read(nodeId).timeout(const Duration(seconds: 5));

      if (!mounted) return;
      if (value.isArray) {
        final size = value.asArray.length;
        setState(() {
          _isProbing = false;
          _arraySize = size;
        });
        // Invalidate selection if it is out-of-range for the new size.
        final current = widget.value;
        if (current != null && (current < 0 || current >= size)) {
          widget.onChanged(null);
        }
      } else {
        setState(() {
          _isProbing = false;
          _arraySize = null;
          _probeError = 'Node is not an array';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProbing = false;
        _probeError = 'Probe failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_arraySize != null && _arraySize! > 0) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Array Index (0-based, size: $_arraySize)',
              ),
              child: DropdownButton<int?>(
                value: widget.value,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('None (whole array)')),
                  ...List.generate(
                    _arraySize!,
                    (i) => DropdownMenuItem<int?>(value: i, child: Text('$i')),
                  ),
                ],
                onChanged: widget.onChanged,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-probe',
            onPressed: _isProbing ? null : probe,
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Array Index',
              errorText: _probeError,
            ),
            child: const Text('—  tap Detect to read from server',
                style: TextStyle(color: Colors.grey)),
          ),
        ),
        const SizedBox(width: 4),
        _isProbing
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: probe,
                icon: const Icon(Icons.search, size: 16),
                label: const Text('Detect'),
              ),
      ],
    );
  }
}
