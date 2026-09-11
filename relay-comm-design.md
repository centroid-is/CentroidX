# Relay pipe — communication design

**Status:** designed, not implemented. Companion to `relay-websocket-notes.md`
(survey, measurements, and the §7 test plan, which is this design's
verification suite).
**Date:** 2026-08-13
**Based on:** five research passes (transport options, RPC/message layer,
industrial HMI/SCADA precedent, Dart/Flutter ecosystem, practitioner-forum
edge cases), all internet-sourced and cited in the reports; local benchmarks
in `relay-bench/`; two locally-verified Dart hazards.

---

## 0. The decision, in one table

| Layer | Decision |
|---|---|
| Transport | **WebSocket (`wss://`), one connection per client**, everything multiplexed on it |
| Envelope | **JSON-RPC 2.0** with a strict conventions layer (§3) |
| Values | JSON, `DynamicValueConverter` slim mode + **integer key handles**; metadata once at subscribe |
| Batching | server tick (50–100 ms), one `u` notification per tick per subscription; last-value-wins conflation per client |
| Liveness | server `pingInterval` **and** app-level heartbeat both ways; per-subscription sequence numbers; client-side freshness watchdog |
| Reconnect | epoch + seq; resync = fresh snapshot, never delta replay; jittered exponential backoff, reset only after resync completes |
| Writes | three-state outcome (`applied` / `rejected` / `unknown`), client-generated idempotency id, `writeStatus` re-query on reconnect, never auto-retried |
| Quality | four-band quality code + timestamp travels with every value; worst-quality-wins composition |
| TLS | private CA; native clients pin the root (`withTrustedRoots: false`); server cert from the CA; keys as mounted files, never in config |
| Server | Dart, `shelf` + `shelf_web_socket`, one isolate, encode-once fan-out |
| Client | `WsDeviceClient implements DeviceClient`; `web_socket_channel` behind a thin adapter; `json_rpc_2` `Peer`, fresh per connection |
| Compression | permessage-deflate **off** initially; config flag to enable per deployment (§6.4) |

Everything below is the reasoning and the exact shapes.

---

## 1. Requirements this design answers

- N Flutter clients (5–20 real, 100 stress-tested): Windows/macOS desktops,
  eLinux panels now; **Flutter web later — hard constraint**.
- One backend is the only thing talking to PLCs (ST101/ST201/ST301 + Baader)
  and TimescaleDB. ~1556 keys, 10 Hz worst case (which cannot actually occur).
- Bidirectional: dominant server→client telemetry push + request/response
  (write/read plus 34 browse/timeseries/history-view/preference methods,
  LISTEN/NOTIFY-style notifications).
- Safety: PLC writes are never silently retried, and their outcome is never
  silently ambiguous.
- The feared failure is stale-but-plausible data. TLS from day one.

## 1a. Architecture: StateMan is the abstraction (decided 2026-08-13)

Everything is built from scratch; #93/#107 and the existing code are
reference only. The organizing idea:

```
        widgets / providers            (unchanged — they already speak StateMan)
              │
        StateManApi                    (one interface: subscribe/read/write/browse
              │                         + timeseries + history-view + prefs + health)
      ┌───────┴────────┐
 RemoteStateMan    LocalStateMan       (client: protocol over one WS)
      │                 │              (server: DeviceClients + TimescaleDB)
  relay pipe       PLCs + DB
```

- **Server**: `LocalStateMan` composes the DeviceClients (OPC UA, M2400,
  Modbus) *and* the database surface (timeseries queries, history-view CRUD,
  preferences, notifications) behind one interface. The WS front-end is a
  thin projection of that interface — method-for-method, nothing else. The
  protocol cannot drift from what the app needs because it *is* the app's
  interface.
- **Client**: `RemoteStateMan` implements the same interface over the pipe.
  Widgets and providers do not change.
- **TDD consequence (the reason this shape wins)**: one **contract test
  suite** written against `StateManApi`, run three ways —
  1. against `LocalStateMan` with fake device clients (server correctness),
  2. against `RemoteStateMan` wired to a real server over an in-memory
     `StreamChannelController` (protocol correctness, no sockets),
  3. against `RemoteStateMan` through the `TcpProxy` fault harness
     (fault-tolerance: every F-scenario from the notes §7.5–7.9 asserts the
     *contract* still holds — values converge, writes reach exactly one
     terminal state, staleness is visible).
  Fault tolerance is therefore not a feature of the transport code; it is a
  property the contract suite enforces on every implementation, forever.
- **Simplicity rule**: if a client capability isn't a `StateManApi` method,
  it doesn't go on the wire. (This is also what kills `query(sql)` forever.)
- **Speed rule**: the hot path (value push → widget) touches exactly one
  map update and one `ValueNotifier` per changed key; everything else
  (encode-once fan-out, conflation, handles) exists to keep that path flat.

**Amendment, 2026-09-02 (Phase 8): there is a fourth way to run the contract
suite, and it is the one that catches what the other three cannot.**

The three legs above are all *in-process fakes at the bottom*: leg 1 fakes the
device clients, legs 2 and 3 fake the plant behind a real socket. Nothing in
that list ever asks a real PLC anything, which is a gap the design did not
notice because it assumed a real PLC needs hardware. It does not — this
repository has been standing an **in-process open62541 `Server`** up in CI on
ubuntu and macOS on every push since long before this project
(`tfc_dart/test/subscription_inactivity_test.dart`), and nobody had noticed.

  4. against `LocalStateMan` over a **real in-process OPC UA server**, dialled
     through a real `opc.tcp` socket, with the byte-level fault proxy available
     unchanged in front of it (there is no TLS record layer at
     `MessageSecurityMode.NONE`, so a mid-frame cut measures the right layer).

This is the only leg that can prove a value carries **the PLC's own quality and
the PLC's own source instant** rather than the gateway's opinion of them, and
it is the leg the whole `StatusCode`/`sourceTimestamp` branch of the binding was
made for. Phase 8 runs it two ways: the shared `UpstreamLink` group against the
adapter, and one end-to-end file (`tfc_relay_local/test/end_to_end_test.dart`)
that composes `LocalStateMan` under `RelayServer` and reads the result on a real
`RemoteStateMan`. Measured there: a sample stamped by the server and held on the
wire for 1500 ms arrives on the panel reporting an instant **1541 ms** in the
past, identical to the millisecond to the instant the gateway holds. An adapter
that stamps arrival collapses that to 29 ms, which is how the leg is known to
bite.

The cost is honest and belongs next to the benefit: this leg needs a native
build and binds listening ports, so it lives in `tfc_relay_local` — a package
with its own CI step — and never in `tfc_relay_server`, which keeps zero native
dependencies precisely so its own suite stays in front of a `pub get`.

## 2. Transport: WebSocket, and why the alternatives lost

Full matrix in the transport report; scores /65 against the requirements:
**WebSocket 56**, gRPC-bidi 47, Socket.IO 47, SSE+POST 45, MQTT/WS 44, NATS
43, WebTransport 36, gRPC-web 35.

- **gRPC**: gRPC-Web still cannot do client/bidi streaming from a browser in
  2026 (official roadmap defers to WebTransport and explicitly rejects
  WebSocket), and needs an Envoy translator. Native-only bidi would work —
  until web arrives, then it's two transports plus Envoy.
- **SSE + POST**: no binary, HTTP/1.1 6-connection limit without HTTP/2,
  proxy buffering surprises, two half-connections to keep alive. One idea
  stolen: `Last-Event-ID` → our sequence-number resume.
- **MQTT/broker**: a second process, cert chain, and ACL model — and QoS 1 is
  an *auto-retry mechanism with unreliable dedup*, directly hostile to the
  write-safety rule (Sparkplug B itself mandates QoS 0). Retained messages ≈
  a hashmap we already hold. The browser path would be MQTT-over-WebSocket
  anyway.
