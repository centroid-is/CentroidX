import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../onscreen_keyboard.dart';
import 'pane_chrome.dart';
import 'standard_dialog.dart';

/// A non-modal pane docked to the right edge of the screen.
///
/// This is the HMI's replacement for `showDialog` on **complicated** equipment
/// popups — conveyors, elevators/lifts, 3rd party devices. Unlike a dialog it
/// does not put a barrier over the plant view: the page behind keeps running,
/// keeps updating and stays clickable, so an operator can jog a conveyor from
/// the pane while watching the actual belt on the mimic.
///
/// Open one with [showSidePane]; close it with [closeSidePane] (or the pane's
/// own close button / the Escape key). Only one pane is open at a time —
/// opening a second one replaces the first, and re-opening the same [id]
/// toggles it shut, which is what makes tapping a device twice feel right.
///
/// ### Keep it to one screen
///
/// A side pane is deliberately narrower than a dialog. The body should hold
/// no more information than fits without scrolling: the headline numbers as
/// [PaneMetricTile]s, the commands as [PaneAction]s in the pinned footer.
/// Bulk detail — channel grids, trends, fault history — goes behind a
/// [PaneGraphTile] or [PaneExpandTile], which open a free-floating
/// `StandardDialog` the operator can drag next to the plant view.
///
/// ```dart
/// showSidePane(
///   context: context,
///   id: 'conveyor:${config.key}',
///   builder: (context) => StreamBuilder<DynamicValue>(
///     stream: ...,
///     builder: (context, snap) => SidePane(
///       title: 'CN-04',
///       subtitle: 'Infeed conveyor',
///       icon: Icons.conveyor_belt,
///       status: running ? const PaneStatus.running() : const PaneStatus.stopped(),
///       actions: [PaneAction.destructive(label: 'Fault reset', onPressed: reset)],
///       child: Column(children: [...]),
///     ),
///   ),
/// );
/// ```
class SidePane extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Live equipment state, rendered as a chip in the header.
  final PaneStatus? status;

  /// Buttons pinned to the bottom of the pane. Closing lives in the header's
  /// corner button; a pane without actions has no footer.
  final List<PaneAction> actions;

  /// Extra control in the header, left of the close button.
  final Widget? headerTrailing;

  /// The pane body.
  final Widget child;

  /// Overrides the close behaviour. Defaults to [closeSidePane].
  final VoidCallback? onClose;

  /// Whether the body scrolls when it does not fit. Leave `true` — the
  /// intent is that content fits, this is the safety net for small screens.
  final bool scrollable;

  const SidePane({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.status,
    this.actions = const [],
    this.headerTrailing,
    this.onClose,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final close = onClose ?? closeSidePane;
    final body = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          title: title,
          subtitle: subtitle,
          icon: icon,
          status: status,
          onClose: close,
          trailing: headerTrailing,
        ),
        Expanded(
          child: scrollable
              ? SingleChildScrollView(
                  primary: false,
                  child: body,
                )
              : body,
        ),
        if (actions.isNotEmpty) PaneActionBar(actions: actions),
      ],
    );
  }
}

/// Names the equipment that a pane opened from this subtree is about.
///
/// A pane is a strip on the far right of a screen full of machinery, and on a
/// busy mimic it is not always obvious which of the four conveyors in a row it
/// belongs to. [AssetStack] wraps every asset in one of these, so a pane
/// opened from an asset's own build context — which is how every asset opens
/// its pane already, for [showSidePane]'s `avoidRect` — records the asset it
/// came from without any call site having to say so. The plant view reads it
/// back off [SidePaneHost.subject] and marks that one asset.
///
/// [subject] is compared by identity, so it wants to be the long-lived object
/// the asset is drawn from (its `Asset`/config), not a value rebuilt per frame.
class SidePaneSubject extends InheritedWidget {
  final Object subject;

  const SidePaneSubject({
    super.key,
    required this.subject,
    required super.child,
  });

  /// The subject [context] sits inside, or null when nothing named one.
  ///
  /// Deliberately not `dependOnInheritedWidgetOfExactType`: this is read once
  /// inside a tap handler to record who is opening the pane, and taking a
  /// dependency there would rebuild the asset every time the value changed.
  static Object? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SidePaneSubject>()?.subject;

  @override
  bool updateShouldNotify(SidePaneSubject oldWidget) =>
      !identical(oldWidget.subject, subject);
}

