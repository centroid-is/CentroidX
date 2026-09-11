import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../onscreen_keyboard.dart';
import '../resizable_overlay_frame.dart';
import 'pane_chrome.dart';

/// The standard popup window: same header, body and pinned action bar as
/// [SidePane], in a rectangle instead of a dock.
///
/// It comes in two flavours, and the choice is about what the operator is
/// doing, not about how much content there is:
///
///  * [showStandardDialog] — **modal**. A centred window with a barrier, for
///    short interactions that must finish before anything else happens:
///    confirmations, a single parameter edit, an error the operator must
///    acknowledge. Returns a value, so it is a drop-in for `showDialog`.
///
///  * [showFloatingDialog] — **free-floating**. A draggable, resizable window
///    with no barrier that the operator can push aside and leave open next to
///    the live plant view. This is what a [PaneGraphTile] or [PaneExpandTile]
///    opens when a trend or a channel grid is too big for the side pane.
///
/// Complicated equipment popups belong in a [SidePane]; reach for a dialog
/// when the content is genuinely wider than a pane (charts, I/O grids,
/// tables) or when you need an answer back.
class StandardDialog extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final PaneStatus? status;
  final List<PaneAction> actions;

  /// Actions that change while the dialog is open — a `Select` that enables
  /// once the operator picks something, say.
  ///
  /// When set it supersedes [actions], and ONLY the action bar rebuilds when
  /// it fires. That matters in a floating dialog: the body is built once and
  /// handed down as a captured child, so rebuilding the dialog to re-enable a
  /// button would take the content's state with it — a browse tree would drop
  /// its loaded nodes and re-issue its reads on every tap.
  final ValueListenable<List<PaneAction>>? actionsListenable;

  final Widget child;
  final VoidCallback? onClose;
  final Widget? headerTrailing;

  /// Wraps the header, used by the floating variant to make it a drag handle.
  final Widget Function(BuildContext context, Widget header)? headerWrap;

  /// Whether the body scrolls when it does not fit.
  final bool scrollable;

  /// Trailing space in the action bar — see [PaneActionBar.endInset].
  final double actionBarEndInset;

  const StandardDialog({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.status,
    this.actions = const [],
    this.actionsListenable,
    this.onClose,
    this.headerTrailing,
    this.headerWrap,
    this.scrollable = true,
    this.actionBarEndInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneHeader(
          title: title,
          subtitle: subtitle,
          icon: icon,
          status: status,
          onClose: onClose,
          trailing: headerTrailing,
          wrap: headerWrap,
        ),
        Flexible(
          child: scrollable
              ? SingleChildScrollView(primary: false, child: body)
              : body,
        ),
        if (actionsListenable != null)
          ValueListenableBuilder<List<PaneAction>>(
            valueListenable: actionsListenable!,
            builder: (context, actions, _) => actions.isEmpty
                ? const SizedBox.shrink()
                : PaneActionBar(
                    actions: actions,
                    endInset: actionBarEndInset,
                  ),
          )
        else if (actions.isNotEmpty)
          PaneActionBar(
            actions: actions,
            endInset: actionBarEndInset,
          ),
      ],
    );
  }
}

