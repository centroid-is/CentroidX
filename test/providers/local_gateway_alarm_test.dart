/// The local gateway alarm provider: raised from the link report, latched to
/// the outage, gone the moment the link returns — and provably never anywhere
/// near the alarm engine or the database.
///
/// The one hard constraint on this feature is that the alarm never touches
/// TimescaleDB: no `alarm_history` row, no definition row, no backend
/// evaluation. The last group here is that constraint made observable at the
/// provider level — the whole dependency closure of a read is enumerated, and
/// the alarm plumbing is not in it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/core/local_gateway_alarm.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/providers/local_gateway_alarm.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

final Uri _url = Uri.parse('wss://10.50.10.11:9444');

GatewayLinkReport _down({String reason = 'the transport ended'}) =>
    describeGatewayLink(
      state: LinkState.down,
      url: _url,
      elapsed: const Duration(minutes: 1),
      lastDownReason: reason,
    );

GatewayLinkReport _up() => describeGatewayLink(
    state: LinkState.ready, url: _url, elapsed: Duration.zero);

GatewayLinkReport _refused() => describeGatewayLink(
      state: LinkState.down,
      url: _url,
      elapsed: const Duration(minutes: 1),
      stopReason: GatewayLinkReasons.credentialRefused,
    );

/// A container whose link report is fed by [reports] and whose clock is
/// [now]'s current value — the two injection points this provider has.
({
  ProviderContainer container,
  StreamController<GatewayLinkReport?> reports,
}) _harness(DateTime Function() clock) {
  final reports = StreamController<GatewayLinkReport?>();
  final container = ProviderContainer(overrides: [
    gatewayLinkProvider.overrideWith((ref) => reports.stream),
    gatewayLinkClockProvider.overrideWithValue(clock),
  ]);
  addTearDown(container.dispose);
  addTearDown(reports.close);
  return (container: container, reports: reports);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('direct mode: the null report raises no alarm — HALF THE FLEET', () async {
    // Direct stations publish exactly null from gatewayLinkProvider. An alarm
    // that is always on for those panels is how alarm surfaces get ignored,
    // so this arm is the one that must never break.
    final h = _harness(() => DateTime(2026, 9, 8, 7, 0));
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});
    h.reports.add(null);
    await _settle();
    expect(sub.read(), isNull);
  });

  test('no report yet (link provider still loading): no alarm', () async {
    final h = _harness(() => DateTime(2026, 9, 8, 7, 0));
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});
    await _settle();
    expect(sub.read(), isNull);
  });

  test('a healthy link raises nothing; a lost one raises the alarm, stamped '
      'from the injected clock', () async {
    var now = DateTime(2026, 9, 8, 7, 0);
    final h = _harness(() => now);
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});

    h.reports.add(_up());
    await _settle();
    expect(sub.read(), isNull);

    now = DateTime(2026, 9, 8, 7, 5);
    h.reports.add(_down());
    await _settle();
    final alarm = sub.read();
    expect(alarm, isNotNull);
    expect(alarm!.alarm.config.title, 'Gateway unreachable');
    expect(alarm.notification.timestamp, DateTime(2026, 9, 8, 7, 5),
        reason: 'the raise instant comes from gatewayLinkClockProvider — '
            'nothing here may call DateTime.now()');
  });

  test('the instance is stable while the prose stands', () async {
    var now = DateTime(2026, 9, 8, 7, 0);
    final h = _harness(() => now);
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});

    h.reports.add(_down());
    await _settle();
    final first = sub.read();

    // A different raw tail, same kind, same sentences: the report is a new
    // object, the alarm must not be — the Alarm View retains selection and
    // the history dedupe works by identity elsewhere on this surface.
    now = DateTime(2026, 9, 8, 7, 9);
    h.reports.add(_down(reason: 'the transport ended: os error 54'));
    await _settle();
    expect(identical(sub.read(), first), isTrue);
  });

  test('the outage start survives a change of prose AND a change of kind',
      () async {
    var now = DateTime(2026, 9, 8, 7, 0);
    final h = _harness(() => now);
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});

    h.reports.add(_down());
    await _settle();
    expect(sub.read()!.notification.timestamp, DateTime(2026, 9, 8, 7, 0));

    // Ten minutes in, the gateway answers — and refuses the credential. The
    // operator's question is still "since when has this panel been out of
    // touch", so the stamp holds while the title moves to the new action.
    now = DateTime(2026, 9, 8, 7, 10);
    h.reports.add(_refused());
    await _settle();
    final refused = sub.read()!;
    expect(refused.alarm.config.title, 'Gateway refused this panel');
    expect(refused.notification.timestamp, DateTime(2026, 9, 8, 7, 0),
        reason: 'one outage, one start instant — re-stamping on every kind '
            'change would make the alarm look freshly raised all night');
  });

  test('recovery clears it; a NEW outage is stamped fresh', () async {
    var now = DateTime(2026, 9, 8, 7, 0);
    final h = _harness(() => now);
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});

    h.reports.add(_down());
    await _settle();
    expect(sub.read(), isNotNull);

    h.reports.add(_up());
    await _settle();
    expect(sub.read(), isNull,
        reason: 'ephemeral: the alarm disappears when the link returns — '
            'there is deliberately no history entry to linger in');

    now = DateTime(2026, 9, 8, 9, 30);
    h.reports.add(_down());
    await _settle();
    expect(sub.read()!.notification.timestamp, DateTime(2026, 9, 8, 9, 30),
        reason: 'a second outage is a second event, not a resumption of the '
            'first');
  });

  test('NEVER reaches the alarm engine, the preferences store or the '
      'database', () async {
    var now = DateTime(2026, 9, 8, 7, 0);
    final h = _harness(() => now);
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});
    h.reports.add(_down());
    await _settle();
    expect(sub.read(), isNotNull);

    final instantiated =
        h.container.getAllProviderElements().map((e) => e.origin).toSet();

    // Live control: the enumeration does see what a read instantiates.
    expect(instantiated, contains(localGatewayAlarmProvider),
        reason: 'control — if the element scan is blind the three '
            'assertions below prove nothing');

    // The constraint itself. `alarmManProvider` is the only object that can
    // put an alarm anywhere near persistence (and on a panel even IT cannot:
    // history is written by the backend's AlarmHistoryWriter, which never
    // hears of this uid). `preferencesProvider` is the DB-backed store;
    // `stateManProvider` is the transport. Raising and reading the local
    // alarm must instantiate none of them.
    expect(instantiated, isNot(contains(alarmManProvider)),
        reason: 'the local alarm must never enter an AlarmSource — that is '
            'the road to ackAlarm crossing the wire and to history rows');
    expect(instantiated, isNot(contains(preferencesProvider)),
        reason: 'nothing about this alarm is stored, not even as a pref');
    expect(instantiated, isNot(contains(stateManProvider)),
        reason: 'an alarm about a dead link cannot be reported through the '
            'dead link');
  });

  test('an errored link provider reads as no alarm, not as a crash',
      () async {
    final reports = StreamController<GatewayLinkReport?>();
    final container = ProviderContainer(overrides: [
      gatewayLinkProvider.overrideWith((ref) => reports.stream),
      gatewayLinkClockProvider
          .overrideWithValue(() => DateTime(2026, 9, 8, 7, 0)),
    ]);
    addTearDown(container.dispose);
    addTearDown(reports.close);
    final sub = container.listen(localGatewayAlarmProvider, (_, __) {});
    reports.addError(StateError('link status stream broke'));
    await _settle();
    expect(sub.read(), isNull,
        reason: 'a link-status provider that cannot say what the link is '
            'doing cannot honestly raise an alarm about it');
  });

  test('the uid it publishes is the one spelling', () async {
    final h = _harness(() => DateTime(2026, 9, 8, 7, 0));
    final sub = h.container.listen(localGatewayAlarmProvider, (_, __) {});
    h.reports.add(_down());
    await _settle();
    expect(sub.read()!.alarm.config.uid, kLocalGatewayAlarmUid);
  });
}
