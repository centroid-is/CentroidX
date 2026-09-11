@TestOn('vm')

/// D-05: every authorization decision the relay's decorator makes writes an
/// audit row — refusals **before** the `forbidden` is thrown — and the sink
/// that receives them can neither stall nor stop a plant write.
///
/// Sweep §3.12 point 2 called a gateway refusal "the one kind of guard nobody
/// can audit afterwards": it left nothing behind. These arms are that entry
/// closing. The counter-rule is `audit_trail_store.dart`'s: reads record
/// nothing, because a guard that wrote a row every time somebody scrolled the
/// trail would bury the trail in itself. And the sink discipline is
/// `lib/providers/access.dart`'s, quoted where the decorator applies it: a
/// plant that stops because the audit database blinked is worse than a gap in
/// the trail.
///
/// In process, deliberately: the sink is a constructor argument on
/// `PolicyStateMan` so it can be tested here first — `RelayServer` grows the
/// parameter in 17-09, and the wire-level composition is that plan's to judge.
@Tags(['ws'])
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show Quality;
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/error_reporter.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

/// A real tag, seeded, so the read arms read something.
const _key = 'CN01.MOT01.speed';

/// The identity every allowed-path arm asks as: the station, the username and
/// the role name are what the rows must carry, so they are distinctive.
final _panel = stationHolding(const {AccessGroup.operate},
    station: 'ST101', username: 'ST101-panel', roleName: 'Line Panel');

/// Holds nothing — every graded write is refused.
final _display = stationHolding(const <AccessGroup>{},
    station: 'HALL-DISPLAY', username: 'hall-display', roleName: 'Wall');

/// An [AuditSink] that keeps every row and stamps each with a shared counter,
/// so "the deny row was written before the throw" is an ordering FACT rather
/// than an inspection.
final class _RecordingSink implements AuditSink {
  _RecordingSink(this._tick);

  final int Function() _tick;
  final rows = <AuditRecord>[];
  final stamps = <int>[];

  @override
  Future<void> record(AuditRecord entry) async {
    rows.add(entry);
    stamps.add(_tick());
  }
}

/// A sink whose write throws synchronously — the audit database being down.
final class _ThrowingSink implements AuditSink {
  int attempts = 0;

  @override
  Future<void> record(AuditRecord entry) {
    attempts++;
    throw StateError('the audit database is down');
  }
}

/// A sink whose write fails asynchronously — the other way a database fails,
/// and the one `unawaited()` silently converts into an unhandled error.
final class _AsyncFailingSink implements AuditSink {
  int attempts = 0;

  @override
  Future<void> record(AuditRecord entry) {
    attempts++;
    return Future<void>.error(StateError('the audit database went away'));
  }
}

/// A sink whose write completes only when the case says so.
final class _SlowSink implements AuditSink {
  final gate = Completer<void>();
  final rows = <AuditRecord>[];

  @override
  Future<void> record(AuditRecord entry) {
    rows.add(entry);
    return gate.future;
  }
}

({FakePreferences store, PolicyStateMan served}) _seenBy(
  StationIdentity? identity, {
  AuditSink? sink,
  KeyPolicy policy = const AccessPolicyKeyPolicy(),
  void Function(Object error, StackTrace stack, String where)? onAuditError,
}) {
  final store = FakePreferences();
  final plant = FakeStateMan(preferences: store);
  addTearDown(plant.dispose);
  return (
    store: store,
    served: PolicyStateMan(
      source: plant,
      policy: policy,
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => identity,
      sink: sink ?? const NullAuditSink(),
      onAuditError: onAuditError ?? reportToStderr,
    ),
  );
}

