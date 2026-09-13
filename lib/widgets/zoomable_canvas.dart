import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';

class ZoomableCanvas extends StatefulWidget {
  final Widget child;
  final double minScale;
  final double maxScale;
  final double aspectRatio;
  final bool panEnabled;
  final bool scaleEnabled;

  /// False pins the canvas at 1:1: no zoom, no pan — not even the middle
  /// button, which otherwise always pans. Turning it off while zoomed snaps
  /// back to 1:1, since there would be no gesture left to get back there.
  /// Overrides [panEnabled] and [scaleEnabled].
  final bool interactive;

  const ZoomableCanvas({
    Key? key,
    required this.child,
    this.minScale = 1.0,
    this.maxScale = 4.0,
    this.aspectRatio = 16 / 9,
    this.panEnabled = true,
    this.scaleEnabled = true,
    this.interactive = true,
  }) : super(key: key);

  @override
  State<ZoomableCanvas> createState() => _ZoomableCanvasState();
}

class _ZoomableCanvasState extends State<ZoomableCanvas> {
  final TransformationController _transformationController =
      TransformationController();

  /// True while a middle-mouse-button drag is in flight. The middle button
  /// always pans, regardless of [ZoomableCanvas.panEnabled]: the page editor
  /// reserves plain drags for its marquee and only enables pan while Space is
  /// held, but a middle-button drag has no other meaning on the canvas.
  /// `InteractiveViewer` consults `panEnabled` on every update, not just at
  /// the start of a gesture, so flipping it on the button's own pointer-down
  /// catches that same drag.
  bool _middleButtonPanning = false;

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  /// The viewport measured on the last build, so a resize can be told apart
  /// from the first layout.
  Size? _viewportSize;

  /// Re-clamps the pan after the viewport itself changes size — a docked
  /// side pane opening insets the canvas out from under it. The transform is
  /// in viewport pixels, so a pan that was flush against the old edge can
  /// point past the new one, which would show a blank strip until the next
  /// gesture. `InteractiveViewer` only clamps during gestures.
  void _clampToViewport(Size viewport) {
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final tx = matrix.storage[12];
    final ty = matrix.storage[13];
    // The child fills the viewport, scaled by `scale`: its image spans
    // [t, t + scale * extent], which covers the viewport iff t is in
    // [extent * (1 - scale), 0].
    final cx = tx.clamp(viewport.width * (1 - scale), 0.0);
    final cy = ty.clamp(viewport.height * (1 - scale), 0.0);
    if (cx == tx && cy == ty) return;
    _transformationController.value = matrix.clone()
      ..setTranslationRaw(cx, cy, matrix.storage[14]);
  }

  @override
  void didUpdateWidget(ZoomableCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interactive && !widget.interactive) {
      _middleButtonPanning = false;
      _resetZoom();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: ClipRect(
          child: LayoutBuilder(builder: (context, constraints) {
            final viewport = constraints.biggest;
            if (_viewportSize != null && _viewportSize != viewport) {
              // Not inline: setting the controller mid-build would rebuild
              // the InteractiveViewer during this very build.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _clampToViewport(viewport);
              });
            }
            _viewportSize = viewport;
            return Stack(
              children: [
                Listener(
                  onPointerDown: (event) {
                    if (widget.interactive &&
                        event.buttons & kMiddleMouseButton != 0) {
                      setState(() => _middleButtonPanning = true);
                    }
                  },
                  onPointerUp: (event) {
                    if (_middleButtonPanning) {
                      setState(() => _middleButtonPanning = false);
                    }
                  },
                  onPointerCancel: (event) {
                    if (_middleButtonPanning) {
                      setState(() => _middleButtonPanning = false);
                    }
                  },
                  child: InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: widget.minScale,
                    maxScale: widget.maxScale,
                    boundaryMargin: EdgeInsets.zero,
                    panEnabled: widget.interactive &&
                        (widget.panEnabled || _middleButtonPanning),
                    scaleEnabled: widget.interactive && widget.scaleEnabled,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: colorScheme.surface,
                        ),
                        widget.child,
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: ValueListenableBuilder<Matrix4>(
                    valueListenable: _transformationController,
                    builder: (context, matrix, child) {
                      final scale = matrix.getMaxScaleOnAxis();
                      if (scale <= 1.0) {
                        return const SizedBox.shrink();
                      }
                      return FloatingActionButton(
                        mini: true,
                        heroTag: null,
                        // Zoomed in is the only state where panning is possible
                        // — at 1:1 the child exactly fills the viewport — so
                        // this is where the page editor's pan gestures are worth
                        // mentioning, and this button is the only chrome that
                        // appears exactly then.
                        tooltip:
                            'Reset zoom — middle-click drag or Space+drag to pan',
                        backgroundColor: colorScheme.primary,
                        onPressed: _resetZoom,
                        child:
                            const Icon(Icons.zoom_out_map, color: Colors.white),
                      );
                    },
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
