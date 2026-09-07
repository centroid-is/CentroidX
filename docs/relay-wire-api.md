# The relay wire API

How a Flutter panel and `centroidx-backend` talk to each other, and **why each
choice was made**. Every rationale below is a decision somebody took with a
reason, not a convention that drifted in — where a decision has been revisited
or measured, that is recorded too.

**Audience:** anyone adding a method, debugging a panel from a packet capture,
or porting a client to another language or to Flutter web.

---

## 1. The shape in one paragraph

One `wss://` WebSocket per panel. **JSON-RPC 2.0** on it, via
`json_rpc_2: ^4.1.0` on both ends. Requests go both directions; live plant data
arrives as JSON-RPC *notifications*. Values are addressed by **integer handles**
minted at subscribe time, not by key strings. There is no gRPC, no protobuf, no
broker, and no codegen anywhere in the protocol package.

```
Flutter panel                                   centroidx-backend
     │                                                  │
     │──── wss:// ────────────────────────────────────▶ │
     │      hello {protocol, supported, client, token}  │
     │ ◀─── result {protocol, server, sessionId, epoch} │
     │──── subscribe {sub:"page-1", keys:[…]} ────────▶ │
     │ ◀─── result {sub, epoch, seq, generation,        │
     │              handles:{key→h}, snapshot:{h→val}}  │
     │ ◀─── u {sub, seq, g, changes:{h→val}}  ×N        │  (notification)
     │──── write {cmd, key, value} ───────────────────▶ │
     │ ◀─── result WriteApplied | WriteRejected | …     │
     │──── ping {ack:{sub→seq}} ─────────────────────▶  │
```

---

## 2. Why JSON-RPC 2.0 and not the alternatives

| Considered | Verdict | Why |
|---|---|---|
| **JSON-RPC 2.0 over one WebSocket** | **chosen** | Bidirectional by construction. `json_rpc_2`'s `Peer` is both client and server on one channel, which is what lets the backend push `u` frames on the socket the panel sends `write` on. Maintained by the Dart team. |
| gRPC / grpc-web | rejected | **No bidirectional streaming from browsers without Envoy.** Flutter web is a hard future constraint (CLAUDE.md); adding a proxy to the plant to make the browser case work is a deployment we are not willing to own. |
| MQTT / any broker | rejected | QoS 1 **auto-retries publishes**. A retried write is an actuation nobody asked for — see §6. The topology is also single-publisher, so a broker buys nothing. |
| A bespoke framing protocol | rejected | We would be re-implementing request/response correlation, error shapes and batching, and losing every existing tool that can read a capture. |

**The load-bearing property of `json_rpc_2`'s `Peer` is what it does *not* do:
it does not queue and it does not retry.** A request on a dead peer fails
immediately. That is the write-safety property in §6 enforced by the library
rather than by our discipline.

### Serialization: JSON, deliberately

Measured at **3.5 ns/byte** with `JsonUtf8Decoder` fused on bytes — 0.42% of one
core in the worst case we could construct. Against that, JSON gives us something
CBOR and protobuf cannot: **a frame is readable in a packet capture on a plant
floor at 3 a.m.** CBOR is written down as the escape hatch if the number ever
stops being true; nothing about the schema would have to change.

`permessage-deflate` is **off by default** — it interacts badly with encode-once
fan-out (§4), because a per-session compression context defeats sharing one
encoded body.

### No codegen in the protocol package

Types are hand-written sealed classes.

- **`freezed` was rejected**: it has been an analyzer-version blocker twice in
  twelve months, and a shared package that cannot be analyzed blocks every
  consumer at once.
- **Dart macros were rejected**: cancelled upstream.
- Sealed classes give exhaustive `switch` at every call site, which is how
  adding a `WriteResult` variant becomes a compile error at every handler
  instead of a silent fall-through.

---

## 3. The handshake

**`hello`** — must be the first request; every other method answers
`-32001 helloRequired` before it.

```jsonc
// params
{"protocol":"2026-08-13","supported":["2026-08-13"],
 "client":{"name":"centroid-hmi","version":"…"},
 "capabilities":{}, "token":"…"}       // token omitted entirely when unconfigured
// result
{"protocol":"2026-08-13","server":{…},"capabilities":{},
 "sessionId":"…","epoch":"…","resumed":false,"serverTime":1757200000000}
```

**Why the version is a date string, and why `supported` is a list.** The client
states what it speaks *and* what it would accept, so a mismatch is a `-32004`
with both sides' vocabularies visible in the error rather than a silent
misparse.