- **WebTransport/HTTP3**: no Dart server exists or is planned
  (dart-lang/sdk#38595); private-CA story worse than WSS; plant firewalls
  drop UDP/443. Kept swappable by keeping the protocol frame-oriented.
- **Precedent**: Ignition Perspective, Grafana Live, Home Assistant, TrueNAS
  all run one multiplexed WebSocket. Nobody puts a control protocol in the
  browser; `opc.wss` is specified and dead (open62541 closed it without
  implementation).

`wss://` (not `ws://`) is also the proxy-traversal decision: TLS makes the
tunnel opaque to middleboxes that would otherwise strip `Connection: Upgrade`.

## 3. Envelope: JSON-RPC 2.0 + conventions

JSON-RPC 2.0 buys id correlation, a peer model, notifications, and one error
shape — the settled 15%. LSP, Ethereum, MCP, and TrueNAS (appliance UI ↔
control daemon, our exact shape) all chose it; a wire capture reads like LSP
to anyone who has debugged one. The conventions layer is where the design
actually lives:

1. **No batch.** JSON-RPC batch is unordered by spec and inconsistently
   implemented (geth silently drops). Telemetry batching is one notification
   with an array payload, not a JSON-RPC batch.
2. **Notifications only for telemetry, status, and heartbeat.** Anything
   needing an outcome is a request. Never a write as a notification.
3. **Ids are monotonic integers**, never null.
4. **`error` means "definitively no effect".** Malformed, unauthorized,
   unroutable — the PLC never saw it, retry is safe. Anything that *may* have
   had effect is a successful `result` with an `outcome` field (§5). This
   inverts the naive instinct and is the highest-value rule in the document.
5. **Error taxonomy in `data.kind` (string) + `data.retryable` (bool)**,
   codes stay in -32000..-32099. Strings grep; booleans stop callers
   switching over codes.
6. **Ordering is TCP's, not the protocol's** — per-subscription sequence
   numbers make gaps detectable rather than assumed absent.

**Implementation hedge (from the RPC report, adopted):** the client write API
is designed first as a three-state sealed result with no `throw` on the
unknown path. `json_rpc_2`'s `sendRequest` returns-or-throws; the wrapper
maps channel-death to `outcome: unknown`. If that wrapper ever fights the
package, we hand-roll the peer (~200 lines) and keep the wire format — the
wire format is the contract, the library is disposable.

## 4. Protocol

Date-stamped protocol version, MCP-style negotiation (client sends latest it
supports; server echoes or counter-offers; client disconnects if
incompatible). Capability object exists from day one, nearly empty, with an
`experimental` section — LSP's scar tissue says everything predating the
capability system becomes mandatory forever.

### 4.1 `hello` (first message; server rejects everything else until it)

```jsonc
→ {"jsonrpc":"2.0","id":1,"method":"hello","params":{
    "protocol":"2026-08-13","supported":["2026-08-13"],
    "client":{"name":"centroid-hmi","version":"1.4.0"},
    "capabilities":{"deltaPush":true,"keyHandles":true},
    "session":{"id":"01J8…","epoch":"01J7…","lastSeq":{"s1":4210}}}}
← result: {"protocol":"2026-08-13","server":{…},
    "capabilities":{…},
    "session":{"id":"01J8…","epoch":"01J9…","resumed":false},
    "clock":{"serverTime":1786000000123}}
```

- `session.epoch` identifies this server subscription-state instance;
  changes on server restart/state loss. `resumed:false` ⇒ client discards
  its cache and resubscribes from scratch (Centrifugo's
  `wasRecovering && !recovered`, with the policy inverted: **we never replay
  missed deltas — an HMI wants the current value, not a 40-second-old one**).
- `clock` establishes the client↔server offset so staleness is measured
  against one clock (§7.9 of the notes: no-RTC panels boot at 1970).

### 4.2 `subscribe` / `unsubscribe`

```jsonc
→ {"id":7,"method":"subscribe","params":{
    "sub":"s1","keys":["ST101.CN01.MOT01.speed", …],
    "mode":"slim","maxRateHz":10}}
← result: {"sub":"s1","epoch":"01J9…","seq":0,
    "handles":{"ST101.CN01.MOT01.speed":1, …},
    "meta":{"1":{…full DynamicValue metadata…}},
    "snapshot":{"1":{"v":1450,"q":192,"t":1786000000100}},
    "rejected":{"BOGUS.KEY":{"kind":"unknown_key"}}}
```

- Snapshot inline: one round trip, atomic with `seq:0`, and the explicit
  "initial state complete" signal every surveyed protocol needed.
- Partial failure per key in `rejected` — one bad key never blanks a page.
- **Per-key subscriptions with a client-side aggregator**, not per-page: the
  client unions the visible widgets' key sets and diffs on navigation
  (leased-subscription behavior falls out: off-screen keys get unsubscribed,
  which is Ignition's answer to 1556 tags at 10 Hz — most load never leaves
  the PLC once deadband + visible-set scoping are in place).
- Keymappings stay server-side; clients speak key space only.

### 4.3 Value push (notification, hot path)

```jsonc
← {"method":"u","params":{
    "sub":"s1","seq":4211,"t":1786000000123,
    "c":{"1":{"v":1450.2},"2":{"v":312,"q":192}},
    "q":{"3":{"q":516}},
    "r":[7]}}
```

- `c` changed values (slim), `q` quality-only transitions, `r` keys removed
  from availability. Single-character keys on the hot path only (HA's
  compressed-state precedent).
- `seq` increments per subscription per message. A gap ⇒ client requests
  resync. A periodic keyframe (full values, OPC UA `KeyFrameCount` idea)
  self-heals missed gap detection; the server sends a keyframe whenever the
  delta would exceed one.
- Quality codes are a four-band model (good / uncertain / bad / error with
  subcodes), adopted from Ignition's — the two states that matter are
  distinct: **uncertain-holding-last-known-value** vs
  **bad-stale-past-deadline**. Composition is worst-quality-wins.
  A connection-level event mass-degrades value quality (Sparkplug NDEATH
  rule): upstream PLC drop ⇒ all its keys go stale in one `q` sweep + one
  status notification, and the alarm system master-inhibits dependents.

### 4.4 Liveness (two layers + per-subscription)

- **Server** sets WebSocket `pingInterval` (~20 s): dead-client reaping and
  NAT keepalive. Browsers auto-pong per RFC 6455; Chrome never sends its own
  pings, so this is the only frame-level liveness that works for web.
- **App-level heartbeat**: server emits a `tick` notification (with `seq`,
  server time, and per-subscription last-evaluated stamps) every 2–5 s *even
  when nothing changed* — OPC UA's keep-alive insight: silence is never
  ambiguous. Client-side death deadline = 3× tick interval (OPC UA's
  LifetimeCount ratio). Client sends `ping` requests on its own timer for
  the reverse direction (browsers cannot see pongs; Ignition's reliance on
  idle timeouts is a documented 2.5-minute stale-data hole — the fix is a
  client-side watchdog, since the server structurally cannot report its own
  death).
- **Any inbound frame resets the client's freshness clock**; `readyState` is
  never trusted (lies after OS sleep). On web the grace period is
  visibility-aware (hidden tabs throttle timers to 1/min) and the client
  probes immediately on resume or a monotonic-clock jump.
- **Per-subscription staleness is distinct from link staleness**: the tick's
  last-evaluated stamps catch the dead-subscription-on-live-socket failure
  (Home Assistant wall-dashboard case), with its own UI state.

### 4.5 Resync

```jsonc
← {"method":"resync","params":{"sub":"s1","epoch":"01JA…","reason":"epoch_changed"}}
```

Reasons: `epoch_changed`, `server_restart`, `overrun`,
`permissions_changed`, `gateway_stalled` (the gateway announces its own
event-loop stalls ≥ the freshness deadline, so clients and the historian can
distinguish "the plant view was frozen for 42 s" from "my link dropped").
Client re-issues `subscribe`; the response snapshot is the resync.

There is a **second epoch at the gateway↔PLC boundary**: per-PLC, keyed on
OPC UA `ServerStatus.StartTime`. A PLC program download rebuilds the NodeId
space and cached-handle reads *succeed with the wrong tag's value* — on
StartTime change the gateway drops its NodeId cache, re-browses, and marks
affected keys bad until re-established. Tags resolve by browse path, never by
cached numeric NodeId across a session boundary.

### 4.5a Amendment, 2026-09-03 (Phase 9): the stall is surfaced, and forgiven

Two behaviours added behind reproduced defects (gate B, F22), written here
because a future reader will look for them in the design rather than in a
phase summary:

- **The client surfaces the stall, damped once per connection.** A
  `gateway_stalled` resync carries `reason` and `stalledMs` — an **absolute**
  duration measured by the gateway's own lag monitor, never recomputed from a
  client clock. `RemoteStateMan` exposes both (`stallReason`/`stalledMs`,
  shaped like `lastDownReason` — no new `StateManApi` member), so a panel can
  say *"gateway stalled for N ms"* instead of *"you disconnected"*, and it
  complains **once per connection** however many subscriptions resync. Before
  this, `connection_supervisor` decoded the reason and dropped it on the
  floor — the wire carried the fact and no operator surface did.

- **The reaper forgives the gateway's own stall, for one tick.** After a
  freeze, every session's `silentForMs` includes the freeze itself, because
  `_lastSeen` only advances when a frame is *processed* — a woken gateway
  would 4003 every panel in the plant for silence it caused (the
  synchronized-false-disconnect headline, reproduced on a 5 s freeze over a
  3 s deadline). `reap` now credits the wake-up tick's own `LagStalled.stalledMs`
  against each session's silence: derived from the `LagMonitor`, **never from
  anything a client sends**, bounded to the single tick that reports the
  stall, and preserving only-dead-sessions — a panel already silent *before*
  the freeze still carries that silence after the credit and is reaped on the
  same tick. The close reason is unchanged (the credit decides, it does not
  rewrite the sentence). Since 09-REVIEW WR-01 the silence and the credit are
  measured on the **same monotonic clock** — every session takes the tick
  engine's own uptime clock as its liveness clock — so a stall only the wall
  clock observes (a hypervisor stun on a guest whose monotonic clock freezes
  across it, an NTP forward step) cannot inflate silence with nothing to
  credit; the wall clock keeps only the *reported* `lastSeenMs`. The
  VM-snapshot cross-check (do the two clocks diverge across a real Veeam
  stun on our hosts?) rides Phase 11's soak rig.

The same stall also reaches the historian honestly: collection's interval
tick declines a wake-up sample (the timer's own missed-window count, past a
250 ms floor) instead of stamping the pre-freeze held value at `now()`, so a
frozen gateway leaves a **gap plus a counted decline** in the trend — never a
flat line — which is F22's third clause ("historian marks the gap") and the
same fail-safe instinct as the band-0-only quality gate. Be precise about
what the counter counts (09-REVIEW IN-03): `Timer.periodic` coalesces every
missed window into one wake-up callback, so `PIPE.collect.rows_dropped`
moves by **~1 per stall**, not by one per missed window — after a 45 s
freeze at 100 ms, ~450 samples are missing and the counter moves by 1–2.
The **loss measure is the gap in the trend**; the counter says a
stall-decline happened. It is kept that way deliberately: the wake-up
callback cannot know whether the gate was open or the held value's band
good during windows it slept through, so a per-window count would be a
census of the unknowable, and F22e's gate expectations pin the per-decline
semantic.

### 4.6 Writes (the safety path)

```jsonc
→ {"id":88,"method":"write","params":{
    "cmd":"01J8XW3K9P…",          // client ULID, minted when the operator ACTS
    "key":"ST101.CN01.MOT01.setpoint","value":{…},
    "expect":{"value":1450},       // optional compare-and-set
    "ttlMs":15000}}
← result: {"cmd":"…","outcome":"applied","readback":1500,"at":…}
← result: {"cmd":"…","outcome":"rejected","reason":{"kind":"interlocked","status":"Bad_NotWritable",…}}
← result: {"cmd":"…","outcome":"unknown","reason":{"kind":"plc_timeout",…}}
```

- **Three-state outcome.** `rejected` is a *successful RPC carrying bad
  news* (interlock, range, mode) — not an error. `unknown` is first-class:
  OPC UA itself says `Bad_Timeout` does not guarantee nothing changed.
- **`cmd` idempotency id** is minted at operator action, not send time; the
  server keeps a short-lived outcome log (~60 s). `writeStatus {cmds:[…]}`
  returns the same result objects; on every reconnect the client re-queries
  its unresolved ids. A `cmd` the server never received (within TTL) returns
  `not_received` — the only case that is definitively safe to re-send, and
  even then re-sending is an operator decision.
- **Readback in the ack**: "applied" means applied *and read back*. The UI
  displays the readback, never the locally-typed value (the IGN-2441 lesson:
  local edit state must never be the confirmation).
- Socket death with a write in flight ⇒ UI shows "outcome unknown — verify",
  requiring dismissal. Client code cannot represent this as failure: the
  write API is a sealed three-state type with no throw on the unknown path.
- **Momentary/hold-to-run controls never use set-on-press/clear-on-release.**
  The wire frames, the PLC-side function block that makes the ruling true on
  the plant, the 1 s deadman constant, the discrete-command pattern and the
  Flutter binding are all §4.6a.
- Reads/RPCs (browse, timeseries, history-view, preferences) are ordinary
  requests — **34 named methods** mapped verbatim from the drift API, plus one
  server→client notification. **No `query(sql)` RPC, ever.** The count and the
  two conventions it introduced are §4.6b.

### 4.6a Hold-to-run and momentary commands

The pipe's half of hold-to-run is code in this repository; the plant's half is
a function block in a PLC program nothing here can read, write or verify, and a
deadman with only one half written down is a deadman nobody can commission.
This subsection is the other half, kept next to the ruling it implements.

**The three wire frames.** Engage and release are ordinary writes — they get
the three-state outcome, the outcome log and the idempotency window of §4.6
for free — and only the ticks in between are a new name.

```jsonc
→ {"id":91,"method":"write","params":{
    "cmd":"01J8XW5R2Q…","key":"ST101.CN01.MOT01.jog",
    "value":1,"hold":true}}        // hold:true + value 1 = engage. The gateway
                                   // takes a handle and remembers it per SESSION,
                                   // so a dead socket cannot leave one behind.
← result: {"cmd":"…","outcome":"applied","readback":1,"at":…}

→ {"method":"h","params":{"k":"ST101.CN01.MOT01.jog","n":7}}
    // ~10 Hz while the finger is down. No `id`, no `cmd`, no answer: a tick has
    // no outcome to correlate, and giving it one would invite somebody to await
    // it — an await on the hot path is a queue with a nicer name.
    // `n` is decoded and validated and then DISCARDED. The gateway mints the
    // next counter from the handle the engage created; the panel's integer never
    // reaches the tag. Trusting it would put a peer-chosen number on a deadman.

→ {"id":92,"method":"write","params":{
    "cmd":"01J8XW6T4V…","key":"ST101.CN01.MOT01.jog",
    "value":0,"hold":true}}        // 0 = release. Stops the machine in the same
                                   // PLC scan instead of coasting out the deadman.
← result: {"cmd":"…","outcome":"applied","readback":0,"at":…}
```

- **The value vocabulary on a hold write is exactly 1 and 0.** Anything else is
  `INVALID_PARAMS`, raised before the handle is taken and before the device is
  consulted — a pre-plant refusal, so "rejected" here means *definitively no
  effect*, provably. Without it, `write` would be a way to put an arbitrary
  integer on a deadman tag while calling it an engage. The check is on `num`,
  not `int`: a REAL tag's `1.0` and a DINT's `1` are the same operator intent,
  and the refusal is about the number 7.

**`FB_HoldToRun`** — the machine runs only while the counter changes:

```
FUNCTION_BLOCK FB_HoldToRun
VAR_INPUT
    Counter    : DINT;   // written by the HMI; advances ~10 Hz while held
    Permissive : BOOL;   // interlocks, mode, guard doors — ANDed in
END_VAR
VAR_OUTPUT
    Run        : BOOL;
END_VAR
VAR
    LastCounter : DINT;
    Deadman     : TON;   // PT := T#1000MS  <- the 1 s decision
END_VAR

// The counter CHANGING is the signal. Its value carries no meaning:
// the HMI may wrap, restart at 1, or skip values after a dropped frame.
IF Counter <> LastCounter THEN
    LastCounter := Counter;
    Deadman(IN := FALSE);   // retrigger
END_IF
Deadman(IN := TRUE, PT := T#1000MS);

// Counter 0 is the explicit release the HMI writes on a clean let-go:
// it stops the machine in the same scan instead of coasting for a second.
Run := Permissive AND (Counter <> 0) AND NOT Deadman.Q;
```

- **1000 ms is a tolerance decision, not a physical one.** At a 100 ms pulse it
  is ten missed frames. It buys through a Wi-Fi hiccup mid-jog at the cost of
  up to one second of coasting when the link dies. Anything whose stopping
  distance makes a second unacceptable needs a hardwired enabling device, not
  this. The client states the same number as
  `ClientConfig.holdPulsePeriod` (100 ms) × `ClientConfig.holdMissedPulsesBeforeStop`
  (10), whose product is the derived `ClientConfig.holdDeadman` — but that is a
  *statement* of what the PLC is configured for and cannot enforce it: the `TON`
  preset above is a number in a PLC program no Dart code can read or set. **The
  two are kept in step by this document and by nothing else.** Change one, change
  the other in the same commit; the derived getter exists so there is exactly
  one place to compare against.
- **This is not a safety function.** It is a usability layer over an interlock
  chain. `Permissive` is where the real safety system enters, and a category-3
  hold-to-run pendant is a hardware device wired to a safety relay.
- **The HMI never sets a boolean and clears it on release.** A panel that
  crashes between the set and the clear leaves the machine running. The counter
  inverts that failure mode: a panel that crashes stops sending, and stopping
  is the safe state. This is the sentence F26 is testing — cable pull, app kill,
  backgrounding.

**Discrete momentary commands — HMI sets, PLC clears:**

```
// HMI writes TRUE. The PLC consumes the edge and writes FALSE itself.
IF CmdStart AND NOT CmdStart_Prev THEN
    // ... act on the command exactly once ...
    CmdStart := FALSE;   // the PLC clears; the HMI never does
END_IF
CmdStart_Prev := CmdStart;
```

The HMI clearing the bit means a panel that dies between set and clear leaves a
latched command; the PLC clearing it means the command is consumed exactly once
and the tag self-heals. It also makes the write idempotent from the pipe's
point of view — a replayed `write(CmdStart, TRUE)` inside the idempotency window
either matches the log or arrives after the PLC has already cleared, and either
way the machine acts once.

**The Flutter binding, specified and not built.** The controller
(`HoldToRunController`, `packages/tfc_relay_client`) is pure Dart with its
triggers injected, so the widget layer is a specification here rather than code
in a package that cannot import Flutter. Building it is transcription: three
release paths, and for each the Flutter API and the controller member it calls.

| Release path | Flutter API | Controller member |
|---|---|---|
| the operator lets go | `GestureDetector.onTapDown` / `onLongPressStart` engages; `onTapUp`, `onTapCancel` and `onLongPressEnd` end it | `press()` / `release()` |
| the app stops being in front of the operator | `WidgetsBindingObserver.didChangeAppLifecycleState` firing on anything but `resumed` | an event on the `Stream<void>` handed to `releaseOn` at construction |
| the link dies | **no widget code at all** | none — `RemoteStateMan` releases every live hold on leaving `ready`, and the handle's `onReleased` settles the controller |

`State.dispose` calls `dispose()`. That is the whole binding: four members, and
nothing about the link needs binding.

- **The one rule the binding must not break:** it may not hold a queue, a retry
  or a debounce between the gesture and the controller. Each of those is a way
  for a finger that lifted to keep a machine moving — a debounced release is a
  release that has not happened yet, and a queued tick is a burst of stale
  counter values delivered the instant a stalled link recovers.
- **A disconnect stops a hold twice over, and the tag reads 0 rather than
  freezing.** The panel stops pulsing (the counter stops advancing, which is
  what the deadman above watches for) *and* the gateway, when it tears the
  session down, releases every hold that session engaged — which writes the
  explicit zero. Two independent mechanisms, either of which is sufficient.
  Do not write a plant-side check that expects the counter to freeze at its
  last value.
- **A second `press()` on a live controller throws `StateError`.** Two
  concurrent holds on one tag are a contradiction at the operator's end — one
  finger, one button — and nothing in the client can decide which the machine
  should obey. A binding that can double-fire its press gesture must not paper
  over it with a `try`. **The gateway refuses the same thing on the wire:** a
  second engage frame on a key the session already holds live comes back
  `INVALID_PARAMS` before `holdToRun` is called, because the displaced handle
  would be reachable by no tick, no release and no session teardown. An engage
  frame replaying an id already recorded is still answered from the outcome
  log — one press arriving twice is one press.
- **A release during the engage round trip wins, and does not throw.** The
  engage is a real write with a 50–100 ms floor over a socket, which is long
  enough for a scroll to steal the pointer or for the app to be backgrounded.
  `release()` in that window records the intent and answers `WriteUnknown`
  (`hold_released_before_engage_answered`) — it never throws, so `onTapCancel`
  can stay wired straight to it. When the engage lands the controller releases
  the hold it just took and **never starts the pulse timer**: the alternative
  is a deadman fed at full cadence from a panel nobody is touching. The same
  holds for a lifecycle event and for `dispose()` inside that window.

### 4.6b Amendment, 2026-09-03 (Phase 10): the data services, as they shipped

§4.6's "~14 named methods" was an estimate made before the families were
counted. They have been counted, and they are **34 requests**:

| Family | Count | Interface |
|---|---|---|
| browse | 4 | `BrowseApi` |
| timeseries | 4 | `TimeseriesApi` |
| history views | 11 | `HistoryViewApi` |
| preferences | 15 | `PreferencesApi` |

`DataServiceMethods.all.length` in `tfc_relay_protocol` is the single spelling
of that 34, built from the four per-family sets rather than as a second copy
of the strings, and `method_table_closed_test.dart` iterates it. With the
pipe's own methods the gateway's handler table is **43** entries.

Plus **one server→client notification**, `preferences.changed`, which takes
the notification set from 5 to **6**. It is deliberately in none of the four
sets and not in `all`: a set that carried it would make the
method-table-closure test demand a handler for a frame that must never have
one.

Two conventions this phase introduced are **visible on the wire**, so they are
written here rather than left in a phase summary:

**Struct series are addressed `<series>:<member>`.** Ninety of the plant's 140
collected keys are whole drive structs, one table with one column per member.
The gateway projects **one scalar series per member** and the wire's sample
type stays `num` — a request for `ST101.CN01.MOT01:speed` gets a list of
numbers, not a list of maps. The alternative (rows of `Object?`) was rejected
because it breaks the arithmetic in every chart and ships members nobody
asked for. An **unaddressed** struct is a refusal naming the available
members, never a `Map`: the client decodes every point as
`TimeseriesData<num>`, so a map there is a cast error that reaches the
operator as "the chart is broken" rather than as "say which member".

**`preferences.changed` carries a key LIST, not a key.** A `clear()` over 500
keys must be one frame per client, not 500 frames in the priority lane. The
payload is therefore a list of the keys that changed, and a single-key change
is a list of one. Note what the frame is and is not: it announces *that* a
write happened, never the value, and it is gated on hello — but every
authenticated station is told which preference keys changed, so whoever ships
per-key preference hiding has to filter this frame as well as the getters.

### 4.7 Status channel & pipeline health

Per-PLC link state is its own notification (`status`), never smuggled inside
tag values, and doubles as the source for the `PIPE.upstream.<alias>.*` keys
(notes §7.7) so AlarmMan and diagnostics pages consume pipeline health as
ordinary keys — including `PIPE.link_degraded`, `PIPE.data_age_ms`, the
gateway's event-loop-lag gauge, and cert days-to-expiry (a plant alarm, so
rotation is a Tuesday ticket, not a Sunday outage).

