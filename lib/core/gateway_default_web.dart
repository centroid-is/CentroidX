import 'package:web/web.dart' as web;

import 'gateway_config.dart';
import 'gateway_declaration.dart';

/// Gateway mode, pointed at what the serving host declared — or, failing that,
/// at the origin the page was served from.
///
/// The decision is `gateway_declaration.dart`'s, and its library doc holds the
/// reasoning: the precedence, what counts as no declaration, and why a
/// malformed one is refused by name rather than dropped. This arm only fetches
/// the two inputs a browser has — its own URL and the `<meta>` tag — and
/// hands them over, so that everything decidable without a DOM is decided in a
/// file the VM can test.
///
/// Only a *default*. A row in the device-local store wins, so Server Config
/// can still point a browser at a different gateway and that choice survives
/// a reload — it is stored in this browser, not on the gateway, exactly as a
/// station's transport row is stored on the station.
///
/// [page] and [declared] default to the document's own; both are parameters
/// only so a caller that already holds them can pass them through. The
/// station arm accepts and ignores them — the two arms share one signature.
GatewayConfig defaultGatewayConfig({Uri? page, String? declared}) =>
    gatewayDefaultFor(
      page: page ?? Uri.base,
      declared: declared ?? readGatewayDeclaration(),
    );

/// The `content` of the page's [kGatewayDeclarationMetaName] tag, or null when
/// the page carries none.
///
/// The attribute, not the element's typed `content` property, so an element
/// that is somehow not a `<meta>` (a hand-edited page) reads as its attribute
/// or as nothing rather than as a cast failure at boot.
String? readGatewayDeclaration() => web.document
    .querySelector('meta[name="$kGatewayDeclarationMetaName"]')
    ?.getAttribute('content');