**Why identity is set exactly once.** `_identity` and `_credentialDigest` are
written together, in the accepted arm, and never again for the life of the
session. This was **write-once-per-turn until 2026-09-07**: `json_rpc_2`
dispatches a JSON-RPC *batch* through `Future.wait`, so two hellos in one frame
both passed the `_identity == null` guard before either resumed from the
credential await. A second, invalid token could tear down a correctly
authenticated session with a 4001. Fixed by re-checking after the await; the
loser is refused with `-32002 alreadyHelloed`, which is what a *sequential*
second hello already got — a client should not have to model the timing it lost
by. See `concurrent_hello_test.dart`.

**The token never lives in a type that could log it.** `Identity` has two
fields — station and role — and neither is the credential. A type that cannot
hold a secret cannot leak one, so an identity is safe to put in a log line, a
close reason and an error message, which is exactly what the revocation sweep
does.

---

## 4. Subscriptions, handles and the update lane

**`subscribe`** takes a client-chosen name and a key list; the answer mints the
handles.

```jsonc
// params
{"sub":"page-1","keys":["CVS01.CN01.FD01.p_stat_State", …],"maxRateHz":null}
// result
{"sub":"page-1","epoch":"…","seq":0,"generation":3,
 "handles":{"CVS01.CN01.FD01.p_stat_State":5, …},
 "snapshot":{"5":{"v":2}, …},
 "rejected":{"BAD.KEY":{"kind":"unknown","message":"…"}}}
```

### Why integer handles instead of keys on the wire

Plant keys are long (`CVS01.CN01.FD01.p_stat_State`) and a busy page carries
~1500 of them changing at 10–20 Hz. Sending the key with every sample would
dominate the frame. Handles are minted per subscription, so the string is paid
for **once**.

### Why values are slim

```dart
'v': v,
if (q != Quality.good) 'q': q.code,   // omitted when good — the common case
if (t != null) 't': t,                // omitted when the batch timestamp applies
```

Good quality is the overwhelmingly common case, so it costs zero bytes.

### Why `u` is one character

```dart
static const update   = 'u';  // hot path — one character on purpose
static const holdTick = 'h';
```

These two are the only frames on a per-tick cadence. Every other method has a
readable name, because legibility in a capture is worth more than bytes
everywhere else.

### Encode-once fan-out

One `u` body is encoded **once per tick per subscription** and shared by every
session watching that page; only the envelope differs per client. Measured cost
of encoding a 1500-key frame: **389 µs**. This is why anything that would give a
session its own view of the payload — per-session filtering, per-session
compression — is refused at design time rather than optimised later.

### `seq` and `generation`, and why the epoch is not enough

`seq` increments by one per message per subscription; **a gap means resync**.

`generation` identifies *which establishment* of that subscription name a frame
belongs to. The session `epoch` cannot do this job, and neither can a
client-side connection counter: both change per *session*, but the frame that
poisons a cache is the one **still in flight from before a resync on the same
socket**. A server-announced resync or a gap-triggered resubscribe rebuilds one
subscription while the session epoch stays put. Three layers cooperate —
generation match before the store, `BatchReplay` never rewinding `lastSeq`, and
`dropSub` on the server buffer.

### Conflation, never queues

A slow consumer receives the **latest value per key**, never a replayed backlog.
Resync is a **snapshot**, never delta replay. This is the difference between a
panel that reconnects showing what is true now and one that spends thirty
seconds animating history it cannot act on.

---

## 5. Containment: one bad entry costs one tag

Every entry in a snapshot decodes in **its own `try`**, and the `rejected` lane
has a separate one. A malformed entry is dropped, a complaint is filed naming
the handle, key and error *type*, and the rest of the snapshot lands.

**Why this is not merely defensive.** Until 2026-09-07 it was not true for
*shape-level* malformation — a non-map entry, a `rejected` entry whose `kind`
was not a string, or a finite-but-huge `t` that `DateTime` cannot represent.
Any of those threw out of the whole decode, and via `hello` (which every
reconnect performs) that meant: rethrow → "the link died before the snapshot
landed" → backoff → redial → **the same poisoned snapshot**. Measured before
the fix: **49 dials in 5 seconds.** One malformed entry cost the connection,
permanently. See `poisoned_snapshot_test.dart`.

Complaints carry the error's **type**, never its message: an exception raised
while decoding gateway-supplied data can carry gateway strings of unbounded
length, and that text reaches a panel standing where anybody can read it.

**Forward compatibility is a deliberate property.** Unknown fields, unknown
quality codes, unknown value tags, unknown write outcomes and unknown methods
all **degrade rather than throw**. A newer backend must never be able to make a
panel go dark.

