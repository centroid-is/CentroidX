@TestOn('vm')

/// A test that exists to break the build on purpose.
///
/// The pure-Dart [ValueListenable] is a hand-copied twin of Flutter's
/// declaration (`flutter/lib/src/foundation/change_notifier.dart:94`, verified
/// against 3.41.9). Phase 4's client ships a class that implements *both* at
/// once, which only compiles while the two declarations agree member-for-member.
/// Drift here is silent until that port, so reflection pins the surface now.
///
/// `dart:mirrors` is VM-only — hence `@TestOn('vm')` and `dart test`, never
/// `flutter test`.
library;

import 'dart:mirrors';

import 'package:test/test.dart';
// The declaring library, not the barrel: this test is about what that one file
// declares and what it imports, so it names the file it is pinning.
import 'package:tfc_relay_protocol/src/value_listenable.dart';

/// Repeated on every expectation: the failure message has to say what breaks,
/// not merely that something changed.
const _bridge = 'the Phase 4 Flutter bridge implements this interface and '
    "Flutter's ValueListenable with one class; any drift here stops that class "
    'from compiling';

void main() {
  final mirror = reflectClass(ValueListenable);

  /// Declared members, constructors excluded: an interface class still carries
  /// an implicit unnamed constructor that is not part of its surface.
  final members = <String, MethodMirror>{
    for (final d in mirror.declarations.values)
      if (d is MethodMirror && !d.isConstructor)
        MirrorSystem.getName(d.simpleName): d,
  };

  group('ValueListenable surface', () {
    test('declares exactly value, addListener and removeListener', () {
      expect(members.keys.toSet(), {'value', 'addListener', 'removeListener'},
          reason: 'a fourth member, or a renamed one, means $_bridge');
    });

    test('value is a getter over the type parameter, not a field or a method',
        () {
      final value = members['value'];
      expect(value, isNotNull, reason: _bridge);
      expect(value!.isGetter, isTrue,
          reason: "Flutter declares `T get value`; making it a method means "
              '$_bridge');
      expect(value.parameters, isEmpty, reason: _bridge);
      // Kernel-based mirrors erase the declared name of a type variable to
      // `X0`, so identity against the class's own variable is the assertion
      // available: the getter returns T, not a fixed type.
      expect(value.returnType.simpleName, mirror.typeVariables.single.simpleName,
          reason: 'the getter returns the type parameter, so a '
              'ValueListenable<DynamicValue> hands out a DynamicValue');
    });

    test('the class has exactly one type parameter', () {
      expect(mirror.typeVariables, hasLength(1), reason: _bridge);
    });

    for (final name in ['addListener', 'removeListener']) {
      test('$name takes one positional VoidCallback and returns void', () {
        final method = members[name];
        expect(method, isNotNull, reason: _bridge);
        expect(method!.isRegularMethod, isTrue, reason: _bridge);
        expect(MirrorSystem.getName(method.returnType.simpleName), 'void',
            reason: _bridge);

        expect(method.parameters, hasLength(1), reason: _bridge);
        final param = method.parameters.single;
        expect(param.isNamed, isFalse, reason: _bridge);
        expect(param.isOptional, isFalse, reason: _bridge);

        final type = param.type;
        expect(type, isA<FunctionTypeMirror>(),
            reason: 'VoidCallback is the structural typedef `void Function()`, '
                'which is why no conversion is needed at the bridge — $_bridge');
        final fn = type as FunctionTypeMirror;
        expect(fn.parameters, isEmpty, reason: _bridge);
        expect(MirrorSystem.getName(fn.returnType.simpleName), 'void',
            reason: _bridge);
      });
    }

    test('VoidCallback is structurally `void Function()`', () {
      // Assignability in both directions: Flutter's dart:ui VoidCallback and
      // ours are the same structural type, so a listener written against
      // either is accepted by the other.
      void listener() {}
      const VoidCallback fromPlain = _noop;
      expect(fromPlain, isA<void Function()>());
      expect(listener, isA<VoidCallback>());
    });

    test('the library imports nothing — no dart:ui can sneak in', () {
      final library = mirror.owner! as LibraryMirror;
      final imported = library.libraryDependencies
          .where((d) => d.isImport)
          .map((d) => d.targetLibrary?.uri.toString())
          .toList();
      expect(imported, isEmpty,
          reason: 'the twin exists because Flutter\'s version is dart:ui-bound '
              'and the gateway runs on the plain Dart VM; an import here is '
              'how that property gets lost');
    });
  });
}

void _noop() {}
