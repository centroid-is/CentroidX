import 'gateway_config.dart';

/// Gateway mode, pointed at the origin the page was served from.
///
/// A browser did not appear from nowhere — it loaded this application over the
/// network, and the host that served it is, in the ordinary case, the gateway
/// itself. So the default needs no configuration at all: open the page and it
/// dials back to where it came from, over `wss` if the page came over `https`.
///
/// Deriving the scheme from the page rather than hardcoding `wss` is
/// deliberate. A page served over `https` cannot open a plain `ws` socket —
/// browsers refuse mixed content — so anything but `wss` there is a dial that
/// could never connect. A bench gateway served over `http` gets `ws`, which is
/// the same latitude `checkDialable` already grants a bench station.
///
/// Only a *default*. A row in the device-local store wins, so Server Config can
/// still point a browser at a different gateway and that choice survives a
/// reload — it is stored in this browser, not on the gateway, exactly as a
/// station's transport row is stored on the station.
GatewayConfig defaultGatewayConfig() {
  final page = Uri.base;
  final scheme = page.scheme == 'http' ? 'ws' : 'wss';
  final authority = page.hasPort && page.port != 0
      ? '${page.host}:${page.port}'
      : page.host;
  return GatewayConfig(
    mode: TransportMode.gateway,
    // An empty host would mean the page came from something with no origin —
    // a `file://` URL. There is no gateway to guess at there, so leave the URL
    // empty and let the link report that it cannot dial, rather than inventing
    // `wss://` and failing somewhere less legible.
    url: page.host.isEmpty ? '' : '$scheme://$authority',
  );
}