/// A [StandardDialog] in a modal frame, for widget classes that ARE the
/// argument to `showDialog` rather than a call to [showStandardDialog].
///
/// This is the drop-in replacement for `AlertDialog` in a class whose
/// `build` returns the dialog itself:
///
/// ```dart
/// // was: AlertDialog(title: Text('Edit key'), content: body, actions: [...])
/// StandardDialogFrame(title: 'Edit key', actions: [...], child: body)
/// ```
class StandardDialogFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final PaneStatus? status;
  final List<PaneAction> actions;
  final Widget child;

  /// Omit the header's close button — for dialogs whose own actions already
  /// cover dismissal (Cancel/Save), where another affordance would be noise.
  final bool showClose;

  final double width;
  final double? height;
  final bool scrollable;

  const StandardDialogFrame({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.status,
    this.actions = const [],
    this.showClose = true,
    this.width = 520,
    this.height,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = height ?? MediaQuery.sizeOf(context).height * 0.8;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: SizedBox(
          width: width,
          height: height,
          child: StandardDialog(
            title: title,
            subtitle: subtitle,
            icon: icon,
            status: status,
            actions: actions,
            scrollable: scrollable,
            onClose: showClose ? () => Navigator.of(context).pop() : null,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Modal
// ---------------------------------------------------------------------------

/// Shows a modal [StandardDialog] and completes with the value the dialog is
/// popped with.
///
/// [actionsBuilder] receives the dialog's own context, so an action can pop a
/// result:
///
/// ```dart
/// final ok = await showStandardDialog<bool>(
///   context: context,
///   title: 'Reset run hours',
///   builder: (_) => const Text('Run hours will be set to zero.'),
///   actionsBuilder: (ctx) => [
///     PaneAction.destructive(
///       label: 'Reset',
///       onPressed: () => Navigator.of(ctx).pop(true),
///     ),
///   ],
/// );
/// ```
Future<T?> showStandardDialog<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  IconData? icon,
  PaneStatus? status,
  List<PaneAction> Function(BuildContext context)? actionsBuilder,
  double width = 520,
  double? height,
  bool barrierDismissible = true,

  /// For callers that live ABOVE the app Navigator — overlay-hosted widgets
  /// like the chat window, whose own context has no Navigator to push onto.
  bool useRootNavigator = false,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: height ?? MediaQuery.sizeOf(dialogContext).height * 0.8,
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: StandardDialog(
            title: title,
            subtitle: subtitle,
            icon: icon,
            status: status,
            actions: actionsBuilder?.call(dialogContext) ?? const [],
            onClose: () => Navigator.of(dialogContext).pop(),
            child: builder(dialogContext),
          ),
        ),
      ),
    ),
  );
}

