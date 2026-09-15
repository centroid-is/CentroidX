import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/state_man_types.dart';

import '../providers/state_man.dart';

/// Builds from the live value of one key, subscribing exactly once.
///
/// The panes and dialogs used to write
/// `StreamBuilder(stream: ref.watch(stateManProvider.future).asStream()
/// .switchMap(...subscribe...))` straight in `build`. That makes a new
/// stream object on every rebuild, and `StreamBuilder` answers a new stream
/// by cancelling the old one and starting over in `ConnectionState.waiting`.
/// So any rebuild -- and tapping a text field is one: focus moves, the pane
/// rebuilds -- replaced the content with "Connecting", unmounted the field,
/// and threw the keystrokes away. That is why a conveyor's speed could not be
/// changed and why the recipes dialog lost its cursor.
///
/// Here the stream is created in state, once per [keyName], and survives
/// rebuilds. It is recreated only when the key changes. The waiting and error
/// widgets are the caller's, so a pane can keep its own chrome around them.
class StateManValueBuilder extends ConsumerStatefulWidget {
  const StateManValueBuilder({
    super.key,
    required this.keyName,
    required this.builder,
    this.waiting,
    this.error,
  });

  final String keyName;

  /// Called with the [StateMan] that produced the value, so the content can
  /// write back through it.
  final Widget Function(BuildContext context, StateMan stateMan, DynamicValue value)
      builder;
  final WidgetBuilder? waiting;
  final Widget Function(BuildContext context, Object error)? error;

  @override
  ConsumerState<StateManValueBuilder> createState() => _StateManValueBuilderState();
}

class _StateManValueBuilderState extends ConsumerState<StateManValueBuilder> {
  Stream<(StateMan, DynamicValue)>? _stream;
  String? _streamKey;

  Stream<(StateMan, DynamicValue)> _streamFor(String keyName) {
    final cached = _stream;
    if (cached != null && _streamKey == keyName) return cached;
    _streamKey = keyName;
    return _stream = ref.read(stateManProvider.future).asStream().switchMap(
          (stateMan) => stateMan.subscribe(keyName).asStream().switchMap(
                (values) => values.map((value) => (stateMan, value)),
              ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<(StateMan, DynamicValue)>(
      stream: _streamFor(widget.keyName),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.error?.call(context, snapshot.error!) ??
              Center(child: Text('Error: ${snapshot.error}'));
        }
        final data = snapshot.data;
        if (data == null) {
          return widget.waiting?.call(context) ??
              const Center(child: CircularProgressIndicator());
        }
        final (stateMan, value) = data;
        return widget.builder(context, stateMan, value);
      },
    );
  }
}
