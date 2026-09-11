/// A pure-Dart twin of Flutter's `ValueListenable`, so the gateway can hand a
/// widget something `ValueListenableBuilder` will later accept without this
/// package ever depending on Flutter.
///
/// Flutter declares `abstract class ValueListenable<T> extends Listenable` in
/// `flutter/lib/src/foundation/change_notifier.dart:94`, in a library whose
/// line 9 is `import 'dart:ui' show VoidCallback;`. `dart:ui` does not exist
/// outside Flutter, and the gateway runs on the plain Dart VM — so a pure-Dart
/// package cannot implement Flutter's interface, and this file re-declares it
/// instead. [VERIFIED against Flutter 3.41.9.]
///
/// The interface is three members, and `VoidCallback` is the structural
/// typedef `void Function()`, so the two declarations line up
/// character-for-character and no adapter or conversion is needed anywhere.
/// The Flutter-side companion — the builder widget that listens to this
/// interface directly, the `ChangeNotifier` escape hatch, and the guard class
/// that `implements` both interfaces at once so drift breaks the build —
/// arrives with the client in Phase 4. Until a Flutter consumer exists,
/// `test/value_listenable_signature_test.dart` guards this side by reflection.
///
/// Nothing is imported here on purpose; an import is how the Flutter-free
/// property gets lost.
library;

/// Structurally identical to `dart:ui`'s `VoidCallback`.
typedef VoidCallback = void Function();

/// An object holding a value that can be observed for change.
///
/// The observation contract is deliberately thin: listeners are told *that*
/// the value changed, never what it changed to. The implementation
/// ([ValueStoreNode]) only notifies on a genuine change, which is what makes
/// 1500 keys on one page cost k rebuilds per batch instead of 1500.
abstract interface class ValueListenable<T> {
  /// The current value. Reading is always safe and never throws.
  T get value;

  /// Registers [listener], called synchronously whenever [value] changes.
  ///
  /// Adding the same listener twice registers it twice; it is then called
  /// twice per change and must be removed twice.
  void addListener(VoidCallback listener);

  /// Removes one registration of [listener]. Removing a listener that was
  /// never added is a no-op, so teardown paths need no bookkeeping.
  void removeListener(VoidCallback listener);
}
