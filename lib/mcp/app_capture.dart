import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show
        CapturedImage,
        ScreenCaptureBusyException,
        ScreenCaptureRasterizationException,
        ScreenCaptureUnavailableException;

/// The seam between the MCP screenshot tools and the live widget tree.
///
/// Two jobs, both of which need something mounted in the app:
///
///  * [captureWindow] photographs whatever the operator is looking at, by
///    rasterizing the [RepaintBoundary] that [AppCaptureScope] wraps the app
///    shell in.
///  * [captureOffscreen] mounts an arbitrary subtree *beside* the visible
///    one, one render at a time, lets it paint, and photographs that instead
///    -- so an agent can look at a page the operator is not on without
///    navigating their screen out from under them.
///
/// One controller owns one [GlobalKey], so a test can use its own instance
/// instead of fighting the app's over the same key.
class AppCaptureController {
  /// Creates a controller with its own capture key.
  AppCaptureController({String debugLabel = 'mcp-window-capture'})
      : windowKey = GlobalKey(debugLabel: debugLabel);

  /// The largest capture, in output pixels, that will be asked of the engine.
  ///
  /// Every capture costs one render target allocated for it alone
  /// (`SkSurfaces::RenderTarget`, unbudgeted) plus a device-to-host copy of
  /// the same size, and both of those can fail -- which is the failure
  /// [checkRasterized] exists to survive. The cheapest protection is not to
  /// ask for the enormous ones at all. 8 MPx is ~32 MB of RGBA, far above
  /// what the tools' base64 budget lets through anyway, so no request is
  /// refused for being too big: it is rendered at a lower pixel ratio.
  static const int kMaxCapturePixels = 8 * 1000 * 1000;

  /// Throws when the engine handed back an image it never actually drew.
  ///
  /// `RepaintBoundary.toImage` does not report a rasterisation failure. When
  /// the snapshot cannot be made -- no render target of that size, a GL
  /// context that would not go current, a device-to-host copy that did not
  /// come back -- `SnapshotControllerSkia::DoMakeRasterSnapshot` ends at
  /// `DlImage::Make(nullptr)`, which is a live `DlImageSkia` wrapping a null
  /// `SkImage`. `Picture::DoRasterizeToImage`'s null check looks at that
  /// wrapper rather than the image inside it, so it passes; `DlImageGPU::Make`
  /// then returns nullptr, and `CanvasImage::set_image` stores the nullptr
  /// behind an `FML_DCHECK` a profile or release engine does not compile in.
  /// What arrives in Dart is an ordinary [ui.Image] with a null native image,
  /// reporting 0 x 0, from a future that completed successfully.
  ///
  /// Handing that image to `toByteData` does not throw -- it is fatal. The
  /// engine posts it to the IO thread, where the matching `FML_DCHECK(image)`
  /// is also compiled out, and `ConvertImageToRasterSkia` dereferences null.
  /// The process dies with an access violation reading address 0 on a thread
  /// no Dart `try` and no zone can reach. That is what took the HMI down.
  ///
  /// So the size is checked here, in Dart, while it is still an error.
  @visibleForTesting
  static void checkRasterized(int width, int height) {
    if (width > 0 && height > 0) return;
    throw const ScreenCaptureRasterizationException(
      'the engine accepted the capture but returned an empty image, which is '
      'how it reports that the frame could not be rasterised (usually no '
      'render target of that size, or a graphics context that was not '
      'available). Nothing was drawn, so there is nothing to encode',
    );
  }

  /// Lowers [pixelRatio] until a capture of [logical] fits
  /// [kMaxCapturePixels].
  @visibleForTesting
  static double capToPixelBudget(double pixelRatio, Size logical) {
    final pixels = logical.width * pixelRatio * (logical.height * pixelRatio);
    if (pixels <= kMaxCapturePixels || pixels <= 0) return pixelRatio;
    return pixelRatio * math.sqrt(kMaxCapturePixels / pixels);
  }

  /// The controller the app and the MCP tools share.
  static final AppCaptureController instance = AppCaptureController();

