/// The socket-level fault kit: break the network on purpose, then measure it.
///
/// A **second library entry**, deliberately not folded into
/// `tfc_stateman_contract.dart`. The contract barrel makes the argument at its
/// own lines 59-63 — the reference implementation is not exported from there,
/// so nothing can acquire an implementation by depending on the contract — and
/// the same argument applies with more force here. Everything behind this
/// entry reaches for `dart:io` sockets and `Process`. An implementation that
/// imports the contract to be judged by it must not acquire the ability to
/// spawn `lsof` and set raw socket options by doing so, and a `LocalStateMan`
/// that one day runs somewhere without `Process` must not fail to compile
/// because the suite it is measured against shells out. Two entry points keep
/// that dependency direction greppable; one entry point makes it a convention
/// nobody can enforce.
///
/// Import path: `package:tfc_stateman_contract/faults.dart`.
///
/// The kit grows through this phase — the fault proxy, the delay line, the
/// scenario schedule, the malformed peer and the channel harness all land
/// behind this entry. What is here now is the ground floor every one of them
/// stands on: counting descriptors, forcing a genuine reset, and asking the
/// machine what it is allowed to do.
library;

export 'src/faults/capabilities.dart';
export 'src/faults/delay_line.dart';
export 'src/faults/fault_proxy.dart';
export 'src/faults/fd_count.dart';
export 'src/faults/line_channel.dart';
export 'src/faults/os_level.dart';
export 'src/faults/scenario_schedule.dart';
export 'src/faults/socket_harness.dart';
export 'src/faults/socket_ops.dart';
