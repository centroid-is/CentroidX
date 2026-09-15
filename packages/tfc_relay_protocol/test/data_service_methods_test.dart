/// The data-service wire names, counted against the interfaces they name.
///
/// [DataServiceMethods] is the whole request surface of Phase 10 (less the
/// audit-cut count method): thirty-three
/// names the gateway registers and the client sends. It lives in this package
/// because both ends import this package and neither imports the other — the
/// server's production `lib/` may not name the contract kit
/// (`handler_table_test.dart:264-296`), and it does not depend on the client at
/// all, so a set declared in the client is a set the gateway cannot iterate.
///
/// The property is the same one `channel_sub_apis_test.dart:39-93` asserts one
/// layer up, and for the same reason: a name and an interface member that drift
/// apart surface as a `NoSuchMethodError` inside a widget two phases later
/// rather than here. Comparing per family in **both** directions is what makes
/// the drift impossible in either direction — a fifth browse method with no
/// constant is a method no client can reach, and a constant with no method is
/// wire surface nobody counted (T-10-01).
library;

// Mirrors for the same reason `channel_sub_apis_test.dart` and
// `suite_integrity_test.dart` use them: the property is about the
// *declarations* of an interface, and restating them as literals here would be
// restating exactly the thing that must not drift.
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

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

/// The method half of a wire name: `preferences.getInt` → `getInt`.
String _member(String wireName) => wireName.split('.').last;

/// The family half of a wire name: `preferences.getInt` → `preferences`.
String _family(String wireName) => wireName.split('.').first;

void main() {
  final families = <String, (Type, Set<String>, String)>{
    'BrowseApi': (BrowseApi, DataServiceMethods.browseMethods, 'browse'),
    'TimeseriesApi': (
      TimeseriesApi,
      DataServiceMethods.timeseriesMethods,
      'timeseries'
    ),
    'HistoryViewApi': (
      HistoryViewApi,
      DataServiceMethods.historyViewMethods,
      'historyViews'
    ),
    'PreferencesApi': (
      PreferencesApi,
      DataServiceMethods.preferencesMethods,
      'preferences'
    ),
  };

  group('the data-service method table', () {
    test('every family names at least one method, and every interface has one',
        () {
      // Anti-vacuity: every case below compares two sets, and two empty sets
      // compare equal. If the reflection stopped seeing members — a rename of
      // dart:mirrors' shape, a family wired to the wrong Type — the
      // both-directions cases would all pass while asserting nothing.
      families.forEach((name, triple) {
        final (type, named, _) = triple;
        expect(_methodsOf(type), isNotEmpty,
            reason: '$name reflects to no methods at all, so every comparison '
                'below is vacuous — the reflection, not the table, is broken');
        expect(named, isNotEmpty,
            reason: '$name has an empty constant set, so comparing it against '
                'the interface asserts nothing');
      });
    });

    test('every interface method has a constant, in every family', () {
      families.forEach((name, triple) {
        final (type, named, _) = triple;
        final declared = _methodsOf(type);
        final namedMembers = named.map(_member).toSet();

        expect(namedMembers, containsAll(declared),
            reason: '$name declares ${declared.length} methods '
                '(${declared.toList()..sort()}) and the table names '
                '${namedMembers.length} of them '
                '(${namedMembers.toList()..sort()}). A method with no constant '
                'is a method no client on the far side of this pipe can '
                'reach, and the way that surfaces is a NoSuchMethodError '
                'inside a widget rather than here');
      });
    });

    test('every constant names a real interface method, in every family', () {
      families.forEach((name, triple) {
        final (type, named, _) = triple;
        final declared = _methodsOf(type);

        for (final wireName in named) {
          expect(declared, contains(_member(wireName)),
              reason: '$name has no member `${_member(wireName)}`, but the '
                  'table names `$wireName`. A constant with no method behind '
                  'it is wire surface nobody counted — the gateway registers '
                  'a handler for it and nothing on either side says what it '
                  'is meant to do (T-10-01)');
        }
      });
    });

    test('every constant is family.methodName, with the family matching', () {
      families.forEach((name, triple) {
        final (_, named, family) = triple;
        for (final wireName in named) {
          expect(_family(wireName), family,
              reason: '`$wireName` is a $name name, so its family segment has '
                  'to be `$family` — the segment is the StateManApi getter a '
                  'reader follows from the wire back to the interface');
          expect(wireName.split('.'), hasLength(2),
              reason: '`$wireName` is not exactly family.methodName, and the '
                  'gateway splits on the single dot to route it');
        }
      });
    });

    test('all is the union of the four families and nothing else', () {
      expect(
          DataServiceMethods.all,
          {
            ...DataServiceMethods.browseMethods,
            ...DataServiceMethods.timeseriesMethods,
            ...DataServiceMethods.historyViewMethods,
            ...DataServiceMethods.preferencesMethods,
          },
          reason: 'all is spelled from the four family sets, so a name in one '
              'of them that never reaches all is a method the closure test '
              'would never demand a handler for');
    });

    test('the whole wire surface of the data services is 33 names', () {
      expect(DataServiceMethods.all, hasLength(33),
          reason: 'thirty-three is the entire request surface the data '
              'services add to the gateway: 4 browse + 3 timeseries + 11 '
              'historyViews + 15 preferences. (Phase 10 shipped 34; the '
              '2026-09-07 dead-code audit cut timeseries.'
              'countTimeseriesDataMultiple — no end caller anywhere.) Every '
              'name is a thing any connected client may invoke, so the count '
              'moving is an access-control decision and it should print when '
              'it does');
    });

    test('the data-service names and the access names do not collide', () {
      // This file is the one that already owns "the wire names do not
      // collide", so the third sibling's disjointness is asserted from here as
      // well as from access_api_test.dart. One mutation reddens two suites,
      // which is what a reviewer wants from a shadowed handler: the gateway
      // registers both names into one table and json_rpc_2 dispatches one of
      // them, with nothing anywhere saying which.
      expect(DataServiceMethods.all, isNotEmpty,
          reason: 'the anti-vacuity half — an empty set is disjoint from '
              'everything and asserts nothing');
      expect(AccessMethods.all, isNotEmpty,
          reason: 'the other half of the same');
      expect(DataServiceMethods.all.intersection(AccessMethods.all), isEmpty,
          reason: 'a name in both tables is a handler registered twice; the '
              'second registration silently shadows the first and the failure '
              'surfaces in the plant as a method doing the wrong thing rather '
              'than as a method that is missing');
    });

    test('the changed notification is named but is not a request', () {
      expect(DataServiceMethods.preferencesChanged, 'preferences.changed',
          reason: 'the notification keeps its wire spelling; the server sends '
              'it and the client fans it out');
      expect(DataServiceMethods.all,
          isNot(contains(DataServiceMethods.preferencesChanged)),
          reason: 'preferences.changed is a server→client notification: it '
              'belongs in expectedNotifications and never in the handler '
              'table. A set that carried it would make the closure test '
              'demand a handler for a frame that must never have one');
      expect(DataServiceMethods.preferencesMethods,
          isNot(contains(DataServiceMethods.preferencesChanged)),
          reason: 'the family set is the request half of PreferencesApi; '
              'onPreferencesChanged is a getter and the reflection excludes '
              'accessors, so a notification in this set would fail the '
              'both-directions comparison with no useful message');
    });
  });
}
