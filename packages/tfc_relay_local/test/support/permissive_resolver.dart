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
/// call `buildGateway`, which now requires a resolver.
///
/// **The third copy of this class**, after `tfc_relay_server`'s and
/// `tfc_relay_client`'s. A Dart package cannot import another package's
/// `test/` directory, and the alternative — one copy in some `lib/` that all
/// three could reach — is exactly the production hole the sweep exists to
/// prevent, because a resolver available in a `lib/` is the one a composition
/// root binds. Three files of four one-line methods is the cheaper half of
/// that trade by a wide margin.
///
/// The gateway *process* does not use this. `bin/relay_gateway.dart` declares
/// `NoSeriesMapped`, which refuses everything, and that difference is
/// deliberate: a fixture wants every table servable, and a plant wants none
/// served that nobody mapped.
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
