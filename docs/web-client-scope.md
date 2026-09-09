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
- **No local database, and no local cache beyond sign-in.** Sign-in already
  persists through `localPreferencesProvider` on `shared_preferences`, which is
  web-safe. So drift-on-WASM is *not* wanted: the database layer is excluded
  rather than ported. `database_drift.dart`'s executor seam is where
  `WasmDatabase.open` would go if that ever changes — drift 2.31 ships
  `wasm.dart`, and it wants `sqlite3.wasm` + `drift_worker.js` served from
  `web/` plus COOP/COEP headers for OPFS.
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

- **Alarm history has no wire API.** `RelayAlarmSource.getRecentAlarms` still
  builds a drift query against the panel's own database (D-11). It is the last
  thing keeping the alarm view off a web build, and adding the API is a
  protocol change in the relay packages — **PR 463's**, not this branch's.

## The one thing that is not obvious

`dbus`, `file_picker`, `media_kit`, `pdfrx` and `dartssh2` produce **zero web
compile errors** today. An import-graph trace suggests otherwise; it is wrong,
because it follows conditional imports naively. Measure with
`flutter build web -t <probe>` before believing any of them is a blocker.
