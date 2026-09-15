// One subscription per key, however many widgets are drawing it and however
// often they rebuild.
//
// Assets built their subscriptions inside `build`, so `StreamBuilder` was
// handed a new stream object on every rebuild — and a new object means cancel
// the old subscription and open a fresh one. Resizing a window rebuilds
// continuously, and so does dragging an asset around the page editor, so
// every asset on the page dropped and re-made its subscriptions once a frame.
//
// Measured on the plant HMI while a window edge was dragged: ~130 KiB of log
// a second against nothing once the mouse stopped, StateMan's retry ladder
// pinned to its first four steps forever, and a window that lagged the mouse
// because each frame asked the server for monitored items it then threw away.
//
// Reading through `keyStreamProvider` moves the subscription off the widget
// and onto the key.

@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// Counts what actually reaches StateMan.
class _CountingStateMan extends Fake implements StateMan {
  final Map<String, int> subscribes = {};
  final Map<String, int> listeners = {};
  final Map<String, StreamController<DynamicValue>> controllers = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    subscribes[key] = (subscribes[key] ?? 0) + 1;
    late StreamController<DynamicValue> controller;
    controller = StreamController<DynamicValue>.broadcast(
      onListen: () => listeners[key] = (listeners[key] ?? 0) + 1,
      onCancel: () => listeners[key] = (listeners[key] ?? 0) - 1,
    );
    controllers[key] = controller;
    return controller.stream;
  }
}

