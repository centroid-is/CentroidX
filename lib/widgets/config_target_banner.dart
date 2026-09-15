/// Which machine am I editing? (17-13, ACCESS-04 — redesigned per owner)
///
/// One screen, two targets, and silently configuring the wrong one is the
/// failure mode the ROADMAP names before it names the feature. The first cut
/// answered with a full-width page band above the Transport card; the owner
/// rejected it on both counts — it labelled the wrong card (the target is a
/// fact about the Backend Configuration card's editor, not about Transport,
/// which is device-local in both modes) and it spent a band of height on one
/// sentence where the JSON editor is what an operator needs the room for.
///
/// So the widget is now two compact faces of the same fact:
///
///  * **`.backend`** — a one-line chip for the Backend Configuration card's
///    own header: the attention yellow, an antenna, and the endpoint the
///    panel is dialling. The colour and glyph read at arm's length; the URL
///    reads on approach. It names a TARGET and nothing else — the card's save
///    button remains the one unsaved-state indicator, and this chip never
///    changes with editing.
///  * **`.station`** — a quiet caption line for the direct-mode page, placed
///    below the Transport card and above the four station sections it
///    describes. Quiet on purpose: editing your own station is the
///    unremarkable case.
///
/// ## Colour
///
/// The backend face wears `HmiStateColors.yellow` — attention, not alarm;
/// only fault red may be saturated here. Ink splits on brightness for the
/// reason the Transport card's save button splits it: both schemes' yellows
/// are readable as ink on a dark card and far too dim on a cream one. Every
/// edge is the yellow itself or `onSurface` with alpha, never the scheme's
/// edge role: neither Solarized scheme sets one, so an edge borrowed from it
/// is invisible on the dark theme the night shift runs (project memory
/// `solarized-outline-is-invisible`). The acceptance grep on this file is
/// literal and counts comments, which is why the offending spelling appears
/// nowhere here.
library;

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../theme.dart';

/// The target, named — one key for both faces, so tests find structure
/// rather than prose.
const Key kConfigTargetBannerKey = Key('config_target_banner');

/// One line that names the machine about to be edited.
class ConfigTargetBanner extends StatelessWidget {
  /// Direct mode: the page edits this station's own configuration, and
  /// [name] is the station's name. Renders as a caption line.
  const ConfigTargetBanner.station({super.key, required this.name})
      : isBackend = false;

  /// Gateway mode: the page edits the plant backend's configuration, and
  /// [name] is the endpoint this panel is dialling. Renders as a chip for
  /// the Backend Configuration card's header.
  const ConfigTargetBanner.backend({super.key, required this.name})
      : isBackend = true;

  /// Whether the target is the plant backend rather than this station.
  final bool isBackend;

  /// The machine, named. A marker that only wears a colour would pass a
  /// presence test while naming the wrong machine.
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!isBackend) {
      // The caption face: this station, named, in a line and no more.
      final ink = theme.colorScheme.onSurface.withValues(alpha: 0.65);
      return Row(
        key: kConfigTargetBannerKey,
        children: [
          FaIcon(FontAwesomeIcons.display, size: 12, color: ink),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'This station’s own configuration — $name.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: ink),
            ),
          ),
        ],
      );
    }

    // The chip face: attention, not alarm.
    final attention = HmiStateColors.of(context).yellow;
    final ink = theme.brightness == Brightness.dark
        ? attention
        : theme.colorScheme.onSurface;
    return Container(
      key: kConfigTargetBannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: attention.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: attention.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(FontAwesomeIcons.towerBroadcast, size: 11, color: ink),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
