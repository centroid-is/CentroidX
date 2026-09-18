# Message/RPC layer design for the HMI telemetry + control pipe

(Research agent report — rpc-layer-research, 2026-08-13)

## Verdict up front

**Use JSON-RPC 2.0 as the envelope, with a documented conventions layer on top, and own your transport/session layer rather than delegating it to `package:json_rpc_2`.**

JSON-RPC 2.0 gives exactly four things — id correlation, a bidirectional peer model, a notification concept, one agreed error shape. Those are ~15% of what this protocol needs. Subscription lifecycle, resync-on-reconnect, delta encoding, write-outcome determinacy, and version negotiation are yours to build regardless of envelope. Pick the envelope on legibility/interop grounds (JSON-RPC wins) and spend design effort on the 85%.

---

## 1. JSON-RPC 2.0 over WebSocket: aging

New protocols keep choosing it: LSP (JSON-RPC 2.0 + Content-Length framing, 10 years, hundreds of impls), Ethereum (`eth_subscribe` over WS — canonical "JSON-RPC plus server push", geth pubsub docs), MCP (chose it 2024 to avoid reinventing RPC mechanisms, transport-agnostic), TrueNAS (migrated entire middleware API to JSON-RPC 2.0 over WebSocket for 25.04 — appliance UI talking to control daemon, almost exactly this problem space: https://api.truenas.com/v25.04.0/jsonrpc.html).

Home Assistant is the holdout: hand-rolled `{"id": N, "type": "..."}` — but it independently reinvented id correlation and `{code, message}` errors, i.e. rebuilt JSON-RPC's useful parts.

### Pain points that bite

- **Batch is a liability. Forbid it outright.** Spec permits any-order batch responses; geth silently ignores the second request in one WS frame (go-ethereum#23575); batch forces buffering whole array. `json_rpc_2` exposes `withBatch()` — don't call it.
- **Notifications have no ack and no flow control.** Correct for telemetry push; dangerous for everything else. Never send writes/subscription changes/status transitions that matter as notifications. Geth closes connection at 10k buffered notifications — you need your own backpressure policy.
- **Ordering unspecified.** One WebSocket gives TCP ordering — a transport guarantee, not protocol. Put per-subscription sequence numbers in payloads.
- **Error taxonomy thin.** code/message/data; -32768..-32000 reserved (-32700 parse, -32600 invalid request, -32601 method not found, -32602 invalid params, -32603 internal, -32099..-32000 server). `data` semantics are yours.
- **Null ids discouraged** — use monotonic integers.

### `package:json_rpc_2`

Version 4.1.0, verified publisher tools.dart.dev (Dart team), 6.69M downloads, all six platforms incl. web. Lives in dart-lang/tools monorepo (dart-archive org in search results is a stale redirect, not abandonment). `Peer` class handles bidirectional both-sides-initiate properly (implements Client and Server over one StreamChannel, routes automatically). **`Peer.withoutJson()` accepts already-decoded objects — decode once yourself, keep control of the hot path.** Recent maintenance real: 4.0.0 custom id generators; 4.1.0 fixed error forwarding when Peer acts as client. Open: strictProtocolChecks on Client (dart-lang/tools#2422, June 2026).

**The one real gap: no reconnection story.** dart-lang/tools#1973 open and unanswered. A Peer is bound to one StreamChannel for life; socket death completes every in-flight sendRequest with an error — precisely when a safety-critical write becomes ambiguous. `web_socket_channel` has no built-in reconnect/heartbeat; dart-lang/sdk#60833 (ping frames not keeping connections alive) open; `web_socket_client` is the community reconnect wrapper.

**Practical conclusion:** use `json_rpc_2` for framing/correlation, wrapped in your own `Connection` object owning the socket, reconnect loop, session/epoch state, and in-flight-write registry. Fresh `Peer` per physical connection; the session outlives the Peer. If the wrapper fights the package, a hand-rolled peer speaking the same wire format is ~200 lines — the wire format is the contract, not the library.

---

## 2. Envelope alternatives

| Option | Dart support | Schema evolution | Wire readable? | Adoption |
|---|---|---|---|---|
| JSON-RPC 2.0 | json_rpc_2 4.1.0, Dart team | ad-hoc | yes | LSP, Ethereum, MCP, TrueNAS |
| Hand-rolled JSON | trivial | yours | yes | HA, Phoenix, graphql-ws, DDP |
| MessagePack-RPC | **no live Dart impl** | — | no | spec dormant |
| Protobuf over WS | protobuf + protoc_plugin, healthy | best in class | no | huge, rarely over raw WS |
| CBOR | cbor 6.5.1, verified, RFC 8949 + 8746 typed arrays | self-describing | semi | IoT/CoAP |
| FlatBuffers | flat_buffers, thin | good | no | games/zero-copy |

- **MessagePack-RPC not a real option in Dart** (no maintained impl; underlying msgpack ecosystem poor).
- **Protobuf buys the wrong thing:** DynamicValue is dynamically typed and self-describing; protobuf means Any/Struct (loses compactness, can be larger than JSON) or hand-rolled oneof reimplementing the existing codec. "Data shape matters more than payload size."
- **The layer is transport-independent** — envelope carries over to SSE+POST/stdio/MQTT unchanged (MCP's property). Don't assume WebSocket close codes; carry own close reason in a `bye` notification.

---

## 3. Serialization in Dart

**The existing measurement is already state of the art.** 55 KiB in 419 µs ≈ 3.7 ns/byte/direction. Egorov (Dart team, FlutterNinjas 2024, mrale.ph/talks/fnf2024): V8 JSON.parse 2.28 ns/byte; Dart JsonDecoder before optimization 8.79; **JsonUtf8Decoder after: 3.5 ns/byte (~300 MB/s)**. No easy 2x on the table.

**Actionable: decode from bytes, not String.** Use `JsonUtf8Decoder` / `utf8.decoder.fuse(json.decoder)` on the raw Uint8List from the socket. That's where 8.79 → 3.5 came from. Remaining time: 41.8% polymorphic character access, 6.8% bounds checks.

At 10 Hz worst case: 4.19 ms CPU/s = 0.42% of one core. MessagePack's 2–4x would recover ~0.3% of a core while making wire captures unreadable. Not worth it.

Caveat: JSON parsing runs on the UI isolate by default in Flutter; 419 µs is 2.5% of a 16.6 ms frame budget. **Move decode to a background isolate before considering a format change.**

### Bytes levers, in payoff order

1. **Don't send unchanged values** (worth more than any format change). HA `subscribe_entities`: full snapshot then only changes. OPC UA PubSub: `ua-keyframe` vs `ua-deltaframe` with guard "publisher shall send a key frame if the delta frame would be larger."
2. **Enable `permessage-deflate`.** Repetitive numeric JSON with shared keys is near-ideal: 2–15x reported (crossbar.io). Cost: few hundred kB context/connection + CPU — irrelevant at this client count. Browsers negotiate automatically; dart:io exposes CompressionOptions. [NOTE: transport report recommends the opposite — encode-once broadcast vs per-connection deflate contexts. Resolve in synthesis.]
3. **Shorten keys on the wire:** integer handles assigned in subscribe response; push `{"41":1450}` not `{"ST101.CN01.MOT01.speed":1450}`. On 36-byte updates the tag name is most of the bytes — beats any codec change. Keep a debug flag for full names.

**If binary later: CBOR, not MessagePack.** `cbor` 6.5.1 verified, RFC 8949 + RFC 8746 typed arrays (whole float array as one blob). Dart msgpack ecosystem fragmented/stale (`messagepack` 0.2.1, five years old, unverified, manual Packer API).

---

## 4. Subscription / delta-push / resync patterns (9 systems)

- **Client-chosen subscription id echoed on every push** — universal (HA, graphql-ws close 4409 on duplicate id, SignalR protocol-error on id reuse but per-endpoint id spaces). Take all three rules.
- **Explicit "initial state complete" signal** (DDP `ready`, graphql-ws first `next`). Fold into subscribe response: snapshot inline, atomic with subscription, one round trip.
- **Per-subscription sequence numbers on pushes.** OPC UA PubSub SequenceNumber; DDP receivedCount on reconnect. The only way a client can *prove* it isn't stale.
- **Epoch/generation id — the single best idea.** Centrifugo: incrementing `offset` + `epoch` string identifying the stream instance; server restart changes epoch → client knows saved position is meaningless. Copy `wasRecovering`/`recovered` flags; critical case `wasRecovering && !recovered` → reload from scratch. **Invert the policy for HMI: use epoch to detect discontinuity, resync via fresh snapshot, never replay old deltas** — a conveyor speed from 40 s ago is worse than useless.
- **Server-side subscription state + rejoin with new id.** Phoenix `join_ref` (protocol v2): late messages from previous session trivially discardable. Epoch does double duty.
- **Coalescing negotiated at handshake** (HA `coalesce_messages`) — good pattern for anything changing wire shape.
- **Delta encoding, concretely — copy HA's compressed-state format:** `{"a": {id: state}, "c": {id: {"+": additions, "-": removals}}, "r": [ids]}`. Single-character keys on the hot path, spelled-out everywhere else.
- **Don't copy:** graphql-ws (no resumption/ordering statements at all); Supabase Realtime postgres_changes (8000-byte NOTIFY limits, WAL buildup, replication lag OOM — cautionary tale about coupling push to a replication mechanism you don't control).
- **Per-key subscriptions with client-side aggregator, not per-page.** Per-page couples wire protocol to UI layout; client unions key sets of visible widgets and diffs on navigation. Server cost is a hash map either way (HA `_KeyedEventTracker` maps entity ids to jobs to avoid O(N) scans).

---

## 5. Write-command semantics

At-most-once has **three outcomes: executed / not executed / unknown** (classical RPC theory; systemsapproach.org). No transport fixes this — make the third state visible and queryable.

OPC UA authority: servers return uncertain codes when operation may not have completed; clients shall always check StatusCode; `Bad_Timeout` *does not guarantee no change took place on the server* (OPC Foundation forum guidance).

### Three mechanisms

1. **Client-generated idempotency key on every write** (Stripe model: V4 UUID, same key within window returns original response including if it was a 500; parameters compared and mismatch errors). For HMI: ~60 s dedup window, not 24 h. MQTT 5 Correlation Data reaches the same design.
2. **Queryable command-status endpoint** — makes "unknown" recoverable. After reconnect, client re-asks about every in-flight command.
3. **Readback in the acknowledgement** (AWS IoT Device Shadow desired/reported/delta). Return the post-write value in the ack: "applied" means "applied and read back."

### The design rule

**Reserve JSON-RPC `error` for "definitively no effect." Anything with uncertain effect is a successful `result` with an outcome field:** `outcome: "applied" | "rejected" | "unknown"`. `rejected` = device said no (interlocked, out of range) — a perfectly successful RPC returning bad news, NOT an error. Callers: error → safe to retry; rejected → show reason; unknown → poll writeStatus, never retry blindly.

---

## 6. Versioning

- **Version in handshake — copy MCP:** client sends latest supported; server echoes it or responds with another it supports; client disconnects if unsupported. Date-stamped versions (`2026-08-13`) sidestep semver bikeshedding. -32602 with `data: {supported, requested}` on mismatch.
- **Capability object from day one** (LSP scar tissue: everything pre-capability became mandatory-forever baseline). Include `experimental` section. LSP registerCapability/unregisterCapability → relevant when a PLC comes online mid-session.
- **Per-method versioning: don't.** Add `methodV2` gated behind a capability flag when a shape must break.

---

## 7. Concrete protocol recommendation (shapes)

### Handshake
```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{
  "protocol":"2026-08-13","supported":["2026-08-13","2026-03-01"],
  "client":{"name":"centroid-hmi","version":"1.4.0"},
  "capabilities":{"deltaPush":true,"keyHandles":true,"experimental":{}},
  "session":{"id":"01J8...","epoch":"01J7...","lastSeq":{"s1":4210}}}}
```
Result: protocol, server info, capabilities, `session:{id, epoch, resumed}`. epoch changes when server subscription state lost; `resumed:false` → resubscribe from scratch. Server rejects all other methods until hello.

### Subscribe
```json
{"jsonrpc":"2.0","id":7,"method":"subscribe","params":{
  "sub":"s1","keys":["ST101.CN01.MOT01.speed","ST101.CN02.SEN01.level"],
  "mode":"slim","maxRateHz":10}}
```
Result: sub, epoch, seq:0, `handles` (key→int), `meta` per handle, `snapshot` inline (atomic, one round trip), `rejected` per-key partial failures (one bad key must not blank the page).

### Push (notification)
```json
{"jsonrpc":"2.0","method":"u","params":{
  "sub":"s1","seq":4211,"t":1786000000123,
  "c":{"1":1450},"q":{"2":{"s":"bad","c":"comm_fault"}},"r":[7]}}
```
`c` changed values, `q` quality transitions, `r` removed keys. Gap in seq → client resync request. Periodic keyframe (OPC UA KeyFrameCount idea); keyframe whenever delta would exceed it.

### Server-initiated resync
```json
{"jsonrpc":"2.0","method":"resync","params":{"sub":"s1","epoch":"01JA...","reason":"epoch_changed"}}
```
Reasons: epoch_changed, server_restart, permissions_changed, overrun. Client re-issues subscribe.

### Write
```json
{"jsonrpc":"2.0","id":88,"method":"write","params":{
  "cmd":"01J8XW3K9P...","key":"ST101.CN01.MOT01.setpoint","value":1500,
  "expect":{"value":1450},"ttlMs":15000}}
```
`cmd` = client-generated ULID idempotency key, generated when the operator acts, NOT at send time. `expect` optional CAS. Results:
- `{"cmd":..., "outcome":"applied","at":...,"readback":1500}`
- `{"cmd":..., "outcome":"rejected","reason":{"code":"interlocked","message":"guard door open","status":"Bad_NotWritable"}}`
- `{"cmd":..., "outcome":"unknown","reason":{"code":"plc_timeout",...}}`
Error only for definitively-no-effect: `{"code":-32001,"message":"not authorized","data":{"kind":"forbidden","retryable":false}}`

### writeStatus
`{"method":"writeStatus","params":{"cmds":[...]}}` → same result objects. On reconnect client re-queries every unresolved command. Unknown cmd within TTL → `outcome:"not_received"` (definitively safe to retry).

### Client rules
- cmd generated once at operator action; retry reuses it.
- Dropped socket with write in flight → UI "outcome unknown", never "failed".
- writeStatus on reconnect resolves; if server doesn't know either, operator decides.
- Never auto-retry a write client-side.

### Error codes
Stay in -32000..-32099; real taxonomy in `data.kind` as string (greps, survives bug reports); always `data.retryable` boolean.

---

## 8. Strongest counterargument

**JSON-RPC's request/notification dichotomy is precisely wrong for the three-state write outcome.** The natural Dart code `try { await peer.sendRequest('write',...) } catch (e) { showError() }` silently converts "unknown" into "failed" on the safety-critical path. A purpose-built envelope with a `kind` discriminator could make the three-state outcome the only representable shape. Five of nine systems studied (HA, Phoenix, graphql-ws, DDP, Supabase) hand-rolled instead. Costs are real: forbid batch, document non-null ids, fit errors into a reserved range, inherit a library with no reconnection story on a protocol whose hardest problem IS reconnection — for ~60 lines of Dart gained.

**Resolution:** the three-state write is a convention either way; the wrapper enforcing it can wrap json_rpc_2 as easily. The weightiest benefit: in three years someone opens a wire capture, recognizes LSP/MCP shape, is productive in a minute. TrueNAS made this exact call recently.

**Actionable hedge: write the client-side write API first, as a three-state sealed class with no `throw` on the unknown path, and only then decide what serializes it.** If that API is awkward over json_rpc_2's sendRequest (returns or throws, no third option), that's the signal to hand-roll. The wire format is the contract; the library is droppable.

(Full source list preserved in the original agent report; key ones: jsonrpc.org/specification, pub.dev/packages/json_rpc_2, dart-lang/tools#1973, mrale.ph/talks/fnf2024, centrifugal.dev/docs/server/history_and_recovery, docs.stripe.com/api/idempotent_requests, reference.opcfoundation.org Part 4 §7.34/Part 14 §7.2.5.4, modelcontextprotocol.io lifecycle, HA websocket API + messages.py, meteor DDP.md, api.truenas.com jsonrpc.)
