/// The Session card on the access admin page: the inactivity timeout,
/// finally somewhere an administrator can reach it.
///
/// The value always existed — `access.inactivity_timeout_minutes`, device-
/// local, clamped 1 min..8 h — but changing it meant editing the panel's
/// local store by hand. This section is the knob: current effective value
/// shown, a bounded minutes field, applied live (the session controller
/// re-arms its monitor), one audit row per change.
///
/// Written RED first, against a page with no such section.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/access_session_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;

/// A store whose string reads never answer — the panel account is the only
/// string this card asks for.
class _PendingStringPreferences extends FakeEditorPreferences {
  @override
  Future<String?> getString(String key) => Completer<String?>().future;
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

({Widget app, FakeEditorPreferences prefs, _RecordingSink sink})
    _shell({int? storedMinutes, bool neverExpires = false, String? panelAccount}) {
  final prefs = FakeEditorPreferences();
  if (storedMinutes != null) {
    prefs.setInt(kAccessInactivityMinutesPrefKey, storedMinutes);
  }
  if (neverExpires) {
    prefs.setBool(kAccessInactivityDisabledPrefKey, true);
  }
  if (panelAccount != null) {
    prefs.setString(kAccessPanelAccountPrefKey, panelAccount);
  }
  final sink = _RecordingSink();
  final app = ProviderScope(
    overrides: [
      localPreferencesProvider.overrideWithValue(prefs),
      accessSessionAuditProvider.overrideWithValue(
        (station: 'TEST-STATION', audit: sink),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AccessSessionSection())),
    ),
  );
  return (app: app, prefs: prefs, sink: sink);
}

void main() {
  testWidgets('shows the effective timeout — the default when nothing stored',
      (tester) async {
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
        find.byKey(kAccessSessionTimeoutFieldKey));
    expect(field.controller!.text,
        kDefaultInactivityTimeout.inMinutes.toString());
  });

  testWidgets('shows the stored per-station value when there is one',
      (tester) async {
    final shell = _shell(storedMinutes: 30);
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
        find.byKey(kAccessSessionTimeoutFieldKey));
    expect(field.controller!.text, '30');
  });

  testWidgets('saving writes the local store, and one audit row',
      (tester) async {
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(kAccessSessionTimeoutFieldKey), '45');
    await tester.tap(find.byKey(kAccessSessionSaveKey));
    await tester.pumpAndSettle();

    expect(
        await shell.prefs.getInt(kAccessInactivityMinutesPrefKey), 45,
        reason: 'device-local on purpose — stations sharing one database '
            'keep their own timeout, like the startup URL');

    expect(shell.sink.rows, hasLength(1),
        reason: 'a device-local write bypasses GuardedPreferences, so the '
            'row is recorded here — a quietly shortened or lengthened '
            'elevation window is exactly what the trail exists to show');
    final row = shell.sink.rows.single;
    expect(row.itemKey, kAccessInactivityMinutesPrefKey);
    expect(row.oldValue, kDefaultInactivityTimeout.inMinutes.toString());
    expect(row.newValue, '45');
    expect(row.station, 'TEST-STATION');
    expect(row.allowed, isTrue);
  });

  testWidgets('out-of-range input refuses to save and says why',
      (tester) async {
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    for (final bad in ['0', '481', '']) {
      await tester.enterText(find.byKey(kAccessSessionTimeoutFieldKey), bad);
      await tester.tap(find.byKey(kAccessSessionSaveKey));
      await tester.pumpAndSettle();
    }

    expect(await shell.prefs.getInt(kAccessInactivityMinutesPrefKey), isNull,
        reason: 'the provider clamps as a backstop, but the knob must not '
            'write a value it knows is out of range');
    expect(shell.sink.rows, isEmpty);
    expect(find.text(kAccessSessionRangeError), findsOneWidget);
  });

  testWidgets('the never-expire switch writes the flag, disables the minutes '
      'and records the change', (tester) async {
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kAccessSessionNeverExpireSwitchKey));
    await tester.pumpAndSettle();

    expect(
        await shell.prefs.getBool(kAccessInactivityDisabledPrefKey), isTrue);
    final row = shell.sink.rows.single;
    expect(row.itemKey, kAccessInactivityDisabledPrefKey);
    expect(row.oldValue, 'false');
    expect(row.newValue, 'true');

    final field = tester.widget<TextField>(
        find.byKey(kAccessSessionTimeoutFieldKey));
    expect(field.enabled, isFalse,
        reason: 'a minutes value under a disabled expiry is a number that '
            'does nothing — greying it is what says so');
  });

  testWidgets('turning never-expire back off restores the minutes',
      (tester) async {
    final shell = _shell(storedMinutes: 30, neverExpires: true);
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    final switchBefore = tester.widget<Switch>(find.descendant(
        of: find.byKey(kAccessSessionNeverExpireSwitchKey),
        matching: find.byType(Switch)));
    expect(switchBefore.value, isTrue, reason: 'seeded from the stored flag');

    await tester.tap(find.byKey(kAccessSessionNeverExpireSwitchKey));
    await tester.pumpAndSettle();

    expect(
        await shell.prefs.getBool(kAccessInactivityDisabledPrefKey), isFalse);
    expect(shell.sink.rows.single.newValue, 'false');
    final field = tester.widget<TextField>(
        find.byKey(kAccessSessionTimeoutFieldKey));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '30',
        reason: 'the stored minutes survive the round trip untouched');
  });

  group('the panel account read-out', () {
    testWidgets('names the account a committed panel returns to',
        (tester) async {
      final shell = _shell(panelAccount: 'freezer');
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSessionPanelAccountKey), findsOneWidget);
      expect(find.text(kAccessSessionPanelCommittedNote('freezer')),
          findsOneWidget,
          reason: 'support asking what this panel comes back as had nowhere '
              'to look — the commitment is device-local and is not the '
              'signed-in identity');
    });

    testWidgets('says so plainly when the panel is committed to nobody',
        (tester) async {
      final shell = _shell();
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text(kAccessSessionPanelUncommittedNote), findsOneWidget,
          reason: 'a blank where the account would be reads as "not loaded '
              'yet", not as "there is none"');
    });

    testWidgets('an empty stored value is no commitment, not an account '
        'named ""', (tester) async {
      final shell = _shell(panelAccount: '');
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text(kAccessSessionPanelUncommittedNote), findsOneWidget,
          reason: 'the same rule the resume applies to a half-written '
              'preference file — one function, so the card and the resume '
              'cannot disagree about it');
    });

    testWidgets('claims nothing before the store has answered', (tester) async {
      final prefs = _PendingStringPreferences();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          localPreferencesProvider.overrideWithValue(prefs),
          accessSessionAuditProvider.overrideWithValue(
            (station: 'TEST-STATION', audit: _RecordingSink()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(child: AccessSessionSection())),
        ),
      ));
      await tester.pump();

      expect(find.byKey(kAccessSessionPanelAccountKey), findsNothing,
          reason: 'the two sentences are opposites, so showing either before '
              'the store has answered is a claim, and a card that briefly '
              'calls a committed panel uncommitted is worse than one that '
              'says nothing');
    });
  });

  testWidgets('an unchanged value writes nothing', (tester) async {
    final shell = _shell(storedMinutes: 30);
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kAccessSessionSaveKey));
    await tester.pumpAndSettle();

    expect(shell.sink.rows, isEmpty,
        reason: 'a save that changes nothing must not fake a change row — '
            'the same no-op suppression the write guards apply');
  });
}
