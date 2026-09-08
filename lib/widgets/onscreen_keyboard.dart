import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Escape takes down the platform's on-screen keyboard.
///
/// On the flutter-elinux panels the embedder is started with
/// `--onscreen-keyboard`, so focusing any text field raises weston's input
/// panel over the bottom third of the screen. Nothing on a touch panel takes
/// that focus away again — tapping the page behind does not unfocus a Flutter
/// text field — so the keyboard sits there covering the plant view until the
/// pane or dialog underneath it is closed. Escape is the way out: it drops
/// focus from the field, Flutter closes the input connection, and the
/// embedder dismisses the panel.
///
/// The catch is that the Escape which dismisses the keyboard must not *also*
/// close the side pane or dialog the field lives in — the operator would lose
/// the values they were half way through typing. `SidePane` and the dialogs
/// each own a [HardwareKeyboard] handler, and every registered handler runs
/// for every event regardless of what the others return, so they cannot defer
/// to each other by returning `true`. They ask [escapeDismissesKeyboard]
/// instead, which decides once per key event and hands every later caller the
/// same answer — after this widget has already unfocused the field and the
/// live focus state no longer says what it said.
///
/// Being the app's root Escape owner, it also mops up the [DismissIntent] a
/// focused field re-dispatches when nothing nearer claims it — see
/// [_IgnoreDismiss].
class OnscreenKeyboardEscape extends StatefulWidget {
  const OnscreenKeyboardEscape({super.key, required this.child});

  final Widget child;

  @override
  State<OnscreenKeyboardEscape> createState() => _OnscreenKeyboardEscapeState();
}

class _OnscreenKeyboardEscapeState extends State<OnscreenKeyboardEscape> {
  final _ignoreDismiss = _IgnoreDismiss();

  @override
  void initState() {
    super.initState();
    // Focus-scoped shortcuts are no use here: the field that raised the
    // keyboard is the thing holding focus, and it does not handle Escape.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    if (!escapeDismissesKeyboard(event)) return false;
    focusedTextField()?.widget.focusNode.unfocus();
    return true;
  }

  @override
  Widget build(BuildContext context) => Actions(
        actions: {DismissIntent: _ignoreDismiss},
        child: widget.child,
      );
}

/// Swallows the Escape a focused text field re-dispatches as a [DismissIntent].
///
/// A field inside a `SidePane` or a floating dialog is not inside a
/// `ModalRoute` — both are plain overlay entries — so there is no
/// `_DismissModalAction` for `EditableText` to hand the intent to, and its
/// re-dispatch asserts. Panes and dialogs do their own Escape handling
/// through [HardwareKeyboard], so the intent has nowhere left to go.
class _IgnoreDismiss extends Action<DismissIntent> {
  @override
  Object? invoke(DismissIntent intent) => null;
}

/// The text field that currently holds focus, or null when focus is anywhere
/// else. A focused field is what keeps the on-screen keyboard up.
EditableTextState? focusedTextField() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();

KeyEvent? _decidedFor;
bool _decision = false;

/// Whether [event] — an Escape — belongs to the on-screen keyboard rather
/// than to whatever is open behind it.
///
/// The answer is computed the first time it is asked for a given event and
/// then replayed, so handlers get the same answer no matter which order
/// [HardwareKeyboard] happens to run them in. Callers that close something on
/// Escape should sit this event out when this returns true.
bool escapeDismissesKeyboard(KeyEvent event) {
  if (identical(_decidedFor, event)) return _decision;
  _decidedFor = event;
  _decision = focusedTextField() != null;
  return _decision;
}

@visibleForTesting
void resetEscapeDecisionForTest() {
  _decidedFor = null;
  _decision = false;
}
