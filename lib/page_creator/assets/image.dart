/// An image on the page: PNG, JPEG, BMP or SVG.
///
/// The asset holds only a content-hash id; the bytes live in the
/// [PageImageStore] (one `kind='page_image'` row per image) so the page JSON
/// stays small. Images arrive through the config pane (file picker / paste button)
/// or by pasting straight onto the editor canvas — see `_handlePaste` in
/// `lib/pages/page_editor.dart`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:tfc/widgets/number_slider.dart';

import '../../providers/page_images.dart';
import 'common.dart';
import 'editor_clipboard.dart';
import 'image_store.dart';

part 'image.g.dart';

/// Side for a placeholder glyph drawn into [constraints]: the box's shorter
/// side, or the 48pt default when the box is unbounded.
double _glyphSide(BoxConstraints constraints) {
  final side = constraints.biggest.shortestSide;
  return side.isFinite && side > 0 ? side : 48;
}

@JsonSerializable(explicitToJson: true)
class ImageConfig extends BaseAsset {
  @override
  String get displayName => 'Image';
  @override
  String get category => 'Visualization';

  /// Content-hash id of the stored bytes; null until an image is chosen, in
  /// which case a placeholder renders instead.
  @JsonKey(name: 'image_id')
  String? imageId;

  /// Original file name, purely informational in the config pane. Pasted
  /// images have none.
  @JsonKey(name: 'source_name')
  String? sourceName;

  /// Width / height of the source image, kept so paste can size the asset to
  /// the image's shape without re-decoding.
  @JsonKey(name: 'natural_aspect')
  double? naturalAspect;

  BoxFit fit;
  double opacity;

  ImageConfig({
    this.imageId,
    this.sourceName,
    this.naturalAspect,
    this.fit = BoxFit.contain,
    this.opacity = 1.0,
  }) {
    size = const RelativeSize(width: 0.15, height: 0.15);
  }

  ImageConfig.preview()
      : fit = BoxFit.contain,
        opacity = 1.0 {
    size = const RelativeSize(width: 0.15, height: 0.15);
  }

  factory ImageConfig.fromJson(Map<String, dynamic> json) =>
      _$ImageConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$ImageConfigToJson(this);

  /// Points this asset at a newly ingested image.
  void applyIngest(PageImageIngest ingest, {String? name}) {
    imageId = ingest.id;
    naturalAspect = ingest.aspectRatio;
    sourceName = name;
  }

  @override
  Widget build(BuildContext context) => PageImage(config: this);

  @override
  Widget configure(BuildContext context) => _ImageConfigEditor(config: this);
}

/// Raised when bytes are not a supported image, or fail to decode.
class PageImageFormatException implements Exception {
  final String message;
  const PageImageFormatException(
      [this.message =
          'Not a supported image. Use PNG, JPEG, BMP or SVG.']);

  @override
  String toString() => message;
}

/// What [ingestPageImage] learned about a stored image.
class PageImageIngest {
  final String id;
  final PageImageFormat format;

  /// Width / height. SVGs without a usable viewBox fall back to 1.
  final double aspectRatio;

  const PageImageIngest({
    required this.id,
    required this.format,
    required this.aspectRatio,
  });
}

/// Validates, measures and stores [bytes].
///
/// Rasters are run through the engine's codec, so anything undecodable is
/// rejected here — before it is stored — rather than becoming a broken image
/// on the canvas. Throws [PageImageFormatException] or
/// [PageImageTooLargeException].
Future<PageImageIngest> ingestPageImage(
    PageImageStore store, Uint8List bytes) async {
  if (bytes.length > PageImageStore.maxBytes) {
    throw PageImageTooLargeException(bytes.length);
  }
  final format = sniffImageFormat(bytes);
  if (format == null) {
    throw const PageImageFormatException();
  }

  double aspect;
  if (format == PageImageFormat.svg) {
    aspect = svgAspectRatio(utf8.decode(bytes, allowMalformed: true)) ?? 1.0;
  } else {
    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (_) {
      throw const PageImageFormatException('The image could not be decoded.');
    }
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      aspect = image.height == 0 ? 1.0 : image.width / image.height;
      image.dispose();
    } catch (_) {
      throw const PageImageFormatException('The image could not be decoded.');
    } finally {
      codec.dispose();
    }
  }

  final id = await store.save(bytes);
  return PageImageIngest(id: id, format: format, aspectRatio: aspect);
}