**`PIPE.cert.days_to_expiry` is built.** It is the first `PIPE.*` key to exist
and it behaves like a conveyor speed: it is in `keys`, it is in a subscribe
snapshot, and a change is pushed on the ordinary notification path.

| Property | Value |
|---|---|
| Value | whole days to `notAfter` on the **sooner of the leaf being served and the leaf on disk**, both read by path, neither cached as bytes |
| Sign | negative is meaningful: an already-expired leaf reads `-3` |
| Quality | `errorConfig` with a **null** value when the PEM is missing or unparseable — never `0`, which would read as "expires today" and fire the alarm for a typo in a path |
| Cadence | recomputed when an hour has elapsed, checked on the read path and on the heartbeat rather than on a timer (the gateway holds exactly one repeating timer, §5's tick, and a second one would fight it); `readFresh` forces a recompute; a gateway with no session does not recompute, and there is nobody to push to |
| Absent | when the gateway is plaintext. A gateway with no certificate has nothing to say about one, and a key answering `0` there would be a lie |
| Threshold | AlarmMan's, not the pipe's. The pipe ships the number |

**The arithmetic truncates.** A 17-day leaf reads `16`, so an alarm configured
at 30 days fires on the day the value first reads 29. Keep that sentence next
to whatever configures the threshold.

**A rotation needs a restart, and the number says so.** `SecurityContext
.useCertificateChain` reads the PEM once, at bind, and the running server
presents that leaf until the process is replaced — there is no certificate
hot-reload here and none is planned. So the key reports the *sooner* of the
served leaf and the mounted one. Mount the new leaf and defer the restart and
the value keeps counting the old one down, which is the true statement: every
panel is still validating it. The alarm clears when the gateway is restarted,
not when the file changes. Mount a *shorter* leaf and the number drops at
once, because that deadline is real the moment the restart happens. Without
this the yearly re-issue would clear the alarm, close the ticket, and leave
the plant to stop on the original expiry date with no warning at all.

**Which requests are deadline checks.** Not all of them. `hello`,
`unsubscribe` and `writeStatus` read no key and check nothing; `ping` is a
deadline check because it was made one deliberately — an established panel
holding its subscriptions sends nothing else for a whole shift, and "a gateway
with no traffic" was not the honest description of the residual.

Until Phase 8 owns the real `PIPE.*` producer the key comes from a small
server-wide overlay chained under the per-session policy decorator of §7.5 —
so the policy filters a key list that already contains it. Phase 8's merge is
a deletion: the computation moves into `LocalStateMan` and the overlay goes.
`PIPE.cert.days_to_expiry` has to be on Phase 8's reserved-name list from the
first day, because `PIPE.` is a reserved *prefix* and a plant keymapping
claiming a name inside it is rejected.

#### The roster as shipped (amended 2026-09-02, Phase 8)

**The merge was not a deletion.** The paragraph above expected one producer;
there are three, and the reason is that `PIPE.*` names three different kinds of
fact. A shared instance cannot answer a per-socket question — it would report
whichever panel last asked — and a per-session overlay cannot answer a
per-plant one without every panel opening its own PLC subscription. So the
overlay stayed, in the same chain slot, with a different job.

| Group | Home | Keys | Why there |
|---|---|---|---|
| 1 — pipe-wide | `LocalStateMan` (`PIPE.connected` only) | `connected` | The plant half of the bit: true when **every** configured link is connected. `rtt_ms`, `data_age_ms`, `reconnects` and `epoch` remain client-minted facts with no gateway producer — see the note below |
| 2 — per session | `SessionHealthStateMan`, one instance per connection, in the chain slot the certificate overlay held | `link_degraded`, `effective_hz`, `egress_kbps`, `pending_keys`, `dropped_hold_ticks`, `event_loop_lag_ms` | Every one is a fact about **one socket**: this panel's send buffer, this panel's tick rate, this panel's egress |
| 3 — per upstream link | `LocalStateMan` | `upstream.<alias>.` × `connected`, `state`, `last_error`, `epoch`, `birth_count`, `last_death_at`, `data_age_ms` | Builders, not constants: the alias comes out of a configuration file, so there is no finite roster of them |
| 4 — gateway self | `tfc_relay_server` | `cert.days_to_expiry` | See below |

**The certificate key stayed server-side, and that is a deviation from the
phase's own ruling with a written reason.** It is a property of the leaf *this
process is serving* — read one line after `useCertificateChain` from the same
`TlsConfig` — not a property of the plant. Moving it would either strand the
sixteen socket-level cases that judge it or put an open62541 native build in
front of a package that has no native dependencies. The **name** is a single
constant in `PipeKeys`, so there is still exactly one spelling, and the
reserved-list entry is unaffected.

**The two rosters are disjoint and that is asserted, not assumed.** The
per-session overlay deliberately does not claim `PIPE.connected`: the socket
half and the plant half are different facts, and one silently shadowing the
other in the chain is the failure the disjointness assertion exists to catch.
Measured over a real socket: six per-session names, eight plant-side names, no
intersection.

**Both flavours are ordinary keys, over a real socket.** A panel subscribes to
`PIPE.upstream.<alias>.connected` and to its own `PIPE.link_degraded` in the
same `subscribe` call it uses for a motor speed; both arrive in the snapshot,
both appear in `keys`, and there is still no health method on the wire.

**A health key legitimately reads `false` before it reads `true`.** The plant
publishes its link keys the instant it has *asked* a link to connect, and the
OPC UA adapter does not report `connected` until the wrapper's heartbeat has
proved the data plane works. A panel that dials during that window is told the
truth twice. Anything asserting on these keys reads them inside a window, never
on the instant.

**HLTH-03 is per key, at boot.** A keymapping entry claiming a name inside the
prefix is refused, named once in the boot log, and absent from `keys`, from
`browse` and from `readMany` (which answers `errorConfig` for it, so a
diagnostics page renders a fault rather than a blank cell). Every other entry
on the same file is served: a gateway that refused to boot over one bad
mapping line would be a plant that is dark over one bad mapping line.

## 5. Backpressure and slow links

Design rule from notes §7.6, confirmed by every precedent (Lightstreamer,
DraftKings, Ignition) and forced by Dart itself — `dart:io` WebSocket has no
`bufferedAmount` and no `flush()` and buffers unboundedly:

- Per-client **conflating send map** (key → latest value), drained only when
  the previous sink write's future completes. Slow clients get the newest
  value at whatever cadence the link sustains; memory is bounded by
  subscription size; recovery has no backlog to flush.
- RPC responses, write acks, status, and ticks ride a small **priority queue
  that is never conflated** and flushes first — a degraded link must still
  deliver the news that it is degraded.
- A watchdog closes any connection exceeding a bounded pending count —
  converting a silent heap leak into a visible reconnect.
- **Encode once per tick, fan the same object out to every sink.** One
  isolate; no isolate sharding (sockets are isolate-bound; fan-out across
  isolates multiplies boundary crossings).
- Message size cap enforced at the encoder (Ignition drops sessions on
  oversized frames; Grafana caps at 64 KiB) — oversized deltas become
  keyframes, oversized keyframes get chunked.

### 5.1 Amendment, 2026-09-01 (Phase 7): the drain gate is not implementable on this transport

The rule above stands as a design rule. The clause **"drained only when the
previous sink write's future completes"** is *not implemented*, and on
`dart:io` WebSockets it is *not implementable* — there is no
egress-completion signal to gate a drain on. This paragraph exists so the
next reader stops looking for the bug: there is no bug, there is a transport
that does not offer the primitive.

**Measured** (07-RESEARCH §B.3, `egress_gating_probe.dart`, macOS arm64, Dart
3.11.5): 100 frames × 7 KiB — **700 KB** — pushed at a client behind a
100 kbit/s token-bucket relay, a link that needs **57 seconds** to carry
them.

| Write path | Push returned in | Client had received | RSS growth |
|---|---|---|---|
| `sink.add` | **7 ms** | **0 of 100** | 2.9 MB |
| `await sink.addStream(Stream.value(m))` | **5 ms** | **0 of 100** | 1.0 MB |

Both paths return in single-digit milliseconds having delivered nothing.
`WebSocket.addStream` completes when the source stream has been drained into
the WebSocket's *own* outgoing controller, not when the kernel accepted the
bytes — so the one hatch `tick_engine.dart:44-71` did not consider is closed,
and **nobody should re-test it**. The other candidate named there,
`ws.sink.done`, completes only on *close*, so it cannot pace anything either.
There is no `bufferedAmount` and no `flush()` (flutter#103306).

**Two queues, and the document above reads as though there were one.** "Queue
stays bounded" is true of the conflating send map and false of the socket:

- the **conflating map** is bounded by subscription size and it is asserted —
  peak `pendingCount` **201** against a 200-key page under sustained
  saturation (Phase 7, `slow_link_recovery_gate_test.dart`), which is
  last-value-wins per (subscription, handle) holding exactly;
- the **`dart:io` write buffer** behind it is unbounded and **cannot be
  observed from this process at all**. Its size is only ever visible
  indirectly, as what comes out afterwards: after 15 s of saturation,
  unthrottling delivered **107 update frames and 376 kB in the first second**
  against a steady state of 10.0 frames/s — a **10.7×** burst on a link that
  had been carrying 12.5 kB/s. So the catalogue's parenthetical "the
  conflating map means there is no backlog to flush" is false here, and it is
  false for this reason.

**What the product does instead**, and both halves are real:

1. **Per-tick conflation.** `drain()` runs every tick and last-value-wins
   within a tick is genuine — 12 update frames delivered against 35 plant
   sweeps during a metered window. What it does *not* do is collapse anything
   *between* ticks: each drained frame is handed to the socket the moment it
   is built, so 115 of 116 sweeps eventually reached the panel. What
   `ConflatingSendBuffer.poll` measures across ticks is therefore this
   server's **production** for one client, not that client's backlog
   (03-REVIEW WR-11) — a slow client is detected by the heartbeat deadline,
   not by the buffer.
2. **The client tells the operator.** Phase 7 wired
   `FreshnessWatchdog.staleSubscriptionsAt` into `RemoteStateMan`'s rendered
   surface, so a starved subscription is **rendered stale** against the local
   clock rather than agreeing with a frame that is a minute old. That closes
   the failure this gap would otherwise cause on a plant floor — a panel a
   minute behind reading as live — without pretending the queue is bounded.

**Where the real answer lives: a protocol-level acknowledgement.** The
client's app heartbeat would carry the highest `seq` it has applied per
subscription, and the gateway would gate the drain on it. The shipped pump
sends `Methods.ping` with no params (`heartbeat_pump.dart`), so a reader
looking for the sequence on the wire today will not find it. That is the honest
implementation of the clause above and it also gives Phase 8's
`PIPE.effective_hz` and `pending_keys` a real source instead of a proxy
measure. It is **a named follow-up, not scheduled** — it is a protocol
addition and belongs to a phase that owns the protocol.

Phase 7's deviations registry
(`packages/tfc_relay_client/test/gate/f_row_registry.dart`) carries the four
catalogue clauses this gap descopes — F20 "queue stays bounded", F20 "never
an old queued one", F21 "no burst of backlogged frames on recovery" and F21's
shortened saturation window — each with its number.

## 6. Wire format rules

1. **JSON, UTF-8 bytes end to end.** Decode with `JsonUtf8Decoder` fused on
   the socket's `Uint8List` (the measured 3.5 ns/byte path); never
   String-then-parse. Send binary frames as `Uint8List` (a `List<int>` takes
   the text path on legacy web).
2. **Integer key handles** assigned at subscribe; slim values thereafter. At
   ~36 bytes/update the tag name is most of the bytes — handles beat any
   codec change. Debug flag restores full names for captures.
3. **Non-finite doubles never reach `jsonEncode`.** Dart *throws* on
   NaN/±Infinity (locally verified) — one open-circuit 4–20 mA input would
   otherwise kill the batch for every client. Sanitized at the OPC UA
   boundary: value `null` + quality `non-finite`. The decoder is fuzzed with
   `1e999` (silently becomes Infinity — a poison value), deep nesting,
   duplicate keys.
4. **PLC strings decode with per-server encoding config** (`utf8`|`latin1`),
   default `allowMalformed: true`, S7 NUL padding stripped. Fixtures use
   "Þorskflök í raspi", not "test string 1" (locally verified:
   `utf8.decode` throws on Latin-1 þ/ý/æ bytes).

   **Outcome, 2026-09-02 (Phase 8): one half landed, the other is a named
   follow-up.** The rule was scoped at the discuss gate to "build the
   Modbus/M2400 half now; the OPC UA half rides the binding branch if cheap,
   else a documented follow-up". It was not cheap, so:

   * **Landed** — per-server encoding is configured per **alias**
     (`string_encoding: utf8|latin1` on each link, derived into one table so
     there is not a second list of aliases to get out of step) and applied to
     the byte-carrying protocols. A string that cannot be decoded under the
     configured encoding fails **that one tag** with quality
     `uncertainEncoding` (260) — never a poll cycle, which is the standing
     constraint this rule serves.
   * **Follow-up, binding-side** — the OPC UA half. Raw bytes are not
     reachable through `ClientApi`: the binding decodes before Dart sees
     anything (`extensions.dart:416`, `types/payloads.dart:235,266`), and the
     branch this phase took did not make a hook there cheap. **It is not a
     plant-visible gap**, which is worth writing down so nobody escalates it:
     SVN's OPC UA servers are TwinCAT and emit UTF-8, and the plant's likely
     Latin-1 sources — the M2400 weighers and the Saia-over-Modbus box erector
     — are both covered by the half that landed. It is filed against the
     binding rather than worked around here, because a workaround would mean
     re-encoding a decoded `String` back to bytes and guessing which ones.
5. **Binary stays available but unused.** If ever needed: CBOR (RFC 8949 +
   typed arrays; the Dart msgpack ecosystem is dead). The measured JSON cost
   — 0.42% of one core at the impossible worst case — says never bother;
   with the client at 10 Hz the real cost is widget rebuilds, not parsing.
6. **Timestamps are UTC epoch ms on the wire**, `timestamptz` in the DB,
   local only at render. CI runs under `TZ=Pacific/Chatham` because
   Iceland's UTC+0/no-DST hides every timezone bug on dev machines.

### 6.4 permessage-deflate: off, with a flag

The reports split (transport: off — ~300 KB/connection, breaks encode-once,
CVE history; RPC + industry: on — closes most of the JSON-vs-binary gap).
Resolution from our own numbers: worst case at 10 clients is 5.5 Mbit/s on a
gigabit LAN — bandwidth is not the constraint at SVN scale, and
delta-push + handles already removed the redundancy deflate would compress.
So: **off by default**, preserving encode-once byte fan-out and
debuggability; a per-deployment config flag enables it if a saturated VLAN
or the web phase measurably needs it. Revisit with data, not taste.

## 7. TLS and auth

Built in Phase 6 and described here as it shipped. This section is written for
two people: the integrator provisioning a new station, and whoever is standing
in front of a dark panel at 06:00. Three of the decisions below are **not**
recoverable by reading the code, which is why they are written down at all.

### 7.1 What is mounted, and where

Four files. Three live on the gateway host, one lives on every panel.

| File | Named by | Where | Rotates |
|---|---|---|---|
| `leaf.pem` — the gateway's certificate | `TlsConfig.chainPath` | gateway host | yearly |
| `leaf-key.pem` — its private key | `TlsConfig.keyPath` (with `keyPassword` if it is encrypted) | gateway host, `0600` | with the leaf |
| the token file | `AuthConfig.tokenFilePath` | gateway host, `0600` | when a station is added or a panel retired |
| `ca.pem` — the private root | `ClientTlsConfig.rootCertPath` | **every panel** | ~ten years |

`ServerConfig.tls` and `ServerConfig.auth` are two separate nullable objects,
and `null` means "not configured": no TLS, no credential checking. They are
separate rather than one because they rotate on different clocks and fail in
different ways — a bad leaf stops every panel at once, a pulled token stops
exactly one. Both default to `null`, which is the whole compatibility story:
every in-repo fixture keeps binding `ws://` on loopback with an ephemeral port
and none of them was rewritten for this phase.

**Independently nullable does not mean the panel side is free to combine them
any way it likes.** Turning the token file on before TLS is the obvious
rollout order and it puts a credential that grants `operate` on the plant's
machines onto the LAN in cleartext, once per reconnect, for as long as the
panel runs. `ClientConfig.checkDialable` therefore refuses three combinations
rather than one: `wss` with no pinned root (an encrypted dial the panel cannot
verify), a pinned root on a `ws` dial (a configuration that reads as encrypted
while the traffic is not — the root is never consulted), and a token on a `ws`
dial. Only the last has an escape hatch, `allowTokenOverPlaintext`, because
only it has a legitimate caller: the fault fixtures that drive the credential
path over plaintext loopback. Plaintext with neither a token nor a root — every
existing fixture — is untouched.

**A gateway binding off loopback with neither half configured warns.** Not a
refusal: cleartext and unauthenticated behind a firewall on a segmented
network is a real deployment and the gateway cannot tell whether it is in one.
But every other misconfiguration this phase can produce is refused with a
paragraph attached, and `ServerConfig(address: anyIPv4)` with both halves null
was the one that was accepted in silence.

**Every one of these config objects holds paths and structurally cannot hold
bytes.** That is SEC-01, and it is enforced by a test that walks `TlsConfig`'s
fields and fails if any of them is not a `String` — because a config object
that *can* carry key material eventually does, and from that moment every
configuration dump and every pasted support ticket is carrying the plant's
keys. An empty path is refused by each object's own constructor, so an
unmountable config cannot be constructed anywhere, not even in a test.

**The one exception is `keyPassword`, and it is redacted rather than
excluded.** A passphrase is a `String`, so the field-type guard cannot see it:
the single field on `TlsConfig` whose purpose is to hold a secret satisfies
the test that exists to keep secrets out of the config. `TlsConfig.toString()`
is therefore written out rather than left to the default, and renders
`keyPassword: <redacted>` or `keyPassword: none` — the second half is the
useful one, because a deployment debugging a start failure needs to know
whether the gateway thinks the key is encrypted. Nothing in the shipped
provisioning sets it: `relay_certs` writes unencrypted keys behind `0600`,
since a passphrase the gateway must know is a passphrase living in a config
file next to the key.

**A missing or unreadable file fails `start()`. There is no downgrade to
`ws://`.** The token file is loaded first, the `SecurityContext` built second,
and both happen before the bind — so a gateway that cannot read its
credentials never opens a port. This matters more than it looks: a gateway
that quietly served plaintext because a path was misspelled is discovered by a
packet capture months later, and `tls == null` (a deliberate choice) must stay
a different thing from a file that did not load.

### 7.2 Minting the certificates

`relay_certs` ships in `tfc_relay_server` and needs no `openssl` on the
machine. Two runs, in order:

```
dart run tfc_relay_server:relay_certs --ca --out /etc/relay/pki
dart run tfc_relay_server:relay_certs --leaf \
    --ca-cert /etc/relay/pki/ca.pem --ca-key /etc/relay/pki/ca-key.pem \
    --san relay.svn.local --san 10.104.29.71 --days 365 \
    --out /etc/relay/pki
```

The root defaults to ten years, the leaf to one. `--leaf` with no `--san` is
refused rather than obliged: a leaf that matches no host is refused by every
panel at the handshake, and producing one silently is worse than not producing
one. Private keys are written `0600` on POSIX.

**The one thing an integrator must not get wrong: the leaf's SANs must include
every address a panel dials, and an address dialled as an IP literal needs an
IP SAN.** The reason is worth one sentence, because the obvious library gets
it wrong: `basic_utils` encodes every subject-alternative name as a `dNSName`,
so `10.104.29.71` goes into the certificate as a DNS *string*, which passes a
hostname test and is refused by every panel in the plant. `relay_certs` writes
a real `iPAddress` GeneralName (DER tag `0x87`, four octets) and a unit test
asserts the tag byte on both branches, so a cleanup that unifies them cannot
reintroduce the defect quietly.

`packages/tfc_dart/bin/generate_certs.dart` still carries that defect. It is a
follow-up, not a bug being shipped: it mints OPC UA **client** certificates,
where `dart:io` is not the verifier and nothing today validates their SANs by
IP. The corrected encoder to copy is `_generalName` in
`tfc_relay_server/lib/src/tls/mint.dart`.

### 7.3 Where the panel's root lives, and what it costs

A panel trusts exactly one root, loaded from a **file path on that station**:

```dart
SecurityContext(withTrustedRoots: false)..setTrustedCertificates(tls.rootCertPath)
```

one `SecurityContext` and one `HttpClient` per panel, built once at
construction and closed after the link on dispose. Never
`badCertificateCallback` — it disables hostname, expiry and issuer checks
together, and pre-Dart-3.13 it receives the wrong certificate (sdk#39425). A
repo-wide sweep fails the build if the identifier appears in any `.dart` file,
comments excepted, and the sweep carries its own anti-vacuity arms so it
cannot pass by reading nothing.

Dialling `wss://` with no pinned root is refused when the panel is
constructed, not at the handshake, because the handshake failure it would
otherwise produce is byte-identical to the one a real impostor produces.

**The ops cost is one path in every station's config**, provisioned with the
image — the `docker/frontend` work owns it. The alternative was installing the
root into each machine's OS trust store and dialling with
`withTrustedRoots: true`, which would cost nothing per station. It was
rejected on security, not on convenience: with the system store in the trust
path, **anything already in that store can vouch for the gateway** — a
corporate MITM appliance, a stale internal CA, whatever an installer put there
in 2019. Pinning one root means the only certificate the panel will accept is
one this plant's CA signed. The property has no offline behavioural test (it
takes a leaf signed by a root the machine already trusts, which no test can
mint), so `withTrustedRoots: false` is pinned by a source-text assertion with
that measurement recorded beside it.

### 7.4 The token file, rotation and revocation

Identity is **per-station static tokens**: no auth server, no people-identity,
no expiry clockwork, and it works on a plant LAN with no route to anywhere.

```jsonc
{"tokens": {"<opaque token>": {"stationId": "ST101", "role": "view"|"operate"}}}
```

Keyed by token so the lookup is O(1) and nothing scans secrets in a loop. What
is held in memory is a SHA-256 digest of each token, not the token, so the map
compares digests and a dump publishes none of the plant's keys; the
confirmation after the lookup compares two 32-byte buffers in constant time
whatever the token's length was.

**Four refusals at load, each naming the station and never the credential:** a
duplicate `stationId`, an unknown role word, a token shorter than 24
characters, and a file any other account can read. Contents failures are
`FormatException` and mount failures are `FileSystemException`, so a
deployment can tell "fix the JSON" from "fix the mount" without reading the
message. Any of them fails `start()` before the port opens.

The panel presents its token in a typed `token` field on `hello` — deliberately
not inside `capabilities`, which is an open map the session logs and copies,
and a credential in a logged map is a credential in a log line. A refused
credential comes back `-32003` and closes 4001, and the panel **stops**
redialling: a bad token is a fact about this panel that retrying cannot
change, and a mistyped one would otherwise be a permanent hello flood against
the gateway. This is the deliberate opposite of §7.7's rule for a certificate
rejection.

**Rotation is in-process.** `reloadTokens()` re-reads the file and then sweeps
the session registry, closing with **4001** every live session whose
credential no longer buys the identity it is carrying. Four cases, and the
fourth is the one that matters most: token gone, station renamed, role
narrowed (a demotion that only takes effect on the next reconnect is a
demotion an operator can postpone indefinitely by not reconnecting), and token
**replaced** — which is what a leaked credential is actually remediated with,
and which no comparison of identities can see, because the station and its
role are exactly what the operator keeps. The session therefore records a
one-way digest of the credential it authenticated with, beside its identity
and never instead of it, and the sweep asks whether *that digest* still
resolves to *that identity*. The revoked station's socket closes while every
other station keeps receiving plant updates. A restart-to-apply design cannot
do this: it drains every session with 4002 and 4001 would never fire.

**The poll or watch that calls `reloadTokens()` belongs to the embedder, and
nothing in this repository calls it yet.** Two reasons, both deliberate:
`File.watch` on a bind-mounted path in Docker is unreliable, and the gateway
argues for exactly one repeating timer (§5's tick) — a second one inside the
process would fight it. The call that poll should make is
`reloadTokensIfChanged()`: **one** read of the file, digest-compared so
re-saving an identical file costs nothing, and the sweep only when the bytes
changed. The two-call sequence it replaces (`reloadIfChanged()` then
`reloadTokens()`) parsed the file twice per change, and the two reads can
disagree — a file edited between them, or half-written by an editor that does
not write atomically, leaves the sweep running against a set the caller never
saw.

A revocation costs the panel **exactly one redial**: the 4001 close carries no
RPC error, so the supervisor cannot tell it from a gateway restart, redials
once, presents the same stale token and gets the `-32003` that stops the loop.
Not zero, and not unbounded.

### 7.5 Authorization, and hiding as architecture

Two synchronous questions, `canSee(key, identity)` and
`canWrite(key, identity)`, asked by a per-session decorator that wraps the
whole `StateManApi`. The session's `api` **is** the decorator and the
unwrapped source is private, so a handler added in a later phase cannot reach
around the policy — the guarantee is structural, not a convention.

The shipped policy is deliberately trivial: **everything visible, `operate`
writes, `view` does not**. The seam is the deliverable; the policy data is not.
The pattern grammar for per-key rules is **not defined in this phase** — that
is a decision, not an oversight, and whoever defines it inherits a seam that is
already consulted on every surface.

**The binding rule is that a hidden key must be indistinguishable from a
nonexistent one**, because "forbidden" is an answer that leaks existence. It is
implemented in one place — `canSee` filters the key list — and five surfaces
inherit it. A test compares a hidden key's answer to a never-existent key's on
six surfaces, field by field, with a companion assertion proving the test
policy is really hiding something the plant really serves.

That rule is what decides the codes, and the four answers are four different
facts:

| What happened | Answer | What the client does |
|---|---|---|
| bad or absent credential at `hello` | `-32003 unauthorized`, then close **4001** | stop redialling — the credential is wrong and retrying cannot fix it |
| write to a key this station may see but not actuate | `-32005 forbidden` | never retry; the session is fine, this action is not permitted. Keep the socket, keep reading |
| any request naming a **hidden** key | `INVALID_PARAMS` + `unknownKey` — byte-identical to a key that does not exist | fix the key name. There is nothing here to ask permission for |
| token revoked mid-session | close **4001**, no RPC error | one redial, then stop (§7.4) |

Rows two and three must differ, and row three must not be `forbidden`: a
typo is fixed by correcting the key, a permission is obtained by asking
somebody. The refusal is raised above the device call, above the outcome log
and above the idempotency window, so `-32005` inherits the write path's
standing promise that a refusal means *definitively no effect* — and a later
`writeStatus` for that command honestly answers `not_received`.

`allowedOrigins` is enforced server-side by `shelf_web_socket`: an
origin-bearing upgrade that is not on the list gets **HTTP 403** before the
upgrade, and a native panel, which sends no `Origin` at all, passes. The field
is non-nullable and defaults to an empty list; making it nullable silently
disables the check, so three separate mechanisms pin it.

Close codes remain **4000–4999 only** (4001 auth expired, 4002 draining, 4003
heartbeat timeout, 4004 backpressure overrun, 4005 protocol mismatch) —
standard codes other than 1000 throw in `web_socket_channel`, and `closeCode`
is unreliable for self-initiated closes, so the client tracks its own. Every
one of the five is now observed client-side by a test; there are no exempted
codes left.

### 7.6 The health key

`PIPE.cert.days_to_expiry`, specified in §4.7. Integer days, recomputed
hourly, `errorConfig` when the file cannot be read, absent when the gateway is
plaintext, and truncating — so an alarm at 30 fires at 29. It measures the
sooner of the served leaf and the mounted one, so rotating the file without
restarting the gateway does not clear the alarm.

### 7.7 Two operational notes

**The backend container needs `ca-certificates`.** Dart 3.13 removes the
compiled-in fallback roots, so the moment the gateway makes any *outbound* TLS
call of its own — an API, a database over TLS, anything — it has no roots to
verify with unless the image provides them. It is **irrelevant to the inbound
pinned path**, which uses only the files we load and would work in a container
with no trust store at all. That distinction is exactly the sort of thing that
gets lost, and the failure mode of losing it is a container rebuild that
"fixes" TLS by accident and a later slim-down that breaks it again.

**Every TLS rejection looks identical.** Wrong CA, expired leaf, SAN mismatch,
self-signed leaf, and a link cut *inside* the handshake all raise the same
`HandshakeException` with the same message and a null close code. A support
ticket saying "certificate error" therefore narrows nothing, and the three have
to be told apart by changing one thing at a time — dial by IP and by name,
check `notAfter` on the leaf, check the root on the panel is the one that
signed it. Never assert *why* a handshake failed by matching its message.

What the health line **can** distinguish is coarser and still useful: `the
gateway's certificate was not trusted by this panel` (a trust problem, or a cut
handshake — they read alike), `did not answer: …TimeoutException` (a bounded
dial that got nothing back), `did not answer: …403` (wrong origin), `did not
answer: …Connection refused` (nothing listening), `the transport ended` (a
clean close on a live link), and the credential refusal, which is the only one
that stops the panel asking.

A certificate rejection **keeps the panel retrying**, on purpose: the fix is a
file on the gateway, so a panel that keeps trying comes back by itself with
nobody visiting the station.

### 7.8 Still open, and deliberately

- **Web trust story** — a deployment decision, unchanged and unbuilt (browsers
  give a failed `wss://` no interstitial and no error detail, by design): root
  pushed via provisioning/GPO — Chrome/Edge ≥133 can scope it to the plant CIDR
  via `CACertificatesWithConstraints` — or a real domain with DNS-01 ACME.
  Either way the **web bundle is served from the same origin as the WS
  endpoint** (turns a silent socket failure into a debuggable page-level error,
  kills CORS, one port).
- **mTLS** stays an option for the centrally-managed eLinux panels only (read
  the client cert before `WebSocketTransformer.upgrade`; enforcement in app
  code — `bindSecure` cannot require it). Token-only is the default posture.
- **Per-key policy data and its pattern grammar** — the seam is built and
  consulted everywhere; the language is not designed.
- **Inactivity behaviour.** The earlier plan of degrading a session to
  view-only on inactivity, with re-auth per privileged write (PIN or badge on
  the confirm dialog), is **not built** and does not follow from per-station
  tokens: there is no person in the identity to re-authenticate. It stays a
  real idea for the day operator identity exists, and it is the answer to audit
  under shared accounts.
- **Connection slots are unbounded** for unauthenticated peers, with only an
  emergent bound (connect rate × the heartbeat deadline). A `maxSessions`
  ceiling and rate limiting are Phase 7's call.

## 8. Implementation stack (Dart specifics)

| Piece | Choice | Notes |
|---|---|---|
| Server HTTP/WS | `shelf` + `shelf_web_socket` 3.x | `allowedOrigins`, `pingInterval`, same-origin static bundle |
| Client socket | `web_socket_channel` 3.x behind a thin adapter | 3.x wraps `package:web_socket` anyway; adapter isolates its 12 open bugs and keeps a fork/migration one file |
| RPC | `json_rpc_2` `Peer` over `stream.cast<String>()` | fresh `Peer` per connection; no queue/retry is a *feature* — in-flight writes fail loudly at channel death |
| Reconnect | hand-rolled (~30 lines) | exponential + full jitter, cap 30 s, **backoff resets only after resync completes**; wrappers with "message queuing" are disqualified by the write rule |
| Protocol types | hand-written sealed classes in a **pure-Dart `protocol` package** (pub workspace) | ~20–40 message types; exhaustive `switch`; no codegen in the shared package (freezed has twice been the repo-wide analyzer blocker under workspaces' one-resolution rule) |
| Rendering | one `ValueNotifier` per key in a long-lived store | equal values skip notification → an unchanged reading costs zero rebuilds |
| Testing | `StreamChannelController` for in-memory protocol tests; `TcpProxy` for everything in notes §7.5–7.9 | plus DraftKings' rule, adopted: the gateway **kills connections on a schedule in staging** so resync is exercised weekly, not discovered in an incident |

Known-bug workarounds baked into the adapter: own close-code tracking
(#1698), 4000-range codes only (#1690), `Uint8List` sends (#1648), never
trust `ready`/`readyState` (#1693, OS-sleep lies), no reliance on
`bufferedAmount` (doesn't exist on IO, unreachable on web 3.x).

Operational hardening from the risk list: 72 h client soak with RSS sampling
+ `leak_tracker` (multi-day Flutter desktop uptime is publicly unvalidated);
pinned Flutter version with soak-before-bump (a stable release shipped a
120→40 fps Windows regression); `ca-certificates` in the backend image
before Dart 3.13; gateway event-loop lag monitor exposed as a `PIPE.` key;
own dart2wasm smoke test when the web phase starts.

**Correction (2026-09-05): that mitigation would have missed the defect it was
for, and the lane is dart2js instead.** `newUlid()` built its 48-bit time prefix
with `<<`, `>>` and `&` — correct on the VM, silently wrong under dart2js, where
bitwise operators coerce to signed 32 bits. Two mints 2^32 ms (49.7 days) apart
produced an identical prefix; uniqueness survived (the 80-bit secure suffix
never touches a shift) but the time-sortability this design calls load-bearing
did not, and every browser-minted id would have sorted before every native one
for ever. All 308 VM tests were green throughout.

**dart2wasm has true 64-bit integers and produced the *correct* id**, so the
Wasm smoke test scheduled above would have passed while the defect shipped.
`flutter build web` emits dart2js, so that is the backend that both matters and
reproduces it. Fixed by replacing the bitwise arithmetic with `%` and `~/`
(exact on both backends below 2^53), pinned by `ulid_web_test.dart` under
`@TestOn('browser')`, and run in CI as *Test tfc_relay_protocol on dart2js*.

The general lesson, which is not about ULIDs: **a smoke test on the wrong
backend is worse than none, because it is reported as coverage.** When a defect
class is "this platform's integers are narrower", the test has to run on the
narrow platform — and it must not build its own inputs with the construct under
test, which the first draft of that file did (`1 << 32` evaluated to 0 there,
and the test reported the *fixed* code as broken).

## 8a. The chaos soak (conventions)

A seeded randomized fault schedule that runs the composed pipe — four fake
PLCs behind the real `LocalStateMan`, the real `RelayServer` on an ephemeral
port, five real `FaultProxy`, five real `RemoteStateMan` over real TCP — for
ninety seconds on every push and thirty-five minutes on every push to `main`.
**The only fake is the PLC.** RES-03 is the requirement; the invariants are
§7.8's five.

It lives in `packages/tfc_relay_local/test/soak/`, behind the `soak` tag,
because a soak that composes both ends can only live where both ends are
already dependencies.

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_SOAK` | unset | Set to anything non-empty to select the 35-minute arm. The same variable also lengthens gate A's F2c and F17b. |
| `RELAY_SOAK_MINUTES` | unset | An explicit duration in minutes. Wins over `RELAY_SOAK`. |
| `RELAY_SOAK_SEED` | `11` | The storm's seed. `random` draws one and prints it. |
| `RELAY_HERD_N` | `5` | Panels in the herd, one of which is the never-faulted control. |

**Two durations, one code path.** The long arm is the same function with a
longer window — not a second run mode — so "the same assertions ran" is a
fact about the code rather than a claim in a comment. What differs is only
what each arm can *prove*: the short one that the machinery has not rotted,
the long one that the pipe endures. Both are declared in `soakDeviations`.

**The seed is fixed by default and that is deliberate** (11-CONTEXT ruling 4):
bit-rot protection has to be deterministic, so the lane replays one schedule
and a deliberate re-run names its own seed through `RELAY_SOAK_SEED`. A failed
run's seed is in its artifact by construction — `repro.log`'s first line is
written before anything composes.

### Forensics

Everything streams to `build/soak/` (gitignored) as it happens rather than
being assembled at the end, because the run that most needs a journal is the
one that died: `repro.log` (seed, both schedules, weights, quiet windows,
every merged entry), `config.json`, `metrics.jsonl` (one line per 5 s
checkpoint, **both clocks on every line**), `events.jsonl`, `verdict.txt`,
`divergences.jsonl`, and a numbered `trip-N.txt` per violation carrying the
last twenty checkpoints and the modes armed at the instant. CI uploads the
directory with `if: always()`, including on a green run — a green journal is
the baseline a later red run's slopes are read against.

### What it does not settle

- **Freshness monotonicity is enforced structurally, not behaviourally.**
  Freeze 9 sweeps `DateTime.now()` out of the soak trees; the soak itself
  cannot catch a wall-clock-aged verdict on a machine nobody is stepping.
- **F22d against VM snapshots stays open.** Both clocks are journalled at
  every checkpoint, which is evidence and not a verdict. Guest-monotonic
  divergence under a real snapshot is unmeasured and rides the on-site arm.
- **The on-site arm is a post-milestone follow-up** (11-CONTEXT ruling 6):
  the same storm against a deployed gateway on plant hardware, which is the
  only thing that can answer the process-isolation and VM-snapshot halves.
  The config seam exists now so the retrofit is not a rewrite.

## 9. What this design deliberately does not do

- No broker, no Envoy, no second wire protocol for native vs web.
- No delta *replay* after reconnect — snapshot resync only.
- No client-side write queue, no retry wrapper, no "reliable delivery" layer
  over the write path — unreliability is surfaced, not hidden.
- No protobuf/msgpack — measured JSON cost doesn't justify losing wire
  readability; CBOR is the designated escape hatch if that ever changes.
- No isolate sharding of the fan-out; no `MultiChannel`.
- No per-page server-side subscriptions — the wire stays UI-layout-agnostic.

## 10. Open decisions (carried from the notes, updated)

- [x] **#93: rewrite fresh** (decided 2026-08-13). The design diverges enough
      (no OPC UA server front-end, key-based, conflation) that harvesting
      costs more than rewriting ~600 lines with tests. #93 stays as
      reference reading.
- [x] **Web trust story: private CA, provisioned root** (decided
      2026-08-13). Root installed on plant machines via provisioning/GPO;
      no reverse proxy required; no internet dependency; no CT-logged
      internal hostnames. Native clients pin the same root as an asset.
- [ ] mTLS for eLinux panels: yes/no (token-only is the default posture).
- [ ] Timestamp provenance: SourceTimestamp vs ServerTimestamp vs gateway
      receive time — which drives history, staleness, operator display.
- [ ] Quality-code numeric values: adopt Ignition's numbers or define our
      own four-band mapping onto OPC UA StatusCodes.
- [ ] Heartbeat/death intervals: proposed 2–5 s tick, 3× death — confirm
      against real plant VLAN behavior during the on-site soak.
