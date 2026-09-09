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

import psutil
import websockets

import ua_server as UA
import mb_server as MB

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "generated")
PY = sys.executable

PROTOCOL = "2026-08-13"
Q_GOOD = 192
Q_BAD_NONFINITE = 524
BAD_FLOOR = 512          # badStale 516, badCommFault 522, error* 770+ all >= this


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
                                   "--fast-hz", str(args.fast_hz)])
        procs.append(ServerProc(p, "ua", [f"ua{n:02d}" for n in range(off, off + count)]))
        off += count
    for n in range(bulk, args.ua):
        extra = ["--count", "1", "--offset", str(n), "--seed", str(args.seed),
                 "--hz", str(args.hz), "--fast-hz", str(args.fast_hz)]
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
                                   "--word-order", args.word_order])
        procs.append(ServerProc(p, "mb", [f"mb{n:02d}" for n in range(mb_bulk)]))
    for n in range(mb_bulk, args.mb):
        extra = ["--count", "1", "--offset", str(n), "--seed", str(args.seed),
                 "--hz", str(args.hz), "--fast-hz", str(args.fast_hz),
                 "--word-order", args.word_order]
        p = spawn("mb_server.py", extra)
        sp = ServerProc(p, "mb", [f"mb{n:02d}"])
        procs.append(sp)
        kill_targets.append(("mb", f"mb{n:02d}", extra, sp))

    return procs, kill_targets


# --------------------------------------------------------------------------
# Config generation
# --------------------------------------------------------------------------

def make_key_mappings(ua_info, mb_info):
    nodes = {}
    for name, info in ua_info.items():
        for node in UA.NODE_MATRIX:
            nodes[f"{name}.{node}"] = {
                "opcua_node": {
                    "namespace": info["ns"],
                    "identifier": f"{name}.{node}",
                    "array_index": None,
                    "server_alias": name,
                },
            }
    for name, info in mb_info.items():
        for key, (cat, rtype, addr, dtype, mask, shift, gen) in MB.MB_KEYS.items():
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
                 "qual_events", "bad_since", "prev_num")

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
        self.latency_ua = []       # ms, only keys with their own source ts
        self.latency_mb = []
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
        elif method == "resync":
            self.resyncs += 1
        elif method == "status":
            self.status_events.append((time.time(), params.get("alias"),
                                       params.get("state")))
        # tick/bye/others: nothing to do for the bench

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
            self.changes += 1
            v = wire.get("v")
            q = wire.get("q", Q_GOOD)
            t = wire.get("t", batch_t)
            self.record(key, v, q, t, now)
        for h, q in (p.get("q") or {}).items():
            key = self.key_for(sub, h)
            if key is not None:
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
        if not snapshot and t is not None and q < BAD_FLOOR:
            lat = now * 1000.0 - t
            (self.latency_ua if key.startswith("ua") else self.latency_mb).append(lat)
        self.check_honesty(key, v, q)

    # ---- honesty: values must come from the generators' closed sets ----

    def check_honesty(self, key, v, q):
        name, _, suffix = key.partition(".")
        seed = (self.ua_info.get(name) or self.mb_info.get(name, {})).get("seed")
        if seed is None:
            return
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
        print(f"SPAWN: {args.ua} OPC UA + {args.mb} Modbus servers "
              f"({args.kill} of each as separate kill-arm processes)")
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

        # ---- 2. generated artifacts ----
        keymap_path = os.path.join(GEN, "key-mappings.json")
        config_path = os.path.join(GEN, "gateway-config.json")
        page_path = os.path.join(GEN, "page_editor_data.json")
        mappings = make_key_mappings(ua_info, mb_info)
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
                print(f"RECV LOOP EXITED (frames Ok, errors={bench.frame_errors})")

        recv_task = asyncio.create_task(recv_loop())

        hello = await bench.rpc(ws, "hello", {
            "protocol": PROTOCOL, "supported": [PROTOCOL],
            "client": {"name": "load-bench", "version": "1"}})
        hb_ms = (hello.get("capabilities") or {}).get("heartbeatDeadlineMs") or 6000
        print(f"HELLO: server={hello.get('server')} heartbeatDeadlineMs={hb_ms}")

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
        chunk = 400
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
        print(f"SUBSCRIBE: {len(all_keys)} keys in {time.time()-t0:.1f}s, "
              f"{len(bench.rejected)} rejected")
        if bench.rejected:
            sample = list(bench.rejected.items())[:10]
            print(f"  rejected sample: {sample}")

        # ---- 5. measure ----
        gw_ps = psutil.Process(gateway.pid)
        fleet_ps = [psutil.Process(p.popen.pid) for p in procs]
        for ps in fleet_ps + [gw_ps]:
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

        def fleet_stats():
            rss = cpu = 0
            for ps in fleet_ps:
                try:
                    rss += ps.memory_info().rss
                    cpu += ps.cpu_percent(None)
                except psutil.Error:
                    pass
            return rss, cpu

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
            f_rss, f_cpu = fleet_stats()
            rss_series.append((elapsed, gw_rss, f_rss))
            cpu_series.append((elapsed, gw_cpu, f_cpu))
            if elapsed >= next_report:
                next_report += 10.0
                rate = (bench.changes - last_changes) / 10.0
                last_changes = bench.changes
                lat = sorted(bench.latency_ua[-20000:])
                print(f"t={elapsed:5.0f}s changes/s={rate:7.0f} "
                      f"updates={bench.updates} gaps={bench.seq_gaps} "
                      f"ua-lat p50={pct(lat,50):6.0f}ms p95={pct(lat,95):6.0f}ms "
                      f"gwRSS={gw_rss/1e6:6.0f}MB gwCPU={gw_cpu:5.0f}% "
                      f"fleetRSS={f_rss/1e9:5.2f}GB fleetCPU={f_cpu:5.0f}%")

        # ---- 6. verdict ----
        print("\n" + "=" * 78)
        print("VERDICT")
        print("=" * 78)
        report(bench, ua_info, mb_info, killed, restarted_at, rss_series,
               cpu_series, args)
        ok = verdict_ok(bench, all_keys)

        hb_task.cancel()
        await ws.close()
        recv_task.cancel()
        return 0 if ok else 1
    finally:
        cleanup()


