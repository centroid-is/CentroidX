/// Guards the `CENTROIDX_CHAT`/`CENTROIDX_KNOWLEDGE` opt-out on every shipping build.
///
/// The flags in `lib/core/feature_flags.dart` default to **on** so development
/// builds and this test suite exercise the AI chat and the knowledge features.
/// Everything we publish — the docker images stations pull, the desktop
/// installers, the MSIX — has to turn them back off explicitly, and "add both
/// `--dart-define`s" is a line you only remember when you already know it is
/// there. The release and profile elinux jobs were each added by copying a
/// build step that had the flags and dropping them, which shipped the chat FAB
/// to `latest-release` and `latest-profile` without anyone noticing.
///
/// So: find every real build invocation in the workflows, and require both
/// defines on each. A new platform, mode, or image is caught the first time CI
/// runs it rather than the first time an operator sees a feature that was
/// supposed to be off.
///
/// No Dockerfile is listed because none of them builds the app any more:
/// `docker/frontend/Dockerfile` assembles the bundle that
/// `.github/workflows/centroid-hmi.yml` already built under this gate, and
/// `docker/backend` builds no Flutter at all. The one that did —
/// `docker/frontend-ivi/Dockerfile.build`, the ivi-homescreen experiment — was
/// deleted. Add a Dockerfile back here the moment one runs `flutter build`.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files that contain build invocations we ship the output of.
const _sources = [
  '.github/workflows/centroid-hmi.yml',
  '.github/workflows/linux.yml',
  '.github/workflows/macos.yml',
  '.github/workflows/windows.yml',
];

/// A `flutter build <platform>`, a `flutter-elinux build elinux`, or the
/// `msix:create` wrapper, which reruns `flutter build windows` itself.
///
/// Comments are stripped before matching, so the prose above a build step that
/// mentions a command does not count as one.
final _buildCommand = RegExp(
  r'(flutter(-elinux)?\s+build\s+\w+|msix:create)',
);

/// One build invocation, kept with enough context to name it in a failure.
class _Invocation {
  _Invocation(this.file, this.line, this.text);

  final String file;
  final int line;
  final String text;

  @override
  String toString() => '$file:$line: ${text.trim()}';
}

/// Every build invocation in [_sources], with comment lines removed.
List<_Invocation> _findInvocations() {
  final found = <_Invocation>[];
  for (final path in _sources) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path is missing');
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) continue;
      if (!_buildCommand.hasMatch(line)) continue;
      found.add(_Invocation(path, i + 1, line));
    }
  }
  return found;
}

void main() {
  test('every shipped build compiles the experimental features out', () {
    final invocations = _findInvocations();

    // If this trips, a build step was renamed or moved out of _sources and the
    // guard is now watching nothing.
    expect(
      invocations.length,
      greaterThanOrEqualTo(6),
      reason: 'expected to find the elinux debug/release/profile, linux, '
          'macos, windows and msix builds; found $invocations',
    );

    final missing = invocations
        .where((i) =>
            !i.text.contains('CENTROIDX_CHAT=false') ||
            !i.text.contains('CENTROIDX_KNOWLEDGE=false'))
        .toList();

    expect(
      missing,
      isEmpty,
      reason: 'these builds ship with the experimental chat bubble and/or '
          'knowledge base compiled in — add '
          '`--dart-define=CENTROIDX_CHAT=false --dart-define=CENTROIDX_KNOWLEDGE=false`:\n'
          '${missing.join('\n')}',
    );
  });

  test('the flags still default to on for development and tests', () {
    final source = File('lib/core/feature_flags.dart').readAsStringSync();
    // The guard above is only meaningful while the defines are opt-out; if the
    // defaults ever flip to false, that test passes vacuously for the wrong
    // reason and this one says so.
    expect(source, contains("bool.fromEnvironment('CENTROIDX_CHAT'"));
    expect(source, contains("bool.fromEnvironment('CENTROIDX_KNOWLEDGE'"));
    expect(source.contains('defaultValue: false'), isFalse,
        reason: 'a flag now defaults off — revisit '
            'shipped_feature_flags_test.dart, which assumes opt-out');
  });
}
