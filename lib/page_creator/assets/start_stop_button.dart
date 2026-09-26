import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;

import 'common.dart';
import '../../providers/state_man.dart';
import '../../widgets/tag_access_guard.dart';

part 'start_stop_button.g.dart';

enum _Segment { run, clean, stop, manual }

@JsonSerializable(explicitToJson: true)
class StartStopPillButtonConfig extends BaseAsset {
  @override
  String get displayName => 'Start/Stop Button';
  @override
  String get category => 'Interactive Controls';

  // pulses (true on press, false on release)
  String runKey;
  String stopKey;
  String? cleanKey; // optional -> hides middle segment if null/empty

  // feedback (boolean states)
  String runningKey;
  String stoppedKey;
  String? cleaningKey; // optional

  /// Manual is a **peer mode** alongside run / clean / stop. Same shape as
  /// the existing modes: a state BOOL (`manualStateKey`) for "is the
  /// system currently in manual mode" + a command BOOL (`manualCommandKey`)
  /// pulsed on tap to ask the PLC to switch into manual mode. NOT a
  /// disable / lockout gate — every other segment stays individually
  /// tappable regardless of the manual state.
  ///
  /// When BOTH manual_* keys are null/empty the manual segment is hidden
  /// (pill keeps its legacy 2- or 3-segment layout).
  ///
  /// Wire keys: `manual_state_key`, `manual_command_key`, `manual_label`.
  @JsonKey(name: 'manual_state_key')
  String? manualStateKey;

  @JsonKey(name: 'manual_command_key')
  String? manualCommandKey;

  /// Optional override for the manual-mode tooltip / a11y label
  /// (default is "Manual"). Wire key: `manual_label`.
  @JsonKey(name: 'manual_label')
  String? manualLabel;

  StartStopPillButtonConfig({
    required this.runKey,
    required this.stopKey,
    required this.runningKey,
    required this.stoppedKey,
    this.cleanKey,
    this.cleaningKey,
    this.manualStateKey,
    this.manualCommandKey,
    this.manualLabel,
  }) {
    textPos = TextPos.right;
  }

  StartStopPillButtonConfig.preview()
      : runKey = previewStr,
        stopKey = previewStr,
        runningKey = previewStr,
        stoppedKey = previewStr,
        cleanKey = null,
        cleaningKey = null,
        manualStateKey = null,
        manualCommandKey = null,
        manualLabel = null {
    textPos = TextPos.right;
  }

  static const previewStr = 'StartStopPillButton preview';

  @override
  Widget build(BuildContext context) => StartStopPillButton(this);

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 360,
          minHeight: 240,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(child: _ConfigContent(config: this)),
          ),
        ),
      ),
    );
  }

  factory StartStopPillButtonConfig.fromJson(Map<String, dynamic> json) =>
      _$StartStopPillButtonConfigFromJson(json);
  Map<String, dynamic> toJson() => _$StartStopPillButtonConfigToJson(this);
}

class StartStopPillButton extends ConsumerStatefulWidget {
  final StartStopPillButtonConfig config;
  const StartStopPillButton(this.config, {super.key});

  @override
  ConsumerState<StartStopPillButton> createState() =>
      _StartStopPillButtonState();
}

class _StartStopPillButtonState extends ConsumerState<StartStopPillButton> {
  static final _log = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 6,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  _Segment? _pressed; // visual press
  String? _activeWriteKey;

  Stream<bool> _boolKey(String? key, {bool seed = false}) {
    if (key == null || key.isEmpty) return Stream.value(seed);
    return ref
        .watch(keyStreamProvider(key))
        .map((v) => v.asBool)
        .startWith(seed);
  }