def report(bench, ua_info, mb_info, killed, restarted_at, rss_series, cpu_series, args):
    silent = [k for k, st in bench.keys.items() if st.count == 0
              and k not in bench.rejected]
    total = len(bench.keys)
    print(f"keys: {total} subscribed, {total - len(silent) - len(bench.rejected)} "
          f"delivered, {len(bench.rejected)} rejected, {len(silent)} SILENT")
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
    for label, lats in (("opcua (device-stamped)", bench.latency_ua),
                        ("modbus (gateway-stamped — Modbus HAS no device "
                         "timestamp; ts_source is the read instant, and that "
                         "is the honest claim)", bench.latency_mb)):
        s = sorted(lats)
        print(f"latency {label}: n={len(s)} p50={pct(s,50):.0f}ms "
              f"p95={pct(s,95):.0f}ms p99={pct(s,99):.0f}ms max={pct(s,100):.0f}ms")

    # memory over time: first vs last quarter slope
    if len(rss_series) > 8:
        q = len(rss_series) // 4
        gw_first = statistics.mean(r[1] for r in rss_series[:q])
        gw_last = statistics.mean(r[1] for r in rss_series[-q:])
        span_h = (rss_series[-1][0] - rss_series[0][0]) / 3600.0
        print(f"\ngateway RSS: {rss_series[0][1]/1e6:.0f} -> {rss_series[-1][1]/1e6:.0f} MB "
              f"(quartile means {gw_first/1e6:.0f} -> {gw_last/1e6:.0f}; "
              f"slope ≈ {(gw_last-gw_first)/1e6/max(span_h,1e-9)*0.75:.0f} MB/h)")
        print(f"fleet RSS end: {rss_series[-1][2]/1e9:.2f} GB; "
              f"gateway CPU mean {statistics.mean(c[1] for c in cpu_series):.0f}% "
              f"(of one core), fleet CPU mean "
              f"{statistics.mean(c[2] for c in cpu_series):.0f}%")

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

    # kill arm
    if killed:
        print("\nkill/restart arm:")
        for name, t_kill in killed.items():
            keys = [k for k in bench.keys if k.startswith(name + ".")]
            det = []
            for k in keys:
                st = bench.keys[k]
                ev = [t for t, q in st.qual_events if q >= BAD_FLOOR and t >= t_kill]
                if ev:
                    det.append(min(ev) - t_kill)
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
                if rec:
                    print(f"      recovered {len(rec)}/{len(keys)} keys, first "
                          f"{min(rec):.1f}s median {statistics.median(rec):.1f}s "
                          f"after restart")
                else:
                    print(f"      NOT RECOVERED after restart <-- check reconnect")

    if bench.violations:
        print(f"\nDETERMINISM VIOLATIONS ({len(bench.violations)}, first 20):")
        for v in bench.violations[:20]:
            print("  " + v)
    else:
        print("\ndeterminism: every checked value came from its generator's set")

    if bench.status_events:
        print(f"\nstatus notifications: {len(bench.status_events)} "
              f"(link up/down announcements reached the client)")


def verdict_ok(bench, all_keys):
    silent = [k for k, st in bench.keys.items()
              if st.count == 0 and k not in bench.rejected]
    # Illegal keys are EXPECTED to be bad — but bad is an arrival, not silence.
    hard_silent = [k for k in silent]
    ok = not hard_silent and bench.hazard_seen["raw_nonfinite"] == 0
    print("\nRESULT: " + ("PASS (no silent keys, sanitizer held)" if ok
                          else "FAIL — see above"))
    return ok


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
    args = ap.parse_args()
    rc = asyncio.run(amain(args))
    sys.exit(rc)


if __name__ == "__main__":
    main()
