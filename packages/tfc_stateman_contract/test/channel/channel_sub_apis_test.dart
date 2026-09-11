/// The data-service legs of the channel: the method table, and one round trip
/// that proves a sample survives the crossing.
///
/// Two properties, and neither is a contract case — the seven sub-suites judge
/// behaviour, and these judge the *forwarding* underneath it.
///
///  * **One name and one handler per method, counted against the interface
///    itself.** T-02-22 is the threat: a generic pass-through that dispatched
///    on a caller-supplied string would make the set of things reachable over
///    this channel stop being a list anybody can read. Counting the constants
///    against `dart:mirrors`' view of the four interfaces is what makes the
///    table unable to fall behind them — a fifth browse method added in Phase 3
///    fails here, naming the leg nobody wrote, instead of failing as a
///    `NoSuchMethodError` inside a widget two phases later.
///  * **A timeseries point crosses unchanged.** T-02-21: `TimeseriesData`
///    decodes through a value parser, and the wrong one is lossy in a way that
///    surfaces as a *wrong number* in a chart rather than as a decode error.
///    Asserting the timestamp and the value on a point that went through the
///    seeding lever and came back through a query is the cheapest place to
///    catch it.
@Tags(['contract'])
library;

// Mirrors for the same reason `test/suite_integrity_test.dart` uses them: the
// property is about the *declarations* of an interface, and restating them as
// literals here would be restating exactly the thing that must not drift.
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The abstract, non-static, non-accessor methods [type] declares.
///
/// Getters are excluded because a getter is not a request:
/// `PreferencesApi.onPreferencesChanged` returns a stream and crosses this
/// channel as a notification going the other way.
Set<String> _methodsOf(Type type) => {
      for (final declaration in reflectClass(type).declarations.values)
        if (declaration is MethodMirror &&
            declaration.isRegularMethod &&
            !declaration.isStatic)
          MirrorSystem.getName(declaration.simpleName),
    };

void main() {
  group('the method table', () {
    test('there is one constant per method on each sub-API', () {
      final expected = {
        'BrowseApi': (_methodsOf(BrowseApi), HarnessMethods.browseMethods),
        'TimeseriesApi': (
          _methodsOf(TimeseriesApi),
          HarnessMethods.timeseriesMethods
        ),
        'HistoryViewApi': (
          _methodsOf(HistoryViewApi),
          HarnessMethods.historyViewMethods
        ),
        'PreferencesApi': (
          _methodsOf(PreferencesApi),
          HarnessMethods.preferenceMethods
        ),
      };

      expected.forEach((name, pair) {
        final (declared, named) = pair;
        expect(named, hasLength(declared.length),
            reason: '$name declares ${declared.length} methods '
                '(${declared.toList()..sort()}) and the channel table names '
                '${named.length} of them. A method with no constant is a '
                'method no client on the far side of this channel can reach, '
                'and the way that surfaces is a NoSuchMethodError inside a '
                'widget rather than here');
      });
    });

    test('every named sub-API method has a handler, and no handler is unnamed',
        () {
      final both = serveFakeOverChannel();
      addTearDown(both.api.dispose);

      expect(both.session.registeredMethods, HarnessMethods.served,
          reason: 'the names this harness declares and the handlers it '
              'registers have diverged. A declared name with no handler is a '
              'call that comes back as METHOD_NOT_FOUND from a table that '
              'claims to carry it; a handler with no declared name is surface '
              'nobody counted, which is T-02-22 — the set of things reachable '
              'over this channel has to stay a list a person can read');
      expect(both.session.registeredMethods,
          containsAll(HarnessMethods.dataServices),
          reason: 'a data-service method is named but not served');
    });
  });

  group('a timeseries point crossing the channel', () {
    test('keeps its timestamp and its value', () async {
      final api = channelServedFake();
      addTearDown(api.dispose);

      final at = DateTime.utc(2026, 8, 13, 6, 30, 15, 250);
      const value = 1207.5;
      dataHarnessOf(api)
          .seedTimeseries('svn.ts', [TimeseriesData<num>(value, at)]);

      final got = await api.timeseries.queryTimeseriesData(
          'svn.ts', at.add(const Duration(minutes: 1)),
          from: at.subtract(const Duration(minutes: 1)));

      expect(got, hasLength(1),
          reason: 'a sample was seeded through the channel and the query it '
              'was seeded for came back with ${got.length} points, so the '
              'lever and the query disagree about where the sample went');
      expect(got.single.time, at,
          reason: 'the sample came back at ${got.single.time} rather than $at. '
              'A chart plots what it is given, so a shifted timestamp is a '
              'shifted event, and nothing downstream can tell');
      expect(got.single.value, value,
          reason: 'the sample came back as ${got.single.value} rather than '
              '$value. TimeseriesData.fromJson decodes through a value parser '
              'and the wrong one is lossy in exactly this way — a number that '
              'is wrong rather than a decode that failed (T-02-21)');
    });
  });

  group('preference changes', () {
    test('reach a listener that subscribed before the write', () async {
      final api = channelServedFake();
      addTearDown(api.dispose);

      final heard = api.preferences.onPreferencesChanged.first;
      await api.preferences.setBool('svn.ui.darkMode', true);

      expect(await heard.timeout(const Duration(seconds: 2)),
          'svn.ui.darkMode',
          reason: 'a preference written over the channel produced no '
              'notification on this side, so a settings page open on a second '
              'client holds a stale form until somebody reopens it (DB-03)');
    });
  });
}
