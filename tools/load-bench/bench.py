#!/usr/bin/env python3
"""Load/soak bench supervisor: N OPC UA + N Modbus servers -> ONE gateway -> one measuring client.

    .venv/bin/python bench.py                 # 100 + 100, 120 s
    .venv/bin/python bench.py --ua 10 --mb 10 --duration 30

What it does, in order:
  1. spawns the fleet (ua_server.py hosts + mb_server.py hosts, plus a few
     SINGLE-server processes reserved for the kill/restart arm),
  2. reads every server's ephemeral port off its stdout (no hardcoded ports),
  3. generates gateway-config.json + key-mappings.json + page_editor_data.json
     into generated/,
  4. launches the real gateway (packages/tfc_relay_local relay_gateway),
  5. connects one WebSocket client, hellos, subscribes to EVERY key,
  6. measures: values/s, end-to-end latency (source ts -> arrival), per-key
     coverage, quality transitions, RSS/CPU of gateway and fleet,
  7. kill arm: SIGKILLs the single-server processes mid-run, watches the keys
     go visibly bad, restarts them on the SAME ports, watches recovery,
  8. prints an honest verdict. Silence is failure: a key that never arrives is
     NAMED, never skipped.

Teardown kills everything it started, always — a bench that leaks servers is
worse than no bench.
"""

from __future__ import annotations

import argparse
import asyncio
import bisect
import datetime as dt
import json
import math
import os
import re
import signal
import statistics
import subprocess
import sys
import time
from array import array

import psutil
import websockets

import ua_server as UA
import mb_server as MB

# Line-buffered progress even when stdout is a file: a three-minute run whose
# log is empty until exit looks exactly like a hung run.
import functools
print = functools.partial(print, flush=True)  # noqa: A001

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "generated")
PY = sys.executable

PROTOCOL = "2026-08-13"
Q_GOOD = 192
Q_BAD_NONFINITE = 524
BAD_FLOOR = 512          # badStale 516, badCommFault 522, error* 770+ all >= this

# Latency histogram buckets (ms). LOG-ish, not linear, deliberately: under
# load, end-to-end latency spans decades — a healthy pipe sits at 10-200 ms
# while an overloaded one produces a tail into seconds. Linear buckets either
# blur the healthy region or amputate the tail; the tail IS the finding, so
# it gets buckets of its own (500-1000, 1-2 s, 2-5 s, >5 s) instead of being
# collapsed into a single max.
HIST_EDGES_MS = [5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]


ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid(now_ms: int | None = None) -> str:
    """A real Crockford-base32 ULID (48-bit ms + 80-bit random). The gateway's
    outcome log DATES cmds by their ULID timestamp — `writeStatus` can only
    answer `not_received` honestly for a cmd it can date, so the bench must
    mint the format the plant mints, not an opaque string."""
    import secrets
    t = int(now_ms if now_ms is not None else time.time() * 1000)
    chars = [ULID_ALPHABET[(t >> (5 * (9 - i))) & 31] for i in range(10)]
    r = secrets.randbits(80)
    chars += [ULID_ALPHABET[(r >> (5 * (15 - i))) & 31] for i in range(16)]
    return "".join(chars)


def hist_bucket(ms: float) -> int:
    """Bucket index for a latency: 0 = <=5 ms ... len(HIST_EDGES_MS) = >5 s."""
    return bisect.bisect_left(HIST_EDGES_MS, ms)


def hist_labels() -> list[str]:
    labels = [f"<={HIST_EDGES_MS[0]}"]
    labels += [f"{a}-{b}" for a, b in zip(HIST_EDGES_MS, HIST_EDGES_MS[1:])]
    labels.append(f">{HIST_EDGES_MS[-1]}")
    return labels


def print_hist(counts: list[int], indent: str = "  "):
    total = sum(counts)
    if total == 0:
        print(indent + "(no samples)")
        return
    width = 40
    peak = max(counts)
    for label, c in zip(hist_labels(), counts):
        bar = "#" * (round(c / peak * width) if peak else 0)
        print(f"{indent}{label:>10} ms {c:>9} {c/total*100:6.2f}%  {bar}")


# --------------------------------------------------------------------------
# Fleet
# --------------------------------------------------------------------------

class ServerProc:
    def __init__(self, popen, kind, names):
        self.popen = popen
        self.kind = kind            # "ua" | "mb"
        self.names = names          # server names hosted by this process
        self.endpoints = {}         # name -> endpoint string
        self.ns = {}                # name -> namespace idx (ua only)
        self.seeds = {}             # name -> seed


