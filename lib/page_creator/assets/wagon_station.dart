/// `ST_WagonStation`, the way the PLC publishes it, and what one station is
/// doing.
///
/// A pallet wagon runs along a rail and serves a fixed row of stations. The
/// PLC's `FB_Wagon` publishes them as one `ARRAY [1..10] OF ST_WagonStation`,
/// not as ten structs: the array is a single OPC UA node, so the whole row
/// costs one subscription however many stations are actually built. That is
/// the same shape as `ECT_Diag.Device_n_SlaveInfo` — a fixed-size array whose
/// real length is not its declared one — and it is decoded the same way here.
///
/// The tail of the array is not empty, it is *stale*: slots the plant never
/// commissioned hold whatever was last written to them, which is usually
/// zeros and occasionally not. `xEnabled` and a non-empty `sName` are what
/// separate a station from that tail, and [wagonStationsFromValue] is the only
/// place that decision is made — a naive render draws ten docks of garbage.
///
/// Nothing in this library knows about Flutter: it is the data layer under the
/// docks a rails conveyor draws beside its track and the pane a dock opens, so
/// both — and the tests — decode the same array the same way.
library;

import 'package:open62541/open62541.dart' show DynamicValue;

/// Member names on `ST_WagonStation`.
///
/// Every member is prefixed `p_stat_` — the PLC's convention for a published
/// status member, the same one `ST_EcSlaveDiag` uses.
abstract final class WagonStationFields {
  /// `etType`: 0 hands a pallet to the wagon, 1 takes one from it.
  static const type = 'p_stat_etType';

  /// `etLoc`: which side of the rail the station stands on.
  static const location = 'p_stat_etLoc';

  static const enabled = 'p_stat_xEnabled';
  static const atStation = 'p_stat_xAtStation';

  /// `rPosition`: millimetres along the rail from the reference end.
  static const position = 'p_stat_rPosition';

  static const interlock = 'p_stat_xInterLock';
  static const order = 'p_stat_xStationOrder';
  static const ready = 'p_stat_xStationReady';
  static const deliveryComplete = 'p_stat_xDeliveryComplete';
  static const outfeed = 'p_stat_xOutfeed';
  static const outfeedComplete = 'p_stat_xOutfeedComplete';
  static const waitingForInterlock = 'p_stat_xWaitingForInterLock';
  static const name = 'p_stat_sName';
}

/// Which way a pallet moves between the station and the wagon.
enum WagonStationRole {
  /// The station hands a pallet to the wagon.
  source('Source'),

  /// The station takes a pallet from the wagon.
  destination('Destination');

  const WagonStationRole(this.label);

  /// The word a pane prints.
  final String label;

  static WagonStationRole fromRaw(int raw) =>
      raw == 1 ? destination : source;
}

/// Which side of the rail the station stands on.
enum WagonStationSide {
  inFront('Front'),
  behind('Behind');

  const WagonStationSide(this.label);

  final String label;

  static WagonStationSide fromRaw(int raw) => raw == 1 ? behind : inFront;
}

/// What a station is doing, as one word.
///
/// The order of the members is the order they are tested in, and that
/// ordering is the whole point of the derivation: several of the flags are
/// set at once in normal running — a station that is asking is usually also
/// ready — so "which one do you show" is a decision, not a lookup. Blocked
/// outranks everything because it is the only one that means nothing is going
/// to happen until somebody does something.
enum WagonStationState {
  /// The wagon may not travel here, or is parked waiting for this station's
  /// interlock to clear.
  blocked('Blocked'),

  /// The station is running its rollers now.
  delivering('Delivering'),

  /// A source has a pallet ready; a destination can take one.
  ready('Ready'),

  /// The station wants a pallet, or has one to give.
  asking('Asking'),

  /// None of the above.
  idle('Idle');

  const WagonStationState(this.label);

  final String label;
}

/// One entry of the array, decoded.
///
/// Every member of the struct is carried, including the two completion flags
/// the dock does not draw: they are what the pane showing one station's
/// handshake would need, and decoding the struct twice in two places is how
/// the two decodings drift apart.
class WagonStation {
  const WagonStation({
    required this.index,
    required this.name,
    required this.role,
    required this.side,
    required this.position,
    this.enabled = false,
    this.atStation = false,
    this.interlock = false,
    this.order = false,
    this.ready = false,
    this.deliveryComplete = false,
    this.outfeed = false,
    this.outfeedComplete = false,
    this.waitingForInterlock = false,
  });