  // precedence: manual > stopped > cleaning > running
  //
  // Manual takes the highest precedence as the active visual indicator —
  // industrial convention is that "operator is in charge" dominates any
  // other mode the PLC may also be reporting.
  Stream<_Segment> _stateStream() {
    final running$ = _boolKey(widget.config.runningKey);
    final stopped$ = _boolKey(widget.config.stoppedKey);
    final cleaning$ = _boolKey(widget.config.cleaningKey);
    final manual$ = _boolKey(widget.config.manualStateKey);
    return Rx.combineLatest4<bool, bool, bool, bool, _Segment>(
      running$,
      stopped$,
      cleaning$,
      manual$,
      (r, s, c, m) {
        if (m) return _Segment.manual;
        if (s) return _Segment.stop;
        if (c) return _Segment.clean;
        if (r) return _Segment.run;
        return _Segment.stop;
      },
    );
  }

  /// Writes one half of a pulse.
  ///
  /// **False only on a refusal** — the prompt is up by then and nothing was
  /// sent. The preview, which has no PLC behind it, answers true: there was
  /// nothing to refuse, and the caller's behaviour must not change with it.
  ///
  /// No member: each of the four command keys is its own BOOL node, so the
  /// question is about the key as a whole.
  Future<bool> _writePulse(String key, bool value) async {
    if (widget.config.runKey == StartStopPillButtonConfig.previewStr) {
      return true;
    }
    final client = await ref.read(stateManProvider.future);
    return writeTag(
        ref, client, key, DynamicValue(value: value, typeId: NodeId.boolean));
  }

  void _onTapDown(_Segment seg) async {
    setState(() => _pressed = seg);
    String? key;
    switch (seg) {
      case _Segment.run:
        key = widget.config.runKey;
        break;
      case _Segment.clean:
        key = widget.config.cleanKey;
        break;
      case _Segment.stop:
        key = widget.config.stopKey;
        break;
      case _Segment.manual:
        key = widget.config.manualCommandKey;
        break;
    }
    if (key == null || key.isEmpty) return;
    _activeWriteKey = key;
    try {
      if (!await _writePulse(key, true)) {
        // Refused at the tap. No pulse went out, so the release must not send
        // its half either — a lone falling edge is a command the PLC never
        // saw the start of, and a second refusal would write a second audit
        // row for one press.
        _activeWriteKey = null;
        return;
      }
      _log.d('press -> $seg ($key)');
    } catch (e, st) {
      // Kept: this catches the comms failure it was written for. A refusal
      // can no longer reach it — `writeTag` answers false instead of throwing
      // — and removing a catch that still guards a real failure mode to make
      // a grep look tidier would be the wrong trade.
      _log.e('press write failed', error: e, stackTrace: st);
    }
  }

  void _onTapEnd() async {
    final key = _activeWriteKey;
    _activeWriteKey = null;
    setState(() => _pressed = null);
    if (key == null || key.isEmpty) return;
    try {
      await _writePulse(key, false);
      _log.d('release -> $key');
    } catch (e, st) {
      _log.e('release write failed', error: e, stackTrace: st);
    }
  }

  bool get _hasClean =>
      widget.config.cleanKey != null && widget.config.cleanKey!.isNotEmpty;

  /// Manual segment is rendered whenever the user has wired EITHER the
  /// state-feedback BOOL or the command-pulse BOOL (or both). Mirrors how
  /// `_hasClean` works for the clean mode.
  bool get _hasManual =>
      (widget.config.manualStateKey != null &&
          widget.config.manualStateKey!.isNotEmpty) ||
      (widget.config.manualCommandKey != null &&
          widget.config.manualCommandKey!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final smAsync = ref.watch(stateManProvider);
    return smAsync.when(
      data: (sm) => StreamBuilder<_Segment?>(
        stream: _stateStream(),
        builder: (context, snapshot) {
          final active = snapshot.data;
          return _PrettyPill(
            hasClean: _hasClean,
            hasManual: _hasManual,
            active: active,
            pressed: _pressed,
            onDown: _onTapDown,
            onEnd: _onTapEnd,
          );
        },
      ),
      loading: () => _PrettyPill(
        hasClean: _hasClean,
        hasManual: _hasManual,
        active: null,
        pressed: _pressed,
        onDown: _onTapDown,
        onEnd: _onTapEnd,
      ),
      error: (_, __) => _PrettyPill(
        hasClean: _hasClean,
        hasManual: _hasManual,
        active: null,
        pressed: _pressed,
        onDown: _onTapDown,
        onEnd: _onTapEnd,
      ),
    );
  }
}

