# Industrial HMI/SCADA precedent: how the field solves "many thin clients, one gateway"

(Research agent report — industry-precedent, 2026-08-13)

**Headline:** the industry has converged, almost unanimously, on exactly the proposed architecture — a single server-side gateway holding the PLC connections, thin clients on one multiplexed WebSocket carrying a custom JSON protocol. Browser-native OPC UA (`opc.wss`) is specified and essentially unadopted. The incumbents are collectively *bad* at the feared failure mode: the market leader (Ignition Perspective) has a documented, still-unfixed **2.5-minute** stale-data window.

## 1. Ignition Perspective

- Sessions sync view properties bidirectionally over a persistent WebSocket; gateway holds a server-side component tree mirroring the frontend. Wire protocol proprietary.
- Public/Private property distinction: sync opt-in per property, not global.
- Tuning knobs (docs, gateway config): `max-message-size` 2048 KB (oversized frame → session drop, real prod failure — cap and chunk from day one); `websocketChannel.maxIdleTimeMs` 120000; `idleCheckIntervalMs` 30000; permessage-deflate ON by default with opt-out flag; value-cache max-age 1 min.
- **The staleness failure — most important finding:** Perspective clients take **~2.5 minutes** to detect a lost gateway connection (Canny request "Make perspective client detect lost connection to the gateway", 53 votes, in-progress since Sept 2023, unshipped as of mid-2025). Arithmetic identity: 120 s idle + 30 s check = 150 s. 2026 forum thread: during gateway failover data "freezes" with no notification. **Structural insight: the server cannot warn the operator, because the thing that broke is the server→browser path.** Every workaround = client-side logic noticing. Also: gateway restart can leave sessions stuck ("project not found"), browser sessions don't auto-failover.
- **Quality propagation is best-in-class — copy this.** Numeric quality code on every value, four bands: Good 0–255 (192 reliable; **2 = write pending**), Uncertain 256–511 (**257 = last known value, current unavailable**; 260 out of range), Bad 512–767 (**516 = stale past refresh interval**; 522 connection unavailable), Error 768–1023 (770 expression failed). Rules: **quality composes pessimistically** (worst sub-quality wins through bindings/expressions); **quality renders automatically** per binding (overlay, no designer effort); **last known value stays visible under the overlay** — overlay disappearance is itself the "trust it again" signal.
- **Leased Tag Groups = the answer to 1556 tags at 10 Hz:** visible working set polls fast (e.g. 1 s), everything else idles (10 s); rate changes debounced 250 ms, max once per 8 s.
- Scaling: 50–100+ sessions per gateway, ~1.5–2 GB RAM per additional session (heavy!), scale-out via stateless front-end gateways + sticky sessions.

## 2. OPC UA's own answers

- **`opc.wss` (Part 6 §7.5) is specified and effectively dead.** Three subprotocols (`opcua+uacp`, `opcua+uajson` — explicitly deprecated, `opcua+openapi`). open62541#2384 closed without implementation. node-opcua#1496 browser prototype worked but needed **seven** structural ecosystem changes. "Not commonly supported."
- **Cert management is the deeper reason browser OPC UA loses:** every client needs a server-trusted cert; gateway collapses 5–20 PKI relationships to one. That's most of the argument.
- **PubSub (Part 14): wrong half.** Consensus framing: client/server for engineering/params/alarms/writes (bidirectional confirmed), PubSub for one-way streaming. Safety-relevant writes need confirmed semantics. Adoption thin.
- **Session limits (documented, the original pain):** SIMATIC Unified PC Runtime 10 as server / 5–8 as client; Unified Comfort Panel 3; third-party PLCs 5–50; MicroLogix 1400 hard-cap 16 TCP. ~50–200 KB server heap per subscription. Gateway/aggregator is the standard vendor advice.
- **Steal the OPC UA subscription state machine (Part 4 §5.14.1.1):**
  - PublishingInterval — batching in the protocol.
  - **MaxKeepAliveCount — after N silent cycles, server sends an empty keep-alive. Silence is never ambiguous.** The single most important idea for the stale-data fear.
  - LifetimeCount ≥ 3 × MaxKeepAliveCount — **death timeout = 3× heartbeat interval.**
  - StatusChangeNotification with Bad_Timeout — server announces subscription death explicitly.
  - Sequence numbers (uint32, starts at 1) + Republish for targeted retransmission.

## 3. Open-source SCADA/HMI