  /// The station's slot in the array, 1-based, as the PLC counts it.
  ///
  /// Kept after sorting: it is the only stable handle on a station, and the
  /// figure somebody comparing the HMI against the PLC is reading.
  final int index;

  /// `sName`. The label, and never a name this code knows in advance — the
  /// plant's own names live in the PLC, which is where they belong.
  final String name;

  final WagonStationRole role;
  final WagonStationSide side;

  /// Millimetres along the rail from the reference end.
  final double position;

  final bool enabled;
  final bool atStation;
  final bool interlock;
  final bool order;
  final bool ready;
  final bool deliveryComplete;
  final bool outfeed;
  final bool outfeedComplete;
  final bool waitingForInterlock;

  /// A commissioned station, as opposed to the array's stale tail.
  bool get isCommissioned => enabled && name.isNotEmpty;

  /// The one word a dock is coloured by and its pane prints. First match wins; see [WagonStationState].
  WagonStationState get state {
    if (waitingForInterlock || interlock) return WagonStationState.blocked;
    if (outfeed) return WagonStationState.delivering;
    if (ready) return WagonStationState.ready;
    if (order) return WagonStationState.asking;
    return WagonStationState.idle;
  }

  /// The position as a pane prints it, or an em dash when the PLC has not
  /// published a number.
  String get positionLabel =>
      position.isFinite ? '${position.round()} mm' : '—';

