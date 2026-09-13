import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Reordering the asset list (send to back / bring to front) must MOVE the
/// existing asset elements, not rebuild every asset at its new index. Asset
/// subtrees hold live state — stream subscriptions, in-flight futures — and
/// an unkeyed reorder either tears that state down (assets of different
/// types) or silently rebinds it to a *different* asset (assets of the same
/// type); both make a z-order change look like a full page reload.
/// `AssetStack` guarantees neither happens by keying each asset's
/// `Positioned` on the asset's identity.
void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('reordering assets preserves their widget state',
      (tester) async {
    const names = ['a', 'b', 'c'];
    // How often a State was created for each asset, and every case of a
    // State created for one asset ending up rendering another.
    final initCounts = <String, int>{};
    final rebinds = <String>[];
    final assets = <Asset>[
      for (var i = 0; i < names.length; i++)
        _StatefulTestAsset(
          names[i],
          coords: Coordinates(x: 0.2 + 0.3 * i, y: 0.5),
          onInit: (name) => initCounts[name] = (initCounts[name] ?? 0) + 1,
          onRebind: (from, to) => rebinds.add('$from->$to'),
        ),
    ];

    await tester.pumpWidget(_wrapStack(assets));
    await tester.pumpAndSettle();
    expect(initCounts, {'a': 1, 'b': 1, 'c': 1});

    // Send 'c' to the back, the same in-place mutation the editor performs.
    final reordered = sendToBackOrder(assets, {assets[2]});
    assets
      ..clear()
      ..addAll(reordered);
    await tester.pumpWidget(_wrapStack(assets));
    await tester.pumpAndSettle();

    // And bring the new bottom-most back to the front again.
    final fronted = bringToFrontOrder(assets, {assets.first});
    assets
      ..clear()
      ..addAll(fronted);
    await tester.pumpWidget(_wrapStack(assets));
    await tester.pumpAndSettle();

    expect(initCounts, {'a': 1, 'b': 1, 'c': 1},
        reason: 'a z-order change must not recreate any asset state');
    expect(rebinds, isEmpty,
        reason: "a z-order change must not hand one asset's live state "
            'to another asset');
  });
}

Widget _wrapStack(List<Asset> assets) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: LayoutBuilder(
              builder: (context, constraints) => AssetStack(
                assets: assets,
                constraints: constraints,
                selectedAssets: const {},
                mirroringDisabled: true,
                absorb: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Minimal stateful asset: reports when its State is created and when an
/// existing State finds itself serving a different asset — the two failure
/// modes of an unkeyed reorder.
class _StatefulTestAsset extends BaseAsset {
  @override
  String get displayName => 'StatefulTestAsset';
  @override
  String get category => 'Test';

  final String name;
  final void Function(String name) onInit;
  final void Function(String from, String to) onRebind;

  _StatefulTestAsset(
    this.name, {
    required Coordinates coords,
    required this.onInit,
    required this.onRebind,
  }) {
    coordinates = coords;
    size = const RelativeSize(width: 0.2, height: 0.2);
  }

  @override
  Widget build(BuildContext context) =>
      _StateProbe(name: name, onInit: onInit, onRebind: onRebind);

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: 'StatefulTestAsset'};
}

class _StateProbe extends StatefulWidget {
  const _StateProbe({
    required this.name,
    required this.onInit,
    required this.onRebind,
  });

  final String name;
  final void Function(String name) onInit;
  final void Function(String from, String to) onRebind;

  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  /// The asset this State was created for — stands in for the per-asset
  /// resources (subscriptions, futures) a real asset's State would hold.
  late final String initialName;

  @override
  void initState() {
    super.initState();
    initialName = widget.name;
    widget.onInit(initialName);
  }

  @override
  void didUpdateWidget(_StateProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.name != initialName) {
      widget.onRebind(initialName, widget.name);
    }
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF00FF00));
}