---

## 6. Writes: three states, and no retry, ever

```
write {cmd, key, value, expect?, hold?}  →  WriteApplied
                                          | WriteRejected
                                          | WriteUnknown
                                          | WriteNotReceived
```

**Why three outcomes and not two.** `applied` and `rejected` are facts.
`unknown` is also a fact — the command reached the wire and the answer did not
come back — and collapsing it into "failed" tells an operator something untrue
about a machine. `WriteNotReceived` is the *only* outcome that means "safe to
re-send", and it is returned only on three pieces of positive evidence.

**Why the client mints `cmd`.** A ULID minted client-side is the idempotency
key. On reconnect the panel re-queries `writeStatus` for every unresolved
command; the gateway answers from a log keyed by that id. Without a client-minted
id there is no question the client could ask.

**Nothing auto-retries. Anywhere.** Not the RPC layer (`json_rpc_2` fails a
request on a dead peer rather than queueing it), not the send buffer (it drops
rather than queues when the link is down), not the client (`isSafeToResend`
defaults to `false` on the sealed base). **Readback is the only confirmation.**

**Non-finite values are refused, not sanitized.** `NaN` and `±Infinity` encode
to `null`, and a write of `null` actuates a device with something nobody chose.
Until 2026-09-07 the client sanitized and sent it — and a test pinned that as
correct. It is now refused with an `ArgumentError` **before an id is minted,
before anything is sent, and before the plant is touched**, at all eight
implementations. The contract sentence is now *"a non-finite write is refused
before the plant, never nulled and applied"*, and it asserts that
`mintedCmds` did not grow — because an id that exists is an action `writeStatus`
can no longer honestly answer `not_received` about.

**Hold-to-run** (`hold: true` on `write`, then `h` ticks) is a deadman. One key
is one counter; a second engage on a live hold is refused. That refusal is
re-checked **after** the upstream await as well as before it — two engages could
otherwise both cross the synchronous guard and strand a handle no tick could
feed and no release could reach.

---

## 7. Liveness, and why the client heartbeats

Browsers **cannot send WebSocket ping frames**. So:

- the **server** sets `pingInterval` (protocol-level pings, `dart:io` side);
- the **client** sends an application-level `ping` **request** on a timer.

**Freshness resets on inbound frames only** — never on `readyState`, which lies
after OS sleep, and never on the wall clock. `serverNowMs` is an anchor plus a
`Stopwatch`.

**A session is kept alive only by what it *sends*.** Nothing the gateway pushes
moves `_lastSeen`. This is deliberate, and it has bitten twice: a test harness
that never beat was silently reaped at ~6 s while an arm went on asserting a
property about two panels that had been disconnected for four seconds; and it is
half of why a stuck reader is hard to detect (§8).

---

## 8. Backpressure — the honest version

`ConflatingSendBuffer.poll` runs **before** the drain, and the buffer is empty at
the start of every tick by construction. So what it measures is **how much this
server produced for one client during one tick** — not how far behind that
client is.

That was measured on 2026-09-07 and both halves are worse than they read:

- **A genuinely stuck reader survives 20–40 s** at the shipping 20 s
  `pingInterval` (worst case 40 s — the cycle is anchored at the *connection*,
  so survival is uniform over (1×, 2×]). During it, the panel produces **41
  pending entries a tick** against a soft ceiling of **1024**. The defence is
  watching a number two orders of magnitude from tripping.
- **A healthy 1100-key page is evicted after 10.1 s** with
  `client unable to keep up: > 1024 pending for 10000ms` — identical at 1300 and
  1800 handles, because the verdict is a *timer on being above a line*, not a
  measure of severity. A 1500-key page is above that line on every tick it
  changes.

`tick_engine.dart` asked for a deliberate choice between a periodic
`ws.sink.done` check and moving to `package:web_socket`. **Both were refuted by
measurement**: `sink.done` completes at exactly 2.00 × `pingInterval` — it *is*
the pong timeout — and `addStream`, the only completion-shaped signal `dart:io`
offers, returned in 0 ms on all 152 frames while 9.5 MiB piled into a socket
nobody was reading.

**The chosen answer is an application-level delivery ack**: `ping` grows an
optional `ack` map of `sub → highest seq applied`, and the server evicts on a
sustained **ack gap** rather than a production peak. It is the only option that
fixes both halves, and the only one identical on web. Healthy links plateau at
≤ 24 frames with a flat slope; unhealthy links grow at 15–20 frames/s without
bound. Full evidence and the implementation spec:
`.planning/phases/16-transport-hardening/16-02-DECISION.md`.

