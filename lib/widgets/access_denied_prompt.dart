/// What a refused write looks like to the person who made it.
///
/// `AccessDenied` is thrown on the write path by `GuardedStateMan` and
/// `GuardedPreferences`, at roughly thirty asset call sites, none of which
/// handles it. Without this widget the visible result of the first denial on a
/// plant is a debug-mode red screen or, in release, nothing at all — and
/// "nothing at all" is worse, because the operator presses the button again.
///
/// **This prompt does not depend on anybody catching the exception.** Both
/// guards fire `onDenied` — which `lib/providers/*.dart` routes into
/// [reportAccessDenial] — *before* they throw, so the event reaches this
/// listener whether the call site swallows the throw, logs it, or lets it
/// escape to the framework. That ordering is the whole safety net; it is
/// asserted in `guarded_state_man_test.dart` ("the rows are written before the
/// exception is raised") and end-to-end in `access_denied_prompt_test.dart`.
///
/// **This is the safety net, not the good version.** Phase 4 is where the
/// elevation prompt fires at *tap* time and the control itself renders locked,
/// so a write that would be refused is never issued. What ships here is that
/// every denial reaches the operator meanwhile.
///
/// **Since plan 04-11 the good version is in front of it on the tag path.**
/// Every `StateMan` write site in `lib/` goes through `writeTag`
/// (`tag_access_guard.dart`) and resolves before it issues — see
/// [kUncaughtAccessDeniedWriteSites], which is 0 and says what that does and
/// does not mean. This widget is unchanged and still needed: the guards still
/// throw, `GuardedPreferences` has no tap-time gate, and a future site that
/// skips `writeTag` lands here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access_policy.dart';
import 'access_sign_in_dialog.dart';
import 'panes/pane_chrome.dart';
import 'panes/standard_dialog.dart';

/// How many `StateMan` write call sites in `lib/` do **not** handle
/// `AccessDenied`.
///
/// Derived on 2026-08-30 by walking every `.dart` file under `lib/`, dropping
/// comment lines, and counting the calls whose receiver is a `StateMan`:
///
/// ```sh
/// grep -rnE '\b(client|stateMan|sm|widget\.stateMan)\.write\(' \
///   --include='*.dart' lib/ | grep -v ':[0-9]*: *//'
/// grep -rn 'AccessDenied' lib/page_creator lib/widgets lib/pages   # empty
/// ```
///
/// `access_denied_prompt_test.dart` runs the same walk in Dart and asserts the
/// number, so the count cannot quietly grow, and it also asserts the second
/// grep is empty — the claim that none of these sites *handles* the refusal is
/// checked rather than assumed.
///
/// **What this number counts, in the terms the phase agreed and no softer.**
/// A site counted here is one where `AccessDenied` is not handled — where it
/// escapes as an unhandled asynchronous error, or where a bare `catch (e)`
/// swallows it into a log line or renders its developer string into a
/// snackbar. **None of those is a handling**: not one of them tells the
/// operator what permission was missing or offers a way through, which is why
/// they were all counted.
///
/// The operator saw this prompt in every one of those cases anyway, because
/// the guard publishes to `accessDenialsProvider` before it throws. Phase 4's
/// tap-time elevation is what removed the throw from the operator's path, by
/// never issuing a write that will be refused.
///
/// **2026-08-30, plan 04-10: 31 -> 22.** Nine sites moved onto
/// `writeTag` (`tag_access_guard.dart`), which owns the `.write(` call, so
/// their files no longer appear in the walk at all:
///
/// | File | Sites | Member passed |
/// |---|---|---|
/// | `conveyor.dart` | 1 | the pane's `write(field, …)` field |
/// | `sensor.dart` | 1 | the `ST_Sensor_HMI` member being set |
/// | `schneider.dart` | 1 | the parameter the edit changed |
/// | `recipes.dart` | 2 | none — both replace a whole line or the whole array |
/// | `number.dart` | 1 | none — a scalar key |
/// | `start_stop_button.dart` | 1 | none — a command BOOL |
/// | `analog_box.dart` | 1 | none — a scalar setpoint |
/// | `conveyor_gate.dart` | 1 | none — a force BOOL |
///
/// **2026-08-30, plan 04-11: 22 -> 0.** The last twenty-two, same move:
///
/// | File | Sites | Member passed |
/// |---|---|---|
/// | `beckhoff.dart` | 8 | none — `force`, `on_filters` and `off_filters` are arrays, so the channel is an index and not a member a template could have a rule for |
/// | `beckhoff.dart` | 1 | `p_cmd_Reset` — the EL9222 reset, a genuine struct member |
/// | `advantys_stb.dart` | 8 | none — the same three arrays |
/// | `button.dart` | 3 | none — a command BOOL |
/// | `section_button.dart` | 2 | the `p_cmd_*` bit being set on `ST_Section_HMI` |
///
/// Both numbers were **re-derived by running the walk**, never by subtracting.
///
/// ## What the zero claims, and what it must not be read as claiming
///
/// Zero means: **no `StateMan.write` call site in `lib/` can present an
/// operator with an unexplained refusal.** Every one of them now goes through
/// `writeTag`, which resolves the permission at the tap, prompts, records the
/// refusal and issues nothing.
///
/// Zero does **not** mean `AccessDenied` is never thrown. `GuardedStateMan`
/// still throws it, deliberately, and it is still the enforcement point — the
/// tap-time check in front of it is advisory, and a write that skips
/// `writeTag` is refused there instead (`tag_access_guard_test.dart`, T-04-32).
/// Reading "0 uncaught sites" as "refusals no longer happen" would be exactly
/// the wrong conclusion about the layer underneath.
///
/// It is not deleted now that it is zero. A constant at zero with a live
/// derivation is a regression test: a future asset that writes without
/// `writeTag` reopens the gap, and `access_denied_prompt_test.dart` is what
/// says so on the next run. That is also why the walk itself is guarded —
/// the scan still finds `tag_access_guard.dart`'s own `sm.write`, so a walk
/// that had quietly stopped finding anything could not pass as a zero.
const int kUncaughtAccessDeniedWriteSites = 0;

