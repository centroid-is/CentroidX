/// The ten letters an Icelandic keyboard has and the HMI could not receive.
///
/// Over the VNC mirror — which is how the plant is reached from a desk, and
/// the only way in on a station with no keyboard plugged into it — the
/// Icelandic letters never arrive. noVNC sends each keypress to weston as an
/// X keysym, and weston's VNC backend turns keysyms into evdev codes through
/// a hardcoded table, `key_translation[]` in `libweston/backend-vnc/vnc.c`.
/// That table is US ASCII and nothing else: it ends at `XKB_KEY_Next`, and
/// every Latin-1 letter — `aacute`, `eth`, `thorn`, `ae`, `odiaeresis`, … —
/// misses it. A miss is not a fallback, it is a drop:
///
///     weston_log("Key not found: keysym %08x, translated %08x\n", …);
///     return;
///
/// So `á` typed over VNC produces nothing at all — no character, no key
/// event, nothing for the embedder or for Flutter to receive. Checked against
/// weston 16.0.0, the version the stations run; the table is byte-identical
/// on `main`. The compositor keymap is no help either: the stations'
/// `weston.ini` has no `[keyboard]` section, so the seat is plain `us`, which
/// is also what the QEMU extended-key-event path would resolve against.
///
/// None of that is reachable from this repo — it is the weston image — and
/// none of it is reachable from the embedder patches in `docker/frontend/`
/// either, because those run downstream of the drop. What *does* arrive
/// intact over VNC is the pointer. So the app carries its own way to type
/// these ten letters, by tapping them.
///
/// It earns its place twice over: the touch panels have no keyboard at all,
/// and weston's input panel (`centroidx-keyboard`) has no Icelandic letters
/// on it either.
///
/// Uppercase is on the bar rather than on Shift for the same reason — weston
/// drops `Shift_L`/`Shift_R` outright, "as per RFC6143 Section 7.5.4", so
/// over VNC there is no held Shift to read.
library;

import 'package:flutter/material.dart';

import 'onscreen_keyboard.dart' show focusedTextField;

/// The Icelandic alphabet minus the twenty-six letters a US keyboard already
/// sends. In alphabet order, so the row reads the way the operator was taught
/// it: á, ð, é, í, ó, ú, ý, þ, æ, ö.
const List<String> kIcelandicLetters = [
  'á',
  'ð',
  'é',
  'í',
  'ó',
  'ú',
  'ý',
  'þ',
  'æ',
  'ö',
];

/// A bar of [kIcelandicLetters] that types into whatever text field has
/// focus, shown for as long as one does.
///
/// Mount it once, above the pages, panes and dialogs it has to reach — the
/// same place [OnscreenKeyboardEscape] sits for the same reason.
///
/// It is anchored to the top of the window, not to the field being typed
/// into. Two reasons, both about where it would otherwise collide: weston's
/// input panel owns the bottom third of an eLinux screen whenever a field is
/// focused, and a bar that follows the caret would have to re-measure the
/// field's box every frame to stay with it through a scrolling pane. A fixed
/// place is also the one a hand learns.
class IcelandicKeyBar extends StatefulWidget {
  const IcelandicKeyBar({super.key});

  @override
  State<IcelandicKeyBar> createState() => _IcelandicKeyBarState();
}

class _IcelandicKeyBarState extends State<IcelandicKeyBar> {
  EditableTextState? _field;
  bool _upper = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    _field = focusedTextField();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final field = focusedTextField();
    if (!mounted || identical(field, _field)) return;
    setState(() {
      _field = field;
      // Shift is per-field: carrying it across a focus move would upper-case
      // the first letter of the next field for no reason the operator asked
      // for.
      _upper = false;
    });
  }

  /// Replaces the selection with [letter], the way a keypress would.
  ///
  /// Goes through [EditableTextState.userUpdateTextEditingValue] rather than
  /// the field's controller so the field's `inputFormatters` and `maxLength`
  /// still get their say — a tapped letter is an edit by the user, and every
  /// field in the app is entitled to treat it as one.
  void _type(String letter) {
    final field = _field;
    if (field == null) return;

    final value = field.textEditingValue;
    final selection = value.selection;
    // A field that has never been touched by the caret reports an invalid
    // selection; append in that case, which is where the caret would be.
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;

    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(start, end, letter),
        selection: TextSelection.collapsed(offset: start + letter.length),
      ),
      SelectionChangedCause.keyboard,
    );

    if (_upper) setState(() => _upper = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_field == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        // Taps here must not count as taps outside the field: TextField's
        // default onTapOutside drops focus on desktop, and dropping focus is
        // exactly what would take this bar down mid-word.
        child: TextFieldTapRegion(
          // A hairline and a shallow lift, not a drop shadow. Material 3
          // takes its shadow from `colorScheme.shadow`, which is black, and a
          // black halo over the light theme reads as a slab hanging off the
          // page; the theme's own `shadowColor` is the muted one the rest of
          // the app casts.
          child: Material(
            elevation: 2,
            shadowColor: theme.shadowColor,
            color: scheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ShiftKey(
                    on: _upper,
                    onTap: () => setState(() => _upper = !_upper),
                  ),
                  const SizedBox(width: 4),
                  for (final letter in kIcelandicLetters)
                    _LetterKey(
                      letter: _upper ? letter.toUpperCase() : letter,
                      onTap: _type,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One letter. A [GestureDetector] rather than a button because every button
/// in Material takes focus when it is tapped, and the focus this bar needs is
/// the one already on the text field.
class _LetterKey extends StatelessWidget {
  const _LetterKey({required this.letter, required this.onTap});

  final String letter;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ValueKey<String>('icelandic-key-$letter'),
      onTap: () => onTap(letter),
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          letter,
          style: TextStyle(fontSize: 20, color: scheme.onSurface),
        ),
      ),
    );
  }
}

/// The bar's own Shift. Latched, not held: it stays on until a letter is
/// typed or it is tapped off, because there is no held modifier to read —
/// weston drops Shift before it reaches the seat.
class _ShiftKey extends StatelessWidget {
  const _ShiftKey({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: const ValueKey<String>('icelandic-key-shift'),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          Icons.keyboard_capslock,
          size: 20,
          color: on ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
      ),
    );
  }
}