/// Runs [call] expecting a refusal — which the gate raises **synchronously**,
/// before any Future exists, so a `throwsA` over the expression never sees it.
Future<rpc.RpcException> _refusedAudit(Future<void> Function() call) async {
  try {
    await call();
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('the call was answered instead of refused');
}

void main() {
  group('a row per decision', () {
    test('an allowed preference write records one row, and the row is whole',
        () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_panel, sink: sink);

      await seat.served.preferences.setString('theme_mode', 'dark');

      expect(sink.rows, hasLength(1),
          reason: 'one decision, one row — an allowed write that recorded '
              'nothing is §3.12 point 2 unclosed, and one that recorded twice '
              'is a trail that cannot be counted');
      final row = sink.rows.single;
      expect(row.allowed, isTrue);
      expect(row.surface, 'pref',
          reason: 'the same surface string the app\'s guard writes for the '
              'same table, so one trail filters both');
      expect(row.itemKey, 'theme_mode');
      expect(row.groupRequired, 'operate',
          reason: 'the group the policy answered for this key — never one the '
              'decorator named itself');
      expect(row.who, 'ST101-panel',
          reason: 'the resolver-verified username (ACCESS-06): the row names '
              'who the server looked up, not what a file claimed');
      expect(row.station, 'ST101');
      expect(row.roleName, 'Line Panel');
      expect(row.origin, 'relay',
          reason: 'the column that says this row came over the wire rather '
              'than from a keyboard');
      expect(row.actionId, 'preferences.setString',
          reason: 'the wire method, so the trail says which door the write '
              'came through');
    });

    test('a refused write records one row with allowed: false — before the '
        'throw', () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_display, sink: sink);

      int caughtAt = 0;
      try {
        await seat.served.preferences.setString('key_mappings', '{}');
        fail('the write was answered instead of refused');
      } on rpc.RpcException catch (error) {
        caughtAt = ++order;
        expect(error.code, ServerErrorCodes.forbidden);
      }

      expect(sink.rows, hasLength(1),
          reason: 'a refusal that leaves no trace is the one kind of guard '
              'nobody can audit afterwards');
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.stamps.single, lessThan(caughtAt),
          reason: 'deny-row-before-throw, asserted by counter: the sink '
              'stamped ${sink.stamps.single} and the catch stamped $caughtAt. '
              'A row written after the throw is a row that is not written '
              'when the throw is the last thing the handler does');
      expect(sink.rows.single.groupRequired, 'configure',
          reason: 'D-03: key_mappings grades as configure, and the deny row '
              'names the group the station would have needed — which is how '
              'a role configured too tightly is found from the trail');
      expect(sink.rows.single.who, 'hall-display');
    });

    test('a refused write records exactly one row, not two and not one per '
        'internal step', () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_display, sink: sink);

      await _refusedAudit(
          () => seat.served.preferences.setString('collector_config', '{}'));

      expect(sink.rows, hasLength(1),
          reason: 'one refusal, one row. Two rows for one decision is a trail '
              'that double-counts denials; zero is §3.12 point 2');
    });

    test('a refused history-view delete records a row naming the surface and '
        'the group', () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_panel, sink: sink);

      await _refusedAudit(() => seat.served.historyViews.deleteHistoryView(7));

      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.surface, 'history_view',
          reason: 'the surface 17-01 moved these rows onto — the app\'s guard '
              'writes the same string for the same operation');
      expect(sink.rows.single.groupRequired, 'configure',
          reason: 'D-04: deleting a saved view takes configure, and the row '
              'says so');
      expect(sink.rows.single.allowed, isFalse);
    });
  });

  group('what records nothing', () {
    test('reads record nothing — and a write in the same test records one',
        () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_panel, sink: sink);
      final plant = seat.served;

      // Every read surface the decorator owns an answer for.
      plant.keys;
      plant.read(_key);
      await plant.readMany(const [_key]);
      await seat.served.preferences.getString('theme_mode');
      await seat.served.preferences.getKeys();
      await seat.served.historyViews.selectHistoryViews();

      expect(sink.rows, isEmpty,
          reason: 'a guard that wrote a row every time somebody read would '
              'bury the trail in itself — the defect audit_trail_store.dart '
              'refuses by design, and the same reasoning holds here');

      // Anti-vacuity: the same composition records a write, so the emptiness
      // above is reads-record-nothing rather than a sink nothing reaches.
      await seat.served.preferences.setString('theme_mode', 'dark');
      expect(sink.rows, hasLength(1));
    });

    test('a hidden key records nothing, and the caller gets the '
        'nonexistent-tag answer', () async {
      var order = 0;
      final sink = _RecordingSink(() => ++order);
      final seat = _seenBy(_panel,
          sink: sink, policy: ScriptedPolicy.hiding(const {_key}));

      final answer = await seat.served.readFresh(_key);

      expect(answer.quality, Quality.errorConfig,
          reason: 'the nonexistent-tag shape, not a forbidden: an absent key '
              'is not a refusal, and answering forbidden would tell the '
              'asker the key exists');
      expect(sink.rows, isEmpty,
          reason: 'writing a row for a hidden key would leak, into the '
              'trail, the existence the hiding rule conceals — a trail '
              'reader may not be someone the hiding rule trusts');
    });
  });

  group('the sink cannot take the plant down', () {
    test('a synchronously throwing sink changes no outcome — both halves',
        () async {
      final errors = <Object>[];
      final sink = _ThrowingSink();

      // The allow half: the write still applies.
      final allowed = _seenBy(_panel,
          sink: sink, onAuditError: (error, stack, where) => errors.add(error));
      await allowed.served.preferences.setString('theme_mode', 'dark');
      expect(await allowed.store.getString('theme_mode'), 'dark',
          reason: 'the write must land although its audit row did not: a '
              'plant that stops because the audit database blinked is worse '
              'than a gap in the trail');

      // The refuse half — the subtle one: a try/catch around the sink that
      // also swallows the forbidden converts a refusal into a pass.
      final refused = _seenBy(_display,
          sink: sink, onAuditError: (error, stack, where) => errors.add(error));
      final refusal = await _refusedAudit(
          () => refused.served.preferences.setString('key_mappings', '{}'));
      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'still refused: the sink failing must not fail the refusal '
              'open');
      expect(await refused.store.containsKey('key_mappings'), isFalse,
          reason: 'and still pre-effect');

      expect(sink.attempts, 2,
          reason: 'both decisions reached the sink — the containment is '
              'around the sink, not instead of it');
      expect(errors, hasLength(2),
          reason: 'and both failures were logged rather than swallowed: an '
              'absent audit row is the one defect nobody ever notices');
    });

    test('an asynchronously failing sink changes no outcome and is caught',
        () async {
      // `unawaited()` attaches no handler, so this half is what forces the
      // catchError: a Future.error left unhandled kills the isolate long
      // after the write succeeded.
      final errors = <Object>[];
      final sink = _AsyncFailingSink();
      final seat = _seenBy(_panel,
          sink: sink, onAuditError: (error, stack, where) => errors.add(error));

      await seat.served.preferences.setString('theme_mode', 'dark');
      expect(await seat.store.getString('theme_mode'), 'dark');

      // Drain the microtask queue so the error had its chance to land —
      // on the handler, not on the zone.
      await pumpEventQueue();
      expect(errors, hasLength(1),
          reason: 'the async failure must land on the attached handler; '
              'unhandled it is an isolate-killing error that detonates after '
              'the write already applied');
    });

    test('a slow sink does not block the write path — ordering, not wall '
        'clock', () async {
      final sink = _SlowSink();
      final seat = _seenBy(_panel, sink: sink);

      // The write's outcome is decided while the sink's future is still
      // pending: `within` fails this arm if the decorator awaited it.
      await within(seat.served.preferences.setString('theme_mode', 'dark'),
          'a write whose audit row has not been made durable yet');
      expect(await seat.store.getString('theme_mode'), 'dark');
      expect(sink.rows, hasLength(1),
          reason: 'the row was handed to the sink before the gate answered — '
              'fire-and-forget is about not WAITING, never about not '
              'recording');
      expect(sink.gate.isCompleted, isFalse,
          reason: 'and the sink really was still pending, or this arm is '
              'asserting nothing about ordering');

      sink.gate.complete();
    });

    test('NullAuditSink is the default, and nothing changes for a '
        'composition that names no sink', () async {
      // Every existing test composition in the workspace builds
      // PolicyStateMan without a sink argument; this arm is why they are all
      // unaffected.
      final store = FakePreferences();
      final plant = FakeStateMan(preferences: store);
      addTearDown(plant.dispose);
      final served = PolicyStateMan(
        source: plant,
        policy: const AccessPolicyKeyPolicy(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => _panel,
      );

      await served.preferences.setString('theme_mode', 'dark');
      expect(await store.getString('theme_mode'), 'dark');

      final refused = PolicyStateMan(
        source: plant,
        policy: const AccessPolicyKeyPolicy(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => _display,
      );
      await _refusedAudit(
          () => refused.preferences.setString('key_mappings', '{}'));
      // The gate holds with no sink at all: the trail is an account of
      // decisions, never a precondition for making them.
    });
  });
}
