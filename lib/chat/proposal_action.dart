import 'dart:convert';
import 'package:tfc/widgets/panes/standard_dialog.dart';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/navigator_key.dart';
import '../providers/proposal_state.dart';

/// Maps MCP proposal types to editor routes.
const _proposalRoutes = <String, String>{
  'alarm': '/advanced/alarm-editor',
  'alarm_create': '/advanced/alarm-editor',
  'alarm_update': '/advanced/alarm-editor',
  'key_mapping': '/advanced/key-repository',
  'page': '/advanced/page-editor',
  'asset': '/advanced/page-editor',
  'asset_update': '/advanced/page-editor',
  'report': '/advanced/report-editor',
  'shift_calendar': '/advanced/report-editor',
};

/// A widget that parses proposal JSON from tool results and provides
/// an "Open in Editor" button to navigate to the appropriate editor.
///
/// Proposal JSON must contain a `_proposal_type` field that maps to
/// a known editor route (alarm editor, key repository, page editor).
///
/// Uses [navigatorKeyProvider] to obtain a [BuildContext] below the
/// app [Navigator], because this widget lives inside the chat overlay
/// which is above the Navigator in the widget tree.
class ProposalAction extends ConsumerWidget {
  /// Raw JSON string from a tool result containing a proposal.
  final String proposalJson;

  const ProposalAction({super.key, required this.proposalJson});

  /// Returns a [BuildContext] that is a descendant of the app Navigator.
  BuildContext _navContext(WidgetRef ref, BuildContext fallback) {
    final key = ref.read(navigatorKeyProvider);
    return key?.currentContext ?? fallback;
  }

  /// Whether this proposal is still pending in the universal state.
  bool _isPending(WidgetRef ref) {
    final state = ref.watch(proposalStateProvider);
    return state.proposals.any((p) => p.proposalJson == proposalJson);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = _parseProposal();
    if (parsed == null) {
      return _buildFallbackButton(context, ref);
    }

    final proposalType = parsed['_proposal_type'] as String?;
    final route = proposalType != null ? _proposalRoutes[proposalType] : null;

    if (route == null) {
      return _buildFallbackButton(context, ref);
    }

    final pending = _isPending(ref);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status indicator: amber for pending, grey for processed
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pending ? Colors.amber : Colors.grey,
          ),
        ),
        ElevatedButton.icon(
          onPressed: () {
            // Report the view so the AI knows its proposal was opened.
            final state = ref.read(proposalStateProvider);
            for (final p in state.proposals) {
              if (p.proposalJson == proposalJson) {
                ref.read(proposalStateProvider.notifier).viewProposal(p.id);
                break;
              }
            }
            try {
              Beamer.of(_navContext(ref, context))
                  .beamToNamed(route, data: proposalJson);
            } catch (_) {
              // Beamer not available from this context — best effort.
            }
          },
          icon: const Icon(Icons.edit, size: 16),
          label: Text(_labelForType(proposalType!)),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildFallbackButton(BuildContext context, WidgetRef ref) {
    return ElevatedButton.icon(
      onPressed: () {
        showStandardDialog<void>(
          context: _navContext(ref, context),
          useRootNavigator: true,
          title: 'Proposal',
          icon: Icons.description_outlined,
          builder: (ctx) => SelectableText(
            _formatJson(proposalJson),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        );
      },
      icon: const Icon(Icons.visibility, size: 16),
      label: const Text('View Proposal'),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        textStyle: const TextStyle(fontSize: 13),
      ),
    );
  }

  Map<String, dynamic>? _parseProposal() {
    try {
      final decoded = jsonDecode(proposalJson);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _labelForType(String type) {
    switch (type) {
      case 'alarm':
        return 'Open in Alarm Editor';
      case 'alarm_create':
        return 'Open in Alarm Editor';
      case 'alarm_update':
        return 'Open in Alarm Editor';
      case 'key_mapping':
        return 'Open in Key Repository';
      case 'page':
        return 'Open in Page Editor';
      case 'asset':
        return 'Open in Page Editor';
      case 'report':
      case 'shift_calendar':
        return 'Open in Report Editor';
      default:
        return 'Open in Editor';
    }
  }

  String _formatJson(String json) {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(jsonDecode(json));
    } catch (_) {
      return json;
    }
  }
}
