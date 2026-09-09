/// Tap-time elevation: decide when the control is **pressed**, and never issue
/// a write that will be refused.
///
/// ## What this changes
///
/// Before this file, an operator met a lock by pressing a button, watching an
/// `AccessDenied` be thrown deep inside `GuardedStateMan`, and seeing a prompt
/// only because the guard publishes to `accessDenialsProvider` *before* it
/// throws (`access_denied_prompt.dart`). Thirty-one call sites let that
/// exception past them. This file moves the decision to the tap: the group is
/// resolved synchronously from the snapshot 04-05 loads, and a refused control
/// never composes a value, never calls `StateMan.write`, and never raises an
/// exception on the operator's path.
///
/// `GuardedStateMan` is unchanged and still enforces underneath. This is a
/// **second** gate, not a replacement — the UI check is advisory and the guard
/// is the enforcement point, which is why `tag_access_guard_test.dart` asserts
/// that a write skipping this helper is still refused (T-04-32).
///
/// ## It reuses the denial path rather than building a second one
///
/// [guardTagWrite] publishes the same [AccessDenied] the guard publishes, onto
/// the same stream, so `AccessDeniedPrompt` shows the same prompt with the
/// same copy and the same de-duplication. There is no prompt in this file and
/// no copy string of its own; if a tap-time refusal ever needs different
/// words, that is an edit to `access_denied_prompt.dart`'s constants.
///
/// The alternative was a second prompt widget with a second copy of "this did
/// not happen" — and then two things to keep in step every time the wording
/// changes, in a phase whose whole point is that the operator is told what
/// permission is missing. One publisher and one listener is also what keeps
/// T-04-35 true: one refusal, one prompt.
///
/// ## And it records the refusal itself — this is the half somebody will want
/// to delete
///
/// Before this file, an operator jabbing a locked Start produced a denial row
/// from the guard on every press. After it, **the guard never sees the
/// press.** If this function did not record, the trail would go quiet in
/// exactly the case plan 03-04 called "a signal, not noise", and a missing
/// audit row is the one defect nobody notices: it looks identical to an action
/// that never happened.
///
/// So the refusal is recorded here, with `allowed: false`, the member, and a
/// **null `newValue`** — no value was ever composed, because the control
/// refused before the caller built one. That null is meaningful rather than
/// missing, and it is what tells a tap-time refusal apart from a guard refusal
/// in the trail. Phase 5's audit page will want that difference.
///
/// ## Nothing is greyed
///
/// A locked control renders its value, takes the tap, and explains itself.
/// [TagLockBadge] annotates a control; it never disables one and never takes a
/// tap of its own. Nothing here returns a disabled widget, and
/// `tag_access_guard_test.dart` greps this file to keep it that way (T-04-33).
///
/// ## Nothing is replayed
///
/// The refused action is not held anywhere. Signing in re-opens the
/// affordance; making the change again is the operator's to do, and
/// `kAccessDeniedNoReplayNote` is what tells them so (T-04-34).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../providers/access.dart';
import '../providers/access_policy.dart';
import '../providers/access_templates.dart';
import '../providers/state_man.dart';

/// This file's diagnostic logger. Only the audit-sink failure logs.
final Logger _log = Logger();

/// The `who` recorded when nobody is signed in. The same string
/// `GuardedStateMan` uses, so the two paths' rows read alike.
const String _anonymousWho = 'anonymous';

/// The parts of a tap-time refusal only a provider `Ref` can supply.
///
/// [reportAccessDenial] and [RefAuditSink] are both typed to Riverpod's `Ref`,
/// which a widget does not have — a `WidgetRef` is a different type. Rather
/// than widen either signature, this provider is the one-line bridge, and
/// being a provider it is also the seam a test overrides to watch what a
/// refusal recorded.
@immutable
class TagRefusalSink {
  const TagRefusalSink({
    required this.station,
    required this.audit,
    required this.publish,
  });

  /// The `station` column of the row this panel writes.
  final String station;

  /// Where the row goes. Resolved per row by [RefAuditSink], so a station that
  /// gains a database mid-session starts recording without a rebuild.
  final AuditSink audit;

  /// Publishes onto `accessDenialsProvider` — the same stream both guards use.
  final void Function(AccessDenied denial) publish;
}

/// The bridge [guardTagWrite] reads to record and publish a refusal.
final tagRefusalSinkProvider = Provider<TagRefusalSink>(
  (ref) => TagRefusalSink(
    station: ref.read(stationNameProvider),
    audit: RefAuditSink(ref),
    publish: (denial) => reportAccessDenial(ref, denial),
  ),
);

