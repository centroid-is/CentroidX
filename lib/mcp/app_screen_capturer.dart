import 'package:flutter/material.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show CapturedImage, ScreenCapturer, ScreenCaptureUnavailableException;

import 'app_capture.dart';

/// [ScreenCapturer] backed by the running Flutter app.
///
/// The server package owns the tools and the payload budget; this owns the
/// pixels. [pageKeys] and [buildPage] are injected rather than reached for,
/// so the MCP layer never has to know that a page is a `PlantPageView` or
/// that its keys live in a Riverpod provider.
///
/// When [buildPage] is null the offscreen half is simply absent and
/// `render_page` is never advertised -- a tool that is honestly missing beats
/// one that always answers "not supported".
class AppScreenCapturer implements ScreenCapturer {
  AppScreenCapturer({
    AppCaptureController? controller,
    List<String> Function()? pageKeys,
    Widget Function(String pageKey)? buildPage,
  })  : _controller = controller ?? AppCaptureController.instance,
        _pageKeys = pageKeys,
        _buildPage = buildPage;

  final AppCaptureController _controller;
  final List<String> Function()? _pageKeys;
  final Widget Function(String pageKey)? _buildPage;

  @override
  Future<CapturedImage> captureWindow({required int maxWidth}) =>
      _controller.captureWindow(maxWidth: maxWidth);

  @override
  ({int width, int height})? get windowSize {
    final size = _controller.windowSize;
    if (size == null || size.isEmpty) return null;
    return (width: size.width.round(), height: size.height.round());
  }

  @override
  bool get canRenderPages => _buildPage != null;

  /// Read live on every call, not snapshotted: a page accepted from a
  /// proposal has to be renderable without restarting the app.
  @override
  List<String> get pageKeys {
    try {
      return _pageKeys?.call() ?? const <String>[];
    } catch (_) {
      // An unavailable page store is not a reason to refuse the render --
      // an empty list just means the tool skips its "did you mean" check.
      return const <String>[];
    }
  }

  @override
  Future<CapturedImage> capturePage({
    required String pageKey,
    required int width,
    required int height,
    required int maxWidth,
  }) {
    final buildPage = _buildPage;
    if (buildPage == null) {
      throw const ScreenCaptureUnavailableException(
        'This app was not wired to render pages offscreen.',
      );
    }
    return _controller.captureOffscreen(
      child: buildPage(pageKey),
      size: Size(width.toDouble(), height.toDouble()),
      maxWidth: maxWidth,
    );
  }
}
