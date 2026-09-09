# load-bench — 100 OPC UA + 100 Modbus servers against ONE gateway

The fan-in scale test the relay milestone never got: Phase 12-08 proved two
real in-process OPC UA servers feeding one pipe; this points the REAL gateway
(`packages/tfc_relay_local` `relay_gateway`) at 200 separate server processes
at once — subscription counts, per-server isolates, conflation under load,
memory over time, kill/restart, and the full type matrix, all in one run.

## One command

```sh
cd tools/load-bench
python3 -m venv .venv && .venv/bin/pip install asyncua "pymodbus==3.12.1" websockets psutil   # once
.venv/bin/python bench.py                      # 100 + 100, 180 s, kill arm on
```

Smaller while iterating: `.venv/bin/python bench.py --ua 5 --mb 5 --duration 30`.
Self-tests (the bench must not lie): `.venv/bin/python -m unittest test_bench -v`.

The gateway is run from `packages/tfc_relay_local` with the pinned SDK
(`~/flutter-sdks/3.44.9/bin/dart`, override with `--dart`). That package must
resolve (`dart pub get` + the native-assets cache — see the worktree setup
note in project memory if `dart test` there does not already pass).

## What a run does

1. **Spawns the fleet.** `ua_server.py` (asyncua) in 8 host processes plus
   `--kill` single-server processes; `mb_server.py` (pymodbus) the same shape.
   Every port is ephemeral and printed on stdout (`SERVER <name> <endpoint>`)
   — no literal anywhere, because a hardcoded port collision in a parallel
   worktree once read exactly like a real failure.
2. **Generates** `generated/gateway-config.json` (200 links, gateway on port 0
   — it logs what it bound and the bench parses that), `generated/
   key-mappings.json` (~4 500 keys), and `generated/page_editor_data.json`
   (one page, one value per server, asset kinds cycling through the matrix —
   import it to SEE all 200 alive on one screen).
3. **Launches the real gateway** and subscribes to every key over one
   WebSocket (JSON-RPC, hello → subscribe ×N, app heartbeat at a third of
   `heartbeatDeadlineMs` — the gateway reaps app-silent sessions with 4003).
4. **Measures**: changes/s, device-stamped OPC UA latency percentiles
   (Modbus latency is gateway-stamped — Modbus has no device timestamp, and
   saying otherwise would be a lie), RSS/CPU of gateway and fleet over time,
   seq gaps, resyncs.
5. **Kill arm** at 40 % of the run: SIGKILLs the single-server processes,
   measures how long each key takes to go visibly bad; at 60 % restarts them
   on their ORIGINAL ports (a rebooting PLC keeps its address) and measures
   recovery.
6. **Verdict**: every key is either delivered, rejected (named), or SILENT
   (named, and the run FAILS — a green run that measured nothing is the
   failure mode this repo has hit repeatedly).

## The type matrix

Every OPC UA server exposes (all values deterministic in `(seed, tick)`;
`Counter` IS the tick, so exact values are assertable):

Bool, Int16/Int32/Int64/UInt16/UInt32 (each cycling through **zero, ±1, and
its exact extremes**), Float/Double (extremes, −0.0, 5e-324),
**DoubleHazard** (NaN, ±Inf, 1e308 — the sanitizer probe), StringUtf8
(Icelandic þ/ð/æ), **StringLatin1 (raw Latin-1 bytes on the wire — not valid
UTF-8, by test)**, DateTime, GUID, ByteString, LocalizedText (is-IS), enum
(custom BenchMode), **abstract-DataType node** (ns=0 Number, the past
write-crash specimen), arrays (double×256, int32, string, bool, **empty**),
struct (built-in `Range` + custom `BenchStruct{Flag,Count,Value,Note}`),
**Dead** (in the address space, never published — the rig's
false-alarm specimen), **Constant** (healthy but never changes), **Fast**
(20 Hz, conflation probe).

Every Modbus server exposes: coils/discrete inputs, holding/input registers
as uint16/int16/int32/uint32/float32/float64 spans (word order `--word-order
abcd|cdab`), a packed status word read through `bit_mask`/`bit_shift`
(two bools + a mode nibble), a scaled raw (`1234` ↔ `12.34 °C`, scale lives
on the page asset), Counter16, Fast, a dead register, Latin-1 text packed
into registers (served, but **unmappable** — see gaps), and **Illegal**: a
key mapped at address 60000 that the server answers with a Modbus exception.

## Findings this bench has already produced (2026-09-09, measured)

1. **Native SEGV in the pinned open62541_dart client** (`0251aa09`): a server
   answering a `DataTypeDefinition` read with **status Good and an empty
   variant** crashes the client process (`client.dart:873`,
   `value!.type.ref.typeId`, si_addr=0xc). asyncua's standard address space
   does exactly that on all 497 base DataType nodes; TwinCAT answers
   `BadAttributeIdInvalid`, which is the only reason the plant never hit it.
   `ua_server.py` prunes those attributes as a workaround (printed loudly);
   the binding needs the null-check.
2. **Four types are undecodable by the binding**: Guid, ByteString,
   LocalizedText, and the built-in struct `Range` throw
   `Unsupported nodeId type` Dart-side. The gateway then leaves the key at
   quality 258 (uncertainNotYetKnown) **forever, with no log line** — an
   operator cannot tell it from a value that is merely late.
   Meanwhile the CUSTOM struct decodes fine (named members) via
   DataTypeDefinition learning — the exotic path works, the built-in doesn't.
3. **OPC UA constant nodes decay to badStale (516)** after `stale_after_ms`
   even though the subscription is alive — while Modbus constants stay good
   because polling re-stamps them every second. A healthy-but-constant tag
   shows stale on one protocol and fresh on the other.
4. **The Modbus illegal-address key also sits at 258 forever** — a server
   actively answering `IllegalDataAddress` surfaces as "not yet known",
   not as an error.
5. **`string_encoding: latin1` on an OPC UA link is accepted and has no
   effect** (documented gap, `gateway_config.dart:203`); the Latin-1 string
   arrives as U+FFFD mojibake. The bench keeps the specimen for the day the
   hook lands in the binding.
6. **The gateway's Modbus link config exposes no endianness, poll groups, or
   address base** (`buildUpstreamLink` builds `ModbusConfig(host, port,
   unitId)` only) — every gateway Modbus link is ABCD at 1 s. `--word-order
   cdab` exists to prove the difference the day the surface grows.
7. **No Modbus string data type** in `ModbusNodeConfig` — packed text
   registers cannot be mapped at all (`StringRaw0` shows the raw word).

## Files

| file | what |
|---|---|
| `ua_server.py` | asyncua fleet host; `--count/--seed/--hz/--fast-hz/--offset/--port` |
| `mb_server.py` | pymodbus fleet host; same shape + `--word-order` |
| `bench.py` | supervisor + measuring client + verdict |
| `test_bench.py` | the bench's own honesty tests |
| `generated/` | configs, page, gateway log, fleet stderr (gitignored) |

Teardown kills everything it started and then scans for leaked
`ua_server.py`/`mb_server.py`/`relay_gateway` children — a bench that leaks
100 servers across runs is worse than no bench.
