/// The fixtures' series resolver, which production may not have.
///
/// **A gateway running this would police nothing**: every node id and every
/// table name is answered with a plant key equal to its own name, so `canSee`
/// is asked about a string the caller supplied and a hiding policy can only
/// hide what a client already knew how to spell. That sentence is the whole
/// reason `SeriesResolver` has no implementation in any `lib/`
/// (`series_address.dart:150-158`, and the sweep in the server package's
/// `handler_table_test.dart` that enforces it): a permissive default ships,
/// something binds to it because it is the only one available, and
/// 10-CONTEXT amendment 6's fail-closed rule becomes advice.
///
/// It lives here, in `test/support/`, because the fixtures in this package
/// build their own `RelayServer` and it now takes a resolver.
///
/// The server package has **a second copy** of this class in its own
/// `test/support/permissive_resolver.dart`, because a Dart package cannot
/// import another package's `test/` directory and the alternative — moving
/// one of
/// them into a `lib/` so both could reach it — is exactly the production hole
/// the sweep exists to prevent. Two small test-only classes are cheaper than
/// one production hole, and the duplication is the cheaper half by a wide
/// margin: this file is four one-line methods.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Maps every name to itself. See this library's doc.
final class PermissiveSeriesResolver implements SeriesResolver {
  const PermissiveSeriesResolver();

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    return ResolvedSeries(
      table: address.series,
      member: address.member,
      plantKey: address.series,
    );
  }

  @override
  String? keyForTable(String table) => table;

  @override
  String? keyForNode(String nodeId) => nodeId;
}