async def read_until_ready(proc: ServerProc, expect: int, timeout: float = 300.0):
    """Parse SERVER/READY lines from a fleet process's stdout."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        if loop.time() > deadline:
            raise TimeoutError(f"{proc.kind} fleet proc: no READY after {timeout}s "
                               f"(got {len(proc.endpoints)}/{expect})")
        line = await loop.run_in_executor(None, proc.popen.stdout.readline)
        if not line:
            raise RuntimeError(f"{proc.kind} fleet proc exited before READY "
                               f"(rc={proc.popen.poll()})")
        line = line.strip()
        m = re.match(r"SERVER (\S+) (\S+)(?: ns=(\d+))? seed=(\d+)", line)
        if m:
            name, ep, ns, seed = m.group(1), m.group(2), m.group(3), m.group(4)
            proc.endpoints[name] = ep
            if ns:
                proc.ns[name] = int(ns)
            proc.seeds[name] = int(seed)
            continue
        if line.startswith("READY"):
            return


def spawn_fleet(args):
    """Returns (procs, ua_info, mb_info, kill_targets).
    ua_info: name -> {endpoint, ns, seed};  mb_info: name -> {endpoint, seed}
    kill_targets: list of (kind, name, spawn_args) for the kill/restart arm —
    each is a SINGLE-server process so a real SIGKILL means one real server."""
    procs = []

    os.makedirs(GEN, exist_ok=True)
    spawn_n = [0]

    def spawn(script, extra):
        cmd = [PY, os.path.join(HERE, script)] + extra
        # stderr to a file, not DEVNULL: a fleet proc that dies before READY
        # must leave its reason somewhere a human can read.
        err = open(os.path.join(GEN, f"fleet-{spawn_n[0]:02d}-{script}.err"), "w")
        spawn_n[0] += 1
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err,
                                text=True, bufsize=1, cwd=HERE)

    kill_targets = []
    k = min(args.kill, args.ua, args.mb)

    # UA: hosts of ~equal share + k singles at the top indices.
    bulk = args.ua - k
    hosts = min(args.ua_hosts, bulk) or 1
    per = [bulk // hosts + (1 if i < bulk % hosts else 0) for i in range(hosts)]
    off = 0
    for count in per:
        if count == 0:
            continue
        p = spawn("ua_server.py", ["--count", str(count), "--offset", str(off),
                                   "--seed", str(args.seed), "--hz", str(args.hz),
                                   "--fast-hz", str(args.fast_hz),
                                   "--replicate", str(args.replicate_ua)])
        procs.append(ServerProc(p, "ua", [f"ua{n:02d}" for n in range(off, off + count)]))
        off += count
    for n in range(bulk, args.ua):
        extra = ["--count", "1", "--offset", str(n), "--seed", str(args.seed),
                 "--hz", str(args.hz), "--fast-hz", str(args.fast_hz),
                 "--replicate", str(args.replicate_ua)]
        p = spawn("ua_server.py", extra)
        sp = ServerProc(p, "ua", [f"ua{n:02d}"])
        procs.append(sp)
        kill_targets.append(("ua", f"ua{n:02d}", extra, sp))

    # MB: one host + k singles.
    mb_bulk = args.mb - k
    if mb_bulk > 0:
        p = spawn("mb_server.py", ["--count", str(mb_bulk), "--offset", "0",
                                   "--seed", str(args.seed), "--hz", str(args.hz),
                                   "--fast-hz", str(args.fast_hz),
                                   "--word-order", args.word_order,
                                   "--replicate", str(args.replicate_mb)])
        procs.append(ServerProc(p, "mb", [f"mb{n:02d}" for n in range(mb_bulk)]))
    for n in range(mb_bulk, args.mb):
        extra = ["--count", "1", "--offset", str(n), "--seed", str(args.seed),
                 "--hz", str(args.hz), "--fast-hz", str(args.fast_hz),
                 "--word-order", args.word_order,
                 "--replicate", str(args.replicate_mb)]
        p = spawn("mb_server.py", extra)
        sp = ServerProc(p, "mb", [f"mb{n:02d}"])
        procs.append(sp)
        kill_targets.append(("mb", f"mb{n:02d}", extra, sp))

    return procs, kill_targets


# --------------------------------------------------------------------------
# Config generation
# --------------------------------------------------------------------------

def make_key_mappings(ua_info, mb_info, replicate_ua=1, replicate_mb=1,
                      write_targets=False):
    nodes = {}
    ua_nodes = UA.replicated_nodes(replicate_ua)
    mb_keys = MB.replicated_keys(replicate_mb)
    if write_targets:
        ua_nodes = ua_nodes + ["WriteSinkInt", "WriteSinkReal", "WriteSinkBool"]
        mb_keys = dict(mb_keys)
        mb_keys["WriteReg"] = ("write-target", "holdingRegister", MB.WRITE_REG,
                               "uint16", None, None, None)
    for name, info in ua_info.items():
        for node in ua_nodes:
            nodes[f"{name}.{node}"] = {
                "opcua_node": {
                    "namespace": info["ns"],
                    "identifier": f"{name}.{node}",
                    "array_index": None,
                    "server_alias": name,
                },
            }
    for name, info in mb_info.items():
        for key, (cat, rtype, addr, dtype, mask, shift, gen) in mb_keys.items():
            entry = {
                "modbus_node": {
                    "server_alias": name,
                    "register_type": rtype,
                    "address": addr,
                    "data_type": dtype,
                    "poll_group": "default",
                },
            }
            if mask is not None:
                entry["bit_mask"] = mask
                entry["bit_shift"] = shift
            nodes[f"{name}.{key}"] = entry
    return {"nodes": nodes}


def make_gateway_config(ua_info, mb_info, keymap_path):
    links = []
    for name, info in ua_info.items():
        links.append({"alias": name, "protocol": "opcua", "endpoint": info["endpoint"]})
    for name, info in mb_info.items():
        links.append({"alias": name, "protocol": "modbus", "endpoint": info["endpoint"]})
    return {
        # port 0: the gateway binds an ephemeral port and LOGS it; the bench
        # parses the log line. No literal anywhere.
        "server": {"port": 0, "address": "127.0.0.1"},
        "links": links,
        "key_mappings": keymap_path,
        "stale_after_ms": 5000,
    }


# Display cycle for the generated page: one value per server, the union of a
# whole column covering the matrix. (asset kind, key suffix, extras)
UA_PAGE_CYCLE = [
    ("NumberConfig", "Double", {}),
    ("LEDConfig", "Bool", {}),
    ("TextAssetConfig", "StringUtf8", {}),
    ("NumberConfig", "Int32", {"decimalPlaces": 0}),
    ("NumberConfig", "Fast", {"decimalPlaces": 3}),
    ("NumberConfig", "Counter", {"decimalPlaces": 0}),
    ("TextAssetConfig", "StringLatin1", {}),
    ("NumberConfig", "DoubleHazard", {}),
    ("NumberConfig", "Constant", {}),
    ("NumberConfig", "Dead", {}),
]
MB_PAGE_CYCLE = [
    ("NumberConfig", "Scaled", {"scale": 0.01, "units": "°C"}),
    ("LEDConfig", "Coil0", {}),
    ("NumberConfig", "HFloat64", {}),
    ("NumberConfig", "Counter16", {"decimalPlaces": 0}),
    ("LEDConfig", "PackedRunning", {}),
    ("NumberConfig", "PackedMode", {"decimalPlaces": 0}),
    ("NumberConfig", "HInt16", {"decimalPlaces": 0}),
    ("NumberConfig", "Fast", {"decimalPlaces": 0}),
    ("LEDConfig", "Disc0", {}),
    ("NumberConfig", "Illegal", {"decimalPlaces": 0}),
]


def make_page(ua_names, mb_names):
    """One page, one asset per server, matrix kinds cycling down the fleet."""
    assets = []
    all_servers = [("ua", n, UA_PAGE_CYCLE) for n in ua_names] + \
                  [("mb", n, MB_PAGE_CYCLE) for n in mb_names]
    cols = 10
    n_rows = max(1, math.ceil(len(all_servers) / cols))
    for i, (kind, name, cycle) in enumerate(all_servers):
        asset_kind, suffix, extras = cycle[i % len(cycle)]
        key = f"{name}.{suffix}"
        col, row = i % cols, i // cols
        base = {
            "asset_name": asset_kind,
            "coordinates": {"x": 0.02 + col * 0.098, "y": 0.03 + row * (0.9 / n_rows),
                            "angle": None},
            "size": {"width": 0.09, "height": min(0.04, 0.8 / n_rows)},
            "text": key,
            "textPos": "below",
        }
        if asset_kind == "NumberConfig":
            base.update({"key": key, "showDecimalPoint": True, "decimalPlaces": 2,
                         "textColor": None, "writable": False, **extras})
            if base["textColor"] is None:
                del base["textColor"]
        elif asset_kind == "LEDConfig":
            base.update({"key": key, "on_color": {"role": "green"},
                         "off_color": {"role": "grey"}, "led_type": "circle"})
        elif asset_kind == "TextAssetConfig":
            base.update({"textContent": f"${key}", "enableVariableSubstitution": True,
                         "decimalPlaces": 2})
        assets.append(base)
    return {
        "/bench": {
            "menu_item": {"label": "Load bench", "path": "/bench", "icon": "speed",
                          "children": []},
            "assets": assets,
        }
    }


# --------------------------------------------------------------------------
# Gateway
# --------------------------------------------------------------------------

def find_dart(explicit):
    if explicit:
        return explicit
    pinned = os.path.expanduser("~/flutter-sdks/3.44.9/bin/dart")
    return pinned if os.path.exists(pinned) else "dart"


def repo_root():
    d = HERE
    while d != "/":
        if os.path.isdir(os.path.join(d, "packages", "tfc_relay_local")):
            return d
        d = os.path.dirname(d)
    raise RuntimeError("cannot find repo root (packages/tfc_relay_local) above " + HERE)


async def start_gateway(dart, config_path, log_path):
    cwd = os.path.join(repo_root(), "packages", "tfc_relay_local")
    log = open(log_path, "w")
    env = dict(os.environ, CENTROIDX_RELAY_HARNESS="1")
    popen = subprocess.Popen(
        [dart, "run", "bin/relay_gateway.dart", "--config", config_path],
        cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1)

    loop = asyncio.get_running_loop()
    port = None
    deadline = loop.time() + 600   # first run may compile the native assets
    while port is None:
        if loop.time() > deadline:
            raise TimeoutError("gateway never logged its port; see " + log_path)
        line = await loop.run_in_executor(None, popen.stdout.readline)
        if not line:
            raise RuntimeError(f"gateway exited rc={popen.poll()}; see " + log_path)
        log.write(line)
        log.flush()
        m = re.search(r"serving on [\d.]+:(\d+)", line)
        if m:
            port = int(m.group(1))

    async def drain():
        while True:
            line = await loop.run_in_executor(None, popen.stdout.readline)
            if not line:
                return
            log.write(line)
            log.flush()

    task = asyncio.create_task(drain())
    return popen, port, task


# --------------------------------------------------------------------------
# Measuring client
# --------------------------------------------------------------------------

class KeyState:
    __slots__ = ("count", "last_v", "last_q", "last_t", "first_at", "last_at",
                 "qual_events", "bad_since", "prev_num", "worst_lat")

    def __init__(self):
        self.count = 0
        self.last_v = None
        self.last_q = Q_GOOD
        self.last_t = None
        self.first_at = None
        self.last_at = None
        self.qual_events = []      # (wall, q) transitions
        self.bad_since = None
        self.prev_num = None       # for monotonicity checks
        self.worst_lat = 0.0       # worst pushed-change latency (ms) — the tail, named


class Bench:
    def __init__(self, args, ua_info, mb_info):
        self.args = args
        self.ua_info = ua_info
        self.mb_info = mb_info
        self.keys = {}             # key -> KeyState
        self.handle_map = {}       # (sub, handle) -> key
        self.rejected = {}         # key -> reject kind
        self.updates = 0
        self.changes = 0
        self.seq = {}              # sub -> last seq
        self.seq_gaps = 0
        self.resyncs = 0
        self.status_events = []    # (wall, alias, state)
        # Latency samples as packed doubles (a 40k-key run collects millions;
        # Python float objects would cost ~5x the RAM) + online histogram
        # counts so the tail is never lost to a truncated sort.
        self.latency_ua = array("d")   # ms, only keys with their own source ts
        self.latency_mb = array("d")
        self.hist_ua = [0] * (len(HIST_EDGES_MS) + 1)
        self.hist_mb = [0] * (len(HIST_EDGES_MS) + 1)
        # Gateway tick observations: the tick notification fires every tick
        # (nominal period in hello capabilities.tickMs). serverTime deltas
        # measure the gateway's own tick cadence — if the per-tick work
        # (conflate + encode-once) outgrows the period, these stretch BEFORE
        # client latency does. arrival-serverTime is delivery delay (same
        # host, same clock).
        self.tick_gaps = array("d")     # ms between consecutive serverTime stamps
        self.tick_delays = array("d")   # ms, arrival wall - serverTime
        self._last_tick_server_time = None
        self.tick_nominal_ms = None
        self.pipe_series = {}      # PIPE.* key -> list[(wall, value)]
        # Kill-arm servers are known BEFORE the run: their keys are excluded
        # from the latency histograms and the conflation ratio, because a
        # reconnecting link legitimately re-emits initial reads with honest
        # OLD source stamps (measured: a 160 s "latency" that was no such
        # thing) and a dead server legitimately delivers nothing. The
        # kill/restart arm gets its own KPI (time-to-visible-bad) instead.
        self.lat_exclude = ()      # server-name prefixes, e.g. ("ua23.", "mb24.")
        self.changes_ua_clean = 0  # UA changes on never-killed servers only
        # Latency and conflation are measured AFTER a warmup: right after
        # subscribe, every link pushes its initial reads carrying honest OLD
        # source stamps (a boot-time constant is minutes old and honestly
        # so) — measured once as a fake 6.8 s "latency" on Dead/Constant at
        # t=0. That is not pipe lag, so it does not go in the histogram.
        # +inf until the measure loop starts: frames arriving during setup
        # (subscribe ramps, extra clients attaching) must never count — a
        # 19-panel attach wave once inflated "delivered" by 47%.
        self.warmup_until = float("inf")
        self.warmup_len = 0.0
        self.measure_start = None
        self.evicted_at = None     # wall time the GATEWAY closed us (4004 etc.)
        self.evict_reason = None
        # Write arm: (probe kind, outcome) -> count, RPC round trips, and a
        # cmd sample for the writeStatus reconciliation at the end.
        self.write_outcomes = {}
        self.write_rpc_ms = array("d")
        self.write_cmds = []       # (cmd, outcome) — capped sample
        self.write_readback_bad = 0
        self.write_readback_sample = None    # (key, wrote, readback) — first
        self.write_reason_samples = {}   # message -> first probe that got it
        self.violations = []       # determinism/honesty violations, named
        self.hazard_seen = {"nonfinite_null": 0, "finite": 0, "raw_nonfinite": 0}
        self._id = 0
        self._pending = {}
        self.frame_errors = 0

    def key_for(self, sub, handle):
        return self.handle_map.get((sub, int(handle)))

    # ---- protocol ----

    async def rpc(self, ws, method, params):
        self._id += 1
        rid = self._id
        fut = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        await ws.send(json.dumps({"jsonrpc": "2.0", "id": rid,
                                  "method": method, "params": params}))
        return await asyncio.wait_for(fut, 120)

    def on_frame(self, raw):
        msg = json.loads(raw)
        if "id" in msg and ("result" in msg or "error" in msg):
            fut = self._pending.pop(msg["id"], None)
            if fut and not fut.done():
                if "error" in msg:
                    fut.set_exception(RuntimeError(str(msg["error"])))
                else:
                    fut.set_result(msg["result"])
            return
        method = msg.get("method")
        params = msg.get("params", {})
        if method == "u":
            self.on_update(params)
        elif method == "tick":
            self.on_tick(params)
        elif method == "resync":
            self.resyncs += 1
        elif method == "status":
            self.status_events.append((time.time(), params.get("alias"),
                                       params.get("state")))
        # bye/others: nothing to do for the bench

    def on_tick(self, p):
        st = p.get("serverTime")
        if st is None:
            return
        now_ms = time.time() * 1000.0
        prev = self._last_tick_server_time
        self._last_tick_server_time = st
        if prev is not None and st > prev:
            self.tick_gaps.append(st - prev)
        self.tick_delays.append(now_ms - st)

    def on_update(self, p):
        now = time.time()
        self.updates += 1
        sub = p["sub"]
        seq = p["seq"]
        last = self.seq.get(sub)
        if last is not None and seq != last + 1:
            self.seq_gaps += 1
        self.seq[sub] = seq
        batch_t = p.get("t")
        for h, wire in (p.get("c") or {}).items():
            key = self.key_for(sub, h)
            if key is None:
                continue
            if key.startswith("PIPE."):
                self.pipe_series.setdefault(key, []).append((now, wire.get("v")))
                continue
            self.changes += 1
            if key[0] == "u" and now >= self.warmup_until \
                    and not key.startswith(self.lat_exclude) \
                    and ".WriteSink" not in key:
                self.changes_ua_clean += 1   # conflation-ratio numerator (UA, never-killed)
            v = wire.get("v")
            q = wire.get("q", Q_GOOD)
            t = wire.get("t", batch_t)
            self.record(key, v, q, t, now)
        for h, q in (p.get("q") or {}).items():
            key = self.key_for(sub, h)
            if key is not None and not key.startswith("PIPE."):
                self.record_quality(key, int(q), now)

    def record_quality(self, key, q, now):
        st = self.keys[key]
        if q != st.last_q:
            st.qual_events.append((now, q))
            if q >= BAD_FLOOR and st.bad_since is None:
                st.bad_since = now
            if q < BAD_FLOOR:
                st.bad_since = None
        st.last_q = q

    def record(self, key, v, q, t, now, snapshot=False):
        st = self.keys[key]
        st.count += 1
        st.last_v = v
        st.last_t = t
        if st.first_at is None:
            st.first_at = now
        st.last_at = now
        self.record_quality(key, q, now)
        # Snapshot values carry the source stamp of whenever they last changed
        # (a boot-time constant is minutes old and honestly so) — only PUSHED
        # changes measure the pipe's latency.
        if not snapshot and t is not None and q < BAD_FLOOR \
                and now >= self.warmup_until \
                and not key.startswith(self.lat_exclude) \
                and ".WriteSink" not in key:
            lat = now * 1000.0 - t
            if key.startswith("ua"):
                self.latency_ua.append(lat)
                self.hist_ua[hist_bucket(lat)] += 1
            else:
                self.latency_mb.append(lat)
                self.hist_mb[hist_bucket(lat)] += 1
            if lat > st.worst_lat:
                st.worst_lat = lat
        self.check_honesty(key, v, q)

    # ---- honesty: values must come from the generators' closed sets ----

    def check_honesty(self, key, v, q):
        name, _, node = key.partition(".")
        base_seed = (self.ua_info.get(name) or self.mb_info.get(name, {})).get("seed")
        if base_seed is None:
            return
        # Replica keys (Int16_c3) derive their seed the same way the servers do.
        suffix, r = UA.parse_replica(node)
        seed = UA.replica_seed(base_seed, r)
        st = self.keys[key]
        bad = None
        if name.startswith("ua"):
            if suffix == "Int16" and v is not None:
                allowed = {UA.gen_int16(seed, t) for t in range(6)}
                if v not in allowed:
                    bad = f"{key}: {v!r} not in {sorted(allowed)}"
            elif suffix == "UInt32" and v is not None:
                allowed = {UA.gen_uint32(seed, t) for t in range(4)}
                if v not in allowed:
                    bad = f"{key}: {v!r} not in allowed set"
            elif suffix == "StringUtf8" and v is not None:
                if not re.fullmatch(rf"Þorskur ævi ð {seed}:\d", str(v)):
                    bad = f"{key}: {v!r} does not match generator pattern"
            elif suffix == "Counter" and v is not None:
                if st.prev_num is not None and v <= st.prev_num:
                    bad = f"{key}: counter went {st.prev_num} -> {v}"
                st.prev_num = v
            elif suffix == "Fast" and v is not None:
                if st.prev_num is not None and v <= st.prev_num:
                    bad = f"{key}: fast ramp went {st.prev_num} -> {v}"
                st.prev_num = v
            elif suffix == "DoubleHazard":
                if v is None and q == Q_BAD_NONFINITE:
                    self.hazard_seen["nonfinite_null"] += 1
                elif isinstance(v, (int, float)):
                    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
                        self.hazard_seen["raw_nonfinite"] += 1
                        bad = f"{key}: RAW non-finite {v!r} crossed the wire"
                    else:
                        self.hazard_seen["finite"] += 1
        else:
            if suffix == "HInt16" and v is not None:
                allowed = {MB.gen_hint16(seed, t) for t in range(5)}
                if v not in allowed:
                    bad = f"{key}: {v!r} not in {sorted(allowed)}"
            elif suffix == "Scaled" and v is not None:
                if not (1200 <= v <= 1299):
                    bad = f"{key}: scaled raw {v!r} outside 1200..1299"
            elif suffix == "Counter16" and v is not None:
                if st.prev_num is not None and v != st.prev_num and \
                        (v - st.prev_num) % 65536 > 60000:
                    bad = f"{key}: counter16 went {st.prev_num} -> {v}"
                st.prev_num = v
        if bad and len(self.violations) < 200:
            self.violations.append(bad)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    i = min(len(sorted_vals) - 1, int(p / 100.0 * len(sorted_vals)))
    return sorted_vals[i]


# --------------------------------------------------------------------------
# Extra fan-out clients (the encode-once claim, measured)
# --------------------------------------------------------------------------

# An update frame starts '{"jsonrpc":"2.0","method":"u","params":{"sub":...,
# "seq":N,...' (frame_encoder.dart builds it by concatenation, field order
# fixed). A load client only needs (sub, seq) to ack honestly — full JSON
# parsing of every frame in N clients would make the BENCH the bottleneck and
# the fan-out measurement a lie.
LOAD_SEQ_RE = re.compile(r'"method":"u","params":\{"sub":("[^"]+"|\d+),"seq":(\d+)')
# The wire is BINARY frames (protocol rule: always Uint8List) — the same
# pattern compiled for bytes, so no client decodes megabytes just to ack.
LOAD_SEQ_RE_B = re.compile(LOAD_SEQ_RE.pattern.encode())


class LoadClient:
    """A deliberately cheap extra panel: hello, subscribe to everything, ack
    heartbeats, count what arrives. It exists so the GATEWAY's marginal cost
    per client can be measured — encode-once fan-out predicts the 20th panel
    is nearly free; per-client encoding predicts linear CPU growth."""

    def __init__(self, idx):
        self.idx = idx
        self.frames = 0
        self.bytes = 0
        self.ws = None
        self.seq = {}
        self._id = 0
        self._pending = {}
        self._task = None

    async def _rpc(self, method, params):
        self._id += 1
        fut = asyncio.get_running_loop().create_future()
        self._pending[self._id] = fut
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self._id,
                                       "method": method, "params": params}))
        return await asyncio.wait_for(fut, 120)

    def _on_frame(self, raw):
        self.frames += 1
        self.bytes += len(raw)
        binary = isinstance(raw, (bytes, bytearray))
        m = (LOAD_SEQ_RE_B if binary else LOAD_SEQ_RE).search(raw[:120])
        if m:
            sub = m.group(1)
            if binary:
                sub = sub.decode()
            self.seq[sub.strip('"')] = int(m.group(2))
            return
        # Everything else is rare (responses, tick, resync, status) or small —
        # full parse is affordable there. NOTE json_rpc_2 puts "result" BEFORE
        # "id", so no prefix sniff for '"id"' can work; that mistake ate a
        # hello response whole.
        msg = json.loads(raw)
        if "id" in msg and ("result" in msg or "error" in msg):
            fut = self._pending.pop(msg["id"], None)
            if fut and not fut.done():
                if "error" in msg:
                    fut.set_exception(RuntimeError(str(msg["error"])))
                else:
                    fut.set_result(msg.get("result"))

    async def start(self, gw_port, all_keys, hb_ms):
        self.ws = await websockets.connect(
            f"ws://127.0.0.1:{gw_port}", max_size=64 * 1024 * 1024,
            ping_interval=None)

        errors = [0]

        async def pump():
            # A silenced parse error here once ate a hello response whole —
            # the wire is binary frames and the first regex was str-only.
            # Errors are NAMED (first few) and counted, never swallowed.
            try:
                async for raw in self.ws:
                    try:
                        self._on_frame(raw)
                    except Exception as e:
                        errors[0] += 1
                        if errors[0] <= 3:
                            print(f"LOAD CLIENT {self.idx} frame error: {e!r}")
                    if self.frames % 50 == 0:
                        await asyncio.sleep(0)   # let the heartbeat run
            except Exception as e:
                print(f"LOAD CLIENT {self.idx} pump ended: {e!r}")

        self._task = asyncio.create_task(pump())
        await self._rpc("hello", {"protocol": PROTOCOL, "supported": [PROTOCOL],
                                  "client": {"name": f"load-client-{self.idx}",
                                             "version": "1"}})
        chunk = max(400, math.ceil(len(all_keys) / 32))  # session cap: 32 subs
        for i in range(0, len(all_keys), chunk):
            await self._rpc("subscribe", {"sub": f"lc{i//chunk}",
                                          "keys": all_keys[i:i + chunk]})

        async def heartbeat():
            while True:
                await asyncio.sleep(hb_ms / 3000.0)
                try:
                    await self._rpc("ping", {"ack": dict(self.seq)})
                except Exception:
                    return

        self._hb = asyncio.create_task(heartbeat())

    async def stop(self):
        for t in (getattr(self, "_hb", None), self._task):
            if t:
                t.cancel()
        try:
            await self.ws.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

async def amain(args):
    os.makedirs(GEN, exist_ok=True)
    started = []                 # every Popen we must reap
    gateway = None

    def cleanup():
        for p in started:
            if p.poll() is None:
                p.terminate()
        deadline = time.time() + 8
        for p in started:
            try:
                p.wait(timeout=max(0.1, deadline - time.time()))
            except subprocess.TimeoutExpired:
                p.kill()
        leaked = []
        me = psutil.Process()
        for ch in me.children(recursive=True):
            try:
                cmd = " ".join(ch.cmdline())
            except psutil.Error:
                continue
            if "ua_server.py" in cmd or "mb_server.py" in cmd or "relay_gateway" in cmd:
                leaked.append(ch.pid)
                ch.kill()
        if leaked:
            print(f"TEARDOWN: killed {len(leaked)} leaked pids {leaked}")
        else:
            print("TEARDOWN: clean, nothing leaked")

    try:
        # ---- 1. fleet ----
        t0 = time.time()
        n_ua_keys = len(UA.NODE_MATRIX) * args.replicate_ua
        n_mb_keys = len(MB.MB_KEYS) * args.replicate_mb
        print(f"SPAWN: {args.ua} OPC UA + {args.mb} Modbus servers "
              f"({args.kill} of each as separate kill-arm processes); "
              f"matrix x{args.replicate_ua} UA / x{args.replicate_mb} MB = "
              f"{n_ua_keys} keys/UA server, {n_mb_keys} keys/MB server, "
              f"{args.ua * n_ua_keys + args.mb * n_mb_keys} total")
        procs, kill_targets = spawn_fleet(args)
        started.extend(p.popen for p in procs)
        await asyncio.gather(*(read_until_ready(p, len(p.names)) for p in procs))
        ua_info, mb_info = {}, {}
        for p in procs:
            for name in p.names:
                info = {"endpoint": p.endpoints[name], "seed": p.seeds[name]}
                if p.kind == "ua":
                    info["ns"] = p.ns[name]
                    ua_info[name] = info
                else:
                    mb_info[name] = info
        fleet_rss = sum(psutil.Process(p.popen.pid).memory_info().rss for p in procs)
        print(f"SPAWN: fleet up in {time.time()-t0:.1f}s, "
              f"{len(ua_info)} ua + {len(mb_info)} mb, fleet RSS {fleet_rss/1e9:.2f} GB")

        # Drain fleet stdout FOREVER (plain daemon threads — the shared
        # executor would deadlock on 50 blocking readlines). Two reasons: a
        # full pipe eventually BLOCKS a server mid-print, and the LAG lines
        # ("sync tick took > budget") are the fleet's own confession that it
        # could not offer its nominal rate — invisible until now.
        import threading
        lag_counts = {"ua": 0, "mb": 0}

        def _drain_fleet(proc):
            for line in proc.popen.stdout:
                if line.startswith("LAG"):
                    lag_counts[proc.kind] += 1

        for p in procs:
            threading.Thread(target=_drain_fleet, args=(p,), daemon=True).start()

        # ---- 2. generated artifacts ----
        keymap_path = os.path.join(GEN, "key-mappings.json")
        config_path = os.path.join(GEN, "gateway-config.json")
        page_path = os.path.join(GEN, "page_editor_data.json")
        mappings = make_key_mappings(ua_info, mb_info,
                                     args.replicate_ua, args.replicate_mb,
                                     write_targets=args.write_rate > 0)
        with open(keymap_path, "w") as f:
            json.dump(mappings, f, indent=1)
        with open(config_path, "w") as f:
            json.dump(make_gateway_config(ua_info, mb_info, keymap_path), f, indent=1)
        with open(page_path, "w") as f:
            json.dump(make_page(sorted(ua_info), sorted(mb_info)), f, indent=1)
        all_keys = list(mappings["nodes"].keys())
        print(f"CONFIG: {len(all_keys)} keys, files in {GEN}")

        # ---- 3. gateway ----
        dart = find_dart(args.dart)
        gw_log = os.path.join(GEN, "gateway.log")
        print(f"GATEWAY: {dart} run relay_gateway (log: {gw_log})")
        t0 = time.time()
        gateway, gw_port, gw_drain = await start_gateway(dart, config_path, gw_log)
        started.append(gateway)
        print(f"GATEWAY: serving on 127.0.0.1:{gw_port} after {time.time()-t0:.1f}s")

        # ---- 4. subscribe ----
        bench = Bench(args, ua_info, mb_info)
        bench.fleet_lag = lag_counts
        # Kill-arm servers are decided at spawn: exclude their keys from the
        # latency/conflation KPIs up front (they get the time-to-visible-bad
        # KPI instead — see Bench.lat_exclude).
        bench.lat_exclude = tuple(f"{name}." for _, name, _, _ in kill_targets)
        for k in all_keys:
            bench.keys[k] = KeyState()
        ws = await websockets.connect(f"ws://127.0.0.1:{gw_port}",
                                      max_size=64 * 1024 * 1024, ping_interval=None)

        recv_task = None

        async def recv_loop():
            # A frame the bench cannot parse must be NAMED, never allowed to
            # silently kill the reader — a dead reader looks exactly like a
            # dead gateway, and that lie cost a shakeout run.
            try:
                async for raw in ws:
                    try:
                        bench.on_frame(raw)
                    except Exception as e:
                        bench.frame_errors += 1
                        if bench.frame_errors <= 5:
                            print(f"FRAME ERROR ({e!r}) on: {raw[:300]}")
            finally:
                code = getattr(ws, "close_code", None)
                reason = getattr(ws, "close_reason", "") or ""
                if code not in (None, 1000):
                    # The gateway closed US — backpressure eviction (4004),
                    # heartbeat reap (4003)... The design sheds a client
                    # rather than queue for it; the bench's job is to say
                    # WHEN that happened and window every KPI before it.
                    bench.evicted_at = time.time()
                    bench.evict_reason = f"{code} {reason}"
                    print(f"CLIENT EVICTED by the gateway: close {code} {reason!r}")
                print(f"RECV LOOP EXITED (frames Ok, errors={bench.frame_errors})")

        recv_task = asyncio.create_task(recv_loop())

        hello = await bench.rpc(ws, "hello", {
            "protocol": PROTOCOL, "supported": [PROTOCOL],
            "client": {"name": "load-bench", "version": "1"}})
        caps = hello.get("capabilities") or {}
        hb_ms = caps.get("heartbeatDeadlineMs") or 6000
        bench.tick_nominal_ms = caps.get("tickMs")
        print(f"HELLO: server={hello.get('server')} heartbeatDeadlineMs={hb_ms} "
              f"tickMs={bench.tick_nominal_ms}")

        # The gateway REAPS a session that sends nothing for heartbeatDeadlineMs
        # (close 4003) — protocol-level pongs do not count, only app frames.
        # Ping at a third of the deadline, carrying the per-sub ack map, which
        # also feeds the server's delivery-lag detector (the honest thing for a
        # load bench to do: a client that never acks can never be judged slow).
        async def heartbeat():
            while True:
                await asyncio.sleep(hb_ms / 3000.0)
                try:
                    await bench.rpc(ws, "ping", {"ack": dict(bench.seq)})
                except Exception as e:
                    print(f"HEARTBEAT failed: {e!r}")
                    return

        hb_task = asyncio.create_task(heartbeat())

        t0 = time.time()
        # The gateway holds AT MOST 32 subscriptions per session (measured:
        # -32602 at the 33rd) — and the bench needs one spare for the PIPE
        # diagnostics sub. 400 keys/sub until that would exceed 31 subs, then
        # exactly ceil(keys/31): at 40k keys that is ~1300-key subscribes,
        # which is itself informative — a real client wanting the whole plant
        # has no smaller option.
        chunk = max(400, math.ceil(len(all_keys) / 31))
        for i in range(0, len(all_keys), chunk):
            sub = f"bench{i//chunk}"
            keys = all_keys[i:i + chunk]
            res = await bench.rpc(ws, "subscribe", {"sub": sub, "keys": keys})
            now = time.time()
            for key, h in res["handles"].items():
                bench.handle_map[(sub, int(h))] = key
            for h, wire in (res.get("snapshot") or {}).items():
                key = bench.key_for(sub, h)
                if key:
                    bench.record(key, wire.get("v"), wire.get("q", Q_GOOD),
                                 wire.get("t"), now, snapshot=True)
            for key, rej in (res.get("rejected") or {}).items():
                bench.rejected[key] = rej.get("kind")
        subscribe_s = time.time() - t0
        print(f"SUBSCRIBE: {len(all_keys)} keys in {subscribe_s:.1f}s, "
              f"{len(bench.rejected)} rejected")
        if bench.rejected:
            sample = list(bench.rejected.items())[:10]
            print(f"  rejected sample: {sample}")

        # The gateway's own diagnostics as value keys: event_loop_lag_ms is
        # the tick engine's measured lateness — the leading indicator the
        # curve exists to catch. Best effort: if the harness rejects them,
        # say so and carry on measuring from the outside.
        pipe_keys = ["PIPE.event_loop_lag_ms", "PIPE.effective_hz",
                     "PIPE.pending_keys", "PIPE.egress_kbps"]
        try:
            res = await bench.rpc(ws, "subscribe", {"sub": "pipe", "keys": pipe_keys})
            for key, h in res["handles"].items():
                bench.handle_map[("pipe", int(h))] = key
            pj = res.get("rejected") or {}
            if pj:
                print(f"PIPE keys rejected: {list(pj)}")
        except Exception as e:
            print(f"PIPE keys unavailable ({e!r}) — tick metrics still measured "
                  f"from the wire")

        # ---- 4b. extra fan-out clients (encode-once claim) ----
        load_clients = []
        if args.clients > 1:
            t0 = time.time()
            for i in range(args.clients - 1):
                lc = LoadClient(i + 1)
                await lc.start(gw_port, all_keys, hb_ms)
                load_clients.append(lc)
            print(f"LOAD CLIENTS: {args.clients - 1} extra panels subscribed to "
                  f"all {len(all_keys)} keys in {time.time() - t0:.1f}s")

        # ---- 5. measure ----
        bench.warmup_len = min(10.0, args.duration * 0.2)
        bench.measure_start = time.time()
        bench.warmup_until = bench.measure_start + bench.warmup_len
        print(f"MEASURE: {args.duration:.0f}s, latency/conflation counted after "
              f"a {bench.warmup_len:.0f}s warmup (initial reads carry honest "
              f"old source stamps — they are not pipe lag)")
        gw_ps = psutil.Process(gateway.pid)
        fleet_ps = [psutil.Process(p.popen.pid) for p in procs]
        me_ps = psutil.Process()      # the measuring client itself: if IT
        for ps in fleet_ps + [gw_ps, me_ps]:   # saturates, latency numbers lie
            ps.cpu_percent(None)
        rss_series = []          # (t, gw_rss, fleet_rss)
        cpu_series = []
        kill_at = args.duration * 0.4
        restart_at = args.duration * 0.6
        killed = {}              # key prefix name -> kill wall time
        restarted_at = None
        killed_procs_rss0 = None
        start = time.time()
        last_changes = 0
        next_report = 10.0

        # ---- 5b. write arm ----
        # Writes ride the SAME session the read load rides — the plant's own
        # shape is a modest write rate against a large read load, and a write
        # path measured in a quiet system would measure the wrong thing.
        # Probe mix: mostly applied-path (WriteSink), every 10th a REJECTED
        # probe (a read-only matrix node), every 3rd Modbus, and during the
        # kill window writes aim at the DEAD servers — the honest way to
        # manufacture genuine UNKNOWN outcomes.
        # Targets are ONLY this bench's own spawned fleet (ua*/mb* keys);
        # nothing door-shaped exists in this key space, asserted per write.
        write_task = None
        if args.write_rate > 0:
            ua_live = sorted(n for n in ua_info
                             if not any(n == kn for _, kn, _, _ in kill_targets))
            mb_live = sorted(n for n in mb_info
                             if not any(n == kn for _, kn, _, _ in kill_targets))
            kill_ua_names = [n for _, n, _, _ in kill_targets if n.startswith("ua")]

            async def write_arm():
                i = 0
                interval = 1.0 / args.write_rate
                while True:
                    await asyncio.sleep(interval)
                    i += 1
                    in_kill_window = killed and restarted_at is None
                    if in_kill_window and kill_ua_names and i % 5 == 0:
                        key = f"{kill_ua_names[i % len(kill_ua_names)]}.WriteSinkInt"
                        val, kind = i, "dead-server"
                    elif i % 10 == 0:
                        # UInt16, an INT value: the int->Int32 typed path is
                        # the only one that reaches the server today, so it is
                        # the only probe that can show the REJECTED class
                        # (Bad_UserAccessDenied on a read-only node). UInt16
                        # has no monotonicity honesty check to trip on the
                        # readback republication.
                        key = f"{ua_live[i % len(ua_live)]}.UInt16"
                        val, kind = 1, "readonly-node"
                    elif i % 3 == 0:
                        key = f"{mb_live[i % len(mb_live)]}.WriteReg"
                        val, kind = i % 65536, "mb-register"
                    elif i % 4 == 0:
                        # The plant's most common write shape (start/stop/
                        # reset BOOLs) — currently dies CLIENT-side: the write
                        # adapter only types ints, and the binding's variant
                        # encoder throws on any untyped scalar
                        # (common.dart:122). Pinned so it is NOTICED the day
                        # it moves.
                        key = f"{ua_live[i % len(ua_live)]}.WriteSinkBool"
                        val, kind = True, "ua-sink-bool"
                    elif i % 2 == 0:
                        # A real-typed setpoint (REAL/LREAL) — same hole,
                        # double flavour.
                        key = f"{ua_live[i % len(ua_live)]}.WriteSinkReal"
                        val, kind = i + 0.5, "ua-sink-real"
                    else:
                        key = f"{ua_live[i % len(ua_live)]}.WriteSinkInt"
                        val, kind = i, "ua-sink-int"
                    assert key.startswith(("ua", "mb")) and "Door" not in key, \
                        f"write arm aimed outside the bench fleet: {key}"
                    cmd = new_ulid()
                    t0 = time.time()
                    try:
                        res = await bench.rpc(ws, "write",
                                              {"cmd": cmd, "key": key, "value": val})
                        outcome = res.get("outcome", "?") if isinstance(res, dict) else "?"
                        if outcome == "applied" and kind == "ua-sink-int" \
                                and res.get("readback") != val:
                            bench.write_readback_bad += 1
                            if bench.write_readback_sample is None:
                                bench.write_readback_sample = \
                                    (key, val, res.get("readback"))
                        if outcome in ("rejected", "unknown"):
                            # The reason IS the finding — an unknown without
                            # its kind is a number nobody can act on.
                            r = res.get("reason") or {}
                            outcome += f"({r.get('kind')}" + \
                                (f":{r.get('status')})" if r.get("status") else ")")
                            msg = r.get("message")
                            if msg and len(bench.write_reason_samples) < 5 \
                                    and msg not in bench.write_reason_samples:
                                bench.write_reason_samples[msg] = f"{kind} {key}"
                    except asyncio.CancelledError:
                        return
                    except Exception as e:
                        if "ConnectionClosed" in type(e).__name__:
                            return
                        outcome = "rpc_error"
                    bench.write_rpc_ms.append((time.time() - t0) * 1000)
                    k = (kind, outcome)
                    bench.write_outcomes[k] = bench.write_outcomes.get(k, 0) + 1
                    bench.write_cmds.append((cmd, outcome))
                    if len(bench.write_cmds) > 100:   # rolling: recent cmds
                        bench.write_cmds.pop(0)       # stay inside outcome TTL

            write_task = asyncio.create_task(write_arm())
            print(f"WRITE ARM: {args.write_rate:.0f} writes/s against the "
                  f"bench's OWN fleet only (applied/rejected/unknown mix)")

        def fleet_stats():
            # (total rss, summed cpu%, HOTTEST single process cpu%). The
            # hottest matters: asyncua is single-threaded per process, so one
            # host pegged at 100% means the FLEET is the cap even while the
            # summed figure looks comfortable.
            rss = cpu = hot = 0
            for ps in fleet_ps:
                try:
                    rss += ps.memory_info().rss
                    c = ps.cpu_percent(None)
                except psutil.Error:
                    continue
                cpu += c
                hot = max(hot, c)
            return rss, cpu, hot

        while (elapsed := time.time() - start) < args.duration:
            await asyncio.sleep(1.0)
            if elapsed >= kill_at and not killed and kill_targets:
                for kind, name, extra, sp in kill_targets:
                    sp.popen.kill()
                    killed[name] = time.time()
                print(f"KILL t={elapsed:.0f}s: SIGKILLed "
                      f"{[n for _, n, _, _ in kill_targets]}")
            if elapsed >= restart_at and killed and restarted_at is None:
                restarted_at = time.time()
                new_targets = []
                for kind, name, extra, sp in kill_targets:
                    script = "ua_server.py" if kind == "ua" else "mb_server.py"
                    # SAME port as before, so the gateway's config still points
                    # at it: the endpoint is re-used, which is exactly what a
                    # rebooting PLC does.
                    old_ep = (ua_info if kind == "ua" else mb_info)[name]["endpoint"]
                    port = old_ep.rsplit(":", 1)[1]
                    p = subprocess.Popen(
                        [PY, os.path.join(HERE, script)] + extra + ["--port", port],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, bufsize=1, cwd=HERE)
                    started.append(p)
                    nsp = ServerProc(p, kind, [name])
                    new_targets.append((kind, name, extra, nsp))
                    fleet_ps.append(psutil.Process(p.pid))
                await asyncio.gather(*(read_until_ready(sp, 1)
                                       for _, _, _, sp in new_targets))
                # A restarted server's tick restarts at 0, so its counters
                # legitimately jump backwards ONCE — reset the monotonicity
                # baselines rather than reporting the restart as a lie.
                for _, name, _, _ in new_targets:
                    for key, st in bench.keys.items():
                        if key.startswith(name + "."):
                            st.prev_num = None
                print(f"RESTART t={elapsed:.0f}s: relaunched "
                      f"{[n for _, n, _, _ in new_targets]} on their old ports")
            try:
                gw_rss = gw_ps.memory_info().rss
                gw_cpu = gw_ps.cpu_percent(None)
            except psutil.Error:
                raise RuntimeError("gateway process died mid-run; see " + gw_log)
            f_rss, f_cpu, f_hot = fleet_stats()
            cl_cpu = me_ps.cpu_percent(None)
            rss_series.append((elapsed, gw_rss, f_rss))
            cpu_series.append((elapsed, gw_cpu, f_cpu, cl_cpu, f_hot))
            if elapsed >= next_report:
                next_report += 10.0
                rate = (bench.changes - last_changes) / 10.0
                last_changes = bench.changes
                lat = sorted(bench.latency_ua[-20000:])
                tg = sorted(bench.tick_gaps[-600:])
                print(f"t={elapsed:5.0f}s changes/s={rate:7.0f} "
                      f"updates={bench.updates} gaps={bench.seq_gaps} "
                      f"ua-lat p50={pct(lat,50):6.0f}ms p95={pct(lat,95):6.0f}ms "
                      f"tick p95={pct(tg,95):5.0f}ms "
                      f"gwRSS={gw_rss/1e6:6.0f}MB gwCPU={gw_cpu:5.0f}% "
                      f"fleetRSS={f_rss/1e9:5.2f}GB fleetCPU={f_cpu:5.0f}% "
                      f"clientCPU={cl_cpu:4.0f}%")

        # ---- 5c. write-arm reconciliation (the reconnect path, exercised) ----
        if write_task is not None:
            write_task.cancel()
            bench.write_status = None
            if bench.write_cmds and bench.evicted_at is None:
                pairs = bench.write_cmds[-50:]
                try:
                    res = await bench.rpc(ws, "writeStatus",
                                          {"cmds": [c for c, _ in pairs]})
                    results = res.get("results") or []
                    agree = sum(1 for (c, o), r in zip(pairs, results)
                                if isinstance(r, dict)
                                and r.get("outcome") == o.split("(")[0])
                    kinds = {}
                    for r in results:
                        k = r.get("outcome", "?") if isinstance(r, dict) else "?"
                        kinds[k] = kinds.get(k, 0) + 1
                    bench.write_status = (agree, len(results), kinds)
                except Exception as e:
                    print(f"writeStatus reconciliation failed: {e!r}")

        # ---- 6. verdict ----
        print("\n" + "=" * 78)
        print("VERDICT")
        print("=" * 78)
        summary = report(bench, ua_info, mb_info, killed, restarted_at, rss_series,
                         cpu_series, args, load_clients)
        summary["subscribe_s"] = round(subscribe_s, 1)
        ok = verdict_ok(bench, all_keys)
        summary["ok"] = ok

        hb_task.cancel()
        for lc in load_clients:
            await lc.stop()
        await ws.close()
        recv_task.cancel()
        return (0 if ok else 1), summary
    finally:
        cleanup()


def pcts_of(vals):
    """{p50, p95, p99, max, n} of an unsorted sample array."""
    s = sorted(vals)
    return {"p50": pct(s, 50), "p95": pct(s, 95), "p99": pct(s, 99),
            "max": pct(s, 100), "n": len(s)}


def report(bench, ua_info, mb_info, killed, restarted_at, rss_series, cpu_series,
           args, load_clients=()):
    summary = {
        "label": f"{len(bench.keys)}k x{args.clients}c",
        "total_keys": len(bench.keys),
        "clients": args.clients,
        "r_ua": args.replicate_ua, "r_mb": args.replicate_mb,
        "ua_servers": args.ua, "mb_servers": args.mb,
        "duration": args.duration,
    }
    silent = [k for k, st in bench.keys.items() if st.count == 0
              and k not in bench.rejected]
    total = len(bench.keys)
    print(f"keys: {total} subscribed, {total - len(silent) - len(bench.rejected)} "
          f"delivered, {len(bench.rejected)} rejected, {len(silent)} SILENT")
    summary["silent"] = len(silent)
    summary["rejected"] = len(bench.rejected)
    if bench.rejected:
        kinds = {}
        for k, kind in bench.rejected.items():
            kinds.setdefault(kind, []).append(k)
        for kind, ks in kinds.items():
            print(f"  rejected[{kind}]: {len(ks)} e.g. {ks[:5]}")
    if silent:
        by_suffix = {}
        for k in silent:
            by_suffix.setdefault(k.split(".", 1)[1], []).append(k)
        print("SILENT KEYS (a green run that measured nothing is the failure mode):")
        for sfx, ks in sorted(by_suffix.items()):
            print(f"  .{sfx}: {len(ks)} servers, e.g. {ks[:4]}")

    print(f"\ntraffic: {bench.changes} value changes in {args.duration}s "
          f"({bench.changes/args.duration:.0f}/s), {bench.updates} update frames, "
          f"{bench.seq_gaps} seq gaps, {bench.resyncs} resyncs")
    summary["changes"] = bench.changes
    summary["changes_per_s"] = bench.changes / args.duration
    summary["seq_gaps"] = bench.seq_gaps
    summary["resyncs"] = bench.resyncs

    # ---- KPI: conflation ratio (offered vs deliverable vs delivered) ----
    # Computed over OPC UA keys on never-killed servers only: their offered
    # rate is a pure function of the config (deterministic generators), so
    # the ratio needs no instrumentation on the far side. Modbus is excluded
    # from this KPI on purpose — its delivery clock is the gateway's own 1 Hz
    # poll (which re-emits unchanged values, finding 5), so delivered/offered
    # there measures the poller, not conflation.
    #
    # Two denominators, because two different things get called "loss":
    #   offered      = source changes/s (Fast counts at fast_hz)
    #   deliverable  = after LEGITIMATE conflation: a 20 Hz key through a
    #                  100 ms tick delivers at most 1000/tickMs changes/s of
    #                  latest-value — by design, not a deficiency.
    # delivered/deliverable < ~0.95 means the pipe is FALLING BEHIND —
    # shedding whole ticks — which is the cliff this bench exists to find.
    killed_ua = sum(1 for p in bench.lat_exclude if p.startswith("ua"))
    clean_ua = args.ua - killed_ua
    tick_ms = bench.tick_nominal_ms or 100
    sync_rate = len(UA.SYNC_NODES) * args.hz
    fast_deliverable = min(args.fast_hz, 1000.0 / tick_ms)
    offered_ua = clean_ua * args.replicate_ua * (sync_rate + args.fast_hz)
    deliverable_ua = clean_ua * args.replicate_ua * (sync_rate + fast_deliverable)
    end_wall = bench.evicted_at or (bench.measure_start + args.duration)
    measured_s = max(1e-9, end_wall - (bench.measure_start + bench.warmup_len))
    delivered_ua = bench.changes_ua_clean / measured_s
    conf = delivered_ua / deliverable_ua if deliverable_ua else float("nan")
    if bench.evicted_at:
        evict_t = bench.evicted_at - bench.measure_start
        print(f"\nCLIENT EVICTED at t={evict_t:.0f}s ({bench.evict_reason}) — "
              f"the gateway sheds a client it cannot serve rather than queue "
              f"for it. Every KPI below covers ONLY the {measured_s:.0f}s "
              f"before the eviction.")
        summary["evicted_at_s"] = round(evict_t, 1)
        summary["evict_reason"] = bench.evict_reason
    print(f"\nconflation (OPC UA, {clean_ua} never-killed servers x "
          f"{args.replicate_ua} copies, {measured_s:.0f}s measured):")
    print(f"  offered at source:            {offered_ua:8.0f} changes/s")
    print(f"  deliverable after conflation: {deliverable_ua:8.0f} changes/s "
          f"(Fast {args.fast_hz:.0f} Hz -> {fast_deliverable:.0f}/s per key at "
          f"tick {tick_ms} ms — by design; model has ~10% headroom error: the "
          f"fleet's sleep-after-work loops undershoot their Hz)")
    print(f"  actually delivered:           {delivered_ua:8.0f} changes/s "
          f"= {conf*100:.1f}% of deliverable "
          f"{'(KEEPING UP)' if conf >= 0.80 else '<-- FALLING BEHIND: shedding, not conflating'}")
    summary["offered_ua"] = offered_ua
    summary["deliverable_ua"] = deliverable_ua
    summary["delivered_ua"] = delivered_ua
    summary["conflation_pct"] = conf * 100

    # ---- KPI: end-to-end latency histograms ----
    for label, lats, hist, tag in (
            ("opcua (device-stamped)", bench.latency_ua, bench.hist_ua, "ua"),
            ("modbus (gateway-stamped — Modbus HAS no device timestamp; "
             "ts_source is the read instant, and that is the honest claim)",
             bench.latency_mb, bench.hist_mb, "mb")):
        p = pcts_of(lats)
        print(f"\nlatency {label}: n={p['n']} p50={p['p50']:.0f}ms "
              f"p95={p['p95']:.0f}ms p99={p['p99']:.0f}ms max={p['max']:.0f}ms")
        print_hist(hist)
        summary[f"lat_{tag}"] = p
        summary[f"hist_{tag}"] = list(hist)
    worst = sorted(((st.worst_lat, k) for k, st in bench.keys.items()
                    if st.worst_lat > 0), reverse=True)[:8]
    if worst and worst[0][0] > HIST_EDGES_MS[-3]:   # tail worth naming: >500 ms
        print("  worst single-key latencies (the tail, named):")
        for lat, k in worst:
            print(f"    {lat:8.0f} ms  {k}")

    # ---- KPI: gateway tick (the leading indicator) ----
    # serverTime gap between consecutive tick notifications = the gateway's
    # own cadence. If per-tick work (conflate + encode-once over every
    # changed key) outgrows the period, this stretches BEFORE latency does.
    tg = pcts_of(bench.tick_gaps)
    td = pcts_of(bench.tick_delays)
    print(f"\ngateway tick: nominal {bench.tick_nominal_ms} ms; measured gap "
          f"p50={tg['p50']:.0f} p95={tg['p95']:.0f} p99={tg['p99']:.0f} "
          f"max={tg['max']:.0f} ms (n={tg['n']})")
    print(f"  tick delivery delay (serverTime -> client arrival, same host): "
          f"p50={td['p50']:.0f} p95={td['p95']:.0f} p99={td['p99']:.0f} "
          f"max={td['max']:.0f} ms")
    summary["tick_gap"] = tg
    summary["tick_delay"] = td
    summary["tick_nominal_ms"] = bench.tick_nominal_ms
    for pk, series in sorted(bench.pipe_series.items()):
        vals = [v for _, v in series if isinstance(v, (int, float))]
        if vals:
            print(f"  {pk}: last={vals[-1]} max={max(vals)} mean={statistics.mean(vals):.1f}")
            summary.setdefault("pipe", {})[pk] = {"max": max(vals), "last": vals[-1]}

    # ---- memory over time: first vs last quarter slope ----
    if len(rss_series) > 8:
        q = len(rss_series) // 4
        gw_first = statistics.mean(r[1] for r in rss_series[:q])
        gw_last = statistics.mean(r[1] for r in rss_series[-q:])
        span_h = (rss_series[-1][0] - rss_series[0][0]) / 3600.0
        print(f"\ngateway RSS: {rss_series[0][1]/1e6:.0f} -> {rss_series[-1][1]/1e6:.0f} MB "
              f"(quartile means {gw_first/1e6:.0f} -> {gw_last/1e6:.0f}; "
              f"slope ≈ {(gw_last-gw_first)/1e6/max(span_h,1e-9)*0.75:.0f} MB/h)")
        gw_cpu_mean = statistics.mean(c[1] for c in cpu_series)
        gw_cpu_max = max(c[1] for c in cpu_series)
        fleet_cpu_mean = statistics.mean(c[2] for c in cpu_series)
        client_cpu_mean = statistics.mean(c[3] for c in cpu_series)
        fleet_hot_mean = statistics.mean(c[4] for c in cpu_series)
        fleet_hot_max = max(c[4] for c in cpu_series)
        ncores = psutil.cpu_count() or 1
        print(f"fleet RSS end: {rss_series[-1][2]/1e9:.2f} GB; "
              f"gateway CPU mean {gw_cpu_mean:.0f}% max {gw_cpu_max:.0f}% "
              f"(of one core), fleet CPU mean {fleet_cpu_mean:.0f}% "
              f"(hottest single process mean {fleet_hot_mean:.0f}% max "
              f"{fleet_hot_max:.0f}% — asyncua is single-threaded, so ~100% "
              f"here means the FLEET is the cap), "
              f"bench client CPU mean {client_cpu_mean:.0f}% "
              f"({ncores} cores on this machine)")
        if fleet_hot_mean > 85:
            print("  MEASUREMENT SUSPECT: a fleet process ran near a full "
                  "core — the source may not have offered its nominal rate")
            summary["fleet_suspect"] = True
        lag = getattr(bench, "fleet_lag", None)
        if lag is not None:
            print(f"  fleet LAG ticks (a source loop missed its Hz budget): "
                  f"ua={lag['ua']} mb={lag['mb']}"
                  + ("  <-- the fleet under-offered; conflation % reads low "
                     "for the fleet's fault, not the pipe's"
                     if lag["ua"] + lag["mb"] > 10 else ""))
            summary["fleet_lag_ua"] = lag["ua"]
            summary["fleet_lag_mb"] = lag["mb"]
        summary["fleet_cpu_hottest_mean"] = fleet_hot_mean
        summary["fleet_cpu_hottest_max"] = fleet_hot_max
        # Honesty: if fleet + gateway + client want more cores than exist,
        # every number above was measured on a contended machine.
        want = (gw_cpu_mean + fleet_cpu_mean + client_cpu_mean) / 100.0
        if want > ncores * 0.75:
            print(f"  MEASUREMENT SUSPECT: processes wanted ~{want:.1f} cores of "
                  f"{ncores} — the fleet was competing with the gateway; treat "
                  f"latency at this size as an upper bound, not a measurement")
            summary["contended"] = True
        if client_cpu_mean > 80:
            print("  MEASUREMENT SUSPECT: the measuring client itself neared a "
                  "full core; arrival timestamps may lag the wire")
            summary["client_suspect"] = True
        summary["gw_cpu_mean"] = gw_cpu_mean
        summary["gw_cpu_max"] = gw_cpu_max
        summary["fleet_cpu_mean"] = fleet_cpu_mean
        summary["client_cpu_mean"] = client_cpu_mean
        summary["gw_rss_start_mb"] = rss_series[0][1] / 1e6
        summary["gw_rss_end_mb"] = rss_series[-1][1] / 1e6
        summary["gw_rss_slope_mb_h"] = (gw_last - gw_first) / 1e6 / max(span_h, 1e-9) * 0.75
        summary["fleet_rss_end_gb"] = rss_series[-1][2] / 1e9

    # ---- write arm ----
    if len(bench.write_rpc_ms):
        wp = pcts_of(bench.write_rpc_ms)
        total_w = sum(bench.write_outcomes.values())
        print(f"\nwrite arm: {total_w} writes at ~{args.write_rate:.0f}/s "
              f"alongside the read load; rpc round-trip p50={wp['p50']:.0f}ms "
              f"p95={wp['p95']:.0f}ms p99={wp['p99']:.0f}ms max={wp['max']:.0f}ms")
        print("  probe -> outcome (what the pipe SAID happened):")
        for (kind, outcome), n in sorted(bench.write_outcomes.items()):
            print(f"    {kind:<14} -> {outcome:<12} {n:6d}")
        if bench.write_readback_bad:
            print(f"  READBACK MISMATCHES: {bench.write_readback_bad} applied "
                  f"writes whose readback was not the written value")
            if bench.write_readback_sample:
                k, wrote, got = bench.write_readback_sample
                print(f"    e.g. {k}: wrote {wrote!r}, readback {str(got)[:120]!r}")
        for msg, src in bench.write_reason_samples.items():
            print(f"  reason sample [{src}]: {msg[:160]}")
        ws_rec = getattr(bench, "write_status", None)
        if ws_rec:
            agree, n, kinds = ws_rec
            print(f"  writeStatus reconciliation (last {n} cmds re-queried): "
                  f"{agree}/{n} answered the outcome recorded at write time; "
                  f"answers: {kinds}")
        summary["writes"] = {
            "total": total_w,
            "rpc": wp,
            "outcomes": {f"{k}->{o}": n
                         for (k, o), n in sorted(bench.write_outcomes.items())},
            "readback_bad": bench.write_readback_bad,
            "status_agree": ws_rec[0] if ws_rec else None,
        }

    if load_clients:
        rates = [lc.frames / args.duration for lc in load_clients]
        mbps = sum(lc.bytes for lc in load_clients) / args.duration / 1e6
        print(f"\nfan-out clients: {len(load_clients)} extra panels, "
              f"{statistics.mean(rates):.0f} frames/s each (min {min(rates):.0f}), "
              f"{mbps:.1f} MB/s total egress to them")
        summary["load_client_frames_s"] = statistics.mean(rates)
        summary["load_client_min_frames_s"] = min(rates)
        summary["load_egress_mb_s"] = mbps

    # hazard node
    hz = bench.hazard_seen
    print(f"\nDoubleHazard: {hz['nonfinite_null']} sanitized (null+q524), "
          f"{hz['finite']} finite, {hz['raw_nonfinite']} RAW non-finite "
          f"{'<-- SANITIZER FAILED' if hz['raw_nonfinite'] else '(sanitizer held)'}")

    # specimens, one server each
    for name in list(ua_info)[:1]:
        for sfx in ("Dead", "Constant", "StringLatin1", "StringUtf8",
                    "StructRange", "StructCustom", "ArrayDouble", "ArrayEmpty",
                    "EnumNode", "AbstractNode", "Int64", "GuidNode",
                    "ByteStringNode", "DateTimeNode", "LocalizedTextNode"):
            st = bench.keys.get(f"{name}.{sfx}")
            if st is None:
                continue
            v = st.last_v
            if sfx == "ArrayDouble" and isinstance(v, list):
                v = f"[{len(v)} doubles, last={v[-1] if v else None}]"
            print(f"  {name}.{sfx:18s} n={st.count:5d} q={st.last_q:4d} v={str(v)[:70]!r}")
    for name in list(mb_info)[:1]:
        for sfx in ("HInt16", "HInt32", "HFloat64", "PackedRunning", "PackedMode",
                    "Scaled", "DeadReg", "StringRaw0", "Illegal", "Coil0",
                    "CoilConst", "IUint16"):
            st = bench.keys.get(f"{name}.{sfx}")
            if st is None:
                continue
            print(f"  {name}.{sfx:18s} n={st.count:5d} q={st.last_q:4d} "
                  f"v={str(st.last_v)[:70]!r}")

    # Keys that only ever answered uncertainNotYetKnown (258): the gateway
    # accepted the subscription, the upstream value never became decodable,
    # and NOTHING was logged. Not silence on the wire — but a key that can
    # never resolve deserves an error quality, and today it does not get one.
    never = [k for k, st in bench.keys.items()
             if st.count <= 1 and st.last_q == 258]
    if never:
        by_sfx = {}
        for k in never:
            by_sfx.setdefault(k.split(".", 1)[1], []).append(k)
        print("\nNEVER-RESOLVED keys (stuck at uncertainNotYetKnown=258, no "
              "error quality, no gateway log line):")
        for sfx, ks in sorted(by_sfx.items()):
            print(f"  .{sfx}: {len(ks)} servers")

    # constant/dead freshness verdicts across the whole fleet
    const_bad = [f"ua{i:02d}" for i in range(len(ua_info))
                 if (st := bench.keys.get(f"ua{i:02d}.Constant"))
                 and any(q >= BAD_FLOOR for _, q in st.qual_events)]
    print(f"\nConstant nodes that decayed to bad quality: "
          f"{len(const_bad)} {'<-- FRESHNESS LIED' if const_bad else '(healthy-but-constant stayed good)'}"
          f"{' e.g. ' + str(const_bad[:5]) if const_bad else ''}")
    dead_qs = {}
    for name in ua_info:
        st = bench.keys.get(f"{name}.Dead")
        if st:
            dead_qs[st.last_q] = dead_qs.get(st.last_q, 0) + 1
    print(f"Dead-at-source final qualities: {dead_qs} "
          f"(the rig scar: initial read is 0.0 GOOD; does it stay that way?)")

    # ---- KPI: time-to-visible-bad (the product's core claim, measured) ----
    # SIGKILL wall time -> the first moment the CLIENT could tell each key had
    # gone bad. One number per killed key, reported as a distribution: "fresh
    # or visibly stale" is only true if the TAIL of this distribution is
    # short, not just its median.
    if killed:
        print("\nkill/restart arm:")
        all_det = []
        all_rec = []
        undetected = 0
        already_bad = 0

        def q_at(st, t):
            q = Q_GOOD
            for ts, qq in st.qual_events:
                if ts > t:
                    break
                q = qq
            return q

        for name, t_kill in killed.items():
            keys = [k for k in bench.keys if k.startswith(name + ".")]
            det = []
            for k in keys:
                st = bench.keys[k]
                if q_at(st, t_kill) >= BAD_FLOOR:
                    # Already visibly bad BEFORE the kill (Dead at 516, Guid
                    # at 771, Illegal...) — freshness cannot lie about a key
                    # it already marked bad, so it is not in this KPI.
                    already_bad += 1
                    continue
                ev = [t for t, q in st.qual_events if q >= BAD_FLOOR and t >= t_kill]
                if ev:
                    det.append(min(ev) - t_kill)
                else:
                    undetected += 1
            all_det.extend(det)
            if det:
                print(f"  {name}: killed; {len(det)}/{len(keys)} keys went bad, "
                      f"first {min(det):.1f}s median {statistics.median(det):.1f}s "
                      f"slowest {max(det):.1f}s after SIGKILL")
            else:
                print(f"  {name}: killed but NO key ever went bad "
                      f"<-- FRESHNESS LIED")
            if restarted_at:
                rec = []
                for k in keys:
                    st = bench.keys[k]
                    ev = [t for t, q in st.qual_events
                          if q < BAD_FLOOR and t >= restarted_at]
                    if ev:
                        rec.append(min(ev) - restarted_at)
                all_rec.extend(rec)
                if rec:
                    print(f"      recovered {len(rec)}/{len(keys)} keys, first "
                          f"{min(rec):.1f}s median {statistics.median(rec):.1f}s "
                          f"after restart")
                else:
                    print(f"      NOT RECOVERED after restart <-- check reconnect")
        if all_det:
            p = pcts_of([d * 1000 for d in all_det])
            print(f"  time-to-visible-bad across ALL {len(all_det)} killed keys "
                  f"that were good at kill time: "
                  f"p50={p['p50']:.0f}ms p95={p['p95']:.0f}ms p99={p['p99']:.0f}ms "
                  f"max={p['max']:.0f}ms "
                  f"({already_bad} already visibly bad before the kill)"
                  + (f"  ({undetected} good keys NEVER went visibly bad "
                     f"<-- FRESHNESS LIED)" if undetected else ""))
            summary["ttvb"] = p
            summary["ttvb_undetected"] = undetected
        if all_rec:
            summary["recovery"] = pcts_of([r * 1000 for r in all_rec])

    if bench.violations:
        print(f"\nDETERMINISM VIOLATIONS ({len(bench.violations)}, first 20):")
        for v in bench.violations[:20]:
            print("  " + v)
    else:
        print("\ndeterminism: every checked value came from its generator's set")

    if bench.status_events:
        print(f"\nstatus notifications: {len(bench.status_events)} "
              f"(link up/down announcements reached the client)")

    return summary


def verdict_ok(bench, all_keys):
    silent = [k for k, st in bench.keys.items()
              if st.count == 0 and k not in bench.rejected]
    # Illegal keys are EXPECTED to be bad — but bad is an arrival, not silence.
    hard_silent = [k for k in silent]
    ok = not hard_silent and bench.hazard_seen["raw_nonfinite"] == 0
    verdict = "PASS (no silent keys, sanitizer held)" if ok else "FAIL — see above"
    if bench.evicted_at:
        verdict += (" — but DEGRADED: the gateway evicted the client "
                    f"({bench.evict_reason}); KPIs cover the pre-eviction window")
    print("\nRESULT: " + verdict)
    return ok


def replicates_for(keys_per_server: int) -> tuple[int, int]:
    """--keys-per-server K -> whole matrix copies. UA matrix is 28 keys, MB is
    19, so a server carries round(K/28) resp. round(K/19) copies — the ACTUAL
    per-server key count is the nearest whole-matrix multiple, printed at
    spawn. Copies, never padding: the matrix is the bench's value."""
    return (max(1, round(keys_per_server / len(UA.NODE_MATRIX))),
            max(1, round(keys_per_server / len(MB.MB_KEYS))))