/// The key the decision is made about, or null when it cannot be resolved.
///
/// Resolution goes through the same `StateMan.resolveKey` the guard uses, so a
/// substituted key produces the same `itemKey` in both paths and an operator
/// who sees "What was refused: ST101.CN01" is reading the key that was
/// actually addressed.
///
/// **Null means "get out of the way".** A key still naming a variable nothing
/// has published is `StateMan`'s failure to raise — it is what
/// `_throwIfUnresolved` is for — and reinterpreting it here as a refusal would
/// put a lock on a control whose real problem is a missing substitution, which
/// is a fault an operator can neither understand nor fix. The guard's own
/// resolve arm decides the same way: it hands the call straight on.
///
/// **An ordinary key never touches `stateManProvider`.** The first line is
/// `resolveKey`'s own first line, so a page of two hundred plain keys resolves
/// two hundred times for the cost of a `String.contains`.
///
/// [stateMan] is the caller's own handle when it has one — [writeTag] always
/// does, and using it is what keeps the decision on the key that is about to
/// be written. Without one the substitutions come from `stateManProvider`, and
/// a provider that has not resolved yet answers null here: fail-open, rather
/// than deciding a variable key on a name that is not the one being addressed.
String? _resolvedTagKey(WidgetRef ref, String key, StateMan? stateMan) {
  if (!key.contains(r'$')) return key;

  if (stateMan == null) {
    try {
      stateMan = ref.read(stateManProvider).valueOrNull;
    } on Object {
      return null;
    }
  }
  if (stateMan == null) return null;

  final String resolved;
  try {
    resolved = stateMan.resolveKey(key);
  } on Object {
    return null;
  }
  return resolved.contains(r'$') ? null : resolved;
}

/// The group [member] of [resolvedKey] needs. Never null since the
/// 2026-09-02 operate-floor ruling: an unbound key answers
/// [AccessGroup.operate], so every control on the plant now has a real
/// question to ask of the session — which is why the callers below all watch
/// `tagAccessProvider` where they used to short-circuit on "nothing bound".
/// A page of controls rebuilding on sign-in is the point, not a regression:
/// the locks have to come off, or go on, the moment the session changes.
///
/// A `read` of the resolver itself: the decision for the session in force is
/// still `TagAccess.canWrite` and nowhere else. This only answers "which
/// group is being asked about?" — for the denial row and the prompt.
AccessGroup _boundGroup(WidgetRef ref, String resolvedKey, String? member) =>
    ref.read(tagBindingResolverProvider).groupFor(resolvedKey, member);

/// Whether the session in force may write [member] of [key]. The pure
/// question: no row, no prompt, no side effect of any kind.
///
/// **Call it from `build`.** It `watch`es `tagAccessProvider` for a bound key,
/// so a control that renders a lock loses it the moment the operator signs in
/// — without the pane having to be navigated away from and back.
///
/// True when the session holds the group the key requires — which is at
/// least `operate` for every key, bound or not (2026-09-02 ruling). The only
/// remaining fail-open arm is an unresolvable key, which is `StateMan`'s
/// failure to raise, not a lock.
bool tagWriteAllowed(
  WidgetRef ref,
  String key, {
  String? member,
  StateMan? stateMan,
}) {
  final resolved = _resolvedTagKey(ref, key, stateMan);
  if (resolved == null) return true;
  return ref.watch(tagAccessProvider).canWrite(resolved, member: member);
}

/// Ask before acting: true when the caller should proceed, false when the
/// operator has just been told why not.
///
/// On a refusal this returns **false** having done three things and no others:
/// written one audit row, published one [AccessDenied] to
/// `accessDenialsProvider`, and thrown nothing. The caller's next line is
/// simply not run — no exception to catch, no `setState` guarded by a `try`.
///
/// Called from a tap handler, so it reads rather than watches. [tagWriteAllowed]
/// is the same question for `build`.
///
/// **The row.** `surface` is the tag surface, `itemKey` is the resolved key,
/// `member` is as given, `groupRequired` is the missing group, `allowed` is
/// false, `origin` is `operator`, and the `actionId` is fresh. `oldValue` and
/// `newValue` are both **null on purpose**: the control refused before a value
/// was composed, so there is nothing to record, and that null is what
/// distinguishes this row from `GuardedStateMan`'s — which always carries the
/// value that was being written.
///
/// **A throwing audit sink does not change the answer.** The refusal still
/// returns false and the operator is still told. A trail that is down is a
/// serious problem and it is logged; it is not a reason to let a write
/// through, and it is not a reason to leave the operator staring at a control
/// that did nothing.
Future<bool> guardTagWrite(
  WidgetRef ref,
  String key, {
  String? member,
  StateMan? stateMan,
}) async {
  final resolved = _resolvedTagKey(ref, key, stateMan);
  if (resolved == null) return true;

  if (ref.read(tagAccessProvider).canWrite(resolved, member: member)) {
    return true;
  }

  final group = _boundGroup(ref, resolved, member);

  final sink = ref.read(tagRefusalSinkProvider);
  final session =
      ref.read(accessSessionProvider).valueOrNull ?? kSessionWhileLoading;

  // The row before the prompt, the same order `GuardedStateMan` uses: the row
  // is the evidence the refusal happened and it must exist even if the prompt
  // never opens.
  try {
    await sink.audit.record(AuditRecord(
      at: DateTime.now(),
      who: session.user?.username ?? _anonymousWho,
      station: sink.station,
      roleName: session.roleName,
      surface: AccessSurface.tag.wireName,
      itemKey: resolved,
      member: member,
      // Both null, and deliberately: nothing was read and nothing was
      // composed. See the paragraph above before "fixing" this.
      oldValue: null,
      newValue: null,
      groupRequired: group.name,
      allowed: false,
      actionId: newActionId(),
    ));
  } on Object catch (error, stack) {
    _log.e('Could not record a tap-time refusal for "$resolved"',
        error: error, stackTrace: stack);
  }

  sink.publish(AccessDenied(resolved, group));
  return false;
}