/// The confirm/cancel prompt, once.
///
/// Returns true only if the operator confirmed; a dismissed dialog is `false`,
/// never null, so callers do not have to handle three outcomes for a
/// two-outcome question.
///
/// Set [destructive] for anything that deletes, resets or stops something —
/// it colours the confirm action with the error colour.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  IconData? icon,
  bool autofocusConfirm = false,
}) async {
  final result = await showStandardDialog<bool>(
    context: context,
    title: title,
    icon: icon ?? (destructive ? Icons.warning_amber : Icons.help_outline),
    builder: (_) => Text(message),
    actionsBuilder: (dialogContext) => [
      // The explicit "no" answer: unlike the chrome's close button this is
      // part of the question, so it stays in the bar next to the confirm.
      PaneAction(
        label: cancelLabel,
        onPressed: () => Navigator.of(dialogContext).pop(false),
      ),
      destructive
          ? PaneAction.destructive(
              label: confirmLabel,
              autofocus: autofocusConfirm,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            )
          : PaneAction.primary(
              label: confirmLabel,
              autofocus: autofocusConfirm,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
    ],
  );
  return result ?? false;
}

// ---------------------------------------------------------------------------
// Free-floating
// ---------------------------------------------------------------------------

/// Opens a free-floating, draggable, resizable [StandardDialog].
///
/// Nothing is dimmed and nothing is blocked — the plant view keeps running
/// behind it and several floating dialogs can be open at once (a trend for
/// each of two conveyors, say). [id] de-duplicates: opening an id that is
/// already showing is a no-op rather than a second copy, and the returned
/// future completes with null immediately — the window already on screen
/// keeps answering to whoever opened it.
///
/// The future completes when the window closes: with the value handed to
/// [closeFloatingDialog], or **null for every other way out** — the header's
/// close button, Escape, [closeAllFloatingDialogs] on navigation, or the
/// overlay being torn down underneath it. So a picker can be awaited like a
/// modal:
///
/// ```dart
/// final node = await showFloatingDialog<BrowseNode>(
///   context: context, id: 'browse:$alias', title: 'Browse',
///   builder: (_) => BrowseBody(onPick: (n) =>
///       closeFloatingDialog('browse:$alias', result: n)),
/// );
/// if (!mounted) return;   // navigation may have closed it AND disposed you
/// ```
///
/// Most callers — a trend, an expanded channel grid — want nothing back and
/// simply ignore the future.
Future<T?> showFloatingDialog<T>({
  required BuildContext context,
  required String id,
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  IconData? icon,
  PaneStatus? status,
  List<PaneAction> actions = const [],

  /// For a dialog whose actions change while it is open — see
  /// [StandardDialog.actionsListenable]. Dispose it from [onClosed].
  ValueListenable<List<PaneAction>>? actionsListenable,
  Size size = const Size(640, 480),
  Offset? position,
  VoidCallback? onClosed,

  /// Set false for content that fills the window itself — a chart with an
  /// `Expanded` inside cannot lay out against a scroll view's unbounded
  /// height, and a chart wants the whole window anyway.
  bool scrollable = true,
}) {
  return FloatingDialogs._show(
    context: context,
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    status: status,
    actions: actions,
    actionsListenable: actionsListenable,
    builder: builder,
    size: size,
    position: position,
    onClosed: onClosed,
    scrollable: scrollable,
    // Untyped inside the registry — one map serves every dialog, whatever
    // each one returns. A [result] of the wrong type surfaces as a failed
    // cast at the awaiting site, not at the closing one.
  ).then((value) => value as T?);
}

/// Closes the floating dialog with this [id], if it is open.
///
/// [result] is what the opener's `await` on [showFloatingDialog] returns; omit
/// it and the caller sees null, which is what every other way out of the
/// window already gives them.
void closeFloatingDialog(String id, {Object? result}) =>
    FloatingDialogs.close(id, result: result);

/// Closes every floating dialog. See [FloatingDialogs.closeAll].
int closeAllFloatingDialogs() => FloatingDialogs.closeAll();

/// Registry of open floating dialogs.
///
/// Public so the side pane can tell whether an Escape key press belongs to a
/// dialog on top of it, and so tests can assert on what is open.
abstract final class FloatingDialogs {
  static final Map<String, OverlayEntry> _entries = {};

  /// Ids in the order they were opened; the last one is the newest.
  static final List<String> _stack = [];

  static bool get isEmpty => _stack.isEmpty;

  static List<String> get openIds => List.unmodifiable(_stack);

  static bool isOpen(String id) => _entries.containsKey(id);

  /// One per open dialog, completed by [_complete] when the window goes.
  ///
  /// Untyped: the registry does not care what a given dialog returns, and
  /// [showFloatingDialog] casts on the way out.
  static final Map<String, Completer<Object?>> _completers = {};

  static Future<Object?> _show({
    required BuildContext context,
    required String id,
    required String title,
    required WidgetBuilder builder,
    String? subtitle,
    IconData? icon,
    PaneStatus? status,
    List<PaneAction> actions = const [],
    ValueListenable<List<PaneAction>>? actionsListenable,
    Size size = const Size(640, 480),
    Offset? position,
    VoidCallback? onClosed,
    bool scrollable = true,
  }) {
    // Already showing: the window on screen keeps its original requester, so
    // this caller gets null rather than a future that would resolve with
    // somebody else's answer.
    if (_entries.containsKey(id)) return Future<Object?>.value();

    final overlay = Overlay.of(context, rootOverlay: true);
    // Cascade so a second dialog does not land exactly on the first.
    final cascade = _stack.length * 28.0;
    final entry = OverlayEntry(
      builder: (context) => _FloatingDialogShell(
        id: id,
        title: title,
        subtitle: subtitle,
        icon: icon,
        status: status,
        actions: actions,
        actionsListenable: actionsListenable,
        initialSize: size,
        initialPosition: position,
        cascade: cascade,
        scrollable: scrollable,
        builder: builder,
      ),
    );
    final completer = Completer<Object?>();
    _entries[id] = entry;
    _stack.add(id);
    _onClosed[id] = onClosed;
    _completers[id] = completer;
    overlay.insert(entry);
    return completer.future;
  }

  static final Map<String, VoidCallback?> _onClosed = {};

  /// Answers the opener's `await`, exactly once, however the window went.
  ///
  /// Both [close] and [_forget] route through here on purpose. [_forget]
  /// reads like pure bookkeeping, but it is the path a dialog takes when the
  /// overlay disappears underneath it — a route change, a hot restart, a
  /// test's next `pumpWidget`. Skipping the completion there leaves an
  /// awaiting caller hanging for the rest of the session.
  static void _complete(String id, Object? result) {
    final completer = _completers.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  static void close(String id, {Object? result}) {
    final entry = _entries.remove(id);
    _stack.remove(id);
    entry?.remove();
    _onClosed.remove(id)?.call();
    _complete(id, result);
  }

  /// Drops the bookkeeping for a dialog whose overlay went away on its own —
  /// a route change, a hot restart, a test's next `pumpWidget`. Without this
  /// the id would stay "open" forever and never show again.
  static void _forget(String id) {
    if (!_entries.containsKey(id)) return;
    _entries.remove(id);
    _stack.remove(id);
    _onClosed.remove(id)?.call();
    _complete(id, null);
  }

  /// Closes every open dialog. Returns how many were closed.
  ///
  /// A floating dialog lives in the ROOT overlay, so nothing about leaving a
  /// page removes it -- it follows the operator to the next one, and they
  /// stack: a trend opened on the home page was still there, under two more,
  /// after a trip through Advanced. Called on every route change, from the
  /// back button and from the navigation bar, the same three places the side
  /// pane closes from. Removal is synchronous (no exit animation), so it is
  /// safe from a dispose() in the same frame.
  static int closeAll() {
    final ids = List<String>.of(_stack);
    for (final id in ids) {
      close(id);
    }
    return ids.length;
  }

  /// Closes the most recently opened dialog. Returns false if none was open.
  static bool closeTop() {
    if (_stack.isEmpty) return false;
    close(_stack.last);
    return true;
  }
}

/// Where a floating dialog currently sits, as one immutable value so the
/// window can move and resize without touching [State] fields.
///
/// [position] is null until the window has been laid out once — the shell
/// centres it against the screen it finds itself on rather than guessing at
/// construction time.
@immutable
class _DialogGeometry {
  final Offset? position;
  final Size size;

  const _DialogGeometry(this.position, this.size);
}

/// The window's arrival: a 150 ms fade with a 3 % grow.
///
/// Most of these windows hold a chart whose history is still on its way when
/// the window appears. Popping in fully formed and then sitting still reads
/// as "stuck"; arriving over a few frames reads as "responding", and those
/// frames are the ones the chart spends drawing its seed. Entrance only --
/// [FloatingDialogs.closeAll] relies on a window leaving synchronously.
///
/// Built once per real rebuild of the shell, like the surface it wraps, so a
/// drag or a resize never replays it.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      child: child,
      // Opacity does not block hit-testing, so a tap landing in the first
      // frames still reaches the window.
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
      ),
    );
  }
}

