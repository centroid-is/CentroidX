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

## Scaling KEY COUNT (`--keys-per-server`) and the curve

The first run was wide and shallow — 200 servers x ~23 keys. Real PLCs carry
far more keys each, and the parts of the pipe that can hit a cliff scale with
KEYS, not servers: conflation is per-key-per-tick, the JSON encode is
per-frame over all changed keys, and encode-once fan-out serialises
everything before any client gets anything.

`--keys-per-server K` scales by REPLICATING the type matrix — never by
padding with identical doubles, because the matrix is the reason the bench
has value at every size. `K` maps onto whole matrix copies:

    UA copies = round(K / 28)   (28 nodes per matrix copy)
    MB copies = round(K / 19)   (19 keys per copy)

so the realised per-server key count is the nearest whole-matrix multiple
(printed at spawn). Copy `r >= 1` suffixes every name `_c{r}` and derives its
seed as `seed + 7919*r` — every copy stays deterministic and distinct, and
the honesty checks derive the same seed on the client side. Modbus copies
live at register strides (+512 holding / +8 input / +16 bits per copy); each
copy's Illegal key stays beyond the datastore up to 117 copies, asserted.

`--curve "2500,10000,40000,10000x5,10000x20"` runs each config (TOTAL keys,
optionally xCLIENTS) against a FRESH fleet + gateway, then prints every KPI
side by side: latency histograms, conflation ratio, time-to-visible-bad,
tick durations, CPU/RSS of gateway AND fleet. Hold `--ua/--mb/--hz/--fast-hz`
fixed so keys (or clients) is the only variable.

`--clients N` keeps one measuring client and adds N-1 cheap
subscribe-everything panels (ack honestly, count frames) — the encode-once
fan-out probe: per-client encoding would show as roughly linear gateway CPU
growth per added panel; encode-once predicts the 20th panel is nearly free.

## The write arm (`--write-rate N`)

`--write-rate 20` drives 20 writes/s **alongside** the read load (the plant's
own shape: modest writes against heavy reads), against the bench's OWN fleet
only — every target key is asserted `ua*/mb*`, nothing door-shaped exists in
this key space. The probe mix exercises all three outcomes on purpose:

- **applied**: `WriteSinkInt` (Int32, writable, never ticked — readback is
  proof) and Modbus `WriteReg` (hr 30);
- **rejected**: an INT write to a read-only matrix node — the int path is
  the only one that reaches the server, so it is the only probe that can
  show `Bad_UserAccessDenied`;
- **unknown**: writes aimed at the KILLED servers during the kill window —
  genuine unknowns (`plc_timeout`), not simulated ones;
- **`WriteSinkReal` (Double) and `WriteSinkBool` (Boolean)**: pin a real
  hole — the gateway's OPC UA write adapter types ONLY `int` as Int32
  (`opcua_upstream_link.dart _toBindingValue`); every other scalar goes to
  the binding untyped and the variant encoder throws (`common.dart:122`
  "Unable to determine type"). So a REAL setpoint and a start/stop BOOL —
  the plant's two commonest write shapes — both answer
  `unknown(unparsed_upstream_error)` without ever reaching the server. The
  bench will notice the day it moves.

Each run reports outcome counts by probe, write RPC round-trip percentiles,
readback checks, a `writeStatus` reconciliation of recent cmds (the reconnect
path), and the same RSS-over-time series as always — compare a `--write-rate
0` run against a write run at the same size to see whether the write path's
maps (`_mintedCmds` / the outcome log, both capped at 4096 + TTL since
WR-08) actually hold their bound in practice.

## The KPIs a run reports (and why these)

- **Latency histogram** (log-ish buckets ≤5 … >5000 ms): latency under load
  spans decades; linear buckets blur the healthy region or amputate the
  tail, and the tail is the finding. Worst single keys are NAMED.
- **Conflation ratio** (OPC UA, never-killed servers only): offered at
  source vs deliverable-after-legitimate-conflation (a 20 Hz key through a
  100 ms tick delivers ≤10/s by design) vs actually delivered.
  delivered/deliverable < ~95 % = the pipe is FALLING BEHIND — shedding
  ticks, not conflating. Modbus is excluded: its delivery clock is the
  gateway's own 1 Hz poll, so the ratio there would measure the poller.
- **Gateway tick**: serverTime gaps between consecutive `tick` notifications
  = the gateway's own cadence; if per-tick work outgrows the period this
  stretches BEFORE latency does (the leading indicator). Plus the gateway's
  own `PIPE.event_loop_lag_ms` / `effective_hz` when subscribable.
- **Time-to-visible-bad**: SIGKILL -> the client can SEE each key is bad,
  as a distribution over every killed key (p50/p95/p99/max), not a single
  figure — "fresh or visibly stale" is the product's core claim and it is
  only true if the TAIL is short.
- **Honesty flags**: fleet CPU beside gateway CPU (if they compete for
  cores, the run says MEASUREMENT SUSPECT rather than quoting numbers
  straight), and the measuring client's own CPU (a saturated bench client
  lies about arrival times). Kill-arm servers are excluded from latency and
  conflation KPIs — a reconnecting link re-emits initial reads with honest
  OLD stamps (measured once as a fake 160 s "latency").

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
