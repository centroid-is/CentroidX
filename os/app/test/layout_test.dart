import 'package:centroidx_setup/answers.dart';
import 'package:centroidx_setup/main.dart';
import 'package:centroidx_setup/system.dart';
import 'package:centroidx_setup/theme.dart';
import 'package:centroidx_setup/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Rect _globalRect(WidgetTester tester, Finder f) {
  final ro = tester.renderObject(f);
  return MatrixUtils.transformRect(ro.getTransformTo(null), ro.paintBounds);
}

/// The on-screen keyboard's inset, which is what makes this reproduce.
///
/// A `SingleChildScrollView` only clips once it can actually scroll, so on an
/// idle 1080-tall panel the step fits and the overhanging label is painted in
/// full. Raising the keyboard shrinks the viewport by ~200px, the content
/// starts scrolling, the clip engages — and the operator, who is typing, is
/// exactly the person for whom the keyboard is up. Remove this and the test
/// still fails for the right reason (the assertion is on geometry, not on
/// pixels), but it stops describing the bug that was reported.
const double _keyboardInset = 200;

Widget _step({List<Widget>? body, Widget? secondary}) => MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              viewInsets: const EdgeInsets.only(bottom: _keyboardInset)),
          child: Scaffold(
            body: SafeArea(
              child: Form(
                child: SetupStep(
                  title: 'Station',
                  subtitle: 'A subtitle, as every real step has.',
                  body: body ??
                      [
                        Field(
                          label: 'Station name',
                          helper: 'Shown in the browser tab, and the hostname',
                          initial: '',
                          validator: validateStationName,
                          onChanged: (_) {},
                        ),
                        PasswordField(
                          label: "Password for the 'centroid' login",
                          helper: 'The operator account on this machine',
                          initial: '',
                          onChanged: (_) {},
                        ),
                      ],
                  secondary: secondary,
                  primary: FilledButton(
                      onPressed: () {}, child: const Text('Continue')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('the first field on a step', () {
    // An operator reported "the text field label gets cut off the top" while
    // typing the station name. A SingleChildScrollView clips at its own edge,
    // and Material paints a floated OutlineInputBorder label straddling the
    // field's top border -- so the first field on every step lost the top
    // 5.75px of its label the moment it floated. Asserted as geometry rather
    // than as a golden because the number is the bug: a golden of Ahem boxes
    // would have looked plausible either way.
    for (final size in const [
      Size(1920, 1080),
      Size(1280, 800),
      Size(1024, 600),
    ]) {
      testWidgets('keeps its floated label inside the scroll view @ $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_step());
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).first, 'st-101');
        await tester.pumpAndSettle();

        final viewport = _globalRect(tester, find.byType(Scrollable).first);
        final label = _globalRect(tester, find.text('Station name'));

        expect(label.top, greaterThanOrEqualTo(viewport.top),
            reason: 'the label is painted ${viewport.top - label.top}px above '
                'the clip rect, so that much of it is invisible');
      });
    }

    testWidgets('reserves no more room than the label actually needs',
        (tester) async {
      // The fix moved 8px from the subtitle gap into the scroll view's
      // padding, so the visible gap under the subtitle is unchanged. If
      // labelOverhang grows without that SizedBox shrinking, this catches it.
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_step());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'st-101');
      await tester.pumpAndSettle();

      final subtitle =
          _globalRect(tester, find.text('A subtitle, as every real step has.'));
      final decorator = _globalRect(tester, find.byType(InputDecorator).first);
      // 24, the same as before the fix: the SizedBox above the scroll view
      // gave up exactly the 8px the scroll view took as padding.
      expect(decorator.top - subtitle.bottom, closeTo(24, 1));
    });
  });

  group('a failed install', () {
    // The action row used to be a single disabled button reading "Failed",
    // which restated the title, did nothing, and left the operator with the
    // power switch as the only way off the screen.
    testWidgets('offers Reboot and Power off, both live', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_step(
        body: const [SizedBox(height: 10)],
        secondary:
            OutlinedButton(onPressed: powerOff, child: const Text('Power off')),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Power off'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNotNull);
    });
  });

  group('the address bar', () {
    testWidgets('shows every address it is given', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AddressBar(
            probe: () async => ['10.104.29.5', '192.168.1.20'],
            interval: const Duration(days: 1),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('10.104.29.5  ·  192.168.1.20'), findsOneWidget);
    });

    testWidgets('says so when there is no network', (tester) async {
      // An unplugged cable is the case worth seeing, not the case to hide.
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AddressBar(
            probe: () async => const [],
            interval: const Duration(days: 1),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('no network'), findsOneWidget);
    });

    testWidgets('carries the remote-access credential once there is one',
        (tester) async {
      // The address and the code are only useful together: an address with no
      // code is a login prompt nobody can answer, and a code with no address is
      // nothing at all. This line is what one person reads to another.
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AddressBar(
            probe: () async => ['10.104.29.5'],
            codeProbe: () async => 'k4m2p9qd',
            interval: const Duration(days: 1),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('https://10.104.29.5   root / k4m2p9qd'), findsOneWidget);
    });

    test('the header line says only what is true', () {
      // https, never http: noVNC's RA2ne handshake needs window.crypto.subtle,
      // which browsers withhold on an insecure origin, so an http URL loads a
      // page that then cannot authenticate at all.
      expect(_AddressBarDescribe.call(['10.0.0.9'], 'abcd2345'),
          'https://10.0.0.9   root / abcd2345');
      // No credential unit means the remote view is unreachable whatever is
      // typed, so no URL is offered.
      expect(_AddressBarDescribe.call(['10.0.0.9'], null), '10.0.0.9');
      expect(_AddressBarDescribe.call(['10.0.0.9', '192.168.1.4'], null),
          '10.0.0.9  ·  192.168.1.4');
      expect(_AddressBarDescribe.call(const [], 'abcd2345'), 'no network');
      expect(_AddressBarDescribe.call(const [], null), 'no network');
    });

    testWidgets('picks up a DHCP lease that arrives after start',
        (tester) async {
      // The app is on screen within a couple of seconds of boot, which is
      // usually before the lease lands. Polling is the whole point of the
      // timer; without it the bar would read "no network" for the entire
      // install on every machine.
      var leased = false;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AddressBar(
            probe: () async => leased ? ['10.0.0.9'] : const [],
            interval: const Duration(seconds: 1),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('no network'), findsOneWidget);

      leased = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('10.0.0.9'), findsOneWidget);
    });
  });
}

/// `AddressBar.describe` is on the private State class, so reach it through a
/// named alias rather than making the widget's API wider for a test.
class _AddressBarDescribe {
  static String call(List<String> addresses, String? code) =>
      addressBarDescribe(addresses, code);
}
