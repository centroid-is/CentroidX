# Transport Selection for the SVN HMI Backend Pipe

(Research agent report — transport-research, 2026-08-13)

**Bottom line up front:** WebSocket (wss://) with a hand-rolled multiplexed sub-protocol is the correct choice, and the research strengthens rather than weakens that leaning. Every serious alternative either cannot do bidirectional traffic from a browser (gRPC-web, SSE), is not implementable in Dart today (WebTransport), or adds a broker process whose semantics actively fight your "never auto-retry a PLC write" requirement (MQTT). The interesting finding is not *which* transport — it's that the hard problems in your system (half-open detection, 15.5k values/sec fanout, safety-relevant writes) are all **sub-protocol design problems that WebSocket does not solve for you**, and which every reference implementation you'd want to copy (Home Assistant, Grafana Live, Ignition Perspective) solved the same way.

Research is complete across all six areas. Nothing material is missing; the one thing I could not find was a first-hand "we switched from gRPC-web to WebSocket for telemetry" post-mortem — the closest equivalents are OpenTelemetry's OpAMP transport decision and the Trello/Socket.IO migration, both cited below.

---

## 1. WebSocket (RFC 6455)

### Maturity and adoption

WebSocket is what the industrial and observability worlds actually ship. Inductive Automation's Ignition uses WebSockets for **all** traffic between the Designer, Vision clients, and Perspective sessions and the Gateway ([Inductive Automation security best practices](https://inductiveautomation.com/resources/webinar/security-best-practices-for-your-ignition-system)). Grafana Live, introduced in Grafana 8.0, is a pub/sub engine over WebSocket where **all subscriptions on a page are multiplexed inside a single WebSocket connection** ([Grafana Live setup docs](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-grafana-live/)) — that is precisely your topology. Home Assistant's entire client API is a single WebSocket at `/api/websocket` ([HA developer docs](https://developers.home-assistant.io/docs/api/websocket/)). OpenTelemetry's OpAMP agent-control protocol chose WebSocket over gRPC streams ([opamp-spec#61](https://github.com/open-telemetry/opamp-spec/issues/61)).

Browser support is universal and has been for a decade ([websocket.org browser support table](https://websocket.org/reference/browser-support/)).

### Proxy traversal

This matters on a plant LAN with VLANs and possibly an inspecting middlebox. Forward and transparent proxies inspecting port 80 see `Connection: Upgrade` — a hop-by-hop header they are not supposed to forward — and either strip it or reject the request, so WebSocket "works on your home network but fails silently for users behind corporate firewalls" ([websocket.org handshake reference](https://websocket.org/reference/handshake/), [Adobe enterprise KB on missing upgrade headers](https://helpx.adobe.com/enterprise/kb/troubleshooting-websocket-missing-upgrade-headers.html)). The fix is exactly what you already require: **wss:// makes the TLS tunnel opaque to intermediaries — they see an HTTPS connection to 443 and pass it through** ([websocket.org wss vs ws](https://websocket.org/reference/wss-vs-ws/)). TLS-mandatory-from-day-one is not just a security decision here, it is the proxy-traversal decision. The residual risk is a TLS-terminating inspection proxy, which can break the upgrade even on 443 — worth confirming none sits between the panels and the backend VLAN.

### Half-open detection — your feared failure mode

RFC 6455 defines ping/pong control frames, and `dart:io`'s server-side `WebSocket` implements them properly: set `pingInterval`, and if a ping is not answered by a pong within that interval the socket is assumed disconnected and closed with `WebSocketStatus.goingAway`. There are never two outstanding pings; the next timer starts when the pong arrives ([Dart API: WebSocket.pingInterval](https://api.dart.dev/dart-io/WebSocket/pingInterval.html)). Default is `null` — **off**. So your Dart backend gets real half-open detection for free, but only if you explicitly set it.

The client side is the trap. **The browser WebSocket API deliberately excludes control-frame access**: from JavaScript (and therefore from Flutter Web, which wraps the same API) you cannot send a ping frame, cannot detect an incoming ping, and cannot know when the browser sent a pong ([websocket.org heartbeat guide](https://websocket.org/guides/heartbeat/)). The browser answers server pings at the protocol layer, invisibly. This means a Flutter Web client **cannot detect a dead server using protocol pings** — it will sit there displaying stale-but-plausible tank levels indefinitely. The consequence is unavoidable: you need an **application-level ping/pong message in your sub-protocol**, and the client must run its own liveness timer. Home Assistant does exactly this — the client sends `{"id": 19, "type": "ping"}` and the server replies `{"id": 19, "type": "pong"}` ([HA WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)); their JS client reconnects if no pong arrives within 5 seconds ([home-assistant-js-websocket](https://github.com/home-assistant/home-assistant-js-websocket)).

Do not rely on TCP keepalive as a substitute. Linux's default is 7200 seconds, and even aggressive tuning does not help because proxies track application-layer activity, not TCP probes ([websocket.org heartbeat guide](https://websocket.org/guides/heartbeat/)). Standard guidance is a heartbeat every 30–45 s at ~75% of the shortest proxy idle timeout, with a ~10 s response window — but for an HMI where an operator acts on the numbers, 30 s of stale data is far too long. Recommend a 2–5 s server-push heartbeat (or treating *any* frame as liveness evidence and expecting one at least every 2 s) with a hard "stale" banner on the UI after ~3 missed intervals. Documented failure class: operator dashboard silently going stale with a stuck button requiring manual refresh, fixed by shorter-interval keepalive and a visible "Reconnecting…" state ([openclaw#7465](https://github.com/openclaw/openclaw/issues/7465)).

### Backpressure — the genuine WebSocket weakness

The browser WebSocket API has **no way to apply backpressure**; when messages arrive faster than the app can process them the application fills memory, pegs the CPU, or both ([Loke.dev on WebSocket backpressure](https://loke.dev/blog/websockets-backpressure-websocketstream-memory), [Medium: understanding backpressure in real-time streaming](https://apuravchauhan.medium.com/understanding-backpressure-in-real-time-streaming-with-websockets-20f504c2d248)). On the server, `send()` queues into an unbounded buffer; if the client reads slower than you write, that buffer grows without limit and the process OOMs ([MDN: WebSocket.bufferedAmount](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount)). The production answer: monitor buffered bytes and **drop, coalesce, or disconnect** slow clients.

For this workload that is the core design constraint. Right shape: **per-client conflation queue** — one slot per subscribed key holding the latest value, flushed on a fixed tick. A slow client degrades to a lower effective frame rate instead of accumulating a backlog, which is also semantically correct for an HMI.

### permessage-deflate — recommend disabling

Compression adds **at least ~300 KB of extra memory overhead per connection** and has produced "huge memory usage in production deployments"; Socket.IO/engine.io disabled it by default for exactly this reason ([engine.io commit 5ad2736](https://github.com/socketio/engine.io/commit/5ad273601eb66c7b318542f87026837bf9dddd21), [python websockets compression docs](https://websockets.readthedocs.io/en/stable/topics/compression.html)). Documented leaks under mass disconnection ([ws#1617](https://github.com/websockets/ws/issues/1617)) and a 2026 DoS CVE in undici's permessage-deflate decompression path ([CVE-2026-1526](https://explore.alas.aws.amazon.com/CVE-2026-1526.html)).

Project-specific decisive reason: **serialize each telemetry frame exactly once and write the same byte buffer to all N sockets.** Per-connection deflate contexts destroy that, forcing N compressions of identical data. On a gigabit LAN, bandwidth is not the scarce resource; backend CPU is. Encode once, broadcast the bytes.

### Dart library status

- **`web_socket_channel`** — 3.0.3, publisher `tools.dart.dev`, 150 pub points, 9.07M downloads, platforms include Web/Windows/macOS/Linux ([pub.dev](https://pub.dev/packages/web_socket_channel)). Last published ~16 months ago — stable-and-finished rather than abandoned given the publisher.
- **`web_socket`** — 1.0.1, also `dart.dev`, explicitly created as an alternative because `web_socket_channel` is "complex and does not have consistent behavior across implementations." Four implementations (BrowserWebSocket, IOWebSocket, CupertinoWebSocket, OkHttpWebSocket) that all pass the same conformance tests ([pub.dev/packages/web_socket](https://pub.dev/packages/web_socket)). **The one to build the client on** — cross-platform behavioral consistency.
- **Server:** `dart:io` `HttpServer` + `WebSocketTransformer`, or `shelf_web_socket` ([pub.dev](https://pub.dev/packages/shelf_web_socket)). First-party.

Dart-server caveat: a `Socket` is bound to a single isolate; sends across isolates do not scale like a single-threaded epoll loop ([dart-lang/sdk#8458](https://github.com/dart-lang/sdk/issues/8458)). Irrelevant at 5–100 connections; don't assume socket sharding across isolates later without work.

### TLS with a private CA

Native Dart: `SecurityContext` with the CA loaded, or `badCertificateCallback` for pinning. Browsers require the private root CA installed in the OS/browser trust store — normal supported practice but a per-machine provisioning step ([Wikipedia: self-signed certificate](https://en.wikipedia.org/wiki/Self-signed_certificate), [Citrix: self-signed certs for WebSocket](https://docs.citrix.com/en-us/linux-virtual-delivery-agent/current-release/best-practices/configure-self-signed-certificates-for-websocket.html)). A browser cannot be told "trust this one cert for wss://" the way a native client can — Firefox has a long-standing bug where the certificate exception UI never appears for a bare WSS connection ([bugzilla 1187666](https://bugzilla.mozilla.org/show_bug.cgi?id=1187666)). Plan on a real private CA with root installed via Group Policy / MDM, not per-cert exceptions. Applies identically to every browser-reachable option — except WebTransport, where it is worse.

### Verdict

**Strongest fit.** Mature, universal, same first-party Dart packages native+web, TLS solves the proxy problem, full control over write semantics. Hands you nothing for framing, liveness, or backpressure — you must build those; reference designs are well documented.

---

## 2. gRPC with bidirectional streaming

### The grpc-web problem is fatal here

gRPC-Web browser clients **do not support client-streaming or bidirectional-streaming methods**, still true in 2026. Official roadmap: "We don't plan to support client-streaming via Fetch/upload-streams," deferring to "when Full-duplex streaming is supported via WebTransport" ([grpc-web streaming-roadmap.md](https://github.com/grpc/grpc-web/blob/master/doc/streaming-roadmap.md)). Underlying cause: native HTTP/2 streams are not exposed to JavaScript ([grpc.io: state of gRPC in the browser](https://grpc.io/blog/state-of-grpc-web/), [Kreya: gRPC-Web under the hood](https://kreya.app/blog/grpc-web-deep-dive/)). Fetch `duplex: 'full'` not shipped in any stable browser as of early 2026 ([oneuptime on gRPC bidi streaming](https://oneuptime.com/blog/post/2026-01-24-grpc-bidirectional-streaming/view)).

Circularity: **gRPC-web's own roadmap explicitly rejects WebSocket** and points at WebTransport — which has no Dart server.

A **mandatory proxy** (Envoy) is required to translate gRPC-Web to gRPC HTTP/2 ([grpc.io](https://grpc.io/blog/state-of-grpc-web/), [Microsoft Learn](https://learn.microsoft.com/en-us/aspnet/core/grpc/grpcweb)).

### Dart status

`package:grpc` 5.1.0, publisher `dart.dev`, healthy ([pub.dev/packages/grpc](https://pub.dev/packages/grpc)). `grpc_web.dart` requires conditional imports; native build fails if grpc-web imported ([grpc-dart#457](https://github.com/grpc/grpc-dart/issues/457)); history of grpc-web revert breaking Flutter apps ([grpc-dart#357](https://github.com/grpc/grpc-dart/issues/357)).

Connect-RPC Dart transports ([connectrpc.com/docs/dart/using-clients](https://connectrpc.com/docs/dart/using-clients/), [connectrpc/connect-dart](https://github.com/connectrpc/connect-dart)):
- `dart:io` (HTTP/1): Connect, gRPC-Web; "Full duplex Bidi streaming is not supported"
- fetch (Web): unary and server-streaming only
- `package:http2`: all four RPC types — **not available on web**

### Verdict

**Rejected for the web constraint.** Native-only bidi gRPC would work today — but when Flutter Web lands you'd run two transports plus Envoy, with the browser one unable to do the thing gRPC was chosen for. If protobuf typing is wanted, take protobuf as *payload encoding* over WebSocket (what Grafana's Centrifuge does — WS transport, JSON or Protobuf framing ([centrifugal/centrifuge](https://github.com/centrifugal/centrifuge))).

---

## 3. Server-Sent Events + HTTP POST up-channel

### Genuine advantages

`EventSource` auto-reconnects; with `id:` on each event the browser sends `Last-Event-ID` on reconnect so the server can resume ([Ably: WebSockets vs SSE](https://ably.com/blog/websockets-vs-sse), [nimbleway 2026 guide](https://www.nimbleway.com/blog/server-sent-events-vs-websockets-what-is-the-difference-2026-guide)). Ordinary HTTP, traverses proxies. Mark Nottingham's critique of WebSocket: "TCP for the Web," abandoning HTTP semantics; recommends SSE "when HTTP/2+ deployment is widespread and binary content isn't required" ([mnot.net](https://www.mnot.net/blog/2022/02/20/websockets)). Both his conditions fail here.

### Where it falls short

1. **No binary.** UTF-8 only; base64 costs 33% ([hpbn.co](https://hpbn.co/server-sent-events-sse/), [Ably](https://ably.com/blog/websockets-vs-sse)). Forecloses MessagePack/protobuf framing.
2. **6-connection limit** under HTTP/1.1 ([textslashplain](https://textslashplain.com/2019/12/04/the-pitfalls-of-eventsource-over-http-1-1/)). HTTP/2 solves it but adds ALPN/HTTP2 server requirement Dart backend wouldn't otherwise need.
3. **Proxy buffering** — "the most common reason SSE appears to work in development but delivers events in batches in production"; needs `X-Accel-Buffering: no` per proxy ([oneuptime: SSE through Nginx](https://oneuptime.com/blog/post/2025-12-16-server-sent-events-nginx/view)). Batched-and-delayed = stale for an HMI.
4. **Two half-connections** to keep alive and correlate to a session.

Centrifugo classifies SSE as **unidirectional**, sacrificing "dynamic subscriptions/unsubscriptions, automatic message recovery on reconnect" ([Centrifugo transports overview](https://centrifugal.dev/docs/transports/overview)). Dynamic subscribe/unsubscribe as operators navigate pages is exactly the access pattern here.

### Verdict

**Rejected, but steal one idea.** `Last-Event-ID` resume → put a monotonic sequence number in telemetry frames; client sends `resume_from: <seq>` after reconnect; gap detection ("missed frames 4400–4520, mark those keys uncertain") for ~20 lines.

---

## 4. MQTT over WebSocket (broker-based)

### Why the broker doesn't apply

Brokers earn their keep with many publishers, many independent subscribers, decoupled lifecycles. Here: **one** publisher, N read-mostly subscribers of the same app. "With a single custom application consuming from a single custom publisher, the overhead… adds complexity with no benefit" ([i-flow: Sparkplug B pros and cons](https://i-flow.io/en/ressources/what-is-sparkplug-b-pros-and-cons-of-the-standard/)).

Broker perf not the issue — EMQX 500k msg/s vs Mosquitto 80k ([EMQX vs Mosquitto benchmark](https://www.emqx.com/en/blog/open-mqtt-benchmarking-comparison-emqx-vs-mosquitto)), both far above ~15.5k/s. Cost is operational: second process, own TLS/CA chain, own auth/ACL, own upgrades, own 03:00 failure modes.

### QoS 1 conflicts with the write safety requirement

Under QoS 1, if PUBLISH arrived but PUBACK was lost, sender cannot distinguish "message lost" from "ack lost," **so it errs on the side of resending** ([merobix: MQTT QoS 1 duplicate delivery](https://www.merobix.com/blog/what-is-mqtt-qos-1-duplicate-delivery)). DUP flag does not save you: "the receiver cannot assume that it has already received the message and must still treat it as a new message" ([HiveMQ MQTT Essentials part 6](https://www.hivemq.com/blog/mqtt-essentials-part-6-mqtt-quality-of-service-levels/), [EMQX QoS guide](https://www.emqx.com/en/blog/introduction-to-mqtt-qos)).

Requirement: safety-relevant PLC write **never** auto-retried. MQTT QoS 1 is an auto-retry mechanism with no reliable receiver-side dedup. QoS 0 + own idempotency keys + explicit-confirm = broker contributes nothing to the write path. Sparkplug B **mandates QoS 0 for all data with no delivery guarantee** ([FlowFuse: MQTT vs Sparkplug B](https://flowfuse.com/blog/2026/06/mqtt-vs-sparkplug-b/), [i-flow](https://i-flow.io/en/ressources/what-is-sparkplug-b-pros-and-cons-of-the-standard/)).

### The one attractive feature

**Retained messages** = instant last-known-value snapshot for new clients. Implementable in ~30 lines: backend already holds a last-value map; send snapshot frame on subscribe. No broker needed for a hashmap.

### Dart status

`mqtt_client` 10.11.11, published 3 months ago, verified publisher darticulate.com, active ([pub.dev](https://pub.dev/packages/mqtt_client), [shamblett/mqtt_client](https://github.com/shamblett/mqtt_client)). **Browser client supports only ws/wss** — Flutter Web client is WebSocket-bound anyway. `mqtt5_client` separate ([pub.dev](https://pub.dev/packages/mqtt5_client)). Single author — bus-factor.

### Verdict

**Rejected.** A process, a cert, an ACL model, and a delivery semantic that fights the safety requirement — in exchange for a last-value cache you can write yourself. Browser path is MQTT-over-WebSocket regardless: broker *on top of* the WebSocket you were going to have.

---

## 5. WebTransport / HTTP/3

### Browser support finally arrived

[caniuse.com/webtransport](https://caniuse.com/webtransport): Chrome 97+, Edge 98+, Firefox 114+, **Safari 26.4+**, ~90% global usage ([testmuai](https://www.testmuai.com/learning-hub/webtransport-browser-support/)). Spec still W3C Working Draft, IETF [draft-ietf-webtrans-http3-11](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http3-11).

### Three reasons it's unusable here

**(a) No Dart server, no Dart HTTP/3.** [dart-lang/sdk#38595](https://github.com/dart-lang/sdk/issues/38595) — no near-term plans. 2015 QUIC request [#22657](https://github.com/dart-lang/sdk/issues/22657) closed *not planned*. grpc-dart HTTP/3 proposal [#374](https://github.com/grpc/grpc-dart/issues/374) points back at #38595. Only hobby-grade [pure-dart-quic](https://github.com/KellyKinyama/pure-dart-quic/) and Rust-backed [server_native](https://pub.dev/packages/server_native). **This alone ends the discussion.**

**(b) Private-CA story worse than WSS.** Requires certs chaining to trusted root or `serverCertificateHashes` (short validity, browser-specific constraints). Strictly harder than "install the root once" for wss://.

**(c) UDP/443 on a plant VLAN.** 3–5% of public networks block UDP/443 entirely; enterprise rates higher; firewalls deliberately block QUIC to force HTTPS inspection; no vendor has robust QUIC inspection as of 2025 ([andrewbaker.ninja](https://andrewbaker.ninja/2026/05/02/quic-the-protocol-that-breaks-your-site-without-warning/), [Forcepoint](https://support.forcepoint.com/s/article/000015410)). Browser fallback "is imperfect."

**(d) Benefit doesn't apply.** Head-of-line-blocking avoidance matters on lossy networks; this is wired gigabit LAN.

Centrifugo labels its WebTransport support "experimental" ([Centrifugo transports](https://centrifugal.dev/docs/transports/overview)).

### Verdict

**Ignore, but keep the sub-protocol transport-agnostic** (frame-oriented, no WebSocket-specific semantics) so the bottom layer is swappable if Dart ships HTTP/3.

---

## 6. What practitioners actually use

**Socket.IO** — skip. Dart port has maintenance smells (fork `socket_io_client_new` created to fix `Uri.parse()` port-0 bug ([pub.dev](https://pub.dev/documentation/socket_io_client_new/latest/))). Trello replaced Socket.IO with raw `ws` + small JSON protocol at ~400k concurrent connections ([Ably: scaling Socket.IO](https://ably.com/topic/scaling-socketio)); practitioners: "no black box… you know exactly what bytes are going over the wire" ([dev.to](https://dev.to/nikhilsharma6/why-i-ditched-socketio-for-raw-websockets-and-what-i-learned-55i6)). Long-poll fallback obsolete.

**NATS** — skip for single-publisher topology. `dart_nats` 1.4.0 active but unverified uploader, no official Dart client ([pub.dev](https://pub.dev/packages/dart_nats), [nats-server discussion #2965](https://github.com/nats-io/nats-server/discussions/2965)). Revisit if a second backend service appears.

**Centrifugo / Centrifuge** — study, don't deploy. Its feature list ("persistent connection management and invalidation, subscription multiplexing, fast reconnect with message recovery, WebSocket fallback") is a specification for the sub-protocol ([centrifugal/centrifuge](https://github.com/centrifugal/centrifuge)). No Dart SDK.

**Design references:** Home Assistant is the closest analog to copy: `auth_required` → `auth` → `auth_ok` handshake; integer `id` on every command; `{"type":"result","success":bool}` echoing id; subscribe/unsubscribe by id; app-level ping/pong ([HA WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)). Grafana Live: all subscriptions multiplexed on one socket; default cap 100 connections; each connection costs an FD against typical 1024 default ([Grafana Live setup](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-grafana-live/)). **Raise `ulimit -n` before the 100-client stress test.**

**Dual transport (raw TCP native + WS web)?** No. Two liveness implementations, two reconnect state machines, two sets of bugs; WS framing overhead 2–14 bytes/frame, not measurable on gigabit.

---

## 7. Comparison matrix (0–5 per requirement)

| | **WebSocket** | gRPC bidi | gRPC-web | SSE + POST | MQTT/WS | WebTransport | Socket.IO | NATS |
|---|---|---|---|---|---|---|---|---|
| Works from Flutter Web (hard req) | **5** | 0 | 3 | 4 | 4 | 2 | 4 | 4 |
| True bidirectional | **5** | 5 | 0 | 2 | 4 | 5 | 5 | 5 |
| Dart client maturity | **5** | 4 | 3 | 4 | 4 | 0 | 2 | 3 |
| Dart **server** maturity | **5** | 4 | 2 | 4 | 1¹ | 0 | 2 | 1¹ |
| No extra infra process | **5** | 5 | 1² | 5 | 1 | 5 | 5 | 1 |
| Half-open detection available | 4³ | 4 | 2 | 3 | 4 | 4 | 4 | 4 |
| Binary payloads | **5** | 5 | 5 | 1 | 5 | 5 | 4 | 5 |
| Private-CA TLS in browser | 4 | 4 | 4 | 4 | 4 | 1 | 4 | 4 |
| Backpressure / slow-client control | 2⁴ | 4 | 2 | 2 | 3 | 5 | 2 | 3 |
| **Write semantics: no auto-retry** | **5** | 5 | 5 | 5 | **1**⁵ | 5 | 4 | 3 |
| Reconnect + gap recovery built in | 2 | 3 | 3 | **5**⁶ | 4 | 3 | 4 | 4 |
| Proxy/VLAN traversal | 4⁷ | 3 | 4 | 4 | 4 | 1 | 5 | 4 |
| Ecosystem precedent in HMI/SCADA | **5** | 1 | 1 | 2 | 5 | 0 | 2 | 2 |
| **Total (/65)** | **56** | 47 | 35 | 45 | 44 | 36 | 47 | 43 |

¹ No Dart broker; separate Erlang/C/Go process. ² Envoy required. ³ Server free via `pingInterval`; client needs app-level heartbeat (browsers can't send pings). ⁴ Must be built: conflation + `bufferedAmount` monitoring + disconnect policy. ⁵ QoS 1 auto-retries with unreliable dedup; QoS 0 no confirmation. ⁶ `Last-Event-ID` — steal this. ⁷ With wss:// only; plain ws:// scores 1.

---

## 8. Recommendation

**Rank 1 — WebSocket (wss://) carrying a custom multiplexed sub-protocol.** One connection per client. Home Assistant framing (integer id correlation, typed messages, explicit subscribe/unsubscribe, app-level ping/pong) + Grafana Live multiplexing.

**Rank 2 — SSE + POST** only if a hostile TLS-inspecting middlebox breaks the Upgrade handshake. **Rank 3 — gRPC bidi native-only** if web requirement dropped (it isn't).

### Concrete design decisions that follow

1. **Liveness:** server sets `WebSocket.pingInterval` AND app-level heartbeat both directions — server emits `tick` frame with monotonic seq + server timestamp at fixed rate even when nothing changed; client shows hard "STALE — no data for Ns" overlay after 3 missed ticks. Non-negotiable: browsers cannot see pongs.
2. **Sequence numbers + resume:** every telemetry frame carries a seq. On reconnect client sends last seq; server replies delta or full snapshot + explicit "you missed frames X–Y" so UI marks those keys uncertain.
3. **Conflation, not queuing:** per-client last-value map flushed on tick; monitor buffered bytes; disconnect client exceeding threshold rather than OOM.
4. **Encode once, broadcast bytes.** permessage-deflate stays **off** (per-connection contexts force N compressions + ~300 KB/connection).
5. **Push work upstream to OPC UA:** `DataChangeFilter` deadband + sampling/publishing interval decoupling ([OPC UA Part 4 §5.13.1](https://reference.opcfoundation.org/specs/OPC-10000-4/5.13.1), [§5.13.1.2](https://reference.opcfoundation.org/specs/OPC-10000-4/5.13.1.2)). Most of the 15.5k values/sec should never leave the PLC.
6. **Writes: unary, non-idempotent, never auto-retried.** One id, one attempt, definitive result. Connection loss with in-flight write → "outcome unknown — verify" to operator. Explicit carve-out from generic reconnect/retry logic — the single most likely place for a well-meaning retry wrapper to cause harm later. Consider server-issued single-use tokens making write frames structurally unreplayable.
7. **Encoding: start with JSON** (debuggable in devtools at 03:00), frame designed so payload codec is swappable. Protobuf: 29.8–48% size reduction, ~21% parse speedup in Flutter ([cretezy](https://cretezy.com/2020/flutter-json-vs-protobuf)); MessagePack via `msgpack_dart` works on Flutter Web ([ssojet](https://ssojet.com/serialize-and-deserialize/serialize-and-deserialize-messagepack-in-flutter-web)), most well-rounded, least memory ([dev.to comparison](https://dev.to/nate10/performance-analysis-of-json-buffer-custom-binary-protocol-protobuf-and-messagepack-for-websockets-2apn)). Switch only when measured.
8. **Client library: `package:web_socket`** over `web_socket_channel` (conformance-tested cross-platform consistency).
9. **Raise `ulimit -n`** before the 100-client stress test.

---

## The two strongest arguments AGAINST WebSocket

### 1. You are signing up to invent a protocol, and protocols are where the bugs live

WebSocket gives a byte pipe and nothing else. Auth handshake, correlation, subscription lifecycle, heartbeat, reconnect, gap recovery, snapshot-on-subscribe, backpressure policy, error taxonomy — all yours to design, implement twice, test, version. Nottingham: WebSocket is "TCP for the Web"; "many incompatible libraries exist" ([mnot.net](https://www.mnot.net/blog/2022/02/20/websockets)). Centrifuge exists because this list is long enough that Grafana adopted it wholesale rather than writing it. There is no Centrifuge for Dart. Every concern is a place where a subtle bug shows an operator a wrong number.

Counter: MQTT is the only option handing you a ready-made version of that list, and its delivery semantics are wrong for the write path — you'd write the important half yourself anyway, on top of a broker.

### 2. Backpressure is WebSocket's genuine architectural gap, and this workload exposes it

Browser WebSocket API is "architecturally incapable of handling backpressure" ([Loke.dev](https://loke.dev/blog/websockets-backpressure-websocketstream-memory)). WebTransport has QUIC flow control; gRPC has HTTP/2 flow control; WebSocket has `bufferedAmount` and your own discipline. The mitigation — server-side conflation, semantically right for telemetry — is what every real HMI does, but slow-client correctness rests entirely on code you wrote, with no protocol-level backstop.

Neither argument overturns the choice (the alternatives that address them fail the browser or Dart-server test outright), but they say where to write adversarial tests first: **the heartbeat/staleness path and the slow-client path**.