/// Geometry, dragging, resizing and Escape handling for a floating dialog.
class _FloatingDialogShell extends StatefulWidget {
  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final PaneStatus? status;
  final List<PaneAction> actions;
  final ValueListenable<List<PaneAction>>? actionsListenable;
  final Size initialSize;
  final Offset? initialPosition;
  final double cascade;
  final bool scrollable;
  final WidgetBuilder builder;

  const _FloatingDialogShell({
    required this.id,
    required this.title,
    required this.actions,
    required this.initialSize,
    required this.cascade,
    required this.builder,
    this.scrollable = true,
    this.subtitle,
    this.icon,
    this.status,
    this.initialPosition,
    this.actionsListenable,
  });

  @override
  State<_FloatingDialogShell> createState() => _FloatingDialogShellState();
}

class _FloatingDialogShellState extends State<_FloatingDialogShell> {
  static const Size _minSize = Size(320, 240);

  /// Window geometry, held in a notifier rather than in [State] fields so that
  /// moving or resizing the window repaints the frame ONLY.
  ///
  /// `setState` here would re-run [build], and with it `widget.builder` — a
  /// fresh content subtree on every pointer move. For the charts these dialogs
  /// mostly hold that means a torn-down subscription and a re-issued history
  /// query per frame, so the window an operator was dragging aside flickers
  /// back to "loading" the whole way across the screen.
  late final ValueNotifier<_DialogGeometry> _geometry =
      ValueNotifier(_DialogGeometry(widget.initialPosition, widget.initialSize));