- **FUXA** (Node/Angular, Socket.IO): `DEVICE_VALUES` (bidirectional; **writes require authorization, reads don't** — clean split); **`DEVICE_STATUS` as first-class separate channel from values**; `DEVICE_TAGS_SUBSCRIBE` stored per-socket server-side; `DAQ_QUERY`/`DAQ_RESULT` for history. Per-value quality/timestamp unconfirmed in docs.
- **ThingsBoard**: WS + JWT in query string; client-chosen integer `cmdId` ↔ `subscriptionId` correlation; per-subscription errorCode/errorMsg in envelope; known multiplexing bugs (#6799, #10874 invalid-entity discussion). Correlation is where these protocols actually break.
- **Rapid SCADA**: custom persistent TCP, not SignalR. **Scada-LTS**: historically AJAX polling, WebSocket since v2.7.1 — mid-migration to where you're starting. **Mango**: WS `/point-values` + REST. **FrameworX/Tatsoft**: HTML5 client on WebAssembly/Blazor; "design once render everywhere" = the Flutter-native-plus-web story validated commercially; ships an ISA-101 compliance guide; transport unpublished.

## 4. Grafana Live / real-time infra

- Grafana Live = pub/sub over one multiplexed WS (channels `ds/<uid>/<path>`), built on Centrifuge (JSON or Protobuf over one strict schema; load-tested to 1M connections).
- `max_connections` default 100 (safety rail; ~50 KB/connection reasoning); `message_size_limit` 64 KB default; HA needs Redis; explicitly framed as **soft** real-time (delays can be hundreds of ms).
- **Centrifugo liveness — most directly applicable prior art:** **application-level ping/pong, not WS frame ping/pong**, by default. Server pings (`{}` in JSON protocol) every 25 s, closes if no pong. Docs: "more efficient than frame-level and enables SDKs to detect broken connections reliably." Frame-level exists behind `?cf_ws_frame_ping_pong=true` — explicitly debugging-only.
- **Centrifugo recovery:** offset + epoch per stream; epoch changes when stream recreated ("offset 10 in the new stream is a different message"); `recovered` + `wasRecovering` booleans; error 112 Unrecoverable Position; `client.recovery_max_publication_limit` default 300. Recovery "is intentionally not authoritative — an optimization that shields the database from reconnect storms." HMI analogue: **on any reconnect where continuity isn't provably intact, discard local tag cache and demand full snapshot. Never silently splice a delta stream onto a cache you can't prove is current.**
- **Lightstreamer — conflation prior art:** per-client max bandwidth guaranteed never exceeded regardless of source rate, changeable mid-session; per-subscription max update frequency; "updates are neither buffered nor delayed, but resampled and conflated — when a subscription can be updated it receives the very latest available message, not an old one." **Last-value-wins conflation is the right default for an HMI.**
- **Serialization:** schema-less binary up to 63% smaller, 2–4x faster (arXiv 2201.03051, 2407.13494); but **with compression the JSON→MessagePack gap collapses to ~10–15%** (jsonic.io). JSON + deflate gets most of binary's benefit while staying debuggable. Centrifuge proves the escape hatch: JSON and Protobuf over one schema — define protocol schema-first, defer the choice.
- **Reconnect storms:** exponential backoff 1/2/4…30 s **plus up to 50% jitter**; removing jitter turned a 12 s recovery into a 45 s cascading failure in one load test (websocket.org reconnection guide). Gateway restart reconnects every panel at once; jitter is one line.

## 5. Big vendors

- **WinCC Unified (Siemens): GraphQL over `graphql-transport-ws`** (modern graphql-ws spec), port 4000. **Copy the `tagValues` subscription payload outright: `{name, value, timestamp, quality{substatus}, error, notificationReason}`** — tags addressed **by name, not ID** (stable across config changes); value+timestamp+quality+error travel together per tag per notification. Read permission gates subscriptions, write gates mutations. Token expiry forces disconnect + re-auth (24/7 HMI wrinkle — design deliberately). Friction: WS support must be manually enabled in IIS; Unity integrator hit self-signed-cert wall. Live third-party ecosystem (Node-RED nodes, MCP server) = the argument for a documented API. Unconfirmed whether the runtime's own web client uses this same GraphQL surface (assume not).
- **FactoryTalk Optix (Rockwell):** native + web presentation engines from one model; **OPC UA is the internal object model**, browser never speaks it; runtime renders. Transport unpublished. Same shape as this gateway.
- **VTScada:** HTTPS thin clients, RFC 6455 WS server-side, all WS over HTTPS required; **"sends updates only when process values change — high performance even on slow networks."** Change-driven, not interval-driven.
- **AVEVA OMI Web:** browser transport not public; gRPC move is server-to-server only.
- **B&R mapp View:** the one near-adopter of browser-side OPC UA ("data management completely based on OPC UA") but **could not confirm the browser speaks opc.wss** — treat as gateway-served absent a packet capture. Don't cite as precedent.

## 6. Summary table

| System | Transport | Protocol | Batching/rate | Staleness | Reconnect |
|---|---|---|---|---|---|
| Ignition Perspective | one WS/session | proprietary JSON-ish | leased tag groups; 2048 KB cap | 4-band quality codes, worst-wins, overlays, last value retained | auto-retry + banner; **~2.5 min to notice** |
| OPC UA client/server | opc.tcp (opc.wss ~unused) | UACP binary | PublishingInterval; deadband | StatusCode + 2 timestamps per value; Bad_Timeout announced | keep-alive; lifetime = 3× keep-alive; seq + Republish |
| FUXA | Socket.IO | named JSON events | server polling decoupled | DEVICE_STATUS separate channel | Socket.IO defaults |
| ThingsBoard | WS + JWT | cmdId/subscriptionId JSON | keys filter | per-sub errorCode | known bugs |
| Grafana Live | one WS (Centrifuge) | JSON or Protobuf, one schema | 64 KB cap; 100 conns default | n/a | app ping 25 s; offset+epoch, recovered flag |
| Lightstreamer | WS/HTTP streaming | proprietary | **per-client bandwidth + per-sub frequency caps; last-value-wins** | n/a | adaptive |
| WinCC Unified | graphql-transport-ws | GraphQL subscriptions | not documented | **{name,value,timestamp,quality{substatus},error,reason} per notification** | token expiry forces re-auth |
| Optix / VTScada / AVEVA | unpublished | unpublished | VTScada: change-driven only | OPC UA codes internally | — |

## 7. Quality/staleness — convergent answer

OPC UA (StatusCode + SourceTimestamp + ServerTimestamp per value; channel quality separate), Ignition (quality code per value, worst-wins, overlays), WinCC Unified (quality+substatus in the same envelope as value), **Sparkplug B makes it normative: on NDEATH, subscribers "should set the data quality of all metrics to STALE"** — a connection-level event mass-degrades value-level quality, by specification. FUXA adds: device/link status as its own channel.

**The distinction that earns its keep: Uncertain-with-last-known-value (Ignition 257) vs Bad-stale-past-refresh-interval (516).** Both mean "don't trust this number"; only one means "the pipe is broken."

## 8. Convergence — steal / avoid

**Unanimous (five things):** 1) gateway in front, always — nobody puts a control protocol in the browser; 2) one WebSocket, multiplexed, per client; 3) JSON is fine (with deflate the binary gap is ~10–15%); 4) value + timestamp + quality travel together per tag in one envelope; 5) batch on an interval, conflate last-value-wins.