def print_comparison(results):
    """Every KPI side by side per configuration — one table a human reads
    against itself, not five separate sections."""
    if len(results) < 2:
        return
    labels = [f"{r['total_keys']}keys/{r['clients']}cl" for r in results]
    w = max(14, max(len(l) for l in labels) + 2)

    def row(name, fmt, get):
        cells = []
        for r in results:
            try:
                v = get(r)
                cells.append(("-" if v is None else fmt.format(v)).rjust(w))
            except (KeyError, TypeError):
                cells.append("-".rjust(w))
        print(f"{name:<34}" + "".join(cells))

    print("\n" + "=" * 78)
    print("CURVE COMPARISON (KEYS is the x-axis; server count and rates fixed)")
    print("=" * 78)
    print(f"{'':<34}" + "".join(l.rjust(w) for l in labels))
    row("total keys", "{:.0f}", lambda r: r["total_keys"])
    row("ws clients", "{:.0f}", lambda r: r["clients"])
    row("monitored items/UA server", "{:.0f}", lambda r: r["r_ua"] * len(UA.NODE_MATRIX))
    row("delivered changes/s", "{:.0f}", lambda r: r["changes_per_s"])
    row("conflation: delivered/deliverable", "{:.1f}%", lambda r: r["conflation_pct"])
    row("UA latency p50 ms", "{:.0f}", lambda r: r["lat_ua"]["p50"])
    row("UA latency p95 ms", "{:.0f}", lambda r: r["lat_ua"]["p95"])
    row("UA latency p99 ms", "{:.0f}", lambda r: r["lat_ua"]["p99"])
    row("UA latency max ms", "{:.0f}", lambda r: r["lat_ua"]["max"])
    row("tick gap p50 ms", "{:.0f}", lambda r: r["tick_gap"]["p50"])
    row("tick gap p95 ms", "{:.0f}", lambda r: r["tick_gap"]["p95"])
    row("tick gap max ms", "{:.0f}", lambda r: r["tick_gap"]["max"])
    row("event_loop_lag max ms", "{:.0f}",
        lambda r: r.get("pipe", {}).get("PIPE.event_loop_lag_ms", {}).get("max"))
    row("time-to-visible-bad p50 ms", "{:.0f}", lambda r: r["ttvb"]["p50"])
    row("time-to-visible-bad p95 ms", "{:.0f}", lambda r: r["ttvb"]["p95"])
    row("time-to-visible-bad max ms", "{:.0f}", lambda r: r["ttvb"]["max"])
    row("gateway CPU mean %", "{:.0f}", lambda r: r["gw_cpu_mean"])
    row("gateway CPU max %", "{:.0f}", lambda r: r["gw_cpu_max"])
    row("gateway RSS end MB", "{:.0f}", lambda r: r["gw_rss_end_mb"])
    row("fleet CPU mean %", "{:.0f}", lambda r: r["fleet_cpu_mean"])
    row("fleet hottest proc mean %", "{:.0f}", lambda r: r["fleet_cpu_hottest_mean"])
    row("fleet RSS end GB", "{:.2f}", lambda r: r["fleet_rss_end_gb"])
    row("bench client CPU mean %", "{:.0f}", lambda r: r["client_cpu_mean"])
    row("subscribe time s", "{:.1f}", lambda r: r["subscribe_s"])
    row("silent keys", "{:.0f}", lambda r: r["silent"])
    row("seq gaps", "{:.0f}", lambda r: r["seq_gaps"])
    row("evicted (backpressure)?", "{}",
        lambda r: f"at {r['evicted_at_s']:.0f}s" if "evicted_at_s" in r else "no")
    row("contended machine?", "{}", lambda r: "YES" if r.get("contended") else "no")

    print("\nUA latency histograms side by side (% of samples per bucket):")
    print(f"{'bucket ms':>12}" + "".join(l.rjust(w) for l in labels))
    for i, label in enumerate(hist_labels()):
        cells = []
        for r in results:
            h = r.get("hist_ua") or []
            tot = sum(h) or 1
            c = h[i] if i < len(h) else 0
            cells.append((f"{c/tot*100:6.2f}% ({c})").rjust(w))
        print(f"{label:>12}" + "".join(cells))
    print(f"{'n':>12}" + "".join(
        str(sum(r.get("hist_ua") or [0])).rjust(w) for r in results))


