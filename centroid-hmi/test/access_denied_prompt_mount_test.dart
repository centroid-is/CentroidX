/// Where the denial prompt is mounted, and that it is mounted exactly once.
///
/// `AccessDeniedPrompt` subscribes to `accessDenialsProvider`, a broadcast
/// stream, and turns each refusal into a modal. One subscription per mount, so
/// the number of mounts *is* the number of dialogs an operator gets for one
/// refused write.
///
/// It used to be mounted in `BaseScaffold`, which reads like "the one place
/// every page passes through" and is not: Beamer's `RoutesLocationBuilder`
/// stacks a page for every route matching the location, `/` matches every
/// path, and a route below the top stays mounted. Any station whose `/` was an
/// ordinary page therefore had two live scaffolds, two subscriptions and two
/// stacked dialogs — Close pressed twice, with the barrier visibly lightening
/// in between as the first of two `black54` scrims came off.
///
/// **This is a source walk, not a widget test, and that is deliberate.** What
/// needs pinning is a fact about the *tree shape of the app*, and booting
/// `MyApp` to observe it would need a database, secure storage and a live
/// router — none of which this fact depends on. The idiom is the one
/// `kUncaughtAccessDeniedWriteSites` uses in
/// `test/widgets/access_denied_prompt_test.dart`: derive the claim from the
/// source so it cannot quietly stop being true.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shell's own entrypoint.
final File _shell = File('lib/main.dart');

/// The shared package the shell is built from.
final Directory _packageLib = Directory('../lib');

/// Source with comment lines dropped.
///
/// Every file below talks *about* `AccessDeniedPrompt` in prose — this file
/// included — and a walk that counted those would be counting its own
/// documentation.
Iterable<String> _code(File file) => file
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'));

void main() {
  setUpAll(() {
    // A wrong cwd would make every expectation below vacuously true.
    expect(_shell.existsSync(), isTrue,
        reason: 'run from centroid-hmi/; lib/main.dart not found');
    expect(_packageLib.existsSync(), isTrue,
        reason: 'run from centroid-hmi/; ../lib not found');
  });

  test('the shell mounts exactly one AccessDeniedPrompt', () {
    final mounts = _code(_shell)
        .where((line) => line.contains('AccessDeniedPrompt('))
        .toList();

    expect(mounts, hasLength(1),
        reason: 'One mount is the whole fix. Two is the bug this file exists '
            'to stop coming back; zero means a refused write is silent.');
  });

  test('the mount is handed the router navigator, not the provider', () {
    final mount = _code(_shell)
        .firstWhere((line) => line.contains('AccessDeniedPrompt('));

    // `routerDelegate.navigatorKey`, synchronously, from the object that owns
    // the Navigator. Not `navigatorKeyProvider`: it holds the same key but is
    // published in a `Future.microtask`, so it is still null on the first
    // build and a refusal in that window would be dropped for a reason that
    // has nothing to do with the panel.
    expect(mount, contains('routerDelegate.navigatorKey'));
    expect(mount, isNot(contains('navigatorKeyProvider')));
  });

  test('nothing in the shared package mounts one', () {
    final offenders = <String>[];
    for (final entity in _packageLib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The file that declares the widget, whose own constructor signature
      // reads like a construction.
      if (entity.path.endsWith('access_denied_prompt.dart')) continue;
      for (final line in _code(entity)) {
        if (line.contains('AccessDeniedPrompt(')) {
          offenders.add(entity.path);
          break;
        }
      }
    }

    // `BaseScaffold` is the one that matters — it is where the duplicate came
    // from — but the rule is the general one: a page, a gate or a pane that
    // mounts its own prompt is a second dialog for one refusal, and the page
    // it is on decides how many.
    expect(offenders, isEmpty,
        reason: 'The prompt is mounted once, in centroid-hmi/lib/main.dart, '
            'above the router. A mount inside the package is a mount inside a '
            'page, and the router keeps more than one page alive.');
  });
}