  /// Where along the rail this station stands, 0..1, on the same scale as
  /// the wagon's own `p_stat_rPosition_percentage`.
  ///
  /// That scale is `FB_Wagon`'s, not ours: 0 is the reference end and 1 is
  /// the furthest enabled station ([wagonRailLength]). Using it is what makes
  /// a dock line up with the wagon parked at it — both are placed by the same
  /// fraction, so they cannot disagree about where the station is.
  double railFraction(double railLength) {
    if (!position.isFinite || !railLength.isFinite || railLength <= 0) {
      return 0;
    }
    return (position / railLength).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is WagonStation &&
      other.index == index &&
      other.name == name &&
      other.role == role &&
      other.side == side &&
      other.position == position &&
      other.enabled == enabled &&
      other.atStation == atStation &&
      other.interlock == interlock &&
      other.order == order &&
      other.ready == ready &&
      other.deliveryComplete == deliveryComplete &&
      other.outfeed == outfeed &&
      other.outfeedComplete == outfeedComplete &&
      other.waitingForInterlock == waitingForInterlock;

  @override
  int get hashCode => Object.hash(
      index,
      name,
      role,
      side,
      position,
      enabled,
      atStation,
      interlock,
      order,
      ready,
      deliveryComplete,
      outfeed,
      outfeedComplete,
      waitingForInterlock);

  /// Decodes one array element, or null when it is not a struct at all.
  static WagonStation? tryParse(DynamicValue value, {required int index}) {
    if (!value.isObject) return null;
    return WagonStation(
      index: index,
      name: _str(value, WagonStationFields.name),
      role: WagonStationRole.fromRaw(_enum(value, WagonStationFields.type, {
        'source': 0,
        'destination': 1,
      })),
      side: WagonStationSide.fromRaw(_enum(value, WagonStationFields.location, {
        'in_front': 0,
        'infront': 0,
        'front': 0,
        'behind': 1,
      })),
      position: _double(value, WagonStationFields.position),
      enabled: _bool(value, WagonStationFields.enabled),
      atStation: _bool(value, WagonStationFields.atStation),
      interlock: _bool(value, WagonStationFields.interlock),
      order: _bool(value, WagonStationFields.order),
      ready: _bool(value, WagonStationFields.ready),
      deliveryComplete: _bool(value, WagonStationFields.deliveryComplete),
      outfeed: _bool(value, WagonStationFields.outfeed),
      outfeedComplete: _bool(value, WagonStationFields.outfeedComplete),
      waitingForInterlock:
          _bool(value, WagonStationFields.waitingForInterlock),
    );
  }
}

/// The commissioned stations in [array], left to right along the rail.
///
/// Two things happen here and nowhere else:
///
///  - the array's uncommissioned tail is dropped ([WagonStation.isCommissioned]);
///  - what is left is ordered by [WagonStation.position], so it reads the
///    way the rail does rather than the way the PLC declared the array.
///
/// The sort is stable on the array index, so two stations sharing a position
/// — which the PLC allows, one in front and one behind — keep the order the
/// PLC lists them in instead of swapping about between readings.
List<WagonStation> wagonStationsFromValue(DynamicValue? array) {
  if (array == null || !array.isArray) return const [];
  final stations = <WagonStation>[];
  final elements = array.asArray;
  for (var i = 0; i < elements.length; i++) {
    final station = WagonStation.tryParse(elements[i], index: i + 1);
    if (station != null && station.isCommissioned) stations.add(station);
  }
  stations.sort((a, b) {
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0 ? byPosition : a.index.compareTo(b.index);
  });
  return stations;
}

/// The length of the rail the wagon's percentage is measured against: the
/// furthest position of any *enabled* entry, in mm.
///
/// This mirrors `FB_Wagon` line for line — `rMaxStationPosition` is the
/// maximum `p_stat_rPosition` over entries with `xEnabled` set, and the name
/// plays no part in it. [wagonStationsFromValue] is stricter about what it
/// draws, but the scale has to be the PLC's or a dock drifts off the wagon
/// parked at it. Zero when nothing is enabled or the value is not an array.
double wagonRailLength(DynamicValue? array) {
  if (array == null || !array.isArray) return 0;
  var longest = 0.0;
  for (final element in array.asArray) {
    if (!element.isObject || !_bool(element, WagonStationFields.enabled)) {
      continue;
    }
    final position = _double(element, WagonStationFields.position);
    if (position.isFinite && position > longest) longest = position;
  }
  return longest;
}

/// A row of stations for goldens and for tests that want a plausible rail
/// without building an array — a picture of the thing.
///
/// Deliberately invented names: a sample is drawn into a golden, and a golden
/// is a published image.
List<WagonStation> sampleWagonStations() => const [
      WagonStation(
        index: 1,
        name: 'Infeed 1',
        role: WagonStationRole.source,
        side: WagonStationSide.inFront,
        position: 0,
        enabled: true,
        order: true,
        ready: true,
      ),
      WagonStation(
        index: 2,
        name: 'Infeed 2',
        role: WagonStationRole.source,
        side: WagonStationSide.behind,
        position: 2400,
        enabled: true,
        atStation: true,
        outfeed: true,
      ),
      WagonStation(
        index: 3,
        name: 'Buffer',
        role: WagonStationRole.destination,
        side: WagonStationSide.inFront,
        position: 5200,
        enabled: true,
        order: true,
      ),
      WagonStation(
        index: 4,
        name: 'Store A',
        role: WagonStationRole.destination,
        side: WagonStationSide.behind,
        position: 8600,
        enabled: true,
        interlock: true,
      ),
      WagonStation(
        index: 5,
        name: 'Store B',
        role: WagonStationRole.destination,
        side: WagonStationSide.behind,
        position: 11800,
        enabled: true,
      ),
    ];

// `DynamicValue.operator[]` throws on a missing member, so every read is
// guarded: a PLC running an older revision of the DUT must degrade to a
// quieter dock, not take the page down.
bool _bool(DynamicValue v, String f) => v.contains(f) ? v[f].asBool : false;

double _double(DynamicValue v, String f) =>
    v.contains(f) ? v[f].asDouble : 0.0;

String _str(DynamicValue v, String f) =>
    v.contains(f) ? v[f].asString.trim() : '';

/// An enum member as its ordinal.
///
/// TwinCAT's OPC UA server publishes an enum as its numeric value, which is
/// what [names] is a fallback for rather than the main path: a server
/// configured to publish the enum's *name* instead would otherwise land every
/// station on ordinal 0 silently, and a whole rail of sources looks
/// plausible enough to go unnoticed.
int _enum(DynamicValue v, String f, Map<String, int> names) {
  if (!v.contains(f)) return 0;
  final member = v[f];
  if (member.isString) {
    final text = member.asString.trim().toLowerCase();
    final parsed = int.tryParse(text);
    if (parsed != null) return parsed;
    for (final entry in names.entries) {
      if (text == entry.key || text.endsWith(entry.key)) return entry.value;
    }
    return 0;
  }
  return member.asInt;
}