def parse_curve(spec: str):
    """'2500,10000x1,10000x5' -> [(2500,1),(10000,1),(10000,5)]."""
    out = []
    for part in spec.split(","):
        part = part.strip()
        if "x" in part:
            keys, clients = part.split("x")
            out.append((int(keys), int(clients)))
        else:
            out.append((int(part), 1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ua", type=int, default=100)
    ap.add_argument("--mb", type=int, default=100)
    ap.add_argument("--kill", type=int, default=3,
                    help="servers of EACH kind spawned as separate processes "
                         "and SIGKILLed mid-run")
    ap.add_argument("--ua-hosts", type=int, default=8,
                    help="processes hosting the bulk OPC UA servers")
    ap.add_argument("--hz", type=float, default=1.0)
    ap.add_argument("--fast-hz", type=float, default=20.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--duration", type=float, default=120.0)
    ap.add_argument("--word-order", choices=["abcd", "cdab"], default="abcd")
    ap.add_argument("--dart", default=None, help="dart executable "
                    "(default: ~/flutter-sdks/3.44.9/bin/dart, else PATH)")
    ap.add_argument("--keys-per-server", type=int, default=None,
                    help="approximate keys per server; realised as whole matrix "
                         "copies (see README). Default: one matrix copy "
                         f"({len(UA.NODE_MATRIX)} UA / {len(MB.MB_KEYS)} MB keys)")
    ap.add_argument("--write-rate", type=float, default=0.0,
                    help="writes/s driven alongside the read load, against the "
                         "bench's OWN fleet only (0 = off). Mix: applied "
                         "(WriteSink), rejected (read-only node), unknown "
                         "(writes at killed servers during the kill window)")
    ap.add_argument("--clients", type=int, default=1,
                    help="total concurrent WebSocket clients (1 measuring + "
                         "N-1 subscribe-everything panels; encode-once fan-out "
                         "probe)")
    ap.add_argument("--curve", default=None,
                    help="comma list of TOTAL key counts, each optionally "
                         "xCLIENTS (e.g. '2500,10000,40000,10000x5,10000x20'): "
                         "runs each config against a FRESH fleet+gateway, then "
                         "prints every KPI side by side")
    args = ap.parse_args()

    if args.curve:
        results = []
        rc = 0
        for total_keys, clients in parse_curve(args.curve):
            per_server = max(1, round(total_keys / (args.ua + args.mb)))
            args.replicate_ua, args.replicate_mb = replicates_for(per_server)
            args.clients = clients
            actual = args.ua * args.replicate_ua * len(UA.NODE_MATRIX) + \
                args.mb * args.replicate_mb * len(MB.MB_KEYS)
            print("\n" + "#" * 78)
            print(f"# CURVE POINT: ~{total_keys} keys requested -> {actual} actual "
                  f"({args.replicate_ua}x UA / {args.replicate_mb}x MB matrix "
                  f"copies), {clients} client(s)")
            print("#" * 78)
            point_rc, summary = asyncio.run(amain(args))
            rc = rc or point_rc
            results.append(summary)
        print_comparison(results)
        sys.exit(rc)

    if args.keys_per_server:
        args.replicate_ua, args.replicate_mb = replicates_for(args.keys_per_server)
    else:
        args.replicate_ua = args.replicate_mb = 1
    rc, _ = asyncio.run(amain(args))
    sys.exit(rc)


if __name__ == "__main__":
    main()
