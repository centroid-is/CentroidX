@TestOn('vm')

/// The four access families, counted against the interfaces they name, and the
/// one parameter shape none of them may have.
///
/// [AccessMethods] is the whole request surface Phase 17 adds to the gateway:
/// templates, roles-and-users, the audit trail and the backend's own config.
/// The mechanics below are `data_service_methods_test.dart`'s, deliberately
/// unaltered — the property is the same one and inventing a second way to walk
/// an interface would mean two things to keep in step instead of one.
///
/// Three properties are enforced here that the data-service file does not need:
///
///  * **No member takes a caller-supplied identity** (ACCESS-06). The relay's
///    identity is the one the *server* verified by constant-time digest
///    compare; a client-supplied identity recorded as verified is worse than
///    recording none, and the honest way to make that unrepresentable is to
///    give the client no field to put one in. The pin reflects over every
///    parameter of every member of all four interfaces and carries an
///    anti-vacuity half, because a reflection that found nothing would pass.
///  * **The audit trail is read-only by construction.** There is no `record`
///    member and there is no member that returns nothing: the relay writes its
///    own rows through the injected `AuditSink`, server-side. A wire method a
///    client could write an arbitrary audit row through is a forgery surface,
///    not an audit trail.
///  * **The one field that is a secret does not print.** `setUserPassword` and
///    `createUser` both carry a password. It crosses inside the `wss://` frame
///    and is hashed server-side by the existing `PasswordHasher`; `toString`
///    is where a credential leaks into a log file that outlives the database,
///    so the params classes withhold it there and only there.
///
/// `AccessGroup` is imported from `package:tfc_access`, not restated. That
/// import is the point of this plan's dependency edge: seven group names spelled
/// a second time as wire strings is exactly the duplication Phase 17 exists to
/// delete.
library;

// Mirrors for the reason `data_service_methods_test.dart` gives: the property
// is about the *declarations* of an interface, and restating them as literals
// here would be restating exactly the thing that must not drift.
import 'dart:io';
import 'dart:mirrors';

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The abstract, non-static, non-accessor methods [type] declares.
///
/// Verbatim from `data_service_methods_test.dart`. Getters are excluded
/// because a getter is not a request.
Set<String> _methodsOf(Type type) => {
      for (final declaration in reflectClass(type).declarations.values)
        if (declaration is MethodMirror &&
            declaration.isRegularMethod &&
            !declaration.isStatic)
          MirrorSystem.getName(declaration.simpleName),
    };

/// Every parameter name declared by every member of [type].
Iterable<String> _parameterNamesOf(Type type) => [
      for (final declaration in reflectClass(type).declarations.values)
        if (declaration is MethodMirror &&
            declaration.isRegularMethod &&
            !declaration.isStatic)
          for (final parameter in declaration.parameters)
            MirrorSystem.getName(parameter.simpleName),
    ];

/// The declared return type of every member of [type], as a mirror.
Map<String, TypeMirror> _returnTypesOf(Type type) => {
      for (final declaration in reflectClass(type).declarations.values)
        if (declaration is MethodMirror &&
            declaration.isRegularMethod &&
            !declaration.isStatic)
          MirrorSystem.getName(declaration.simpleName): declaration.returnType,
    };

/// The non-static getters [type] declares — the sub-API accessors and `keys`.
Set<String> _gettersOf(Type type) => {
      for (final declaration in reflectClass(type).declarations.values)
        if (declaration is MethodMirror &&
            declaration.isGetter &&
            !declaration.isStatic)
          MirrorSystem.getName(declaration.simpleName),
    };

/// Every wire string [Methods] declares, read out of the class rather than
/// listed here.
///
/// Anchored on what the class *is* — a table of wire names — instead of on the
/// count somebody wrote in its doc comment. A tenth request name added to
/// [Methods] tomorrow is compared against the access families the same day.
Set<String> _everyMethodsName() {
  final mirror = reflectClass(Methods);
  return {
    for (final declaration in mirror.declarations.values)
      if (declaration is VariableMirror &&
          declaration.isStatic &&
          !declaration.isPrivate)
        mirror.getField(declaration.simpleName).reflectee as String,
  };
}

/// The method half of a wire name: `audit.entries` → `entries`.
String _member(String wireName) => wireName.split('.').last;

/// The family half of a wire name: `audit.entries` → `audit`.
String _family(String wireName) => wireName.split('.').first;