  Size _screen = Size.zero;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    FloatingDialogs._forget(widget.id);
    _geometry.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    // A field in the dialog has the on-screen keyboard up: this Escape takes
    // the keyboard down and nothing else. The dialog closes on the next one.
    if (escapeDismissesKeyboard(event)) return false;
    // Only the newest dialog reacts, so Escape peels the stack one at a time.
    if (FloatingDialogs._stack.isEmpty ||
        FloatingDialogs._stack.last != widget.id) {
      return false;
    }
    FloatingDialogs.close(widget.id);
    return true;
  }

  /// Shrinks the window to fit a screen smaller than it is.
  Size _fit(Size size) => Size(
        size.width.clamp(
          _minSize.width,
          _screen.width < _minSize.width ? _minSize.width : _screen.width,
        ),
        size.height.clamp(
          _minSize.height,
          _screen.height < _minSize.height ? _minSize.height : _screen.height,
        ),
      );

  /// Centres a window that has not been placed yet, and keeps every window
  /// on-screen — one dragged off the edge could never be grabbed again.
  ///
  /// Pure, so the clamping can happen while laying out rather than by writing
  /// corrected geometry back into the notifier mid-build.
  Offset _resolvePosition(Offset? position, Size size) {
    final at = position ??
        Offset(
          (_screen.width - size.width) / 2 + widget.cascade,
          (_screen.height - size.height) / 2 + widget.cascade,
        );
    final maxX = (_screen.width - size.width).clamp(0.0, double.infinity);
    final maxY = (_screen.height - size.height).clamp(0.0, double.infinity);
    return Offset(at.dx.clamp(0.0, maxX), at.dy.clamp(0.0, maxY));
  }

  /// The visible corner grip resizes by pointer *deltas*, so it has to read
  /// the notifier rather than close over geometry from the last build: several
  /// pointer moves can land between two frames, and a captured size would
  /// silently drop every delta but the first.
  void _onGripDrag(Offset delta) {
    final geometry = _geometry.value;
    final size = _fit(geometry.size);
    final position = _resolvePosition(geometry.position, size);
    _geometry.value = _DialogGeometry(
      position,
      Size(
        (size.width + delta.dx)
            .clamp(_minSize.width, _screen.width - position.dx),
        (size.height + delta.dy)
            .clamp(_minSize.height, _screen.height - position.dy),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _screen = MediaQuery.sizeOf(context);

    return ValueListenableBuilder<_DialogGeometry>(
      valueListenable: _geometry,
      // Built HERE — once per real rebuild of the shell — and handed to the
      // builder below as `surface`, which passes it through untouched. That is
      // what keeps a drag or a resize from rebuilding the dialog's content;
      // see [_geometry]. Anything the content depends on (theme, media query,
      // the actions list) still reaches it, because a change to those rebuilds
      // the shell itself rather than only the notifier.
      child: _Entrance(child: _dialogSurface(context)),
      builder: (context, geometry, surface) {
        final size = _fit(geometry.size);
        final position = _resolvePosition(geometry.position, size);

        return Positioned(
          left: position.dx,
          top: position.dy,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: ResizableOverlayFrame(
              position: position,
              size: size,
              minSize: _minSize,
              screenSize: _screen,
              onResize: (newPosition, newSize) =>
                  _geometry.value = _DialogGeometry(newPosition, newSize),
              child: Stack(children: [
                Positioned.fill(child: surface!),
                // The frame's own handles are 6px of invisible edge — fine
                // with a mouse, unusable with a finger and undiscoverable
                // either way. This corner grip is visible and 44px square.
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _ResizeGrip(onDrag: _onGripDrag),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _dialogSurface(BuildContext context) {
    return Material(
      // Matches SidePane: outline, not shadow (see side_pane.dart). A
      // floating window keeps a touch of elevation so it reads as
      // sitting above the pane it came from.
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      color: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: StandardDialog(
        title: widget.title,
        subtitle: widget.subtitle,
        icon: widget.icon,
        status: widget.status,
        actions: widget.actions,
        actionsListenable: widget.actionsListenable,
        scrollable: widget.scrollable,
        // Keep the trailing action clear of the corner grip, which is a
        // Positioned sibling drawn OVER this surface and would otherwise
        // swallow taps meant for the last button in the bar.
        actionBarEndInset: _ResizeGrip._size,
        onClose: () => FloatingDialogs.close(widget.id),
        // The header doubles as the window's title bar.
        headerWrap: (context, header) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanUpdate: (d) {
            // Reads the notifier live rather than capturing geometry: this
            // closure is built once and then survives every drag.
            final geometry = _geometry.value;
            final size = _fit(geometry.size);
            _geometry.value = _DialogGeometry(
              _resolvePosition(geometry.position, size) + d.delta,
              size,
            );
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: header,
          ),
        ),
        child: widget.builder(context),
      ),
    );
  }
}

/// The visible corner grip that resizes a floating dialog.
///
/// 44px square — a finger target, not a mouse one — with the diagonal rules
/// that say "drag me" on every desktop, drawn into the corner radius so it
/// reads as part of the window rather than as content.
class _ResizeGrip extends StatelessWidget {
  final ValueChanged<Offset> onDrag;

  const _ResizeGrip({required this.onDrag});

  static const double _size = 44;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag(d.delta),
        child: SizedBox(
          width: _size,
          height: _size,
          child: CustomPaint(
            painter: _ResizeGripPainter(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  final Color color;

  const _ResizeGripPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // Three rules stepping out of the corner, longest innermost.
    const inset = 8.0;
    for (final offset in const [6.0, 13.0, 20.0]) {
      canvas.drawLine(
        Offset(size.width - inset, size.height - inset - offset),
        Offset(size.width - inset - offset, size.height - inset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ResizeGripPainter oldDelegate) =>
      oldDelegate.color != color;
}