class _PrettyPill extends StatelessWidget {
  final bool hasClean;
  final bool hasManual;
  final _Segment? active;
  final _Segment? pressed;
  final void Function(_Segment) onDown;
  final VoidCallback onEnd;

  const _PrettyPill({
    required this.hasClean,
    required this.hasManual,
    required this.active,
    required this.pressed,
    required this.onDown,
    required this.onEnd,
  });

  // Layout order: run | clean? | stop | manual?
  //
  // Manual is appended at the end so the existing run / clean / stop
  // layout positions stay stable for users with no manual wiring (which
  // is the v1.0 → v1.1 backwards-compat contract).
  List<_Segment> get _segments => [
        _Segment.run,
        if (hasClean) _Segment.clean,
        _Segment.stop,
        if (hasManual) _Segment.manual,
      ];

  int _indexOf(_Segment seg) => _segments.indexOf(seg);

  Color _accent(BuildContext c, _Segment s) {
    switch (s) {
      case _Segment.run:
        return Colors.green;
      case _Segment.clean:
        return Colors.blue;
      case _Segment.stop:
        return Colors.red;
      case _Segment.manual:
        // Industrial convention: operator override = orange / amber.
        return Colors.orange;
    }
  }

  IconData _icon(_Segment s) => switch (s) {
        _Segment.run => FontAwesomeIcons.play.data,
        _Segment.clean => FontAwesomeIcons.droplet.data,
        _Segment.stop => FontAwesomeIcons.stop.data,
        _Segment.manual => FontAwesomeIcons.screwdriverWrench.data,
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      final height = c.maxHeight.clamp(32.0, 160.0);
      final radius = height * 0.4;
      final outerR = BorderRadius.circular(radius);
      final count = _segments.length;

      final pad = height * 0.08; // internal inset
      final segW = (width - pad * 2) / count;

      final display = pressed ?? active ?? _segments.last;
      final idx = _indexOf(display);
      final left = pad + segW * idx;

      final scheme = Theme.of(context).colorScheme;
      final trackColor = scheme.surfaceContainerHighest;
      final trackBorder = scheme.outline; // a bit bolder
      final divider = scheme.outlineVariant.withAlpha(64);

      final thumbTop = pad;
      final thumbH = height - pad * 2;
      final isPressed = pressed != null;
      final thumbScale = isPressed ? 0.8 : 0.95;
      final thumbColor = scheme.surface;
      final accent = _accent(context, display);

      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints.tight(Size(width, height)),
          // --- IMPORTANT: clip everything to the pill contour ---
          child: ClipRRect(
            borderRadius: outerR,
            child: Stack(
              children: [
                // Track with *slightly* bolder outer border
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: trackColor,
                    borderRadius: outerR,
                    border: Border.all(color: trackBorder, width: 1.5),
                  ),
                  child: Row(
                    children: List.generate(count * 2 - 1, (i) {
                      if (i.isEven) {
                        return const Expanded(child: SizedBox());
                      } else {
                        return Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: height * 0.12, // keep lines off the arcs
                          ),
                          child: Container(width: 1, color: divider),
                        );
                      }
                    }),
                  ),
                ),

