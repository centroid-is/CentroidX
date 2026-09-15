/// The local gateway alarm's mapping: which link states raise it, what it
/// says, and the properties that keep it out of TimescaleDB.
///
/// The alarm this maps to is **client-local by design** — see
/// `lib/core/local_gateway_alarm.dart` for the argument. The arms here pin the
/// properties that argument depends on:
///
///  * it is raised only for the five kinds where the panel is out of touch,
///    and never for a healthy or still-dialling link — an alarm that stands on
///    half the fleet is an alarm surface nobody reads;
///  * its uid lives outside the `ALARM.` key namespace, because it is not a
///    relay key and never crosses the wire;
///  * nothing about it asks to be persisted: no ack required, no pendingAck,
///    `countsAsStop: false`, and its timestamp is the caller's injected
///    instant, never an ambient clock.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/core/local_gateway_alarm.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AlarmKeys;

final Uri _url = Uri.parse('wss://10.50.10.11:9444');
final DateTime _raisedAt = DateTime(2026, 9, 8, 7, 30);

/// A report of [kind], built through the REAL describers wherever one can
/// produce that kind, so the prose the alarm carries is the prose the app
/// actually writes — a hand-built report would pass on a vocabulary the
/// mapper no longer speaks.
GatewayLinkReport _report(GatewayLinkKind kind) => switch (kind) {
      GatewayLinkKind.connected => describeGatewayLink(
          state: LinkState.ready, url: _url, elapsed: Duration.zero),
      GatewayLinkKind.connecting => describeGatewayLink(
          state: LinkState.connecting,
          url: _url,
          elapsed: const Duration(seconds: 2)),
      GatewayLinkKind.unreachable => describeGatewayLink(
          state: LinkState.down,
          url: _url,
          elapsed: const Duration(minutes: 3),
          lastDownReason: GatewayLinkReasons.transportEnded),
      GatewayLinkKind.untrustedCertificate => describeGatewayLink(
          state: LinkState.down,
          url: _url,
          elapsed: const Duration(seconds: 20),
          lastDownReason: GatewayLinkReasons.certificateNotTrusted),
      GatewayLinkKind.credentialRefused => describeGatewayLink(
          state: LinkState.down,
          url: _url,
          elapsed: const Duration(seconds: 20),
          stopReason: GatewayLinkReasons.credentialRefused),
      GatewayLinkKind.versionRefused => describeGatewayLink(
          state: LinkState.down,
          url: _url,
          elapsed: const Duration(seconds: 20),
          stopReason: GatewayLinkReasons.versionRefused),
      GatewayLinkKind.notBuilt => describeGatewayLinkFailure(
          url: _url,
          failure: const GatewayLinkBuildFailure(
              raw: 'PathNotFoundException: /etc/centroid/ca.pem',
              path: '/etc/centroid/ca.pem')),
    };

