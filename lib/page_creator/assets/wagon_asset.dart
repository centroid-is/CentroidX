/// The layer every pallet-wagon asset sits on.
///
/// A strip of stations, a wagon pane and whatever is drawn next are not alike
/// on screen, but they read the same two things off the PLC: the wagon's
/// `ARRAY [1..10] OF ST_WagonStation`, and — optionally — the wagon's own
/// state string. That is a fact about one family of equipment, not about
/// every asset on a page, so it lives here rather than on [BaseAsset], and an
/// asset joins the family by extending this instead.
///
/// **The two-key contract.** The subscribe budget on this project is about two
/// keys per asset, and the PLC's struct has thirteen members per station
/// across ten stations. A key per field would be 130 subscriptions for one
/// picture. So the array is read as *one* node and decoded on this side
/// ([wagonStationsFromValue]), exactly as the EtherCAT device table reads
/// `ECT_Diag.Device_n_SlaveInfo`. Nothing in this family may add a third
/// key without a very good reason; adding a per-field one is the mistake the
/// contract exists to prevent.
library;

import 'package:json_annotation/json_annotation.dart';

import 'common.dart';

part 'wagon_asset.g.dart';

/// The section heading the family's settings sit under in the multi-select
/// property editor.
const String wagonBulkGroup = 'Wagon';

@JsonSerializable(createFactory: false, explicitToJson: true)
abstract class WagonAsset extends BaseAsset {
  WagonAsset({this.stationsKey = '', this.wagonStateKey});

  /// The key of the wagon's `ARRAY [1..10] OF ST_WagonStation`.
  ///
  /// One node for the whole row. Empty means the asset is not bound yet, and
  /// every asset in this family draws a sample of itself rather than an empty
  /// box while that is true.
  ///
  /// `defaultValue` rather than a nullable field: a page saved by a build
  /// that did not have this asset cannot contain the member at all, and an
  /// unbound asset and a missing one should look the same.
  @JsonKey(defaultValue: '')
  String stationsKey;

  /// The key of the wagon's own state string (`p_cmd_sWagonState`), or null.
  ///
  /// Optional on purpose. It is the second half of the subscribe budget, and
  /// plenty of pages will want the stations without spending it — so every
  /// asset in this family must render correctly with only [stationsKey]
  /// bound. `includeIfNull: false` keeps that additive: an asset that never
  /// had one round-trips without the member.
  @JsonKey(includeIfNull: false)
  String? wagonStateKey;

  /// Whether a wagon state string was actually bound, as opposed to the field
  /// existing and holding an empty string — which is what the key picker
  /// leaves behind when somebody clears it.
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get hasWagonState => (wagonStateKey ?? '').isNotEmpty;

  /// Stated rather than inherited.
  ///
  /// `BaseAsset.allKeys` would find both of these by their `…Key` names, and
  /// would go on finding them right up until somebody renamed a JSON field or
  /// added a `positionKey` that is not a tag. The family's key list is its
  /// contract with the subscribe budget, so it is written down.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get allKeys => [
        if (stationsKey.isNotEmpty) stationsKey,
        if (hasWagonState) wagonStateKey!,
      ];

  // No bulk rows for the two keys, deliberately. `TextBulkProperty` does not
  // carry key fields: bulk-setting a tag name points every selected asset at
  // one signal, and `bulk_property_test` holds that line. Keys are set one at
  // a time in the per-asset form, where the key picker can vet them.
}