                // Sliding thumb (no border; soft shadow)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOut,
                  left: left,
                  top: thumbTop,
                  width: segW,
                  height: thumbH,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 100),
                    scale: thumbScale,
                    curve: Curves.easeOut,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(thumbH / 2),
                        color: thumbColor,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(50),
                            blurRadius: 8,
                            offset: Offset(
                              // Adjust shadow offset based on segment position
                              display == _Segment.run
                                  ? -5
                                  : display == _Segment.stop
                                      ? 5
                                      : 0.0,
                              2,
                            ),
                          ),
                        ],
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withAlpha(4),
                            Colors.black.withAlpha(3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Icons & gesture layers
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: List.generate(count, (i) {
                    final seg = _segments[i];
                    final isActive = display == seg;
                    final iconColor = isActive
                        ? _accent(context, seg)
                        : scheme.onSurfaceVariant.withOpacity(0.9);

                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) => onDown(seg),
                        onTapUp: (_) => onEnd(),
                        onTapCancel: onEnd,
                        child: LayoutBuilder(
                          builder: (context, cc) {
                            final size = cc.maxHeight * 0.44;
                            return Center(
                              child: Icon(_icon(seg),
                                  size: size, color: iconColor),
                            );
                          },
                        ),
                      ),
                    );
                  }),
                ),

                // Subtle accent underline (softer, clipped to pill)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOut,
                  left: display == _Segment.stop
                      ? left + segW * 0.4
                      : left + segW * 0.30,
                  width: segW * 0.40,
                  bottom: height * 0.12,
                  height: (height * 0.018).clamp(2.0, 4.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent.withAlpha(50),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _ConfigContent extends StatefulWidget {
  final StartStopPillButtonConfig config;
  const _ConfigContent({required this.config});

  @override
  State<_ConfigContent> createState() => _ConfigContentState();
}

class _ConfigContentState extends State<_ConfigContent> {
  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Write Keys', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Run Key'),
        KeyField(
          initialValue: cfg.runKey,
          onChanged: (v) => setState(() => cfg.runKey = v),
        ),
        const SizedBox(height: 12),
        const Text('Stop Key'),
        KeyField(
          initialValue: cfg.stopKey,
          onChanged: (v) => setState(() => cfg.stopKey = v),
        ),
        const SizedBox(height: 12),
        const Text('Clean Key (optional)'),
        KeyField(
          initialValue: cfg.cleanKey ?? '',
          onChanged: (v) => setState(() => cfg.cleanKey = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 20),
        const Text('Feedback Keys',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Running Key (bool)'),
        KeyField(
          initialValue: cfg.runningKey,
          onChanged: (v) => setState(() => cfg.runningKey = v),
        ),
        const SizedBox(height: 12),
        const Text('Stopped Key (optional, bool)'),
        KeyField(
          initialValue: cfg.stoppedKey,
          onChanged: (v) => setState(() => cfg.stoppedKey = v),
        ),
        const SizedBox(height: 12),
        const Text('Cleaning Key (optional, bool)'),
        KeyField(
          initialValue: cfg.cleaningKey ?? '',
          onChanged: (v) =>
              setState(() => cfg.cleaningKey = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 20),
        const Text('Manual Mode (optional peer mode)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Wires manual as a 4th peer segment alongside run / clean / '
          'stop. Leave BOTH keys empty to hide the manual segment.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        const Text('Manual Command Key (pulse on tap)'),
        KeyField(
          initialValue: cfg.manualCommandKey ?? '',
          onChanged: (v) => setState(
              () => cfg.manualCommandKey = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 12),
        const Text('Manual State Key (bool feedback)'),
        KeyField(
          initialValue: cfg.manualStateKey ?? '',
          onChanged: (v) =>
              setState(() => cfg.manualStateKey = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: cfg.manualLabel ?? '',
          decoration: const InputDecoration(
            labelText: 'Manual Label (optional, defaults to "Manual")',
          ),
          onChanged: (v) =>
              setState(() => cfg.manualLabel = v.isEmpty ? null : v),
        ),
        const SizedBox(height: 20),
        TextFormField(
          initialValue: cfg.text,
          decoration: const InputDecoration(labelText: 'Text'),
          onChanged: (v) => setState(() => cfg.text = v),
        ),
        const SizedBox(height: 12),
        CoordinatesField(
          initialValue: cfg.coordinates,
          onChanged: (c) => setState(() => cfg.coordinates = c),
        ),
        const SizedBox(height: 16),
        DropdownButton<TextPos>(
          value: cfg.textPos,
          isExpanded: true,
          onChanged: (v) => setState(() => cfg.textPos = v ?? cfg.textPos),
          items: TextPos.values
              .map((e) => DropdownMenuItem(value: e, child: Text(e.name)))
              .toList(),
        ),
        const SizedBox(height: 16),
        SizeField(
          initialValue: cfg.size,
          onChanged: (c) => setState(() => cfg.size = c),
        ),
      ],
    );
  }
}