/// The headline, kept at the top of the file so tests assert against the
/// string the widget renders rather than one they supply — the
/// `access_gate.dart` idiom.
///
/// Reads like `kAccessLockedHeadline` in `access_gate.dart`, not like an error: this write is shut,
/// not broken.
const String kAccessDeniedHeadline = 'Sign in to make this change';

/// Which permission was missing, named by [AccessGroup.name] — the same word
/// the roles screen shows, so "needs force" and the tick box that grants it
/// read alike.
String kAccessDeniedGroupNote(AccessGroup group) =>
    'This change needs the "${group.name}" permission.';

/// What was refused. An operator who pressed one of four buttons on a mimic
/// needs to know which one this is about.
String kAccessDeniedItemNote(String itemKey) => 'What was refused: $itemKey';

/// The never-replay rule, made visible rather than merely obeyed.
///
/// The requirement is that signing in "never replays the original action", and
/// nothing here holds the attempted write. This sentence is what stops an
/// operator signing in, walking away, and believing the jog happened.
const String kAccessDeniedNoReplayNote =
    'Nothing was changed. Signing in will not repeat this action for you — '
    'once you are signed in you will need to make the change again yourself.';

/// The prompt body, so a test can assert the prompt rendered at all.
const Key kAccessDeniedBodyKey = Key('access-denied-body');

/// The lock glyph. Keyed so a test can pin the colour it is painted in.
const Key kAccessDeniedLockKey = Key('access-denied-lock');

/// The permission line.
const Key kAccessDeniedGroupKey = Key('access-denied-group');

/// The refused-item line.
const Key kAccessDeniedItemKey = Key('access-denied-item');

/// The never-replay line's key, so a test can assert the widget carrying it is
/// not the single-line ellipsising kind. Phase 1 shipped exactly that defect
/// past a green `find.text`.
const Key kAccessDeniedNoReplayKey = Key('access-denied-no-replay');

/// The Sign in action.
const Key kAccessDeniedSignInKey = Key('access-denied-sign-in');

