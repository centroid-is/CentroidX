import 'dart:io';

import 'package:centroidx_setup/answers.dart';
import 'package:centroidx_setup/main.dart';
import 'package:centroidx_setup/system.dart';
import 'package:centroidx_setup/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The last screen of an install, which is the one the operator cannot walk
/// away from: there is no back, and the only two ways off it are Reboot and
/// (on a failed install) Power off.
///
/// What was reported: the machine did not reboot and the screen said nothing
/// about why. It did say something -- a line appended to the log -- but the log
/// is a 300px window already scrolled to its end, so the line landed one row
/// below the fold and no operator ever saw it.
void main() {
  final defaultRunProcess = runProcess;
  final defaultGrace = shutdownGrace;

  setUp(() {
    // Every rung refuses, instantly. The ladder itself is pinned in
    // shutdown_test.dart; what is under test here is what the screen does once
    // it has run out of rungs.
    runProcess = (exe, args) async => ProcessResult(0, 1, '', 'refused by pid 1');
    shutdownGrace = Duration.zero;
  });

  tearDown(() {
    runProcess = defaultRunProcess;
    shutdownGrace = defaultGrace;
  });

  /// A [ProgressStep] whose install has already finished with [exitCode] and
  /// left [lines] behind it. Nothing here may reach the real installer, which
  /// wipes a disk.
  Widget progress({int exitCode = 0, int lines = 400}) => MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SafeArea(
            child: ProgressStep(
              answers: Answers()..targetDisk = 'sda',
              install: (answers, {required onLine}) async {
                for (var i = 0; i < lines; i++) {
                  onLine('installer line $i');
                }
                return InstallResult(exitCode, null);
              },
            ),
          ),
        ),
      );

  Future<void> pumpAt(WidgetTester tester, Widget w, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('says so on screen when every rung refuses to reboot',
      (tester) async {
    await pumpAt(tester, progress(), const Size(1920, 1080));

    expect(find.text('Reboot'), findsOneWidget);
    await tester.tap(find.text('Reboot'));
    await tester.pumpAndSettle();

    // Not in the log, where it went unread: in its own bordered box, with the
    // one instruction that is still true -- the disk IS installed, so the
    // operator wants the power switch, not another attempt at the install.
    expect(find.text('This machine refused to shut down.'), findsOneWidget);
    expect(find.textContaining('systemctl --force --force reboot'),
        findsWidgets);
    expect(find.textContaining('power the machine off at the switch'),
        findsOneWidget);
  });

  testWidgets('hands the button back, so a second press is possible',
      (tester) async {
    await pumpAt(tester, progress(), const Size(1920, 1080));
    await tester.tap(find.text('Reboot'));
    await tester.pumpAndSettle();

    // It used to grey out on the first press and stay that way for good, which
    // is what "the reboot button does not work" looked like from the panel.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  testWidgets('scrolls the log to a line appended after the install',
      (tester) async {
    await pumpAt(tester, progress(), const Size(1920, 1080));
    await tester.tap(find.text('Reboot'));
    await tester.pumpAndSettle();

    // The failure is also in the log, and the log is only useful if it is
    // showing the end of itself. A ListView does not build what it has scrolled
    // past, so findsOneWidget here IS the assertion that it scrolled.
    expect(find.text('Reboot failed:'), findsOneWidget);
  });

  testWidgets('a failed install offers Power off, and it escalates too',
      (tester) async {
    final asked = <List<String>>[];
    runProcess = (exe, args) async {
      asked.add(args);
      return ProcessResult(0, 1, '', 'refused by pid 1');
    };

    await pumpAt(tester, progress(exitCode: 1), const Size(1920, 1080));
    await tester.tap(find.text('Power off'));
    await tester.pumpAndSettle();

    expect(asked.last, ['--force', '--force', 'poweroff']);
    expect(find.text('This machine refused to shut down.'), findsOneWidget);
    // The install failed, so the disk was erased on the way out: nothing about
    // that changes because the machine also would not power down.
    expect(find.text('The disk was not installed.'), findsOneWidget);
  });
}