/// Parameter names that would let a client name **who** an action is
/// attributed to.
///
/// `subject` is deliberately absent and deliberately different: the account a
/// role change is *applied to* is the administered thing, and `AuditRecord`'s
/// own factories already spell that `subject:` while spelling the actor `who:`.
/// The two must not share a name, or a handler that passes the wire's value
/// into the row's actor column looks correct at the call site.
///
/// `roleName` is here for the same reason. On `AuditRecord` it means *the role
/// the caller's session resolved to* — the caller's authority. The role being
/// granted to somebody else is `newRole` / `grantedRole`, following the same
/// factories.
///
/// `origin` is here because it is attribution too: it is the column that says a
/// row came from the relay rather than from an operator at a panel, and a
/// client that could set it could dress a wire write up as a keyboard.
const Set<String> forbiddenIdentityParameters = {
  'who',
  'username',
  'userId',
  'user',
  'identity',
  'station',
  'stationId',
  'roleName',
  'operator',
  'origin',
  'actor',
  'session',
};

void main() {
  final families = <String, (Type, Set<String>, String)>{
    'AccessTemplateApi': (
      AccessTemplateApi,
      AccessMethods.templateMethods,
      'accessTemplates'
    ),
    'AccessAdminApi': (
      AccessAdminApi,
      AccessMethods.adminMethods,
      'accessAdmin'
    ),
    'AuditApi': (AuditApi, AccessMethods.auditMethods, 'audit'),
    'BackendConfigApi': (
      BackendConfigApi,
      AccessMethods.configMethods,
      'backendConfig'
    ),
  };

  group('the access method table', () {
    test('every family names at least one method, and every interface has one',
        () {
      // Anti-vacuity for arm 1, the same one data_service_methods_test.dart
      // carries: every case below compares two sets, and two empty sets compare
      // equal. If the reflection stopped seeing members the both-directions
      // cases would all pass while asserting nothing.
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

    test('arm 1a: every interface method has a constant, in every family', () {
      families.forEach((name, triple) {
        final (type, named, _) = triple;
        final declared = _methodsOf(type);
        final namedMembers = named.map(_member).toSet();

        expect(namedMembers, containsAll(declared),
            reason: '$name declares ${declared.length} methods '
                '(${declared.toList()..sort()}) and the table names '
                '${namedMembers.length} of them '
                '(${namedMembers.toList()..sort()}). A method with no constant '
                'is a method no client on the far side of this pipe can reach, '
                'and the way that surfaces is a NoSuchMethodError inside a '
                'widget rather than here');
      });
    });

    test('arm 1b: every constant names a real interface method', () {
      families.forEach((name, triple) {
        final (type, named, _) = triple;
        final declared = _methodsOf(type);

        for (final wireName in named) {
          expect(declared, contains(_member(wireName)),
              reason: '$name has no member `${_member(wireName)}`, but the '
                  'table names `$wireName`. A constant with no method behind it '
                  'is wire surface nobody counted — the gateway registers a '
                  'handler for it and nothing on either side says what it is '
                  'meant to do');
        }
      });
    });

    test('arm 2: all is the union of the four families and nothing else', () {
      expect(
          AccessMethods.all,
          {
            ...AccessMethods.templateMethods,
            ...AccessMethods.adminMethods,
            ...AccessMethods.auditMethods,
            ...AccessMethods.configMethods,
          },
          reason: 'all is spelled from the four family sets, so a name in one '
              'of them that never reaches all is a method the closure test '
              'would never demand a handler for');
    });

    test('arm 2b: the four families are pairwise disjoint', () {
      final sets = <String, Set<String>>{
        'templateMethods': AccessMethods.templateMethods,
        'adminMethods': AccessMethods.adminMethods,
        'auditMethods': AccessMethods.auditMethods,
        'configMethods': AccessMethods.configMethods,
      };

      final names = sets.keys.toList();
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          expect(sets[names[i]]!.intersection(sets[names[j]]!), isEmpty,
              reason: '${names[i]} and ${names[j]} share a wire name. A name '
                  'in two families is a name two handlers would register, and '
                  'the second registration silently shadows the first');
        }
      }

      expect(
          AccessMethods.all,
          hasLength(AccessMethods.templateMethods.length +
              AccessMethods.adminMethods.length +
              AccessMethods.auditMethods.length +
              AccessMethods.configMethods.length),
          reason: 'the union is exactly as long as the four parts added up, '
              'which is the same disjointness said as arithmetic — a set that '
              'swallowed a duplicate would be shorter and nothing above would '
              'notice');
    });

    test('arm 3: no collision with the surface that already exists', () {
      expect(AccessMethods.all.intersection(DataServiceMethods.all), isEmpty,
          reason: 'a wire name shared with a data service is a silently '
              'shadowed handler: json_rpc_2 dispatches one of the two and '
              'nothing says which');

      final sessionNames = _everyMethodsName();
      expect(sessionNames, isNotEmpty,
          reason: 'the reflection over Methods found no wire strings at all, '
              'so the intersection below is vacuous');
      expect(AccessMethods.all.intersection(sessionNames), isEmpty,
          reason: 'a wire name shared with the session vocabulary is the same '
              'shadowing, one class over');
    });

    test('arm 4: every name is family.member, with the family matching', () {
      families.forEach((name, triple) {
        final (_, named, family) = triple;
        for (final wireName in named) {
          expect(wireName.split('.'), hasLength(2),
              reason: '`$wireName` is not exactly family.member, and the '
                  'gateway splits on the single dot to route it');
          expect(_family(wireName), family,
              reason: '`$wireName` is a $name name, so its family segment has '
                  'to be `$family` — the segment is the StateManApi getter a '
                  'reader follows from the wire back to the interface');
        }
      });
    });
  });

  group('no member of the four families takes a caller-supplied identity', () {
    test('arm 5: the reflection sees enough parameters to be worth trusting',
        () {
      // The anti-vacuity half, and it is half the pin. A reflection that walked
      // nothing — a family wired to the wrong Type, a mirrors shape that moved
      // — would report no forbidden parameter and pass while asserting
      // nothing at all.
      final all = [
        for (final triple in families.values) ..._parameterNamesOf(triple.$1),
      ];
      expect(all.length, greaterThan(20),
          reason: 'the four interfaces between them declare well over twenty '
              'parameters; finding ${all.length} means the walk is broken, not '
              'that the surface got smaller');
    });

    test('arm 5: no member names the identity an action is attributed to', () {
      families.forEach((name, triple) {
        final (type, _, _) = triple;
        for (final parameter in _parameterNamesOf(type)) {
          expect(forbiddenIdentityParameters, isNot(contains(parameter)),
              reason: 'ACCESS-06: `$name` declares a parameter named '
                  '`$parameter`. The identity a relay write is attributed to '
                  'is the token file\'s username, which the server verified by '
                  'constant-time digest compare — a hand-rolled client that '
                  'could name somebody else would be recording a forged '
                  'attribution as a verified one, which is worse than '
                  'recording none. The subject of an administration is spelled '
                  '`subject`, the role being granted `newRole` or '
                  '`grantedRole`, and neither is an actor.');
        }
      });
    });
  });

  group('the audit trail cannot be written from the wire', () {
    test('arm 8: AuditApi has no member that writes', () {
      final returns = _returnTypesOf(AuditApi);
      expect(returns, isNotEmpty,
          reason: 'AuditApi reflects to no members, so the check below is '
              'vacuous');

      returns.forEach((member, returnType) {
        final arguments = returnType.typeArguments;
        expect(arguments, isNotEmpty,
            reason: 'AuditApi.$member does not return a Future of anything. '
                'Every read answers with data; a member that answers with '
                'nothing is a write, and the relay writes its own rows through '
                'the injected AuditSink, server-side');
        expect(MirrorSystem.getName(arguments.first.simpleName), isNot('void'),
            reason: 'AuditApi.$member returns Future<void> — it is a write. A '
                'wire method a client could write an arbitrary audit row '
                'through is a forgery surface, not an audit trail');
      });
    });
  });

  group('StateManApi grew by exactly four getters', () {
    test('arm 6: the sub-API getters are the agreed nine and nothing more', () {
      // A literal list, on api_surface_test.dart's own argument: a set computed
      // from the type would agree with any change and assert nothing.
      const expected = <String>{
        'keys',
        'browse',
        'timeseries',
        'historyViews',
        'preferences',
        'accessTemplates',
        'accessAdmin',
        'audit',
        'backendConfig',
      };

      expect(_gettersOf(StateManApi), expected,
          reason: 'Phase 17 adds four getters — accessTemplates, accessAdmin, '
              'audit, backendConfig — and no others. A fifth getter is a fifth '
              'family of things any connected client may invoke, and this file '
              'is where that decision is written down');
    });

    test('arm 6b: each family segment is the getter it hangs off', () {
      final getters = _gettersOf(StateManApi);
      families.forEach((name, triple) {
        final (_, _, family) = triple;
        expect(getters, contains(family),
            reason: '$name\'s wire names are prefixed `$family.`, so '
                'StateManApi must carry a getter of that name — the prefix is '
                'how a reader gets from a frame in a log back to the '
                'interface');
      });
    });
  });

  group('AccessGroup crosses the wire by name', () {
    test('arm 7: all seven names round-trip', () {
      expect(AccessGroup.values, hasLength(7),
          reason: 'the enum is seven and Phase 17 adds none — the count is '
              'asserted in tfc_access too, and this arm is the wire\'s half of '
              'the same claim');

      for (final group in AccessGroup.values) {
        expect(AccessGroup.byName(group.name), same(group),
            reason: '`${group.name}` is what crosses the wire for '
                '$group, so it has to come back as the same value');
      }
    });

    test('arm 7b: an unknown group name decodes to null, not to a throw', () {
      expect(AccessGroup.byName('nonsense'), isNull,
          reason: 'a station running a newer build may have written a group '
              'name this one has never heard of. Null means "not granted"; a '
              'throw means a panel that cannot render the roles screen at all '
              'because one row mentions a group it does not know');
    });
  });

  group('the one secret on these families does not print', () {
    test('arm 9: setUserPassword params withhold the password from toString',
        () {
      const params = SetUserPasswordParams(
        subject: 'ST101-panel',
        password: 'correct-horse-battery-staple',
      );

      expect(params.toString(), isNot(contains('correct-horse')),
          reason: 'TlsConfig\'s discipline — paths, never bytes — applied to '
              'the one field here with the same problem. toString reaches log '
              'files that live longer and travel further than the database '
              'does');
      expect(params.toString(), contains('ST101-panel'),
          reason: 'the live control: a toString that printed nothing at all '
              'would pass the arm above while telling an operator nothing');
      expect(params.toJson()['password'], 'correct-horse-battery-staple',
          reason: 'the password does cross the wire, inside the wss frame, and '
              'is hashed server-side by the existing PasswordHasher. No digest '
              'is computed on the client, because a client-computed digest IS '
              'the password');
    });

    test('arm 9b: createUser params withhold it too', () {
      const params = NewUserParams(
        subject: 'ST201-panel',
        password: 'hunter2-and-then-some',
        grantedRole: 'Panel Operator',
      );

      expect(params.toString(), isNot(contains('hunter2')),
          reason: 'createUser carries a password for exactly the same reason '
              'setUserPassword does, so it carries the same discipline');
      expect(params.toString(), contains('ST201-panel'),
          reason: 'the live control');
      expect(params.toJson()['password'], 'hunter2-and-then-some',
          reason: 'and it still crosses, hashed at the far end');
    });
  });

  group('the protocol names the access vocabulary rather than restating it',
      () {
    test('arm 10: access_api.dart imports tfc_access and not tfc_dart', () {
      final source = File('lib/src/access_api.dart').readAsStringSync();

      expect(source, contains('package:tfc_access'),
          reason: 'the seven group names exist once, in the master package. '
              'Restating them here as wire strings is the duplication this '
              'phase exists to delete');
      expect(source, isNot(contains('package:tfc_dart')),
          reason: 'tfc_dart carries drift, logger and the open62541 FFI; the '
              'protocol package has none of them and the audit query\'s wire '
              'shape is declared here and mapped at both ends for exactly that '
              'reason');
    });

    test('arm 11: the edge stays one-way — tfc_access does not depend back',
        () {
      // This arm lives here, in the package that created the edge, because
      // tfc_access's own package_purity_test.dart forbids `tfc_dart`,
      // `flutter`, `open62541` and `cryptography_flutter` in its pubspec and
      // — measured at 17-03 — does NOT forbid `tfc_relay_protocol`. The rule
      // the CONTEXT calls "the reverse edge stays forbidden and stays tested"
      // was true of three strings and not of the one this plan introduces.
      final pubspec = File('../tfc_access/pubspec.yaml');
      expect(pubspec.existsSync(), isTrue,
          reason: 'the subject of this scan is not where this arm looks for '
              'it. A pin that reads a path goes vacuous the moment the content '
              'moves, silently and staying green, so this half fails loudly '
              'instead');

      final raw = pubspec.readAsStringSync();
      expect(raw, contains('name: tfc_access'),
          reason: 'the live control: the file was found AND is the one meant');

      // Comment lines are stripped before matching, per the house rule and per
      // the same discipline that file's own suite uses — the explanatory block
      // in a pubspec names the things it forbids.
      final code = raw
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');
      expect(code, contains('dependencies:'),
          reason: 'the second live control: stripping comments left something '
              'to search. A scan of an empty string passes every isNot below');
      expect(code, isNot(contains('tfc_relay_protocol')),
          reason: 'tfc_relay_protocol -> tfc_access is the edge 17-03 adds; '
              'the reverse would be a cycle, and worse, it would put the wire '
              'protocol inside the package whose whole argument is that it '
              'depends on nothing a panel or a gateway has to carry');
    });
  });
}