/// The dismissal.
const Key kAccessDeniedDismissKey = Key('access-denied-dismiss');

/// Turns every refusal on [accessDenialsProvider] into a locked prompt.
///
/// **Mounted exactly once, above the router.** It used to be mounted in
/// `BaseScaffold`, which put one on every page — and that was the defect. The
/// router stacks a page for *every* route that matches the location
/// (`RoutesLocationBuilder`; see `lib/providers/menu.dart`), and a route below
/// the top stays mounted. `/` matches every path, so on any station whose `/`
/// is an ordinary page there were permanently **two** live `BaseScaffold`s,
/// two subscriptions to one broadcast stream, and two dialogs for one refused
/// write: Close pressed twice, and the barrier visibly lightening in between
/// as the first of two stacked `black54` scrims came off. The second dialog
/// also outlived "Sign in", which popped only the top one and put the sign-in
/// form over the one still standing.
///
/// Two guards used to stand here and neither could see that case: an
/// inherited scope, which only found prompts nested *inside* another, and a
/// widget-local latch, which is a different field in a different `State`. Both
/// are gone. A sibling cannot be a sibling of itself, so mounting once is not
/// a third guard — it is the reason no guard is needed.
///
/// The mount is `centroid-hmi/lib/main.dart`, in the `MaterialApp.builder`
/// Stack beside `AccessSessionEndedNotice`. That Stack is **above** the
/// router's `Navigator`, so this widget's own context cannot push a route —
/// which is why [navigatorKey] is required rather than optional. `MyApp` owns
/// the `BeamerDelegate` and hands over its `navigatorKey` directly and
/// synchronously; `navigatorKeyProvider` holds the same key but is published
/// in a `Future.microtask` and is null for the first build, so it is the wrong
/// source for this.
///
/// **Costs nothing until it fires.** With no [child] it renders
/// `SizedBox.shrink()`; with one it renders the child itself and contributes
/// **no render object at all** — which is what let it live in `BaseScaffold`
/// without moving a pixel, and is still what the section tests rely on when
/// they wrap a page fragment in one.
class AccessDeniedPrompt extends ConsumerStatefulWidget {
  const AccessDeniedPrompt({
    super.key,
    required this.navigatorKey,
    this.openSignIn = showAccessSignInDialog,
    this.child,
  });

  /// The router's own `Navigator`, to push the prompt onto.
  ///
  /// Required, and required for a reason: the only place this widget belongs
  /// is above that `Navigator`, where `showDialog(context: context)` would
  /// throw for want of one. A caller that has to supply the key is a caller
  /// that has had to think about where its one prompt is mounted, which is
  /// exactly the question that mounting it per-page answered wrongly.
  final GlobalKey<NavigatorState> navigatorKey;

  /// How the sign-in prompt is opened. Injectable so a widget test can count
  /// the taps without standing up a dialog route — the `AccessStatusAction`
  /// idiom.
  final AccessSignInOpener openSignIn;

  /// The subtree this prompt watches over, passed through untouched.
  ///
  /// Passing the page through rather than sitting beside it in a `Stack` is
  /// deliberate: a `Stack` would re-constrain the body — `Scaffold` hands it
  /// `_BodyBoxConstraints`, and a stack sizes and positions its children
  /// itself — and the pixel budget for this plan is zero.
  final Widget? child;

  @override
  ConsumerState<AccessDeniedPrompt> createState() => _AccessDeniedPromptState();
}

class _AccessDeniedPromptState extends ConsumerState<AccessDeniedPrompt> {
  StreamSubscription<AccessDenied>? _subscription;