ProviderContainer _container(StateMan stateMan) {
  final container = ProviderContainer(
    overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets `stateManProvider` resolve, the key provider rebuild on it, and the
/// `subscribe` future land — three turns of the loop, so give it a few.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the same key hands back the same stream', () async {
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    // Hold a listener, or an auto-disposed provider is free to go between
    // reads and the second read builds a fresh one.
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);
    await _settle();

    final first = container.read(keyStreamProvider('A'));
    final second = container.read(keyStreamProvider('A'));
    expect(identical(first, second), isTrue);
  });

  test('and opens exactly one subscription for it', () async {
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);
    await _settle();

    // Ten rebuilds' worth of reads.
    for (var i = 0; i < 10; i++) {
      container.read(keyStreamProvider('A'));
    }
    await _settle();

    expect(stateMan.subscribes['A'], 1);
  });

  test('two assets on one key share the subscription', () async {
    // Two conveyors bound to the same drive used to open two monitored items
    // for it — and could disagree about its value.
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final a = container.listen(keyStreamProvider('A'), (_, __) {});
    final b = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(a.close);
    addTearDown(b.close);
    await _settle();

    expect(stateMan.subscribes['A'], 1);
  });

  test('different keys are subscribed separately', () async {
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final a = container.listen(keyStreamProvider('A'), (_, __) {});
    final b = container.listen(keyStreamProvider('B'), (_, __) {});
    addTearDown(a.close);
    addTearDown(b.close);
    await _settle();

    expect(stateMan.subscribes, {'A': 1, 'B': 1});
  });

  test('a late listener is given the latest value, not a blank', () async {
    // This is what makes a rebuild free: whoever re-listens sees what the
    // asset was already showing rather than falling back to "no data".
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);
    await _settle();

    stateMan.controllers['A']!.add(DynamicValue(value: 42));
    await _settle();

    final seen = await container.read(keyStreamProvider('A')).first;
    expect(seen.asInt, 42);
  });

  test('re-listening does not reach StateMan again', () async {
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);
    await _settle();
    final afterOpen = stateMan.subscribes['A'];

    // What a rebuilding StreamBuilder does: drop its subscription and take
    // another one out on the same stream.
    for (var i = 0; i < 5; i++) {
      final listener =
          container.read(keyStreamProvider('A')).listen((_) {});
      await _settle();
      await listener.cancel();
    }

    expect(stateMan.subscribes['A'], afterOpen,
        reason: 'a re-listen must be served by the subject, not by StateMan');
  });

  test('a failure to subscribe reaches the asset', () async {
    // An asset bound to a key the PLC does not serve has to be able to show
    // that; swallowing it would paint a belt that looks connected.
    final stateMan = _ThrowingStateMan();
    final container = _container(stateMan);
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);

    await expectLater(
        container.read(keyStreamProvider('A')), emitsError(isA<StateError>()));
  });

  test('dropping the last watcher releases the subscription', () async {
    // Leaving a page should hand its monitored items back, which is the whole
    // reason this is auto-disposed.
    final stateMan = _CountingStateMan();
    final container = _container(stateMan);
    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    await _settle();
    expect(stateMan.listeners['A'], 1);

    sub.close();
    await _settle();

    expect(stateMan.listeners['A'], 0);
  });

  group('a key named through a substitution variable', () {
    // `Line1.$sb_line_stats_period` — the speedbatcher throughput readouts.
    // StateMan resolves the variable once, at subscribe time. When
    // subscriptions moved off the widgets and into this provider, a
    // substituted key was subscribed exactly once for its RAW spelling:
    // subscribed before the OptionVariable published, the resolve threw and
    // the failure was held forever; subscribed after, a period change left
    // the stream pointed at the old target. Every throughput number on the
    // speedbatcher screen broke the day that landed. Before the sharing,
    // widgets rebuilt their subscriptions every frame, and that waste was
    // also what retried the resolve.

    test('resolves once the variable is published', () async {
      final stateMan = _SubstitutingStateMan();
      addTearDown(stateMan.closeSubs);
      final container = _container(stateMan);
      final sub = container.listen(
          keyStreamProvider(r'Line1.$sb_line_stats_period'), (_, __) {});
      addTearDown(sub.close);
      await _settle();
      // Subscribed before the OptionVariable published: nothing resolved yet.
      expect(stateMan.subscribedResolved, isEmpty);

      stateMan.setSubstitution('sb_line_stats_period', 'avgBPM1Minute');
      await _settle();

      expect(stateMan.subscribedResolved, ['Line1.avgBPM1Minute'],
          reason: 'publishing the variable must retry the resolve');
    });

    test('re-points when the operator picks a new period', () async {
      final stateMan = _SubstitutingStateMan();
      addTearDown(stateMan.closeSubs);
      final container = _container(stateMan);
      stateMan._subs['sb_line_stats_period'] = 'avgBPM1Minute';
      final sub = container.listen(
          keyStreamProvider(r'Line1.$sb_line_stats_period'), (_, __) {});
      addTearDown(sub.close);
      await _settle();
      expect(stateMan.subscribedResolved, ['Line1.avgBPM1Minute']);

      stateMan.setSubstitution('sb_line_stats_period', 'avgBPM30Minute');
      await _settle();

      expect(stateMan.subscribedResolved,
          ['Line1.avgBPM1Minute', 'Line1.avgBPM30Minute'],
          reason: 'a period change must re-subscribe at the new target');

      // And the new stream delivers.
      stateMan.controllers['Line1.avgBPM30Minute']!
          .add(DynamicValue(value: 4.2));
      await _settle();
      final v = await container
          .read(keyStreamProvider(r'Line1.$sb_line_stats_period'))
          .first;
      expect(v.asDouble, closeTo(4.2, 1e-9));
    });

    test('a plain key ignores substitution changes', () async {
      final stateMan = _SubstitutingStateMan();
      addTearDown(stateMan.closeSubs);
      final container = _container(stateMan);
      final sub = container.listen(keyStreamProvider('CV.Drive'), (_, __) {});
      addTearDown(sub.close);
      await _settle();
      expect(stateMan.subscribedResolved, ['CV.Drive']);

      stateMan.setSubstitution('sb_line_stats_period', 'avgBPM5Minute');
      await _settle();

      expect(stateMan.subscribedResolved, ['CV.Drive'],
          reason: 'operator clicks must not churn unrelated subscriptions');
    });
  });

  test('nothing is subscribed before there is a StateMan', () async {
    final container = ProviderContainer(overrides: [
      stateManProvider.overrideWith((ref) => Completer<StateMan>().future),
    ]);
    addTearDown(container.dispose);

    final sub = container.listen(keyStreamProvider('A'), (_, __) {});
    addTearDown(sub.close);
    await _settle();

    // An empty stream: done, no values, no error — the same "nothing yet"
    // every asset already renders while it waits for a first reading.
    expect(await container.read(keyStreamProvider('A')).isEmpty, isTrue);
  });
}

/// A fake with real substitution semantics: `$var` keys resolve against the
/// current substitutions at subscribe time and throw while unresolved —
/// mirroring `StateMan.resolveKey` + `_throwIfUnresolved`.
class _SubstitutingStateMan extends Fake implements StateMan {
  final Map<String, String> _subs = {};
  final _subs$ = StreamController<Map<String, String>>.broadcast();
  final List<String> subscribedResolved = [];
  final Map<String, StreamController<DynamicValue>> controllers = {};

  @override
  Stream<Map<String, String>> get substitutionsChanged => _subs$.stream;

  void setSubstitution(String name, String value) {
    _subs[name] = value;
    _subs$.add(Map.of(_subs));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    var resolved = key;
    for (final e in _subs.entries) {
      resolved = resolved.replaceAll('\$${e.key}', e.value);
    }
    if (resolved.contains(r'$')) {
      throw StateError('unresolved variable in "$resolved"');
    }
    subscribedResolved.add(resolved);
    final c = StreamController<DynamicValue>.broadcast();
    controllers[resolved] = c;
    return c.stream;
  }

  void closeSubs() => _subs$.close();
}

class _ThrowingStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      throw StateError('no such node');
}