/// Closes [paneId] when its subtree leaves the tree.
///
/// A docked pane lives in the root overlay, so nothing tears it down when the
/// page that opened it goes away. Assets with their own `State` close their
/// pane from `dispose()`; wrap this around a stateless asset body to get the
/// same guarantee without turning it into a `StatefulWidget`.
class SidePaneOwner extends StatefulWidget {
  final String paneId;
  final Widget child;

  const SidePaneOwner({
    super.key,
    required this.paneId,
    required this.child,
  });

  @override
  State<SidePaneOwner> createState() => _SidePaneOwnerState();
}

class _SidePaneOwnerState extends State<SidePaneOwner> {
  @override
  void dispose() {
    closeSidePane(id: widget.paneId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tunables shared by every docked pane. An app can set these once at
/// start-up instead of passing them at each call site.
abstract final class SidePaneDefaults {
  /// Space kept clear of the app chrome so the pane never covers the
  /// `BaseScaffold` AppBar (top) or NavigationBar (bottom) — an operator must
  /// still see alarms and be able to navigate while a pane is open.
  static EdgeInsets insets = const EdgeInsets.only(
    top: kToolbarHeight,
    bottom: 80,
  );

  /// Gap between the pane and the screen/chrome edges.
  static double margin = 12;

  /// Pane width. An app can widen this once at start-up; a caller can
  /// override it per pane via `showSidePane(width: ...)`.
  static double width = 380;

  /// Floor for the width when the window is too narrow to honour it.
  static double minWidth = 300;
}

/// Opens [builder]'s pane docked to the right edge.
///
/// [id] identifies the equipment (e.g. `'conveyor:CN04'`). Calling
/// `showSidePane` again with the id that is already open closes it, so a
/// single tap handler can serve as an open/close toggle.
///
/// Returns `true` if a pane is showing after the call, `false` if the call
/// toggled it shut.
///
/// [resizable] adds a drag handle to the pane's left edge. Equipment panes
/// leave it off — they are a fixed strip and their content is built to fit.
/// Turn it on where the content is not: the page editor's asset config forms
/// range from a colour swatch to a two-column subdevice manager, and no single
/// width suits both. [onWidthChanged] reports each new width so the caller can
/// hand the same one back the next time it opens the pane.
///
/// [avoidRect] is the on-screen rectangle that must stay visible beside the
/// pane — the tapped device. It defaults to [context]'s own render box, which
/// is exactly right for equipment panes (assets open their pane from their own
/// build context). Only when it would end up under the pane does the page
/// yield the strip (see [SidePaneInset]); a pane opened for something in
/// plain view leaves the page exactly where it was. Callers whose [context]
/// spans the whole page (the page editor) pass the device's rect explicitly.
bool showSidePane({
  required BuildContext context,
  required String id,
  required WidgetBuilder builder,
  double? width,
  EdgeInsets? insets,
  VoidCallback? onClosed,
  bool resizable = false,
  ValueChanged<double>? onWidthChanged,
  Rect? avoidRect,
}) {
  if (SidePaneHost.openId == id) {
    closeSidePane();
    return false;
  }
  SidePaneHost._show(
    context: context,
    id: id,
    builder: builder,
    width: width,
    insets: insets,
    onClosed: onClosed,
    resizable: resizable,
    onWidthChanged: onWidthChanged,
    avoidRect: avoidRect ?? _paintRectOf(context),
  );
  return true;
}

/// The on-screen rect of [context]'s render box, the default "keep this
/// visible" rect for [showSidePane]. Null when the context has no laid-out
/// box to measure; the host then treats the pane as covering it, which keeps
/// the safe behaviour — the page insets.
Rect? _paintRectOf(BuildContext context) {
  final ro = context.findRenderObject();
  if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
  return MatrixUtils.transformRect(
      ro.getTransformTo(null), Offset.zero & ro.size);
}

/// Closes the docked pane.
///
/// When [id] is given the pane closes only if that id is the one showing —
/// use this from an asset's `dispose()` so a pane cannot outlive the widget
/// that opened it after a page change.
/// Close the docked pane, optionally without the exit animation.
///
/// [immediate] removes the overlay entry in this frame instead of gliding it
/// out. Use it from a `dispose()`: the normal path awaits the slide, so the
/// pane stays mounted and rebuilding for the length of it -- against a state
/// object that has just been torn down. Anything the pane reads (a
/// ValueNotifier, a stream) is gone by then, and the rebuild throws. Leaving
/// the page is also the one time the glide buys nothing, since the page it
/// was gliding away from is going too.
void closeSidePane({String? id, bool immediate = false}) =>
    SidePaneHost.close(id: id, immediate: immediate);

/// Whether a pane (optionally a specific [id]) is currently open.
bool isSidePaneOpen({String? id}) =>
    SidePaneHost.openId != null && (id == null || SidePaneHost.openId == id);

/// Keeps [child] clear of the docked pane — when it has to.
///
/// Wrap a page's content in this and it yields the strip of screen the pane
/// occupies instead of being covered by it. The strip is only claimed when
/// the device that opened the pane would otherwise end up underneath it
/// ([showSidePane]'s `avoidRect`), so most panes open without the page moving
/// at all.
///
/// When the strip is claimed or released, the pad is applied in a single
/// layout pass and the 220ms glide between the two states is painted as a
/// transform of the already-laid-out page. Padding the page frame by frame —
/// the first version of this — re-laid-out and rebuilt the entire plant view
/// on every frame of the pane's slide (every asset, every label remeasured),
/// which made the animation stutter on a full page; a transform costs a
/// matrix. The mapping assumes the child fits itself to its box as a
/// centred canvas of [aspectRatio] — true of both consumers, whose child is
/// a [ZoomableCanvas] — so mid-glide the transformed page sits exactly where
/// a per-frame layout would have put it. A pane resize drag arrives as a
/// stream of settled widths instead and is tracked 1:1, as before.
class SidePaneInset extends StatefulWidget {
  final Widget child;

  /// Width / height of the aspect-fitted canvas inside [child]; shapes the
  /// glide only — the settled layouts are exact regardless.
  final double aspectRatio;

  const SidePaneInset({
    super.key,
    required this.child,
    this.aspectRatio = 16 / 9,
  });

  @override
  State<SidePaneInset> createState() => _SidePaneInsetState();
}

class _SidePaneInsetState extends State<SidePaneInset>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// The glide runs from [_from] to [_target]; [_target] is also the pad the
  /// child is laid out with, from the moment the glide starts.
  double _from = SidePaneHost.occupiedWidth.value;
  double _target = SidePaneHost.occupiedWidth.value;

  /// Matches the pane's own slide: ease-out on the way in, ease-in out.
  Curve _curve = Curves.easeOutCubic;

  @override
  void initState() {
    super.initState();
    _controller.value = 1;
    SidePaneHost.occupiedWidth.addListener(_onTargetChanged);
  }

  @override
  void dispose() {
    SidePaneHost.occupiedWidth.removeListener(_onTargetChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Where the page appears to be inset to right now, mid-glide.
  double get _apparent =>
      _from + (_target - _from) * _curve.transform(_controller.value);

  void _onTargetChanged() {
    final next = SidePaneHost.occupiedWidth.value;
    if (next == _target) return;
    setState(() {
      if (_target == 0 || next == 0) {
        // The strip is being claimed or released: glide.
        _from = _apparent;
        _curve = next == 0 ? Curves.easeInCubic : Curves.easeOutCubic;
        _target = next;
        _controller.forward(from: 0);
      } else {
        // A resize drag (or a swap to a pane of another width): the pane is
        // already in place, track it 1:1.
        _from = next;
        _target = next;
        _controller.value = 1;
      }
    });
  }

  /// Where a centred, aspect-fitted canvas sits in a box of [size].
  Rect _fittedRect(Size size) {
    final h = math.min(size.height, size.width / widget.aspectRatio);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: h * widget.aspectRatio,
      height: h,
    );
  }

  /// Maps the settled layout to its mid-glide appearance: the uniform scale
  /// and shift that carries the canvas fitted beside the pane onto the canvas
  /// as it would be fitted at the in-between inset.
  Matrix4 _glideMatrix(Size outer) {
    final inset = _apparent;
    if (inset == _target) return Matrix4.identity();
    final settled = _fittedRect(Size(outer.width - _target, outer.height));
    final apparent = _fittedRect(Size(outer.width - inset, outer.height));
    if (settled.height <= 0 || apparent.height <= 0) return Matrix4.identity();
    // x' = s·x + (apparentCenter - s·settledCenter): scale about the origin,
    // then carry the settled fit's centre onto the apparent one.
    final scale = apparent.height / settled.height;
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, apparent.center.dx - scale * settled.center.dx)
      ..setEntry(1, 3, apparent.center.dy - scale * settled.center.dy);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final outer = constraints.biggest;
        return Padding(
          padding: EdgeInsets.only(right: _target),
          child: AnimatedBuilder(
            animation: _controller,
            // The Transform stays in the tree even when idle (identity), so
            // the child's element — live subscriptions and all — is never
            // reparented by a glide starting or ending.
            builder: (context, child) => Transform(
              transform: _glideMatrix(outer),
              child: child,
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// Owns the single docked-pane [OverlayEntry].
///
/// Public only so tests can assert on [openId]; call [showSidePane] /
/// [closeSidePane] from application code.
abstract final class SidePaneHost {
  static OverlayEntry? _entry;
  static GlobalKey<_SidePaneShellState>? _shellKey;
  static String? _openId;
  static VoidCallback? _onClosed;

  /// The id of the pane currently showing, or null.
  static String? get openId => _openId;

  /// The strip of the screen's right edge the page must leave to the pane, in
  /// logical pixels from the edge to one [SidePaneDefaults.margin] left of the
  /// pane. Zero while no pane is showing — and zero too while the device that
  /// opened the pane (its `avoidRect`) sits clear of it, which is what keeps
  /// the page from stepping aside for a pane that covers nothing it needs.
  /// Published as settled values only — claim, resize, release — with the
  /// glide between them left to [SidePaneInset], so the page is laid out once
  /// per change instead of once per animation frame.
  static ValueListenable<double> get occupiedWidth => _occupied;
  static final ValueNotifier<double> _occupied = ValueNotifier<double>(0);

  /// The [SidePaneSubject] the open pane was opened from, or null — either no
  /// pane is showing, or the one that is came from somewhere that names no
  /// subject (the page editor opens its config pane from the page's own
  /// context, and marks the asset itself). The plant view watches this to
  /// mark the asset the operator is looking at; nothing about the pane
  /// depends on it, so a pane whose subject is null works exactly as before.
  static ValueListenable<Object?> get subject => _subject;
  static final ValueNotifier<Object?> _subject = ValueNotifier<Object?>(null);

  static void _setSubject(Object? value) {
    if (identical(_subject.value, value)) return;
    _publish(() => _subject.value = value);
  }

  /// Runs [apply] where it is safe to notify listeners.
  ///
  /// Panes are closed from `dispose()` as well as from taps, and a dispose
  /// runs inside the frame's build phase — notifying from there is a
  /// "setState during build" against whatever is listening (the page's inset,
  /// the plant view's selection mark), and the listener may be half torn down
  /// itself. Every other caller (animation ticks, drag updates) is outside
  /// the build phase and applies straight away.
  static void _publish(VoidCallback apply) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
      return;
    }
    apply();
  }

  /// The on-screen rect the pane must not cover, in un-inset coordinates —
  /// measured before the page moves. Null means "assume covered".
  static Rect? _avoidRect;

  /// Whether the page has yielded the strip. Ratchets: once the strip is
  /// claimed it stays claimed until the pane closes — including across a swap
  /// to another device's pane and a narrowing resize. Releasing it mid-open
  /// would re-fit the page under the operator's pointer, and a rect measured
  /// on the inset page cannot answer where the device would sit on the
  /// un-inset one.
  static bool _insetEngaged = false;

  static void _setOccupied(double value) {
    if (_occupied.value == value) return;
    // A shell can go away mid-build — the whole overlay torn down by a route
    // change or a test's next pumpWidget — so this goes through [_publish].
    _publish(() => _occupied.value = value);
  }

  /// Width of the pane currently showing. Set per open, so a wide pane (the
  /// page editor's asset config) does not leave every equipment pane opened
  /// afterwards stretched to its width.
  static double _width = SidePaneDefaults.width;

  static void _show({
    required BuildContext context,
    required String id,
    required WidgetBuilder builder,
    double? width,
    EdgeInsets? insets,
    VoidCallback? onClosed,
    bool resizable = false,
    ValueChanged<double>? onWidthChanged,
    Rect? avoidRect,
  }) {
    // Replacing an open pane: keep the sheet and swap what is inside it. The
    // old path removed the overlay entry and inserted a new one, so the pane
    // slid out and back in -- a container animating for a content change,
    // which is the one thing a persistent side sheet should never do.
    final shell = _shellKey?.currentState;
    if (shell != null && _openId != null) {
      // The pane it is replacing is finished with, even though the sheet
      // stays: the old path removed the entry and _removeNow ran this, and
      // callers rely on it. The page editor's, for one, flushes the config
      // edits made in the pane it is leaving into the undo history -- skip it
      // and edits to the previous asset are silently dropped.
      final previous = _onClosed;
      _openId = id;
      _onClosed = onClosed;
      _avoidRect = avoidRect;
      _setSubject(SidePaneSubject.of(context));
      _width = width ?? SidePaneDefaults.width;
      // The chrome travels with the pane, not with the sheet: the overlay
      // entry was built for whichever pane opened first and is not rebuilt
      // here, so anything read off that widget would be the first pane's.
      shell.swapTo(
        id,
        builder,
        resizable: resizable,
        onWidthChanged: onWidthChanged,
        insets: insets ?? SidePaneDefaults.insets,
      );
      previous?.call();
      return;
    }
    _avoidRect = avoidRect;

    final overlay = Overlay.of(context, rootOverlay: true);
    _width = width ?? SidePaneDefaults.width;
    final key = GlobalKey<_SidePaneShellState>();
    _shellKey = key;
    _openId = id;
    _onClosed = onClosed;
    _setSubject(SidePaneSubject.of(context));
    _entry = OverlayEntry(
      builder: (context) => _SidePaneShell(
        key: key,
        insets: insets ?? SidePaneDefaults.insets,
        builder: builder,
        resizable: resizable,
        onWidthChanged: onWidthChanged,
      ),
    );
    overlay.insert(_entry!);
  }

  static void close({String? id, bool immediate = false}) {
    if (_openId == null) return;
    if (id != null && id != _openId) return;
    final shell = _shellKey?.currentState;
    if (shell == null || immediate) {
      _removeNow();
      return;
    }
    // Mark closed straight away so a tap during the exit animation opens a
    // fresh pane instead of toggling against a pane that is on its way out.
    _openId = null;
    // The mark on the asset goes with it: it says "this is what the pane is
    // about", and the pane is on its way out.
    _setSubject(null);
    // That fresh pane takes over the statics -- _entry, _shellKey, _onClosed
    // -- while this one is still sliding out. So when the slide finishes,
    // remove THIS entry, not whichever one the host holds by then: removing
    // the host's took the new pane down and left the old shell mounted for
    // good, invisible and off-screen, rebuilding a builder whose asset had
    // since been disposed (the soak test logged a thousand
    // "used after being disposed" from exactly that). Same for onClosed: the
    // pane that is leaving gets its own callback, once, when it has left.
    final entry = _entry;
    final onClosed = _onClosed;
    _onClosed = null;
    shell.dismiss().then((_) {
      if (_entry == entry) {
        _removeNow();
      } else {
        entry?.remove();
      }
      onClosed?.call();
    });
  }

  static void _removeNow({bool keepInset = false}) {
    _entry?.remove();
    _entry = null;
    _shellKey = null;
    _openId = null;
    _setSubject(null);
    if (!keepInset) {
      _insetEngaged = false;
      _avoidRect = null;
      _setOccupied(0);
    }
    final onClosed = _onClosed;
    _onClosed = null;
    onClosed?.call();
  }

  /// Drops the bookkeeping for a shell that went away on its own — the whole
  /// overlay was torn down by a route change, a hot restart or a test's next
  /// `pumpWidget`. Without this the host would still believe a pane is open
  /// and refuse to show the next one.
  static void _forget(Key? shellKey) {
    if (_shellKey != shellKey) return;
    _entry = null;
    _shellKey = null;
    _openId = null;
    _setSubject(null);
    _insetEngaged = false;
    _avoidRect = null;
    _setOccupied(0);
    final onClosed = _onClosed;
    _onClosed = null;
    onClosed?.call();
  }
}

/// Geometry, animation, resizing and Escape handling for the docked pane.
class _SidePaneShell extends StatefulWidget {
  final EdgeInsets insets;
  final WidgetBuilder builder;
  final bool resizable;
  final ValueChanged<double>? onWidthChanged;

  const _SidePaneShell({
    super.key,
    required this.insets,
    required this.builder,
    this.resizable = false,
    this.onWidthChanged,
  });

  @override
  State<_SidePaneShell> createState() => _SidePaneShellState();
}

class _SidePaneShellState extends State<_SidePaneShell>
    // Two controllers, so not the Single- variant: [_controller] slides the
    // sheet in and out, [_fade] fades the body around a content swap.
    with TickerProviderStateMixin {
  /// The pane's own Navigator. The pane lives in the root overlay, and
  /// `Overlay.rearrange` keeps it above every route the app Navigator will
  /// ever push — so a `DropdownButton` menu or `showDialog` opened from pane
  /// content would land BEHIND the pane, invisible but armed (tapping the
  /// dropdown a second time trips the framework's `_dropdownRoute == null`
  /// assertion). Giving the pane subtree its own Navigator makes those routes
  /// open in the pane's overlay instead, on top of the pane.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  late final OverlayEntry _paneEntry = OverlayEntry(builder: _buildPane);

  /// The content currently shown, and the id it belongs to.
  ///
  /// Held in state rather than read off the widget so an open pane can be
  /// pointed at different content without the overlay entry being replaced --
  /// see [swapTo].
  late WidgetBuilder _builder = widget.builder;
  late Object _contentKey = SidePaneHost._openId ?? 'pane';

  /// The chrome that belongs to the content currently shown.
  ///
  /// These travel with the pane, not with the sheet. The overlay entry — and
  /// so the widget — is built once for whichever pane opened first and is not
  /// rebuilt by a swap, so reading them off `widget` gave every swapped-in
  /// pane the FIRST pane's values: the page editor's asset-config pane (the
  /// one caller that is resizable) opened over an equipment pane came up with
  /// no resize handle, and an equipment pane opened over IT stayed resizable
  /// and drove the page editor's `onWidthChanged` — a setState for a pane it
  /// no longer owns.
  late bool _resizable = widget.resizable;
  late ValueChanged<double>? _onWidthChanged = widget.onWidthChanged;
  late EdgeInsets _insets = widget.insets;

  /// Fades the body out and back in around a content change.
  ///
  /// Deliberately sequential rather than a cross-fade. Two translucent copies
  /// stacked let the sheet's own surface show through both, so the middle of
  /// the transition reads as a flash -- and an incoming child that also scales
  /// makes the content jump while it brightens. One thing on screen at a time,
  /// no scale, and the sheet itself never moves.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    value: 1,
  );

  /// Show different content in this pane, without closing it.
  ///
  /// Tapping a second device while a pane is open used to tear the whole shell
  /// down and build a new one, so the sheet slid out and back in for what the
  /// operator experiences as one pane changing what it is about. The sheet now
  /// stays exactly where it is.
  Future<void> swapTo(
    String id,
    WidgetBuilder builder, {
    required bool resizable,
    required ValueChanged<double>? onWidthChanged,
    required EdgeInsets insets,
  }) async {
    if (_contentKey == id) return;
    await _fade.reverse();
    if (!mounted) return;
    setState(() {
      _builder = builder;
      _contentKey = id;
      _resizable = resizable;
      _onWidthChanged = onWidthChanged;
      _insets = insets;
    });
    if (!mounted) return;
    await _fade.forward();
  }

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  late final Animation<double> _slide = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    // Escape closes the pane wherever focus happens to be. A non-modal pane
    // never owns focus, so a focus-scoped shortcut would not fire.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    SidePaneHost._forget(widget.key);
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    // A field in the pane has the on-screen keyboard up: this Escape takes
    // the keyboard down and nothing else. The pane closes on the next one.
    if (escapeDismissesKeyboard(event)) return false;
    // A floating dialog opened from this pane sits on top of it, so it gets
    // the Escape first and the pane only closes once they are all gone.
    if (!FloatingDialogs.isEmpty) return false;
    // Same for anything pushed onto the pane's own Navigator — an open
    // dropdown menu or a modal dialog goes first, the pane after.
    final navigator = _navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return true;
    }
    closeSidePane();
    return true;
  }

  /// Runs the exit animation. The host removes the overlay entry afterwards.
  Future<void> dismiss() async {
    if (!mounted) return;
    // Release the strip as the slide-out begins, so the page's glide back
    // runs alongside the pane's exit rather than after it.
    SidePaneHost._setOccupied(0);
    await _controller.reverse();
  }

  /// Feeds [SidePaneHost.occupiedWidth]: the settled strip the pane claims —
  /// or nothing, while the device that opened it is in plain view anyway.
  void _publishOccupied() {
    if (!SidePaneHost._insetEngaged) {
      SidePaneHost._setOccupied(0);
      return;
    }
    final width = SidePaneHost._width < SidePaneDefaults.minWidth
        ? SidePaneDefaults.minWidth
        : SidePaneHost._width;
    SidePaneHost._setOccupied(width + 2 * SidePaneDefaults.margin);
  }

  @override
  Widget build(BuildContext context) {
    // Full-screen, but hit-transparent everywhere the pane is not: the
    // Navigator's Overlay claims a tap only where a child does, so the plant
    // view behind stays interactive — the pane remains non-modal.
    return Navigator(
      key: _navigatorKey,
      onGenerateRoute: (_) => null,
      onGenerateInitialRoutes: (_, __) => [_PaneCanvasRoute(_paneEntry)],
    );
  }

  Widget _buildPane(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final margin = SidePaneDefaults.margin;
    // Never let the reserved chrome squeeze the pane off a short screen.
    final chrome = _insets;
    final maxChrome = screen.height - 160;
    final scale = (chrome.top + chrome.bottom) > maxChrome && maxChrome > 0
        ? maxChrome / (chrome.top + chrome.bottom)
        : 1.0;
    final top = chrome.top * scale + margin;
    final bottom = chrome.bottom * scale + margin;
    final maxWidth = screen.width - margin * 2 < SidePaneDefaults.minWidth
        ? SidePaneDefaults.minWidth
        : screen.width - margin * 2;
    final width =
        SidePaneHost._width.clamp(SidePaneDefaults.minWidth, maxWidth);

    // Does the page have to yield the strip? Only if the device that opened
    // the pane would otherwise end up underneath it. Horizontal overlap is
    // the whole test — the strip spans the working height of the screen.
    // Re-checked on every pane build so a resize drag (or a shrinking
    // window) that pushes the pane over the device engages the inset then;
    // disengaging is the host's job and only happens when the pane closes.
    // `openId` goes null the moment the close begins: a rebuild during the
    // exit animation must not re-claim the strip `dismiss` just released.
    if (SidePaneHost._openId != null) {
      if (!SidePaneHost._insetEngaged) {
        final avoid = SidePaneHost._avoidRect;
        final strip = width + 2 * margin;
        if (avoid == null || avoid.right > screen.width - strip) {
          SidePaneHost._insetEngaged = true;
        }
      }
      _publishOccupied();
    }

    // No shadow at all: on the dark solarized theme even a small elevation
    // renders as a black halo, which reads like a warning frame around the
    // pane rather than depth. A hairline outline is enough to separate it
    // from the plant view.
    Widget pane = Material(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      color: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _fade, curve: Curves.easeInOut),
        child: KeyedSubtree(
          key: ValueKey<Object>(_contentKey),
          child: _builder(context),
        ),
      ),
    );

    if (_resizable) {
      pane = Stack(
        children: [
          Positioned.fill(child: pane),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 10,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Dragging the handle left widens the pane: it is pinned to
                // the right edge, so the left edge is the only one that moves.
                onHorizontalDragUpdate: (details) => _resizeBy(
                  -details.delta.dx,
                  SidePaneDefaults.minWidth,
                  maxWidth,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Positioned(
      right: margin,
      top: top,
      bottom: bottom,
      width: width,
      child: AnimatedBuilder(
        animation: _slide,
        builder: (context, child) => Transform.translate(
          offset: Offset((1 - _slide.value) * (width + margin), 0),
          child: Opacity(opacity: _slide.value.clamp(0.0, 1.0), child: child),
        ),
        child: pane,
      ),
    );
  }

  void _resizeBy(double delta, double minWidth, double maxWidth) {
    final next = (SidePaneHost._width + delta).clamp(minWidth, maxWidth);
    if (next == SidePaneHost._width) return;
    SidePaneHost._width = next;
    _publishOccupied();
    // The pane sits in its own route's OverlayEntry, which a plain setState
    // here would not reach.
    _paneEntry.markNeedsBuild();
    _onWidthChanged?.call(next);
  }
}

/// The base route of the pane's private Navigator: just the pane's
/// [OverlayEntry], with none of what `ModalRoute` would bring — no barrier
/// (which would block the plant view) and no transition. Routes pushed on top
/// of it by pane content (dropdown menus, dialogs) behave normally.
class _PaneCanvasRoute extends OverlayRoute<void> {
  _PaneCanvasRoute(this._entry);

  final OverlayEntry _entry;

  @override
  Iterable<OverlayEntry> createOverlayEntries() => <OverlayEntry>[_entry];
}
