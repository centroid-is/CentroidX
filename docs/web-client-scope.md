# The web client — scope, and the rulings behind it

Decided with Jón, 2026-09-09, while porting `feat/relay-pipe` to the browser.
Written down because every one of these was arrived at by measurement or by a
deliberate call, and re-deriving them costs a day each.

## What the browser is

A **client of the gateway, and only that.** It holds no PLC session, no
database and no secrets. Direct mode is not a feature a web build is missing —
it is a thing a browser cannot be.

## The routes it carries

Eight, and no others:

| route | notes |
|---|---|
| page view | the plant pages |
| alarm view | |
| alarm editor | added 2026-09-09; writes `alarm_man_config`, which now crosses the socket |
| access | |
| audit trail | |
| sign in | |
| server config | edits the **backend's** config through `BackendConfigApi` |
| page editor | |

Everything else is **absent from the build**, not stubbed. That is what
`centroid-hmi/lib/main_web.dart` is for: a second entrypoint with its own route
table, built with `flutter build web -t lib/main_web.dart`. Native `main.dart`
is untouched.

A page that compiles and then fails at runtime on a laptop is worse than a page
the navigation never offers, and the second is also what makes the build
succeed at all.

## The rulings

- **D-Bus: never.** Not "not yet" — a browser has no business with NetworkManager,
  systemd-timesyncd or the session bus, and the commissioning pages that use
  them are panel work by definition. A guard test keeps it out, because right
  now it is absent by luck rather than by rule.
- **MCP: off in web** for the foreseeable future.
- **media_kit / RTSP: deferred.** Jón is following up with mediamtx.
- **pdfrx: deferred.**
- **No local database, and no local cache beyond the device-local store.**
  What a station keeps in `config.sqlite` — the transport row, the theme,
  the session — a browser keeps in its own per-origin `localStorage`
  through `shared_preferences`; `lib/providers/device_local_store_open.dart`
  is the seam, and `main_web.dart` opens it before `runApp` exactly as
  `main.dart` does. (Measured 2026-09-16: with that call missing, every
  provider on the boot path held a `StateError`, the home route rendered
  the blank it renders when there are no pages, and the console said
  nothing.) So drift-on-WASM is *not* wanted: the database layer is
  excluded rather than ported. `database_drift.dart`'s executor seam is
  where `WasmDatabase.open` would go if that ever changes — drift 2.31
  ships `wasm.dart`, and it wants `sqlite3.wasm` + `drift_worker.js` served
  from `web/` plus COOP/COEP headers for OPFS.
- **The keychain is none.** `SecureStorage` gets `BrowserSecureStorage`, an
  in-memory map: the gateway keeps the secrets, and the only secret-flagged
  key a web boot touches is the default `state_man_config` a gateway client
  never dials with. Not `flutter_secure_storage`'s web arm, which needs
  `crypto.subtle` and therefore a secure context — a page opened over
  `http://` on a LAN address would throw on its first secret read.
- **The serving host declares the gateway.** A browser served from a host
  that is not the gateway used to come up misconfigured until somebody typed
  the address into Server Config. Now `index.html` carries
  `<meta name="centroidx-gateway" content="$CENTROIDX_GATEWAY">` and the
  serving host substitutes the address (`wss://host:port`, or `host:port`
  and `wss` is supplied) the way it substitutes `$FLUTTER_BASE_HREF` — one
  line of HTML, no rebuild. Precedence, and nothing cleverer: the stored
  `gateway_transport` row, then the declaration, then the page's origin.
  An absent, empty or un-substituted tag is no declaration; a malformed one
  is refused by name with the typo on the banner. `lib/core/
  gateway_declaration.dart` decides all of it without a DOM, so the VM tests
  it; the web arm only reads the tag.
- **A browser is nobody until it signs in — on the client too.** The gateway
  admits a credential-less `hello` as anonymous-awaiting-sign-in, an identity
  with the groups the plant's `anonymous` row grants (none, on the plant this
  was measured on) that may do nothing but wait. The client used to give that
  same session the seeded Operator groups and no whitelist, so a browser drew
  navigation into pages the gateway would not fill. Now a gateway client that
  presented no token lands on no groups and an empty whitelist
  (`lib/providers/access.dart`, `_anonymousSession`): every plant page refuses
  with the sign-in first (`AccessSignInFirstBody`), every raised route with
  the lock, and the first frame is a sign-in. Narrower than the server may be
  on a plant whose `anonymous` row does grant pages; closing that gap means
  the `hello` result carrying the admitted session's groups and pages, the
  way `session.login` already does. A station with a token is unchanged.
- **A browser cannot pin.** `kCanPinTrustRoot` (the client's constant, now
  exported) is what `GatewayConfig` consults: in a browser a trustless
  `wss` row is dialable and Save runs no fetch-and-approve ceremony; `ws`,
  a pinned root and a token path are refused at the field, by name.
- **https only.** The page is served over `https` and the socket is `wss`.
  Plaintext is refused by `ClientConfig.checkDialable` and again by the web
  dialler, rather than left to the browser's mixed-content rules — those depend
  on how the page was served, so a page opened over `http` would put the
  station credential and every plant write on the wire in the clear.
- **The gateway keeps the secrets.** There is no `secret:` on the wire and
  there should not be. `state_man_config` holds PLC credentials; a direct
  station keeps it in secure storage, and a gateway-mode client reads the
  redacted document the backend serves. A browser never receives plant
  credentials.
- **Writes are allowed**, gated by the signed-in user's rights — enforced on
  the backend, which is also why the client-side preferences guard is not
  applied in gateway mode.

## Known open, and owned elsewhere

- **The page editor cannot save from a browser.** The plant's pages, assets
  and key mappings reach a browser over the fifth access family
  (`configItems.items` one kind per call, `configItems.fingerprint`;
  `packages/tfc_relay_protocol/lib/src/config_items_api.dart`), cached in
  the browser's device-local store and refreshed on `preferences.changed`
  — reads only, graded `operate`, refused to a session nobody signed in
  on. There is no write on that route by design: a save is a merge against
  the plant's rows, a `configure` check and an audited `config_change`, the
  discipline `ConfigStore` applies against a mirror, and a browser has none.
  Until that is designed, `lib/providers/page_manager.dart` refuses the save
  by name and editing pages is station work.
- **Alarm history has no wire API.** `RelayAlarmSource.getRecentAlarms` still
  builds a drift query against the panel's own database (D-11). It is the last
  thing keeping the alarm view off a web build, and adding the API is a
  protocol change in the relay packages — **PR 463's**, not this branch's.

## The one thing that is not obvious

`dbus`, `file_picker`, `media_kit`, `pdfrx` and `dartssh2` produce **zero web
compile errors** today. An import-graph trace suggests otherwise; it is wrong,
because it follows conditional imports naively. Measure with
`flutter build web -t <probe>` before believing any of them is a blocker.