/// Width / height declared by an SVG document, from its viewBox or explicit
/// width/height attributes; null when neither is usable.
double? svgAspectRatio(String svg) {
  final viewBox = RegExp(r'viewBox\s*=\s*"([^"]*)"').firstMatch(svg);
  if (viewBox != null) {
    final parts = viewBox.group(1)!.trim().split(RegExp(r'[\s,]+'));
    if (parts.length == 4) {
      final w = double.tryParse(parts[2]);
      final h = double.tryParse(parts[3]);
      if (w != null && h != null && w > 0 && h > 0) return w / h;
    }
  }
  double? attr(String name) {
    final m = RegExp('<svg[^>]*\\s$name\\s*=\\s*"([0-9.]+)(px)?"')
        .firstMatch(svg);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  final w = attr('width');
  final h = attr('height');
  if (w != null && h != null && w > 0 && h > 0) return w / h;
  return null;
}

/// The canvas-side widget: rotates with the asset, dims with its opacity, and
/// falls back to placeholder glyphs when there is no image yet (palette tile,
/// fresh drop) or the bytes are gone (garbage-collected blob).
class PageImage extends ConsumerWidget {
  final ImageConfig config;
  const PageImage({super.key, required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = config.imageId;
    Widget content;
    if (id == null) {
      content = _glyph(context, Icons.image_outlined);
    } else {
      content = ref.watch(pageImageBytesProvider(id)).when(
            data: (bytes) => bytes == null
                ? _glyph(context, Icons.broken_image_outlined)
                : PageImageBytesView(bytes: bytes, fit: config.fit),
            loading: () => const SizedBox.expand(),
            error: (_, __) => _glyph(context, Icons.broken_image_outlined),
          );
    }
    if (config.opacity < 1.0) {
      content = Opacity(opacity: config.opacity.clamp(0.0, 1.0), child: content);
    }
    return LayoutRotatedBox(
      angle: (config.coordinates.angle ?? 0.0) * pi / 180,
      child: content,
    );
  }

  // Sized from the box rather than drawn at 48pt and scaled by a `FittedBox`:
  // an icon is a font glyph, so a scale transform resamples it exactly as it
  // resamples text. See `AutoSizedText` in common.dart.
  Widget _glyph(BuildContext context, IconData icon) => LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Icon(
            icon,
            size: _glyphSide(constraints),
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
}

/// Renders stored image bytes, picking the codec off the bytes themselves so
/// a re-used id never renders with a stale format assumption.
class PageImageBytesView extends StatelessWidget {
  final Uint8List bytes;
  final BoxFit fit;
  const PageImageBytesView({super.key, required this.bytes, required this.fit});

  @override
  Widget build(BuildContext context) {
    if (sniffImageFormat(bytes) == PageImageFormat.svg) {
      return SvgPicture.memory(bytes, fit: fit);
    }
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, _, __) => LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: _glyphSide(constraints),
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

class _ImageConfigEditor extends ConsumerStatefulWidget {
  final ImageConfig config;
  const _ImageConfigEditor({required this.config});

  @override
  ConsumerState<_ImageConfigEditor> createState() => _ImageConfigEditorState();
}

class _ImageConfigEditorState extends ConsumerState<_ImageConfigEditor> {
  ImageConfig get config => widget.config;

  Future<void> _ingest(Uint8List bytes, {String? name}) async {
    try {
      final store = await ref.read(pageImageStoreProvider.future);
      final ingest = await ingestPageImage(store, bytes);
      // A replaced image gets a new content-hash id, so the bytes provider
      // for the new id is either fresh or already correct — but invalidate
      // anyway in case this id was garbage-collected and re-added.
      ref.invalidate(pageImageBytesProvider(ingest.id));
      setState(() => config.applyIngest(ingest, name: name));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _pickFile() async {
    final pick = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'bmp', 'svg'],
      dialogTitle: 'Select image',
      withData: true,
    );
    final file = pick?.files.single;
    if (file == null || file.bytes == null) return;
    await _ingest(file.bytes!, name: file.name);
  }

  Future<void> _pasteFromClipboard() async {
    final bytes = await EditorClipboard.instance.readImage();
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No image on the clipboard.')),
      );
      return;
    }
    await _ingest(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 140,
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: config.imageId == null
                ? Center(
                    child: Text(
                      'No image selected',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: ref
                        .watch(pageImageBytesProvider(config.imageId!))
                        .when(
                          data: (bytes) => bytes == null
                              ? const Center(child: Text('Image data missing'))
                              : PageImageBytesView(
                                  bytes: bytes, fit: BoxFit.contain),
                          loading: () => const SizedBox.expand(),
                          error: (_, __) =>
                              const Center(child: Text('Image data missing')),
                        ),
                  ),
          ),
          if (config.sourceName != null || config.imageId != null) ...[
            const SizedBox(height: 4),
            Text(
              config.sourceName ?? 'Pasted image',
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose file'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste image'),
                ),
              ),
            ],
          ),
          if (config.imageId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  config.imageId = null;
                  config.sourceName = null;
                  config.naturalAspect = null;
                }),
                icon: const Icon(Icons.clear),
                label: const Text('Remove image'),
              ),
            ),
          const SizedBox(height: 16),
          Text('Fit', style: theme.textTheme.titleMedium),
          DropdownButton<BoxFit>(
            value: config.fit,
            isExpanded: true,
            onChanged: (value) => setState(() => config.fit = value!),
            items: const [
              BoxFit.contain,
              BoxFit.cover,
              BoxFit.fill,
              BoxFit.fitWidth,
              BoxFit.fitHeight,
              BoxFit.scaleDown,
              BoxFit.none,
            ]
                .map((f) =>
                    DropdownMenuItem<BoxFit>(value: f, child: Text(f.name)))
                .toList(),
          ),
          const SizedBox(height: 8),
          NumberSlider(
            label: 'Opacity:',
            value: config.opacity,
            min: 0.0,
            max: 1.0,
            divisions: 20,
            decimals: 2,
            onChanged: (v) => setState(() => config.opacity = v),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: config.text,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => config.text = value),
          ),
          const SizedBox(height: 8),
          DropdownButton<TextPos>(
            value: config.textPos,
            hint: const Text('Label position'),
            isExpanded: true,
            onChanged: (value) => setState(() => config.textPos = value),
            items: TextPos.values
                .map((e) =>
                    DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                .toList(),
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: config.size,
            onChanged: (size) => setState(() => config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            enableAngle: true,
            initialValue: config.coordinates,
            onChanged: (c) => setState(() => config.coordinates = c),
          ),
        ],
      ),
    );
  }
}