  /// Identifies the boundary wrapping the app shell.
  final GlobalKey windowKey;

  _AppCaptureScopeState? _scope;
  bool _rendering = false;

  /// Whether an [AppCaptureScope] is currently mounted for this controller.
  bool get isAttached => _scope != null;

  /// Whether an offscreen render is in flight.
  bool get isRendering => _rendering;

  /// The logical size of the app window, or null when nothing is mounted.
  Size? get windowSize {
    final object = windowKey.currentContext?.findRenderObject();
    if (object is RenderBox && object.hasSize) return object.size;
    return null;
  }

  void _attach(_AppCaptureScopeState scope) => _scope = scope;

  void _detach(_AppCaptureScopeState scope) {
    // Guarded: on a hot reload the new scope attaches before the old one
    // disposes, and an unguarded detach would clear the live one.
    if (identical(_scope, scope)) _scope = null;
  }

  /// Photographs the app shell as it stands.
  ///
  /// [maxWidth] bounds the PNG's width by rendering at a smaller pixel ratio,
  /// which is both cheaper and sharper than resampling afterwards.
  Future<CapturedImage> captureWindow({int maxWidth = 1280}) async {
    final object = windowKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      throw const ScreenCaptureUnavailableException(
        'No AppCaptureScope is mounted, so there is no window to photograph. '
        'The app shell wraps itself in one at startup; this means the UI is '
        'not up yet.',
      );
    }
    await _awaitPaint(object);
    return _encode(object, maxWidth);
  }

  /// Mounts [child] at [size] outside the visible area, lets it paint, and
  /// photographs it.
  ///
  /// The subtree is a sibling of the app shell, so it inherits the same
  /// theme, providers, fonts and localizations -- which is the whole point:
  /// a preview rendered in a bare test harness is a different picture from
  /// the one the operator would get.
  ///
  /// One at a time. Two concurrent renders would share the same slot in the
  /// scope, and the second would photograph the first.
  Future<CapturedImage> captureOffscreen({
    required Widget child,
    required Size size,
    int maxWidth = 1280,
  }) async {
    final scope = _scope;
    if (scope == null) {
      throw const ScreenCaptureUnavailableException(
        'No AppCaptureScope is mounted, so there is nowhere to render.',
      );
    }
    if (_rendering) {
      throw const ScreenCaptureBusyException(
        'another offscreen render is already in flight; try again in a moment',
      );
    }
    _rendering = true;
    final key = GlobalKey(debugLabel: 'mcp-offscreen-capture');
    try {
      scope._setOffscreen(_OffscreenRender(key: key, child: child, size: size));

      // Two frames, not one. The first builds and lays the subtree out; the
      // second is the one that has certainly painted it, which is what
      // toImage needs -- a boundary with no layer yet throws.
      await _nextFrame();
      await _nextFrame();

      final object = key.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary) {
        throw const ScreenCaptureUnavailableException(
          'The offscreen subtree never mounted; nothing was rendered.',
        );
      }
      await _awaitPaint(object);
      return await _encode(object, maxWidth);
    } finally {
      scope._setOffscreen(null);
      _rendering = false;
    }
  }

  /// Rasterizes [boundary] and encodes it as a PNG.
  Future<CapturedImage> _encode(
      RenderRepaintBoundary boundary, int maxWidth) async {
    final logical = boundary.size;
    if (logical.isEmpty) {
      throw const ScreenCaptureUnavailableException(
        'The capture boundary has zero size; nothing has been laid out.',
      );
    }

    var pixelRatio = 1.0;
    if (maxWidth > 0 && logical.width > maxWidth) {
      pixelRatio = maxWidth / logical.width;
    }
    pixelRatio = capToPixelBudget(pixelRatio, logical);

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      // Before toByteData, never after: an unrasterised image is fatal to
      // encode, and only its size says so. See [checkRasterized].
      checkRasterized(image.width, image.height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const ScreenCaptureUnavailableException(
          'The frame could not be encoded as a PNG.',
        );
      }
      return CapturedImage(
        pngBytes:
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
        logicalWidth: logical.width,
        logicalHeight: logical.height,
        pixelRatio: pixelRatio,
      );
    } finally {
      image.dispose();
    }
  }

  /// Returns once [object] has a painted layer to photograph.
  ///
  /// The common case costs nothing: an MCP call arrives between frames, with
  /// the scheduler idle and the boundary already painted, so there is nothing
  /// to wait for. Only a boundary that is mid-flight needs a frame.
  Future<void> _awaitPaint(RenderObject object) async {
    var needsPaint = false;
    // debugNeedsPaint is debug-only -- reading it in a release build throws
    // on an uninitialised late field -- so it is read inside the assert that
    // is compiled out with it.
    assert(() {
      needsPaint = object.debugNeedsPaint;
      return true;
    }());
    if (!needsPaint &&
        SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      return;
    }
    await _nextFrame();
  }

  /// Completes after the next frame has been drawn.
  Future<void> _nextFrame() {
    final binding = SchedulerBinding.instance;
    final completer = Completer<void>();
    binding.addPostFrameCallback((_) {
      if (!completer.isCompleted) completer.complete();
    });
    // The app is often idle with nothing animating, so a frame has to be
    // asked for -- otherwise the callback waits for the operator to touch
    // something.
    binding.scheduleFrame();
    return completer.future;
  }
}