  /// True from the moment a refusal is taken until its prompt closes.
  ///
  /// Set synchronously, before the first `await`, so the three further
  /// denials a struct write produces are **dropped** rather than queued: one
  /// action, one prompt. Not latched — it clears when the prompt closes, so
  /// the operator's next refused action gets its own.
  bool _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // `ref.read`, not `watch`: the provider holds a broadcast stream that
    // never changes value, and a watch here would rebuild the child on any
    // container churn.
    //
    // No stand-down check any more. There is nothing to stand down from:
    // this widget is mounted once, above the router, and the mount site is
    // asserted in `centroid-hmi/test/access_denied_prompt_mount_test.dart`.
    _subscription ??= ref.read(accessDenialsProvider).listen(_onDenied);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _onDenied(AccessDenied denial) async {
    if (_showing || !mounted) return;

    // The router's Navigator, never `context`: this widget sits above it.
    //
    // Null means no first frame has been built yet. Dropping the denial is
    // the same thing that happened before this widget moved — with no page
    // mounted there was no listener and the broadcast stream discarded the
    // event — and there is nobody standing at the panel to be told.
    final navigator = widget.navigatorKey.currentContext;
    if (navigator == null) {
      debugPrint('AccessDeniedPrompt: no navigator yet, dropped a refusal of '
          '"${denial.itemKey}"');
      return;
    }

    _showing = true;
    try {
      await showDialog<void>(
        context: navigator,
        builder: (_) => _AccessDeniedDialog(
          denial: denial,
          onSignIn: _signIn,
        ),
      );
    } finally {
      _showing = false;
    }
  }

  /// Dismisses the prompt and opens the sign-in form.
  ///
  /// **Nothing is retried here, and nothing is remembered to retry.** The
  /// refused write is not held anywhere, so signing in cannot replay it —
  /// which is the requirement, and [kAccessDeniedNoReplayNote] is how the
  /// operator is told.
  Future<void> _signIn(BuildContext dialogContext) async {
    Navigator.of(dialogContext).pop();
    if (!mounted) return;

    // The navigator again, for the same reason: `showAccessSignInDialog`
    // pushes a route too, and this widget's own context has none to push on.
    final navigator = widget.navigatorKey.currentContext;
    if (navigator == null) return;
    try {
      await widget.openSignIn(navigator, ref);
    } on Object catch (error) {
      // A sign-in form that fails to open must not take the page with it.
      debugPrint('AccessDeniedPrompt: could not open the sign-in form: $error');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}

/// The prompt itself: what was refused, what it needed, and that it did not
/// happen.
///
/// Built on [StandardDialogFrame] rather than a surface of its own, so a
/// refusal looks like the rest of the app instead of like a new feature — the
/// same frame `AccessSignInDialog` uses, with `showClose: false` for the same
/// reason: the two actions below already cover dismissal, and a third
/// affordance in the corner would make "exactly a sign-in and a dismissal"
/// untrue.
class _AccessDeniedDialog extends StatelessWidget {
  const _AccessDeniedDialog({required this.denial, required this.onSignIn});

  final AccessDenied denial;
  final Future<void> Function(BuildContext dialogContext) onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary =
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    return StandardDialogFrame(
      title: kAccessDeniedHeadline,
      icon: Icons.lock_outline,
      showClose: false,
      actions: [
        PaneAction(
          buttonKey: kAccessDeniedDismissKey,
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          buttonKey: kAccessDeniedSignInKey,
          label: 'Sign in',
          onPressed: () => unawaited(onSignIn(context)),
        ),
      ],
      child: Column(
        key: kAccessDeniedBodyKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A lock, not a warning triangle: this write is shut, not
              // broken. `onSurfaceVariant` rather than HmiStateColors.orange,
              // which means forced/override and — since plan 01-08 — an
              // elevated session; a lock is neither, and red is the plant's
              // fault colour.
              Icon(
                Icons.lock_outline,
                key: kAccessDeniedLockKey,
                size: 28,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  kAccessDeniedGroupNote(denial.required),
                  key: kAccessDeniedGroupKey,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // The item key, never `denial.toString()`: that is a developer
          // string and this is the operator's prompt.
          Text(
            kAccessDeniedItemNote(denial.itemKey),
            key: kAccessDeniedItemKey,
            maxLines: null,
            overflow: TextOverflow.visible,
            style: secondary,
          ),
          const SizedBox(height: 12),
          Text(
            kAccessDeniedNoReplayNote,
            key: kAccessDeniedNoReplayKey,
            maxLines: null,
            overflow: TextOverflow.visible,
            style: secondary,
          ),
        ],
      ),
    );
  }
}
