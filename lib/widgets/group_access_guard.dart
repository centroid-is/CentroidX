/// The tap-time gate for a control that writes something other than a tag or
/// a preference.
///
/// `tag_access_guard.dart` covers every `StateMan` write and `GuardedPreferences`
/// covers every `PreferencesApi` write. Neither covers a control that reaches
/// the host directly — the About Linux page sets the clock, the timezone and
/// the NTP servers over D-Bus, and reboots or powers off the station through
/// `login1`. Those calls touch no tag and no preference, so they arrive at
/// polkit with nothing in front of them, and the station rule in
/// `docs/polkit/49-centroid-clock.rules` grants them to the container
/// unconditionally. The HMI is the only thing that can ask who is standing at
/// the panel.
///
/// **This is the same shape as [guardTagWrite], deliberately.** Ask before
/// acting; on a refusal write one audit row, publish one [AccessDenied], throw
/// nothing, and return false so the caller's next line simply does not run.
/// A control that renders locked stays visible, enabled and tappable — the
/// ruling in `access_lock_badge.dart` — because a greyed control teaches the
/// operator the panel is broken, while a refusal tells them which permission
/// they need and offers a way to get it.
///
/// **The decision comes from [resolveAccessGate] and is not re-derived here.**
/// A second copy of "locked when…" is how a lock ends up on a control that
/// works, the first time one of the two copies is edited.
/// [allowWhenRepositoryUnavailable] is false with no parameter to change it:
/// the one route that stays open through a database outage is Server Config,
/// for the reasons `access_gate.dart` sets out at length, and none of them is
/// about setting a plant's clock.
///
/// **On a gateway panel these controls follow the relayed session**, because
/// the gate asks `accessAuthorityProvider` rather than the repository. A
/// station with no Postgres by design is not a station where nobody can sign
/// in, and before that distinction existed the clock, the timezone and the
/// reboot button were refused on every gateway panel no matter who was
/// standing at it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access.dart';
import '../providers/access_policy.dart';
import 'access_gate.dart';
import 'tag_access_guard.dart';

final Logger _log = Logger();

/// The `who` written when nobody is signed in. Matches the tag guard's.
const String _anonymousWho = 'anonymous';

/// Whether this session holds [group].
///
/// For `build`. Watches, so a control that renders locked loses the lock the
/// moment the operator signs in, without the page being navigated away from
/// and back.
///
/// **Waiting counts as locked.** [AccessGate] renders neither the page nor the
/// lock while the session resolves, because a whole page flashing a lock is
/// worse than one arriving a frame late. A single glyph on a control is the
/// opposite trade: showing it for a frame and then removing it is unremarkable,
/// and the alternative — rendering a control as open while the session is still
/// unknown — is the arm that would be wrong.
bool groupAllowed(WidgetRef ref, AccessGroup group) =>
    resolveAccessGate(
      group: group,
      authority: ref.watch(accessAuthorityProvider),
      session: ref.watch(accessSessionProvider),
      allowWhenRepositoryUnavailable: false,
    ) ==
    AccessGateState.allowed;

/// Ask before acting: true when the caller should proceed, false when the
/// operator has just been told why not.
///
/// Called from a tap handler, so it reads rather than watches.
///
/// [itemKey] is what the audit trail and the denial prompt name as the thing
/// that was refused, so it must be the action in the operator's words —
/// `system.clock.timezone`, not a D-Bus member name they have never seen.
///
/// The row is written before the prompt is published, the order
/// [guardTagWrite] uses: the row is the evidence the refusal happened, and it
/// has to exist even if nothing is watching the stream. A throwing audit sink
/// is logged and does not change the answer — a trail that is down is not a
/// reason to let a write through.
Future<bool> guardGroupAction(
  WidgetRef ref,
  AccessGroup group, {
  required String itemKey,
}) async {
  if (resolveAccessGate(
        group: group,
        authority: ref.read(accessAuthorityProvider),
        session: ref.read(accessSessionProvider),
        allowWhenRepositoryUnavailable: false,
      ) ==
      AccessGateState.allowed) {
    return true;
  }

  final sink = ref.read(tagRefusalSinkProvider);
  final session =
      ref.read(accessSessionProvider).valueOrNull ?? kSessionWhileLoading;

  try {
    await sink.audit.record(AuditRecord(
      at: DateTime.now(),
      who: session.user?.username ?? _anonymousWho,
      station: sink.station,
      roleName: session.roleName,
      // `pref`, not a new enum value. Every non-tag surface in the app already
      // records as `pref` — history views, knowledge stores, access templates
      // and the session section — and a fifth spelling for the same idea would
      // split the trail without telling anybody anything new.
      surface: AccessSurface.pref.wireName,
      itemKey: itemKey,
      member: null,
      // Both null: the control refused before a value was composed. Same
      // reasoning as `guardTagWrite`, and the same thing that distinguishes
      // this row from a guard's.
      oldValue: null,
      newValue: null,
      groupRequired: group.name,
      allowed: false,
      actionId: newActionId(),
    ));
  } on Object catch (error, stack) {
    _log.e('Could not record a tap-time refusal for "$itemKey"',
        error: error, stackTrace: stack);
  }

  sink.publish(AccessDenied(itemKey, group));
  return false;
}

/// A lock glyph for a control this session cannot use, and nothing at all
/// when it can.
///
/// Advisory, exactly like [TagLockBadge] — [guardGroupAction] is the check.
/// With nothing to show it is a zero-width `SizedBox`, including its own gap,
/// so adding it beside a control cannot change how that control lays out.
class GroupLockBadge extends ConsumerWidget {
  const GroupLockBadge({super.key, required this.group, this.size = 16.0});

  /// The permission the control needs.
  final AccessGroup group;

  /// The glyph's size. Smaller than the control's own icon: the badge
  /// annotates the control, it is not a second subject in it.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (groupAllowed(ref, group)) return const SizedBox.shrink();

    return Semantics(
      // Named, not just drawn: a glyph-only lock says nothing to a screen
      // reader, and `group.name` is the same word the roles screen ticks and
      // the denial prompt repeats.
      label: 'Locked. Needs the "${group.name}" permission.',
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(
          Icons.lock_outline,
          size: size,
          // Not orange, which means forced/override; not red, because a lock
          // is not a fault. The colour the denial prompt paints its own lock.
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
