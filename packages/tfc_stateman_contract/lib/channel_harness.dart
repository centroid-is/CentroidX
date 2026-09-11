/// The socket-free half of the fault harness: a `StateManApi` served over a
/// message channel, with no sockets anywhere behind it.
///
/// A **third library entry**, and the reason is the same one the other two
/// already make, pointed the other way. The contract barrel
/// (`tfc_stateman_contract.dart:59-63`) exports no implementation, so nothing
/// can acquire one by depending on the contract. `faults.dart` is separate
/// because everything behind it reaches for `dart:io` sockets and `Process`,
/// and an implementation being judged must not acquire the ability to shell out
/// to `lsof` by being judged. This entry exists because the converse also has
/// to be true: the channel harness must be importable **without** acquiring
/// sockets.
///
/// That is not tidiness. Phase 3's server session and Phase 4's
/// `RemoteStateMan` are both judged over this channel, and Flutter web is a
/// hard constraint on the client half — a harness that dragged `dart:io` in
/// would be a harness the browser client could never be tested with, discovered
/// at the point where it is too late to restructure. The enforcement is a grep
/// that has to keep returning nothing:
///
/// ```sh
/// grep -rnE "^import .dart:io" lib/channel_harness.dart lib/src/channel/
/// ```
///
/// It matches an import directive rather than the library's name, because the
/// name is discussed in prose in these files and a check a comment can trip is
/// a check that gets deleted. The socket-backed leg of the same idea lands
/// behind `faults.dart` in plan 02-12.
///
/// Import path: `package:tfc_stateman_contract/channel_harness.dart`.
///
/// ```dart
/// void main() {
///   runSubscribeContract(channelServedFake);
///   runStoreContract(channelServedFake);
/// }
/// ```
///
/// That is the whole integration, and it is deliberately the same shape as
/// `test/subscribe_contract_test.dart`'s direct one: a factory in, a sub-suite
/// out, no case rewritten. What the channel driver proves that the direct one
/// cannot is that the property survives a message boundary — and
/// `test/channel/channel_bite_test.dart` is what makes that claim honest, by
/// severing the boundary and showing the same named checks fail.
///
/// The reference implementation *is* reachable from here, unlike from the
/// contract barrel: [channelServedFake] builds a `FakeStateMan`. That is the
/// deliberate difference between a contract and a harness — a harness has to
/// have something to serve — and it is why this entry is not folded into the
/// barrel.
library;

export 'src/channel/channel_harness.dart';
export 'src/channel/channel_pair.dart';
export 'src/channel/channel_state_man.dart';
export 'src/channel/channel_sub_apis.dart';
export 'src/channel/malformed_peer.dart';
export 'src/channel/rpc_names.dart';
export 'src/channel/served_state_man.dart';
