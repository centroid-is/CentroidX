/// The trust ceremony: one dialog, one fingerprint, one real choice.
///
/// This is deliberately the shape of the "Server identity" dialog noVNC shows
/// on this plant's own rigs — the operator has seen it before, and precedent
/// is half of what makes a security prompt readable. The other half is that
/// it asks exactly one answerable question: does this fingerprint match the
/// one printed where the gateway's certificates were made?
///
/// **What approval means, and what it does not.** Approving pins the fetched
/// certificate authority in this station's device-local store; from then on
/// the panel refuses anything else claiming to be the gateway, and a changed
/// CA is a hard handshake refusal — never a re-prompt. This dialog therefore
/// appears once per station per plant CA, at configuration time, with an
/// operator present; it is not an interstitial and it can never appear on a
/// connection.
///
/// No raw `Colors.*` and no `colorScheme.outline` (invisible in both schemes);
/// the fingerprint carries no colour of its own — the theme's `roboto-mono`
/// is what makes it comparable character by character.
library;

import 'package:flutter/material.dart';

/// Shows the ceremony; resolves `true` only on Approve.
///
/// `barrierDismissible: false`, so a tap beside the dialog cannot be mistaken
/// for a decision either way — the null of a dismissed barrier would have to
/// be interpreted, and both interpretations are wrong.
Future<bool> showGatewayIdentityDialog(
  BuildContext context, {
  required Uri gateway,
  required String fingerprint,
}) async {
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        GatewayIdentityDialog(gateway: gateway, fingerprint: fingerprint),
  );
  return approved ?? false;
}

/// The dialog itself, public so a golden can pump it directly.
class GatewayIdentityDialog extends StatelessWidget {
  const GatewayIdentityDialog({
    super.key,
    required this.gateway,
    required this.fingerprint,
  });

  /// The endpoint the operator typed — rendered without userinfo, the same
  /// discipline `gateway_link_status.dart` applies to every URL that reaches
  /// a screen.
  final Uri gateway;

  /// SHA-256 of the fetched CA's DER, computed on this panel.
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final where = gateway.replace(userInfo: '').toString();
    return AlertDialog(
      title: const Text('Gateway identity'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('The gateway at $where has provided the following '
                'identifying information:'),
            const SizedBox(height: 16),
            Text('SHA-256 fingerprint of its certificate authority',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(fingerprint),
            const SizedBox(height: 16),
            Text(
              'Compare it with the fingerprint printed where the gateway\'s '
              'certificates were made — approve only if they match. '
              'Approving pins this authority on this station: the panel '
              'will refuse anything else claiming to be the gateway.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