/// [guardTagWrite], then `sm.write` when it passes. True when the write was
/// issued, false when it was refused.
///
/// **This is the form plans 04-10 and 04-11 convert 31 call sites to, and the
/// reason is mechanical as well as ergonomic.** It owns the `.write(` call.
/// `kUncaughtAccessDeniedWriteSites` (`access_denied_prompt.dart`) is derived
/// by walking `lib/` for `.write(` calls whose receiver is a `StateMan`, so a
/// converted asset — which no longer contains a `stateMan.write(` of its own —
/// disappears from that walk and the count falls, without the derivation
/// needing to understand control flow. A helper that took a callback and left
/// the `.write(` at the call site would read just as well and lower nothing.
///
/// The false return is what a caller uses instead of catching: an asset that
/// must not run its optimistic `setState` after a refusal has an answer,
/// rather than an exception it would have to distinguish from a comms failure.
///
/// **It does not catch what `sm.write` throws.** A comms failure, a resolve
/// failure, or an `AccessDenied` from the guard itself — the belt to this
/// file's braces — all reach the caller exactly as they do today.
Future<bool> writeTag(
  WidgetRef ref,
  StateMan sm,
  String key,
  DynamicValue value, {
  String? member,
}) async {
  if (!await guardTagWrite(ref, key, member: member, stateMan: sm)) {
    return false;
  }
  await sm.write(key, value);
  return true;
}

/// A small lock beside a control the session may not write, and nothing at all
/// otherwise.
///
/// **Advisory, never an enforcement point** — the same standing as
/// `AccessLockBadge` on a menu row. It annotates the control; the control
/// stays visible, stays tappable, and keeps whatever gesture it had. This
/// widget takes no tap of its own, so a caller can put it inside the control's
/// own hit area without stealing the press that opens the prompt.
///
/// With nothing to show it is a `SizedBox.shrink()` measured at `Size.zero`,
/// including the gap — a `SizedBox` beside the badge in the caller would
/// survive the badge disappearing and every ordinary control in the app would
/// silently gain 8 px.
class TagLockBadge extends ConsumerWidget {
  const TagLockBadge({super.key, required this.tagKey, this.member});

  /// The tag the control writes.
  ///
  /// Named `tagKey` rather than `key`, which on a widget is `Widget.key`: a
  /// `String key` here would shadow it, leaving the badge unable to carry a
  /// framework key and reading as one at every call site.
  final String tagKey;

  /// The struct member, or null to ask about the key as a whole.
  final String? member;

  /// The glyph's size. Smaller than a control's own icon: the badge annotates
  /// the control, it is not a second subject in it.
  static const double glyphSize = 16.0;

  /// The gap between the control and the glyph, kept **inside** this widget so
  /// an unlocked control contributes exactly zero width.
  static const double gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = _resolvedTagKey(ref, tagKey, null);
    if (resolved == null) return const SizedBox.shrink();

    if (ref.watch(tagAccessProvider).canWrite(resolved, member: member)) {
      return const SizedBox.shrink();
    }

    final group = _boundGroup(ref, resolved, member);

    return Semantics(
      // Named, not just drawn: a glyph-only lock says nothing to a screen
      // reader, and `group.name` is the same word the roles screen ticks and
      // the prompt repeats.
      label: 'Locked. Needs the "${group.name}" permission.',
      child: Padding(
        padding: const EdgeInsets.only(left: gap),
        child: Icon(
          Icons.lock_outline,
          size: glyphSize,
          // Not `HmiStateColors.orange`, which means forced/override and an
          // elevated session — a locked control and an elevated one would read
          // alike. Not red either: a lock is not a fault. The same colour the
          // prompt paints its own lock.
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
