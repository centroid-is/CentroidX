<!-- GSD:project-start source:PROJECT.md -->
## Project

**Relay Pipe**

A single Dart backend gateway that is the only process talking to the plant's
PLCs (OPC UA: ST101/ST201/ST301 + Baader) and TimescaleDB, with every Flutter
client (Windows/macOS desktops, eLinux panels now; Flutter web later)
connected over exactly one WebSocket (`wss://`, JSON-RPC 2.0). Built from
scratch, test-driven, for the tfc-hmi codebase at SVN (fish factory).

**The organizing idea: StateMan is the abstraction.** `StateManApi` is one
interface (subscribe/read/write/browse + timeseries + history-view +
preferences + health). `LocalStateMan` implements it on the server over
DeviceClients + TimescaleDB; `RemoteStateMan` implements it on the client
over the pipe; widgets don't change. One shared contract test suite runs
against both implementations — including through a fault-injection proxy —
so fault tolerance is an enforced property, not a hope.

**Core Value:** Operators can always trust what the screen shows: values are fresh or
visibly stale, writes are applied / rejected / explicitly unknown — never
silently lost, never silently retried. (Fault tolerance first, speed second,
everything else third.)

### Constraints

- **Fault tolerance is the top priority**, speed second: half-open
  connections detected in seconds; staleness always visible per value;
  resync = snapshot, never delta replay; conflation, never queues.
- **Writes are safety-relevant**: three-state outcome (applied / rejected /
  unknown), client-minted idempotency ids, `writeStatus` re-query on
  reconnect, never auto-retried, readback is the only confirmation.
- **TDD throughout**: tests first; contract suite shared across Local and
  Remote implementations; TcpProxy-based fault harness; Home Assistant's
  websocket_api test cases as reference patterns.
- Flutter web is a hard future constraint: no browser ping frames, no
  private-CA interstitial for wss — server pings + app heartbeat; private CA
  root provisioned to plant machines (decided).
- JSON on the wire (slim values + integer handles); permessage-deflate off
  by default; encode-once fan-out; one isolate.
- No broker, no Envoy, no `query(sql)` RPC, no codegen in the protocol
  package.
- Wire hazards handled at the boundary: NaN/±Inf sanitized (Dart jsonEncode
  throws), per-server string encoding (Icelandic þ/ð/æ in Latin-1 S7
  strings), `1e999` decode poison defused.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended stack (all decisions made, high confidence)
| Layer | Choice | Version/state | Why |
|---|---|---|---|
| Server HTTP/WS | `shelf` + `shelf_web_socket` | 3.0.0, tools.dart.dev, stable | `allowedOrigins` (CSWSH), `pingInterval`, same-origin web bundle later |
| Client socket | `web_socket_channel` 3.x behind a thin adapter | 3.0.3, SLOW maintenance, 12 open bugs | 3.x wraps `package:web_socket`; adapter isolates known bugs |
| RPC envelope | `json_rpc_2` `Peer` | 4.1.0, ALIVE (Dart team) | Bidirectional peer; **no queue/no retry = the write-safety property** |
| Protocol types | Hand-written sealed classes, pure-Dart package | `packages/tfc_relay_protocol` (exists) | No codegen; exhaustive switch; workspace-safe |
| Serialization | JSON (`JsonUtf8Decoder` fused on bytes) | measured 3.5 ns/byte | 0.42% of a core worst case; CBOR is the escape hatch |
| TLS | `SecurityContext(withTrustedRoots: false)` + private CA root asset | — | Real pinning; never `badCertificateCallback` (sdk#39425) |
| Reconnect | Hand-rolled (~30 lines), exp backoff + full jitter, cap 30 s | — | Wrappers not production-grade; reset backoff only after resync |
| Testing | `package:test`, `StreamChannelController`, fresh TcpProxy | — | In-memory protocol tests; fault harness |
## What NOT to use
- **gRPC/grpc-web** — no bidi from browsers, Envoy required.
- **MQTT brokers** — QoS 1 auto-retries writes; single-publisher topology.
- **msgpack_dart** — zombie (2023). **freezed** in shared package — analyzer-cap blocker twice in 12 months. **Dart macros** — cancelled.
- **Isolate sharding for fan-out** — sockets are isolate-bound; encode-once on one isolate wins.
- **web_socket_client / flutter_websocket_plus** — latest release fixed an infinite backoff loop / "message queuing" violates write safety.
## Known bugs to work around (in the adapter)
- `closeCode` null after self-initiated close (dart-lang/http#1698, all platforms) → track own close codes; use 4000–4999 only (#1690).
- No `bufferedAmount`/`flush()` on dart:io WebSocket (flutter#103306) → bounded conflating send buffer + watchdog close.
- `sink.add(List<int>)` sends text frame on legacy web (#1648) → always `Uint8List`.
- `readyState` lies after OS sleep → freshness resets on any inbound frame only.
## Version constraints
- Package SDK floor: `^3.6.0` (digit separators). Repo Dart: 3.11.5.
- Dart 3.13 removes compiled-in fallback roots → backend container needs `ca-certificates`.
- Pin Flutter; soak before bumps (flutter#178916: stable shipped 120→40 fps Windows regression).
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
