/// Decides, in one place, where golden tests are allowed to run.
///
/// This used to be spelled out in each of 64 test files as
/// `skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null`, which
/// meant moving the reference platform was a 64-file edit and that a new
/// golden file could quietly pick the wrong guard. The decision belongs to the
/// suite, not to each file.
///
/// The reference platform is **Linux**, and the reason is not cost -- it is
/// that Linux is the only platform where the text rasteriser is pinned by
/// something we control.
///
/// Our goldens load RobotoMono from repo bytes (see [golden_fonts.dart]), so
/// the font data is already pinned and the host's installed fonts are never
/// consulted. What remains is the glyph rasteriser. On macOS, Skia rasterises
/// glyphs through CoreText -- part of the operating system, which changes when
/// macOS changes. That is why a golden authored on macOS 15 could fail on CI's
/// macOS 26 under an identical Flutter 3.44.9, and why regenerating never
/// helped: neither machine can produce the other's raster, so the only
/// available fix was to keep widening the tolerance. On Linux, Skia rasterises
/// through the FreeType compiled into the engine binary, which ships inside the
/// SDK, so `.flutter-version` pins the whole text raster stack.
///
/// Measured on 2026-09-12 against a three-golden probe:
///
/// | comparison                             | result           |
/// | -------------------------------------- | ---------------- |
/// | linux/amd64 vs linux/arm64             | byte-identical   |
/// | two fresh containers, same arch        | byte-identical   |
/// | macOS vs Linux, pure line drawing      | byte-identical   |
/// | macOS vs Linux, sparse text            | 0.104% of pixels |
/// | macOS vs Linux, dense small text       | 1.482% of pixels |
///
/// Architecture does not matter, so a developer runs the container on their
/// machine's native architecture and still reproduces CI's amd64 output.
///
/// On a machine that is not Linux, use `scripts/goldens.sh` -- it runs these
/// same tests inside the pinned image from `docker/goldens/`.
library;

import 'dart:io';

/// Pass to a `group`'s or a `test`'s `skip:` argument:
///
/// ```dart
/// group('my golden tests', skip: goldenSkip, () { ... });
/// ```
///
/// Deliberately a reason string rather than a bare `bool`, so a skipped run
/// prints how to render the goldens instead of the tests just vanishing.
final Object? goldenSkip = Platform.isLinux
    ? null
    : 'Goldens are rendered on Linux — run scripts/goldens.sh';

/// The same decision as [goldenSkip], as a plain `bool`, for `testWidgets`:
///
/// ```dart
/// testWidgets('renders the gate', (tester) async { ... },
///     skip: goldenSkipFlag);
/// ```
///
/// Two names for one rule is not a nicety. `group` and `test` type `skip` as
/// `dynamic` and show the reason when they skip; `testWidgets` types it as
/// `bool?` and cannot. Handing the string to `testWidgets` is a compile error,
/// not a silent misfire, so the split is enforced rather than remembered --
/// but it does mean the reason is only printed where the framework has
/// somewhere to print it.
final bool goldenSkipFlag = !Platform.isLinux;

/// Whether golden tests run on this machine.
///
/// For the rare test that needs to branch rather than skip. Prefer
/// [goldenSkip]: a skipped test is reported, a branched one is silent.
bool get goldensRunHere => Platform.isLinux;