void main() {
  group('which kinds raise the alarm', () {
    /// Total over the enum ON PURPOSE: a kind added to
    /// `GatewayLinkKind` without a row here fails below with its name,
    /// rather than silently falling to whatever the mapper's newest arm
    /// happened to say.
    const expectedTitle = <GatewayLinkKind, String?>{
      GatewayLinkKind.connected: null,
      GatewayLinkKind.connecting: null,
      GatewayLinkKind.unreachable: 'Gateway unreachable',
      GatewayLinkKind.untrustedCertificate: 'Gateway certificate refused',
      GatewayLinkKind.credentialRefused: 'Gateway refused this panel',
      GatewayLinkKind.versionRefused: 'Gateway refused this build',
      GatewayLinkKind.notBuilt: 'Panel misconfigured',
    };

    for (final kind in GatewayLinkKind.values) {
      test(kind.name, () {
        expect(expectedTitle.containsKey(kind), isTrue,
            reason: 'GatewayLinkKind.${kind.name} has no expected outcome '
                'here — a new kind must be mapped deliberately, in the mapper '
                'AND in this table.');
        final alarm = localGatewayAlarm(_report(kind), raisedAt: _raisedAt);
        final title = expectedTitle[kind];
        if (title == null) {
          expect(alarm, isNull,
              reason: 'a ${kind.name} link must raise no alarm — an alarm '
                  'that stands while the link is healthy (or still inside '
                  'the first-dial patience) is how the surface stops being '
                  'read');
        } else {
          expect(alarm, isNotNull,
              reason: '${kind.name} means this panel is out of touch and '
                  'the alarm surface must say so');
          expect(alarm!.alarm.config.title, title);
        }
      });
    }
  });

  test('direct mode: a null report raises nothing', () {
    expect(localGatewayAlarm(null, raisedAt: _raisedAt), isNull);
  });

  group('the alarm it raises', () {
    test('is an error, active, and carries the injected instant', () {
      final report = _report(GatewayLinkKind.unreachable);
      final alarm = localGatewayAlarm(report, raisedAt: _raisedAt)!;

      expect(alarm.notification.rule.level, AlarmLevel.error,
          reason: 'a panel that cannot reach its gateway is showing stale '
              'values on every page — that is a genuine fault, and error is '
              'the alarm surface\'s fault level');
      expect(alarm.notification.active, isTrue);
      expect(alarm.notification.timestamp, _raisedAt,
          reason: 'the stamp is the caller\'s injected instant — the mapper '
              'must never read an ambient clock, or every golden of this '
              'alarm churns per run');
    });

    test('carries the report\'s own prose, both sentences', () {
      final report = _report(GatewayLinkKind.unreachable);
      final alarm = localGatewayAlarm(report, raisedAt: _raisedAt)!;
      expect(alarm.alarm.config.description, contains(report.headline),
          reason: 'the headline names the endpoint; losing it would make '
              'the alarm say less than the chip it replaced');
      expect(alarm.alarm.config.description, contains(report.detail),
          reason: 'the detail names the end of the wire to go and check — '
              'the operator action is the point of distinguishing the kinds');
    });

    test('the misconfigured panel is told to fix the station, not the wire',
        () {
      final report = _report(GatewayLinkKind.notBuilt);
      final alarm = localGatewayAlarm(report, raisedAt: _raisedAt)!;
      expect(alarm.alarm.config.title, 'Panel misconfigured');
      expect(alarm.alarm.config.description,
          contains('/etc/centroid/ca.pem'),
          reason: 'a build failure that named a file must surface the file '
              '— that is the 15-08 gap this alarm absorbs from the chip');
    });

    test('asks for nothing the alarm engine would have to store', () {
      final alarm =
          localGatewayAlarm(_report(GatewayLinkKind.unreachable), raisedAt: _raisedAt)!;
      expect(alarm.notification.rule.acknowledgeRequired, isFalse,
          reason: 'an ack would have to be recorded somewhere, and there is '
              'deliberately nowhere — the alarm clears itself when the link '
              'returns');
      expect(alarm.pendingAck, isFalse);
      expect(alarm.deactivated, isNull);
      expect(alarm.alarm.config.countsAsStop, isFalse,
          reason: 'a lost panel link is not plant downtime');
      expect(alarm.notification.expression, isNull,
          reason: 'the raw client reason is ticket text, not operator prose '
              '— the Transport card is where a support engineer reads it');
    });

    test('its uid is deliberately outside the ALARM. key namespace', () {
      // Live control first: the predicate does reject and accept.
      expect(AlarmKeys.isAlarmKey(AlarmKeys.active), isTrue,
          reason: 'control — if this fails the predicate itself is broken '
              'and the arm below proves nothing');
      expect(AlarmKeys.isAlarmKey(kLocalGatewayAlarmUid), isFalse,
          reason: 'ALARM.* is the reserved relay-key namespace, owned by '
              'the backend\'s alarm engine and spelled in exactly one file. '
              'This uid is not a key: it names nothing on the wire, is '
              'never subscribed, and must not read as if the backend '
              'produced it.');
      final alarm =
          localGatewayAlarm(_report(GatewayLinkKind.unreachable), raisedAt: _raisedAt)!;
      expect(alarm.alarm.config.uid, kLocalGatewayAlarmUid);
      expect(alarm.notification.uid, kLocalGatewayAlarmUid);
    });
  });
}
