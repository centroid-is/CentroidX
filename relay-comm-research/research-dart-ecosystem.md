# Dart/Flutter ecosystem report: production WebSocket telemetry pipe

(Research agent report — dart-ecosystem-research, 2026-08-13. All verdicts from live pub.dev/GitHub fetches.)

## Headline conclusions
1. Transport layer stable but quietly rotting: `web_socket_channel` 3.0.3, 16 months since publish, **12 open functional bugs, none fixed** (incl. close-code broken on every platform). Still the right choice — budget for workarounds, not fixes.
2. **`json_rpc_2` is the strongest piece** — Peer fits the topology exactly; **no queue, no retry** (write-safety property holds natively).
3. **Flutter web + private CA is the one genuinely hard constraint**: failed wss:// in a browser = no interstitial, no error detail, hard-coded in Chromium (subresource cert errors DENY). Solve at deployment (GPO root install / CACertificatesWithConstraints CIDR-scoped, or DNS-01 ACME real domain) or not at all.
4. **Server-initiated ping is the only protocol-level liveness for web clients** (browsers must auto-pong per RFC 6455; Chrome never sends pings itself). Client half must be app-level heartbeat.
5. **dart:io WebSocket buffers unboundedly — no bufferedAmount, no flush()** (flutter#103306 open since 2022). Build bounded coalescing send buffer + watchdog-close.
6. Skip protobuf/gRPC/isolates/probably codegen. 0.56 MB/s JSON ≈ 0.2–2 ms/frame (Egorov: ~285 MB/s post-opt). Cost is widget rebuilds, not parsing.

## Maintenance verdicts
| Package | Ver | Last publish | Verdict |
|---|---|---|---|
| web_socket_channel | 3.0.3 | ~2025-04 | SLOW — API-stable, bug-stale; moved to dart-lang/http monorepo |
| web_socket | 1.0.1 | ~2025-05 | SLOW — conformance-tested; 3.x web_socket_channel wraps it |
| json_rpc_2 | 4.1.0 | ~2026-03 | ALIVE |
| shelf_web_socket | 3.0.0 | ~2025-02 | ALIVE (thin, stable) |
| stream_channel | 2.1.4 | ~2025-01 | ALIVE (primitive) |
| web_socket_client | 0.2.1 | 2025-05-22 | SLOW/small — last release fixed an infinite backoff loop; not load-bearing |
| json_serializable | 6.14.1 | ~2026-07 | ALIVE (Google) |
| build_runner | 2.16.0 | ~2026-07 | ALIVE (2.13–2.16 much faster; 2.16 retires --delete-conflicting-outputs) |
| freezed | 3.2.5 | ~2026-02 | ALIVE but ecosystem-blocking (twice in 12 mo the analyzer-cap blocker; workspaces = one resolution repo-wide) |
| grpc | 5.1.0 | ~2025-12 | ALIVE but slow; grpc-web no bidi → trap |
| msgpack_dart | 1.0.1 | ~2023-08 | ZOMBIE |
| mkcert | 1.4.4 | 2022-04 | DEAD |
| Dart macros | — | cancelled 2025-01-29 | DISCONTINUED — don't plan around |

## 1. web_socket_channel key facts
- 3.0.0 inversion: WebSocketChannel abstract; AdapterWebSocketChannel (over package:web_socket) is the impl; IOWebSocketChannel extends it.
- `pingInterval` ONLY on IOWebSocketChannel.connect (native). Cross-platform connect has none (dart-lang/http#1563 open since 2021). Web ping impossible in principle (WHATWG §5; whatwg/websockets#10). dart:io semantics: unanswered ping → close with goingAway; never >1 outstanding.
- Browsers MUST auto-pong (RFC 6455 §5.5.2; Chromium's Adam Rice: "Chrome doesn't currently ever send ping frames… keep alive is only ever server-initiated"). → **set pingInterval on the SERVER**: dead-client detection + NAT keepalive for web and native alike.
- **Close-code bugs:** #1698 — after `sink.close(code)`, `channel.closeCode` reads null (all platforms, broken in all 3.x; ordering bug in adapter). #1690 — close(1001) throws (only 1000 or 3000–4999 accepted). Rules: track own local close code; treat closeCode as "peer's or null"; use 4000–4999 for HMI semantics (4001 auth expired, 4002 draining, 4003 heartbeat timeout).
- Other open bugs: #1701 readyState/innerWebSocket removed; #1775 close event fires twice (one uncatchable, Linux/macOS); #1693 `ready` doesn't fail if socket closes pending; #1691 no send acknowledgement (sink.add() return ≠ delivery — the JSON-RPC response is the only write ack); #1648 sink.add(List<int>) sends TEXT frame on legacy Html path → **always add(Uint8List)**.
- Reconnect wrappers not production-grade (web_socket_client's latest release fixed infinite backoff; flutter_websocket_plus has "priority-based message queuing" = anti-feature for write path, 74 downloads). **Hand-roll ~30 lines: exponential backoff + full jitter, cap ~30 s, reset backoff only after RESYNC COMPLETES** (not on TCP connect — hot-loop hazard).

## 2. json_rpc_2
Peer = Client+Server over one StreamChannel<String> (`channel.stream.cast<String>()` needed). No queue/no retry: sendRequest fails on channel death — preserves write safety; fresh Peer per connection (no reconnection story: dart-lang/tools#1973 open, unanswered). Don't use JSON-RPC batch for telemetry — single notification with array payload. Call listen() before sending. No official shelf_web_socket recipe (#739).

## 3. Server side
- **shelf + shelf_web_socket**: webSocketHandler(onConnection, protocols, **allowedOrigins** — SET IT (CSWSH defence; browser WS can't send Authorization header; RFC 6455 §10.2, OWASP cheat sheet), **pingInterval**). Serve Flutter web bundle same-origin via shelf_static.
- **Backpressure:** no bufferedAmount/flush on dart:io WebSocket (flutter#103306 since 2022, P3, silent heap growth on stalled client; #103281 add() slowing UI). Mitigation = bounded coalescing per-client send buffer keyed by tag, latest-value-wins + watchdog closing connections exceeding N buffered frames (converts leak into reconnect). (DraftKings retrospective: compaction + drop-stale correct for telemetry; also "don't use WebSockets without planned periodic interruptions at the gateway level" — scheduled connection kills exercise reconnect in staging; and 56 KiB frame ≈ 38 MTU packets, one loss = hundreds of ms retransmit.)
- **Isolates: no.** Socket bound to one isolate; fan-out across isolates = N boundary crossings; sdk#36106 shared HttpServer isolate-exit bug. 100 clients × 8 KiB × 10 Hz ≈ 8 MB/s typical — **encode once per tick, hand same object to every sink**. (If ever sharding: immutable Strings/unmodifiable typed data pass by reference within isolate group.)
- No credible modern Dart WS server load test published — benchmark own target hardware (100 synthetic clients) before committing.

## 4. TLS private CA
- Native: `SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(caPem)` (CA as Flutter asset) + `IOWebSocketChannel.connect(customClient: HttpClient(context: ctx), pingInterval: 20s)`. Server: bindSecure + useCertificateChainBytes (FULL chain) + usePrivateKeyBytes.
- Folklore corrections: SecurityContext.defaultContext docs wrong — Windows uses system stores (since 2020), macOS SecTrust, Linux ca-certificates paths. Desktop Flutter = platform behavior. Android ignores user-installed CAs (sdk#48056).
- **Never badCertificateCallback**: disables hostname+expiry+issuer simultaneously; pre-Dart-3.13 receives the WRONG cert (chain cert/root, not leaf — sdk#39425, fixed only 2026-06-23).
- No pinning package supports desktop. withTrustedRoots:false is stronger anyway.
- mTLS: read HttpRequest.certificate BEFORE WebSocketTransformer.upgrade; client certs need explicit extendedKeyUsage=clientAuth (sdk#60881 uncatchable reject); bindSecure can't REQUIRE client cert (sdk#48406) — enforce in app code.
- Dart 3.13 removes compiled-in fallback roots — slim containers need ca-certificates for outbound HTTPS.

## 5. Web constraint
- Chromium: subresource cert error → CERTIFICATE_REQUEST_RESULT_TYPE_DENY, no interstitial; Firefox WONTFIX (bug 1187666); WHATWG mandates all failures collapse to close 1006, empty reason (anti-probing).
- Options: (1) GPO root push; Chrome/Edge ≥133 `CACertificatesWithConstraints` with `permitted_cidrs` (e.g. 10.104.29.0/24). (2) Real domain + DNS-01 ACME to private IP — Let's Encrypt explicitly OK (2026-02 dns-persist-01 post); costs CT-logged internal hostnames + internet for renewal; only zero-client-install option. (3) Public CA for private IP/.local banned since 2016; Caddy `tls internal` = just a private CA; mkcert dead.
- **Serve web bundle same-origin as WS**: converts silent wss failure into clickable page-load interstitial; Chrome cert exception is per-HOST across schemes/ports (7-day expiry, debugging aid only); enables SameSite=Strict. https page can never open ws://; 10.104.29.x gets no localhost exemption.

## 6. Flutter web behavioral deltas
- WebSocket message delivery exempt from throttling, BUT page-level carve-out removed (Chromium b3ca8d2bef22, 2021): **hidden tab → Timer.periodic throttles to 1/min after 5 min** → 15 s/45 s heartbeat spuriously declares death. Make heartbeat grace visibility-aware (AppLifecycleState resumed/inactive/hidden delivered on web; paused never; no tab-close callback).
- **Chrome ≥149 (stable 2026-06) silently closes WebSockets on bfcache entry** — back-navigation kills socket, restores healthy-looking page.
- After OS sleep readyState lies (OPEN, no close event, TCP_KEEPIDLE 7200 s). **Never trust readyState/ready as liveness. Reset freshness clock on any inbound frame; probe on resumed + monotonic clock jump.**
- Kiosk escapes throttling/bfcache but design for general browser; kiosk gets it free.
- Binary frames clean (Uint8List both paths); no receive-side flow control on web (pause() buffers after delivery); bufferedAmount unreachable in 3.x.
- WASM: is:wasm-ready badge is static analysis only — maintainers never ran WS suite under dart2wasm (#1653). Own smoke test; keep dart:html importers out.

## 7. Protocol typing
- Macros cancelled (2025-01-29). build_runner much improved. **Recommendation: hand-write protocol types** — 20–40 message types, Dart 3 sealed classes + hand fromJson/toJson (~15 lines/type), exhaustive switch free, no .g.dart, no analyzer coupling; hand decode folds batch frame directly into value store without DTO churn (matters vs 1–5 ms GC pauses). If codegen: json_serializable or dart_mappable (useAsDefault fallback). Beware freezed in a pub workspace (one-resolution rule; twice the ecosystem analyzer blocker).
- Shared pure-Dart `protocol` package (no flutter dep) in pub workspace (Dart 3.6+/Flutter 3.27+); never put dart:ui types in messages; CI runs dart analyze/test with plain SDK.
- **Keep JSON.** msgpack_dart zombie; protobuf ergonomically weak + loses exhaustive matching. Enable permessage-deflate first (5–10x on repetitive JSON keys). Bigger win: short/positional keys ([[keyId, value],…] + key registry) + changed-values-only — every JSON key = fresh String allocation; 500 × 10 Hz = 5k allocs/s GC churn.
- Isolates: Isolate.run/compute spawn per call (10 spawns/s at 10 Hz); compute is a NO-OP on web. If ever needed: one long-lived worker isolate returning deltas.

## 8. gRPC cross-check, case studies, rendering
- grpc-web: unary + server-streaming only, no bidi, mandatory Envoy → two connections, two auth paths, two reconnect machines + ordering problem. JSON-RPC-over-WS is the right call.
- No published Flutter precedent at this rate — "you will be the case study." Promwad (2026-04): OPC UA end-to-end display latency 50–200 ms — validates 10 Hz; Dart GC 1–5 ms (6–30% frame budget); control logic never in HMI layer.
- Rendering at 10 Hz: one ValueNotifier per point owned by long-lived store; ValueListenableBuilder per widget; ValueNotifier skips equal values (unchanged reading = ZERO rebuilds, 10–100x cut); RepaintBoundary around animation; single CustomPainter for dense grids.
- **Windows warning:** flutter#178916 — 3.38 collapsed all Windows apps 120→40 fps, shipped to stable, survived a release. Pin Flutter, soak before bumps, keep rollback installer.

## 9. stream_channel
Stable primitive. MultiChannel NOT needed (Peer already multiplexes). Useful: Disconnector (supervisory kill-switch), StreamChannelController (test protocol layer against in-memory channel — do this).

## Recommended stack
Server: shelf + shelf_web_socket (allowedOrigins, pingInterval 20 s, same-origin web bundle). Client transport: IOWebSocketChannel.connect(customClient, pingInterval) desktop / WebSocketChannel.connect web, behind thin adapter. TLS: withTrustedRoots:false + CA asset. RPC: json_rpc_2 Peer over cast<String>(), fresh Peer per connection. Telemetry: JSON notification, array payload, short/positional keys, deflate on, changed-only. Types: hand-written sealed classes in pure-Dart protocol package, pub workspace. Reconnect: hand-rolled exp backoff + full jitter cap 30 s, reset after resync. Liveness: server pingInterval AND app-level heartbeat with visibility-aware grace. Concurrency: one isolate, encode once.

## Risks R1–R12
R1 web_socket_channel bugs open for years (own close-code tracking; 4000–4999 only; thin adapter for forkability). R2 no bufferedAmount/flush (bounded coalescing buffer + watchdog close). R3 web + private CA silent failure (decide trust story BEFORE web client; GPO/CIDR-scoped policy or DNS-01; same-origin serving). R4 web can't ping + hidden-tab throttling (server pingInterval; visibility-aware app heartbeat; freshness on any inbound frame). R5 reconnect wrappers not production-grade (hand-roll; reset after resync). R6 queuing wrappers violate write safety (never queue writes across reconnect; RPC response is the only proof). R7 pub workspace one-resolution (protocol package codegen-free). R8 no published load tests (spike: 100 clients, 500 values, 10 Hz, real Windows hardware). R9 multi-day Flutter desktop uptime unvalidated (72 h soak with RSS sampling; leak_tracker; consider supervised nightly restart — cheap once resync exists). R10 wasm untested upstream (own smoke test). R11 Flutter stable Windows regressions (pin + soak + rollback). R12 Dart 3.13 drops fallback roots (container needs ca-certificates).
