import 'gateway_config.dart';

/// Unchanged station behaviour: direct, with no URL.
///
/// [page] and [declared] are the web arm's parameters — the origin a browser
/// was served from, and what the serving host declared to it. A station's
/// default depends on neither, so both are accepted and ignored here; the two
/// arms have to share one signature.
GatewayConfig defaultGatewayConfig({Uri? page, String? declared}) =>
    GatewayConfig.defaults;
