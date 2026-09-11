/// Setting a subdevice's reset handshakes.
///
/// `FB_EcDeviceDiag` owns both edges: the HMI writes TRUE, the FB does the
/// reset and writes FALSE, so only TRUE is ever sent and nothing can get stuck
/// high on this side.
///
/// Behind an interface because *how* it is written depends on what the server
/// publishes. TwinCAT publishes the arrays, their elements and each member as
/// separate nodes (`ECT_Diag.Device_1_Diag[17].p_cmd_resetCrcCounter`), so the
/// default writes that one BOOL through a key derived from the array's
/// mapping (see `KeyMappings.lookupNodeId`). A server that only publishes the
/// array whole gets [EcArrayCommandWriter] through [ecCommandWriterProvider],
/// and nothing that calls it changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;

import '../../providers/state_man.dart';
import '../../widgets/tag_access_guard.dart' show writeTag;

abstract class EcCommandWriter {
  const EcCommandWriter();

  /// Sets [member] TRUE on subdevice [position] of the array at [diagKey].
  ///
  /// True when the write went out, false when the access guard refused it
  /// (the operator has already been told why). Comms failures throw.
  Future<bool> setCommand(
    WidgetRef ref, {
    required String diagKey,
    required int position,
    required String member,
  });
}

/// Writes the member node itself: `<diagKey>[<position>].<member>`.
///
/// One BOOL on the wire. Nothing else in the struct is touched, so the
/// counters the FB accumulates in place cannot be rolled back and two HMIs
/// resetting two subdevices at once cannot clobber each other.
class EcMemberCommandWriter extends EcCommandWriter {
  const EcMemberCommandWriter();

  /// The derived key for [member] of subdevice [position].
  static String keyFor(String diagKey, int position, String member) =>
      '$diagKey[$position].$member';

  @override
  Future<bool> setCommand(
    WidgetRef ref, {
    required String diagKey,
    required int position,
    required String member,
  }) async {
    final sm = await ref.read(stateManProvider.future);
    return writeTag(
      ref,
      sm,
      keyFor(diagKey, position, member),
      DynamicValue(value: true, typeId: NodeId.boolean),
      member: member,
    );
  }
}

/// Reads the whole array, flips one member of one element, writes it back.
///
/// For a server that publishes the array but not its elements.
///
/// Read immediately before the write, so the only difference from what the
/// PLC holds is the flag — the access guard's diff sees exactly one member
/// move. The cost is that the counters the FB accumulates in place
/// (`aLinkLostPort`, `nCrcStableS`) are written back as they were read, a
/// round trip earlier: at worst one increment is lost, and the FB rewrites
/// every other `p_stat_` member within its next poll.
class EcArrayCommandWriter extends EcCommandWriter {
  const EcArrayCommandWriter();

  static const _readTimeout = Duration(seconds: 5);

  @override
  Future<bool> setCommand(
    WidgetRef ref, {
    required String diagKey,
    required int position,
    required String member,
  }) async {
    final sm = await ref.read(stateManProvider.future);
    final latest = await sm.read(diagKey).timeout(_readTimeout);
    if (!latest.isArray ||
        position < 1 ||
        position > latest.asArray.length ||
        !latest[position - 1].contains(member)) {
      throw StateError('Subdevice $position has no $member in $diagKey');
    }
    final next = DynamicValue.from(latest);
    next[position - 1][member] = true;
    return writeTag(ref, sm, diagKey, next, member: member);
  }
}

final ecCommandWriterProvider =
    Provider<EcCommandWriter>((_) => const EcMemberCommandWriter());
