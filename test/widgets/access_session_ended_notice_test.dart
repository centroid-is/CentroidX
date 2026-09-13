/// The line that says a session ended.
///
/// Fires on the elevated-to-anonymous transition and on nothing else, and says
/// where the way back in is. The point is not the snack bar: it is that an
/// operator who did not watch the app bar change can still tell a panel that
/// signed itself out from a panel that has hung.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_session_ended_notice.dart';
import 'package:tfc_access/tfc_access.dart';

class _DrivenSession extends AccessSessionController {
  _DrivenSession(this._initial);

  final AccessSession _initial;

  @override
  Future<AccessSession> build() async => _initial;

  void set(AccessSession next) => state = AsyncData(next);
}

AccessSession _elevated() => AccessSession(
      user: const AuthenticatedUser(
        username: 'centroid',
        roleName: 'Engineering',
        displayName: 'centroid',
      ),
      groups: AccessGroup.values.toSet(),
      expiresAt: DateTime.utc(2026, 9, 11, 14, 38),
    );

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

Future<_DrivenSession> _pump(
  WidgetTester tester, {
  required AccessSession initial,
}) async {
  final session = _DrivenSession(initial);
  await tester.pumpWidget(ProviderScope(
    overrides: [accessSessionProvider.overrideWith(() => session)],
    child: const MaterialApp(
      home: Scaffold(body: AccessSessionEndedNotice()),
    ),
  ));
  await tester.pump();
  return session;
}

void main() {
  testWidgets('the session ending says so, and says where to sign in',
      (tester) async {
    final session = await _pump(tester, initial: _elevated());
    expect(find.text(kAccessSessionEndedMessage), findsNothing);

    session.set(_anonymous());
    await tester.pump();
    await tester.pump();

    expect(find.text(kAccessSessionEndedMessage), findsOneWidget);
    // The way back in is named, not merely implied — the app bar is where
    // AccessStatusAction lives.
    expect(kAccessSessionEndedMessage, contains('top bar'));
  });

  testWidgets('an anonymous panel starting up says nothing', (tester) async {
    await _pump(tester, initial: _anonymous());
    await tester.pump();
    await tester.pump();

    expect(find.text(kAccessSessionEndedMessage), findsNothing);
  });

  testWidgets('signing in says nothing', (tester) async {
    final session = await _pump(tester, initial: _anonymous());

    session.set(_elevated());
    await tester.pump();
    await tester.pump();

    expect(find.text(kAccessSessionEndedMessage), findsNothing);
  });

  testWidgets('it contributes no visible box of its own', (tester) async {
    await _pump(tester, initial: _elevated());
    expect(
      tester.getSize(find.byType(AccessSessionEndedNotice)),
      Size.zero,
    );
  });
}