**A `ping` with no `ack` stays valid for ever.** The gateway and the panels do
not always ship together.

---

## 9. Errors and close codes

| RPC error | Code | Means |
|---|---|---|
| `helloRequired` | −32001 | a method arrived before `hello` |
| `alreadyHelloed` | −32002 | second hello, sequential or racing |
| `unauthorized` | −32003 | credential refused — **terminal**, the client stops dialling |
| `versionMismatch` | −32004 | **terminal** |
| `forbidden` | −32005 | policy refused this key for this identity |
| `typeMismatch` | −32010 | |
| `handlerFailed` | −32011 | the handler threw |
| `unknownSubscription` | −32020 | |

| Close code | Meaning |
|---|---|
| 4001 | `authExpired` — credential revoked under a live session |
| 4002 | `serverDraining` — orderly shutdown |
| 4003 | `heartbeatTimeout` |
| 4004 | `backpressureOverrun` |
| 4005 | `protocolMismatch` |

**Why 4000–4999 only.** `dart-lang/http#1690` — other ranges are not reliably
delivered. And `closeCode` is **null after a self-initiated close on every
platform** (`#1698`), so the client tracks its own close codes rather than
reading them back.

**Why "hidden" is spelled as "absent".** A key the policy will not show is
filtered out of `keys` — the one getter that `read`, `readFresh`, `readMany`,
`subscribe` and `write` all already gate on. So a hidden tag takes the
*nonexistent-tag* path on all five without any of them being edited, and a
client cannot probe for the existence of keys it may not see. **Existence is
checked before permission**, and the two refusals never leak into each other.

---

## 10. Authorisation

**Enforced server-side. This is a hard requirement**, and the client is not a
security boundary: once the transport is a WebSocket, anything a panel declines
to send another client can send anyway. Checks in the app are a usability
affordance.

The gate is a **decorator, not a call-site check**: `PolicyStateMan` wraps the
shared source once per session, between the handlers and the plant. Handlers
never consult the policy themselves — which is the property that keeps a method
added later from being able to forget it. A 2026-09-06 sweep walked all 43
registered methods and found no bypass.

> **Planned change (Phase 17).** `tfc_relay_server` currently carries its own
> two-value `Role { view, operate }` and an `Identity { stationId, role }`.
> `tfc_access` is the master access-control system and already models a panel
> via `AuthenticatedUser.stationAccount`. Both relay types are to be **deleted**
> and `KeyPolicy` becomes an adapter over `AccessPolicy`; the token file,
> digests and constant-time compare stay, because a wall-mounted panel proving
> itself with a mounted token is a genuinely different credential from a typed
> password. The rule: the transport may answer *"which identity is this"*, never
> *"and therefore may do X"*.

---

## 11. Porting notes

**Anything speaking this protocol must:**

1. Send `hello` first, and exactly once.
2. Treat unknown fields, methods, quality codes and outcomes as **degrade**, not
   error.
3. Never auto-retry a `write`. Re-query `writeStatus` instead.
4. Track its own close codes; do not read `closeCode` after closing.
5. Reset freshness on **inbound frames only**.
6. Refuse non-finite write values before sending.
7. Contain a bad snapshot entry to that entry.

**Web-specific:** always send `Uint8List`, never `List<int>` —
`sink.add(List<int>)` sends a *text* frame on legacy web (`#1648`). Do not rely
on `bufferedAmount` or `flush()`; neither exists on `dart:io`
(`flutter#103306`), so nothing in this protocol depends on them. Beware 32-bit
bitwise coercion under dart2js: `<<` and `&` discard the top bits of a 48-bit
millisecond field, which is why ULID encoding uses `%` and `~/` arithmetic. All
wire integers (epoch ms, seq, handles) sit well below 2^53.

---

## 12. Where the source of truth lives

| | |
|---|---|
| Method names, close codes | `packages/tfc_relay_protocol/lib/src/methods.dart` |
| Params/result DTOs | `.../lib/src/messages.dart` |
| Slim value encoding | `.../lib/src/wire_value.dart` |
| Write outcomes | `.../lib/src/write_result.dart` |
| Conflation | `.../lib/src/send_buffer.dart` |
| RPC error codes | `packages/tfc_relay_server/lib/src/error_codes.dart` |
| The interface both ends implement | `.../lib/src/state_man_api.dart` |
| Cross-implementation contract suite | `packages/tfc_stateman_contract/` |

The contract suite is the real specification: it runs against **both** the
in-process implementation and the WebSocket one, so a behaviour that differs
between them is a test failure rather than a surprise on a plant.
