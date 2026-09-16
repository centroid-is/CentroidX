/// How a browser learns where the gateway is when nobody has told *it*: the
/// host that served the page declares it.
///
/// ## The three answers, in order
///
/// 1. **The device-local `gateway_transport` row** — what Server Config saved
///    in this browser. Always wins; `readGatewayConfig` returns it before this
///    file is consulted, so a person's choice survives every redeploy of the
///    bundle. Nothing here can overwrite or invalidate it.
/// 2. **The declaration served with the page** — a `<meta>` tag in
///    `index.html`, [kGatewayDeclarationMetaName]. The host serving the bundle
///    knows the gateway's address, and a static file server can rewrite one
///    line of HTML without rebuilding a seven-megabyte bundle — where a
///    `--dart-define` would pin the address into the build, which is exactly
///    the wrong place for a thing the *server* declares. A `gateway.json`
///    fetched at boot would carry the same information at the cost of a
///    network round trip, and a failure mode, before the first frame; the tag
///    is in the document already.
/// 3. **The page's own origin** — the gateway served the page itself, the
///    ordinary production case, and the default before declarations existed.
///
/// ## What "no declaration" is
///
/// A tag that is absent, empty, whitespace, or still carries the template's
/// placeholder ([kGatewayDeclarationPlaceholder], the `$FLUTTER_BASE_HREF`
/// convention) is **no declaration** and falls through to the origin. That is
/// what keeps the template inert: a bundle served by something that does not
/// know about the tag behaves exactly as it did before the tag existed, never
/// as a configured-but-broken gateway.
///
/// ## What a malformed declaration is
///
/// Anything else is taken **verbatim** — through [normalizeGatewayAddress], so
/// `10.50.10.11:9443` becomes `wss://10.50.10.11:9443` exactly as it does in
/// the Server Config field — and handed to `GatewayConfig`, whose
/// `validationError` refuses a bad one *by name*: the link reports
/// "misconfigured" with the declared text in it, and Server Config opens
/// because nobody can sign in through a refused link. Deliberately not
/// silently dropped: an integrator who typos the address must see the typo,
/// not a browser that dialled its own origin and failed somewhere less
/// legible.
///
/// ## Why this is not in `gateway_default_web.dart`
///
/// That arm reads the DOM and so cannot be exercised on the VM. Everything
/// that can be decided without a DOM — the precedence between declaration and
/// origin, the placeholder rule, the normalisation — is decided here, in a
/// pure function a VM test drives with any page and any declaration, and the
/// web arm's whole job is to fetch the two inputs and call it.
library;

import 'gateway_config.dart';

/// The `name` of the `<meta>` tag a serving host declares the gateway in:
///
///     <meta name="centroidx-gateway" content="wss://10.50.10.11:9443">
///
/// The `content` is what an integrator has written down — `wss://host:port`,
/// or `host:port` and the secure scheme is supplied.
const String kGatewayDeclarationMetaName = 'centroidx-gateway';

/// The template's un-substituted value, which is no declaration at all.
///
/// A dollar-prefixed token the way `$FLUTTER_BASE_HREF` is, so the same
/// serve-time substitution reaches both, and matched exactly rather than by
/// prefix: any other `$`-something is a real declaration that happens to be
/// wrong, and it is refused by name like any other typo.
const String kGatewayDeclarationPlaceholder = r'$CENTROIDX_GATEWAY';

/// The transport a browser comes up on with no stored row: the declaration
/// when there is one, the page's origin when there is not.
///
/// [page] is the page's own URL (`Uri.base` in a browser). [declared] is the
/// `<meta>` tag's content, or null when the tag is absent.
GatewayConfig gatewayDefaultFor({required Uri page, String? declared}) {
  final declaration = declared?.trim() ?? '';
  if (declaration.isNotEmpty &&
      declaration != kGatewayDeclarationPlaceholder) {
    return GatewayConfig(
      mode: TransportMode.gateway,
      url: normalizeGatewayAddress(declaration),
    );
  }

  // The origin. Deriving the scheme from the page rather than hardcoding
  // `wss` is deliberate, and the two cases it produces are not equally useful.
  // A page served over `https` gets `wss`, which is the production case. A
  // page served over `http` gets `ws`, which a browser client refuses **by
  // name** — at the field (`GatewayConfig.validationError`), at boot
  // (`undialable`, which lands as `GatewayLinkKind.notBuilt`), and at
  // construction (`ClientConfig.checkDialable`). That refusal is the point of
  // keeping `ws` here: the alternative, `wss://` to an origin that speaks
  // plain `http`, is a dial that fails its handshake and spends the
  // fifteen-second patience window before the panel says anything, and then
  // blames the network. Refused by name, the link says "misconfigured",
  // nobody can sign in, and the Server Config exemption opens the one page
  // where the real address is typed — which is what a bench serving the
  // bundle from a plain static server on `http://127.0.0.1` needs on its
  // first load, and what the declaration above exists to make unnecessary.
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
