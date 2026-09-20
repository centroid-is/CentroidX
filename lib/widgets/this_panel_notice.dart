/// Says which machine a page is acting on, when that is not the machine the
/// operator is thinking about.
///
/// ## The problem it exists for
///
/// A handful of surfaces reach the operating system through `dart:io` or
/// D-Bus — the network configuration, the host's temperatures and clock, the
/// local database. Every one of them was written for a station wired directly
/// to the plant, where "this machine" and "the machine serving the plant" are
/// the same computer and the distinction has no way to come up.
///
/// On a **relayed** panel they are two computers. The page keeps working and
/// keeps telling the truth about the wrong host: the network card an engineer
/// reconfigures is the panel's, and nothing on the screen says so. An error
/// would be honest. A plausible wrong answer is not, which is why this ranks
/// above the features a relayed panel cannot reach at all.
///
/// ## What it does, and what it deliberately does not
///
/// It **names the machine**. It does not lock the page, hide a control or
/// refuse a write, and that is a decision rather than an omission: a relayed
/// panel is still a real computer whose network may genuinely need
/// configuring, and taking the ability away would break a legitimate job to
/// prevent a misreading. The same choice the database card makes one file
/// over in `preferences.dart` — gate what the page SAYS, never what it lets
/// an operator change.
///
/// Nothing renders on a direct station. There, the sentence would be noise
/// about a distinction that does not exist.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/gateway_default.dart';
import '../providers/gateway.dart';

/// Finds the notice in tests and goldens.
const Key kThisPanelNoticeKey = ValueKey<String>('this-panel-notice');

/// This panel's own hostname, as the operating system reports it.
///
/// A provider rather than a bare `Platform.localHostname` at the call site:
/// the notice names a machine, and a widget test or a golden that renders
/// whichever laptop happened to build it is not a test. Overriding this is
/// how a case pins the name.
///
/// A throw answers `this panel` rather than propagating. The hostname is the
/// nicety here; the load-bearing half of the sentence is that the station is
/// somewhere else, and that must still be said on a host whose name cannot
/// be read.
final panelHostnameProvider = Provider<String>((ref) {
  try {
    return Platform.localHostname;
  } catch (_) {
    return 'this panel';
  }
});

class ThisPanelNotice extends ConsumerWidget {
  const ThisPanelNotice({super.key, required this.subject});

  /// What the page acts on, as a noun phrase that follows "this panel's" —
  /// `'network configuration'`, `'temperatures and clock'`. Lower case, no
  /// trailing period; the notice supplies the sentence around it.
  final String subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `valueOrNull` with the default, never a spinner: this sits above a page
    // that is already rendering, and a progress indicator in its place would
    // make the page look like it was loading something it is not. The default
    // is direct mode, so the honest failure is that the notice is absent —
    // never that a direct station is told it is relayed.
    final gateway =
        ref.watch(gatewayConfigProvider).valueOrNull ?? defaultGatewayConfig();
    if (!gateway.isGateway) return const SizedBox.shrink();

    final theme = Theme.of(context);
    // Muted `onSurface`, never `colorScheme.outline`: neither Solarized scheme
    // sets that and it vanishes on dark (project memory
    // solarized-outline-is-invisible). The same value the database card uses,
    // because this is the same kind of statement.
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final station = gateway.url.trim();

    return Padding(
      key: kThisPanelNoticeKey,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: muted),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                // The panel first, because that is what the page is about
                // and what the operator is most likely to be wrong about.
                // The address gets its OWN sentence rather than trailing
                // the first: "not the station serving the plant at
                // wss://…" reads, on the screen, as though the PLANT were
                // at that address. Caught by looking at the golden.
                'This is ${ref.watch(panelHostnameProvider)}’s $subject '
                '— this panel, not the station serving the plant.'
                "${station.isEmpty ? '' : ' That machine is at $station.'}"
                ' Nothing here reaches it.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