/// What the scope is currently rendering offscreen.
class _OffscreenRender {
  const _OffscreenRender({
    required this.key,
    required this.child,
    required this.size,
  });

  final GlobalKey key;
  final Widget child;
  final Size size;
}

/// Wraps the app shell so the MCP screenshot tools have something to
/// photograph.
///
/// Goes directly under `MaterialApp.builder`, which is the highest point that
/// still has the theme: a capture taken above it would be unthemed, and one
/// taken lower would miss the overlays (proposal banner, chat) that are part
/// of what the operator is looking at.
class AppCaptureScope extends StatefulWidget {
  const AppCaptureScope({
    super.key,
    required this.child,
    this.controller,
  });

  /// The app shell.
  final Widget child;

  /// Defaults to [AppCaptureController.instance]; tests pass their own.
  final AppCaptureController? controller;

  @override
  State<AppCaptureScope> createState() => _AppCaptureScopeState();
}

class _AppCaptureScopeState extends State<AppCaptureScope> {
  AppCaptureController get _controller =>
      widget.controller ?? AppCaptureController.instance;

  _OffscreenRender? _offscreen;

  @override
  void initState() {
    super.initState();
    _controller._attach(this);
  }

  @override
  void dispose() {
    _controller._detach(this);
    super.dispose();
  }

  void _setOffscreen(_OffscreenRender? render) {
    if (!mounted) {
      _offscreen = render;
      return;
    }
    setState(() => _offscreen = render);
  }

  @override
  Widget build(BuildContext context) {
    final offscreen = _offscreen;
    return Stack(
      // passthrough, so the shell keeps the exact constraints it had before
      // this widget was introduced. StackFit.loose would quietly relax them
      // and re-lay-out the whole app.
      fit: StackFit.passthrough,
      // No clip: the offscreen slot lives far outside the stack, and a clip
      // layer around it buys nothing (it is off screen either way) while
      // adding a composited layer to every frame the app ever draws.
      clipBehavior: Clip.none,
      children: [
        RepaintBoundary(key: _controller.windowKey, child: widget.child),
        if (offscreen != null)
          Positioned(
            // Parked to the left of everything, still painting. Offstage and
            // Opacity(0) both skip paint, and a subtree that never paints has
            // no layer -- toImage on it throws. This is the one arrangement
            // that is invisible and photographable at the same time.
            left: -(offscreen.size.width + 10000),
            top: 0,
            width: offscreen.size.width,
            height: offscreen.size.height,
            child: RepaintBoundary(
              key: offscreen.key,
              child: MediaQuery(
                // The page must lay itself out for the canvas it was asked
                // for, not for the operator's window.
                data: MediaQuery.of(context).copyWith(
                  size: offscreen.size,
                  viewInsets: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: offscreen.child,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