**Steal specifically:**
- **The keep-alive is the whole ballgame:** subscription with nothing to say still says so on schedule (OPC UA MaxKeepAliveCount). Death timeout = 3× keep-alive.
- **App-level ping/pong, not WS frame ping/pong** (browser JS can't see control frames; Centrifugo chose app-level in production and documented why).
- **Client-side watchdog that ages out its own data** — the correction to Ignition's 2.5-min hole. Server cannot warn about a broken server link. `lastMessageAt` + independent whole-view stale marking, no server cooperation needed.
- **Heartbeat: 75% of shortest proxy idle timeout; on plant LAN be aggressive: 2–5 s heartbeat, 10–15 s death timeout** → Ignition's 2.5 min becomes ~10 s. TCP keepalive won't save you (2 h default; proxies track app-layer).
- **Overlay, don't blank** — last known value visible under staleness overlay; blanking during an upset is its own hazard.
- **Four-band quality model + worst-quality-wins composition;** derived values never look healthier than their worst input. Write-pending as a quality state (Good subcode 2) for the in-flight window.
- **Device/link status as its own channel** (FUXA DEVICE_STATUS; Sparkplug NDEATH→mass-STALE): operator sees "ST201 is down", not 300 tags going stale one by one.
- **Epoch + sequence; distrust cache on reconnect** — re-snapshot unless continuity proven.
- **Jittered exponential backoff** (1/2/4…30 s, ≤50% jitter).
- **Leased subscriptions:** subscribe per open page, not per catalogue; debounce rate changes (250 ms / max once per 8 s).
- **Per-subscription rate caps + last-value-wins conflation** (Lightstreamer property: newest value, never a backlog).
- **Cap and chunk messages** (Ignition 2048 KB drop; Grafana 64 KB) — enforce at encoder or rediscover as mystery disconnects.
- **Split read/write authorization at protocol level** (FUXA, WinCC); write-pending visible to operator.

**Avoid:** browser-native OPC UA (cert management kills it); OPC UA PubSub for this (wrong half); **relying on idle timeouts for liveness (Ignition's documented hole — the market leader has this bug, don't inherit it)**; server-push-only warnings (structurally cannot work); optimizing serialization before needed; assuming reconnect resumed cleanly (prove or re-snapshot).

**Gaps flagged:** none of the big four publish their browser transport; no shipping product verified to run OPC UA natively in a browser; FUXA per-value quality unconfirmed.

**Short version:** the architecture is the industry standard, the transport choice is the industry standard, and the place the industry is weakest is exactly the feared failure mode. Build the keep-alive, the client-side watchdog, and the quality envelope first.
