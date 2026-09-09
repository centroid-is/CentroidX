#!/usr/bin/env python3
"""OPC UA load-bench server fleet (asyncua).

One process hosts --count servers, each on its own ephemeral port, each
exposing the SAME type-matrix of nodes with values generated DETERMINISTICALLY
from (seed, tick). The point of determinism: given the Counter node's value c,
every sync-group node must equal its generator at tick c — a test can assert
exact expected values instead of "something changed".

stdout protocol (line-buffered, one line per server, then READY):

    SERVER <name> opc.tcp://127.0.0.1:<port> ns=<idx> seed=<seed>
    READY <count>

No hardcoded ports anywhere: each port is drawn from the kernel and printed.
SIGTERM/SIGINT stop every server cleanly.

The type matrix (per server) — see NODE_MATRIX below for the single source of
truth the coverage self-test asserts on:

  numbers with extremes/negatives/zero, booleans, UTF-8 + Latin-1 Icelandic
  strings, DateTime, GUID, ByteString, LocalizedText, enum, abstract-DataType,
  arrays (incl. empty + large), built-in struct (Range), custom struct,
  NaN/±Inf hazards, a dead-at-source node, a constant node, a 20 Hz node.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import math
import signal
import socket
import struct
import sys
import uuid

# --------------------------------------------------------------------------
# Deterministic value generation. Pure functions of (seed, tick) ONLY.
# test_bench.py asserts on these; the server merely publishes them.
# --------------------------------------------------------------------------

F32_MAX = 3.4028234663852886e38
F64_MAX = 1.7976931348623157e308

def gen_bool(seed, tick):        return (seed + tick) % 2 == 0
def gen_int16(seed, tick):       return [0, 1, -1, 32767, -32768, (seed % 100) - 50][tick % 6]
def gen_int32(seed, tick):       return [0, -1, 2147483647, -2147483648, (seed * 7919) % 100000][tick % 5]
def gen_int64(seed, tick):       return [0, -1, 9223372036854775807, -9223372036854775808, seed * 104729][tick % 5]
def gen_uint16(seed, tick):      return [0, 1, 65535, seed % 65536][tick % 4]
def gen_uint32(seed, tick):      return [0, 1, 4294967295, (seed * 2654435761) % 4294967296][tick % 4]
def gen_float(seed, tick):       return [0.0, -0.0, 1.5, -F32_MAX, F32_MAX, float(seed)][tick % 6]
def gen_double(seed, tick):      return [0.0, -F64_MAX, F64_MAX, 5e-324, seed * 1.25][tick % 5]
def gen_double_hazard(seed, tick):
    # The deliberate wire hazards: Dart jsonEncode throws on these, so the
    # gateway MUST sanitize (null + badNonFinite). A bench that cannot emit a
    # NaN cannot prove the sanitizer works.
    return [math.nan, math.inf, -math.inf, 1e308, 0.0][tick % 5]
def gen_string_utf8(seed, tick): return f"Þorskur ævi ð {seed}:{tick % 10}"
def gen_string_latin1(seed, tick):
    # Raw Latin-1 bytes on the wire — the S7-string hazard. bytes, not str:
    # asyncua packs bytes into a UA String verbatim.
    return f"Síld þæð {tick % 10}".encode("latin-1")
def gen_datetime(seed, tick):
    return dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=seed * 100 + tick)
def gen_guid(seed, tick):        return uuid.UUID(int=((seed & 0xFFFFFFFF) << 64) | (tick % 16))
def gen_bytestring(seed, tick):  return bytes([tick % 256, seed % 256, 0xFE, 0xDE])
def gen_localized(seed, tick):   return (f"Ýsa {tick % 10}", "is-IS")   # (text, locale)
def gen_enum(seed, tick):        return tick % 4                        # BenchMode
def gen_abstract(seed, tick):    return tick * 0.5                      # Double under abstract DataType
def gen_array_double(seed, tick):
    # Large array: wire-cost / conflation specimen. 256 doubles, all change.
    return [(tick + i) * 0.5 for i in range(256)]
def gen_array_int32(seed, tick): return [tick % 1000, -(tick % 1000), seed % 1000, 0, 2147483647]
def gen_array_string(seed, tick): return [f"æ{tick % 5}", "ðelta", "þristur"]
def gen_array_bool(seed, tick):  return [(tick + i) % 2 == 0 for i in range(5)]
def gen_range(seed, tick):       return (-(float(seed % 50) + tick % 10), float(seed % 50) + tick % 10)  # (Low, High)
def gen_struct(seed, tick):      return {"Flag": tick % 2 == 0, "Count": tick % 100000,
                                         "Value": tick * 0.25, "Note": f"þæð {seed}"}
def gen_counter(seed, tick):     return tick % 4294967296
def gen_fast(seed, fast_tick):   return fast_tick * 0.001               # 20 Hz ramp
def gen_constant(seed):          return 42.42 + seed                    # written ONCE at boot

# name -> (category, generator or None). Single source of truth for coverage.
# Categories are what the self-test asserts the matrix covers.
NODE_MATRIX = {
    "Counter":       ("uint32-monotonic", gen_counter),
    "Bool":          ("boolean",          gen_bool),
    "Int16":         ("int16-extremes",   gen_int16),
    "Int32":         ("int32-extremes",   gen_int32),
    "Int64":         ("int64-extremes",   gen_int64),
    "UInt16":        ("uint16-extremes",  gen_uint16),
    "UInt32":        ("uint32-extremes",  gen_uint32),
    "Float":         ("float-extremes",   gen_float),
    "Double":        ("double-extremes",  gen_double),
    "DoubleHazard":  ("nan-inf-hazard",   gen_double_hazard),
    "StringUtf8":    ("string-utf8-icelandic",   gen_string_utf8),
    "StringLatin1":  ("string-latin1-icelandic", gen_string_latin1),
    "DateTimeNode":  ("datetime",         gen_datetime),
    "GuidNode":      ("guid",             gen_guid),
    "ByteStringNode":("bytestring",       gen_bytestring),
    "LocalizedTextNode": ("localizedtext", gen_localized),
    "EnumNode":      ("enum",             gen_enum),
    "AbstractNode":  ("abstract-datatype", gen_abstract),
    "ArrayDouble":   ("array-double-large", gen_array_double),
    "ArrayInt32":    ("array-int32",      gen_array_int32),
    "ArrayString":   ("array-string",     gen_array_string),
    "ArrayBool":     ("array-bool",       gen_array_bool),
    "ArrayEmpty":    ("array-empty",      None),   # written once, stays []
    "StructRange":   ("struct-builtin",   gen_range),
    "StructCustom":  ("struct-custom",    gen_struct),
    "Dead":          ("dead-at-source",   None),   # NEVER written after creation
    "Constant":      ("constant",         None),   # written once at boot
    "Fast":          ("high-frequency",   None),   # fast loop, gen_fast
}

# The nodes rewritten every base tick (everything with a generator except Fast).
SYNC_NODES = [n for n, (_, g) in NODE_MATRIX.items() if g is not None]


# --------------------------------------------------------------------------
# Matrix replication: how the bench scales KEY COUNT without touching the
# matrix. Replica 0 is the original names; replica r >= 1 suffixes _c{r} and
# derives its own seed, so every copy stays deterministic AND distinct.
# The matrix is replicated whole — never padded with identical doubles —
# because the matrix is the reason the bench has value at every size.
# --------------------------------------------------------------------------

def replica_seed(seed: int, r: int) -> int:
    return seed if r == 0 else seed + 7919 * r     # 7919: prime, keeps seeds apart


def replica_node_name(base: str, r: int) -> str:
    return base if r == 0 else f"{base}_c{r}"


def parse_replica(node_name: str) -> tuple[str, int]:
    """'Int16_c3' -> ('Int16', 3); 'Int16' -> ('Int16', 0)."""
    base, sep, tail = node_name.rpartition("_c")
    if sep and tail.isdigit():
        return base, int(tail)
    return node_name, 0


def replicated_nodes(replicate: int) -> list[str]:
    return [replica_node_name(b, r) for r in range(replicate) for b in NODE_MATRIX]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


async def build_server(name: str, seed: int, fixed_port: int | None = None,
                       replicate: int = 1):
    """One asyncua server with the full matrix. Returns (server, ctx dict).

    [fixed_port] exists for ONE caller: the bench's restart arm, which brings a
    killed server back on the port it originally drew (a rebooting PLC keeps
    its address). Everyone else gets an ephemeral draw."""
    from asyncua import Server, ua
    from asyncua.common.structures104 import new_struct, new_struct_field, new_enum

    last_err = None
    for _ in range(3):  # free-port draw race: redraw and retry, never a literal
        port = fixed_port if fixed_port is not None else free_port()
        server = Server()
        await server.init()
        server.set_endpoint(f"opc.tcp://127.0.0.1:{port}")
        server.set_server_name(f"loadbench-{name}")
        try:
            await server.start()
            break
        except OSError as e:
            last_err = e
            await server.stop()
    else:
        raise RuntimeError(f"{name}: no free port in 3 draws: {last_err}")

    idx = await server.register_namespace(f"urn:loadbench:{name}")
    obj = await server.nodes.objects.add_object(ua.NodeId(name, idx), f"{idx}:{name}")

    # Custom enum + custom struct, registered per server namespace.
    await new_enum(server, idx, "BenchMode", ["Stopped", "Starting", "Running", "Fault"])
    await new_struct(server, idx, "BenchStruct", [
        new_struct_field("Flag", ua.VariantType.Boolean),
        new_struct_field("Count", ua.VariantType.Int32),
        new_struct_field("Value", ua.VariantType.Double),
        new_struct_field("Note", ua.VariantType.String),
    ])
    types = await server.load_data_type_definitions()
    # asyncua generates struct classes into the process-wide `ua` module: the
    # SECOND server in a host process gets an empty dict back because the
    # class already exists. Same layout, and the deterministic per-aspace node
    # ids give every server's BenchStruct the same TypeId, so reuse is sound.
    BenchStruct = types.get("BenchStruct") or getattr(ua, "BenchStruct")

    # ---- WORKAROUND for a REAL native crash in the pinned open62541_dart ----
    # asyncua's standard address space gives every base DataType node (e.g.
    # ns=0;i=294 DateTime) a DataTypeDefinition attribute whose answer is
    # status GOOD with an EMPTY variant. That is spec-legal. The pinned
    # binding's readAttribute auto-schema follow-up then dereferences
    # `value.type` (NULL for an empty variant) and SEGVs the whole client
    # process — measured 2026-09-09, si_addr=0xc, client.dart:873. TwinCAT
    # never triggers it because it answers BadAttributeIdInvalid instead.
    # Until the binding null-checks, prune the empty attributes so asyncua
    # answers BadAttributeIdInvalid too, which the binding tolerates.
    # The bench's custom BenchMode/BenchStruct definitions are real (non-empty)
    # and are NOT pruned — struct/enum type learning still goes down the
    # DataTypeDefinition path.
    from asyncua.ua import AttributeIds
    pruned = 0
    for nd in server.iserver.aspace._nodes.values():
        a = nd.attributes.get(AttributeIds.DataTypeDefinition)
        if a is not None and (a.value is None or a.value.Value.Value is None):
            del nd.attributes[AttributeIds.DataTypeDefinition]
            pruned += 1
    print(f"WORKAROUND {name}: pruned {pruned} empty DataTypeDefinition "
          f"attributes (Good+empty-variant answer SEGVs the pinned "
          f"open62541_dart client natively — see tools/load-bench/README.md)",
          flush=True)

    V = ua.Variant
    T = ua.VariantType

    def nid(node_name):
        return ua.NodeId(f"{name}.{node_name}", idx)

    async def add(node_name, variant, datatype=None):
        node = await obj.add_variable(nid(node_name), f"{idx}:{node_name}", variant, datatype=datatype)
        return node

    # Enum DataType node id, resolved once (shared by every replica).
    enum_dtype = None
    for child in await server.nodes.enum_data_type.get_children():
        bn = await child.read_browse_name()
        if bn.Name == "BenchMode" and bn.NamespaceIndex == idx:
            enum_dtype = child.nodeid
            break

    nodes = {}
    for r in range(replicate):
        s = replica_seed(seed, r)

        def N(base, _r=r):
            return replica_node_name(base, _r)

        nodes[N("Counter")]   = await add(N("Counter"),   V(gen_counter(s, 0), T.UInt32))
        nodes[N("Bool")]      = await add(N("Bool"),      V(gen_bool(s, 0), T.Boolean))
        nodes[N("Int16")]     = await add(N("Int16"),     V(gen_int16(s, 0), T.Int16))
        nodes[N("Int32")]     = await add(N("Int32"),     V(gen_int32(s, 0), T.Int32))
        nodes[N("Int64")]     = await add(N("Int64"),     V(gen_int64(s, 0), T.Int64))
        nodes[N("UInt16")]    = await add(N("UInt16"),    V(gen_uint16(s, 0), T.UInt16))
        nodes[N("UInt32")]    = await add(N("UInt32"),    V(gen_uint32(s, 0), T.UInt32))
        nodes[N("Float")]     = await add(N("Float"),     V(gen_float(s, 0), T.Float))
        nodes[N("Double")]    = await add(N("Double"),    V(gen_double(s, 0), T.Double))
        nodes[N("DoubleHazard")] = await add(N("DoubleHazard"), V(gen_double_hazard(s, 4), T.Double))  # start finite
        nodes[N("StringUtf8")]   = await add(N("StringUtf8"),   V(gen_string_utf8(s, 0), T.String))
        nodes[N("StringLatin1")] = await add(N("StringLatin1"), V(gen_string_latin1(s, 0), T.String))
        nodes[N("DateTimeNode")] = await add(N("DateTimeNode"), V(gen_datetime(s, 0), T.DateTime))
        nodes[N("GuidNode")]     = await add(N("GuidNode"),     V(gen_guid(s, 0), T.Guid))
        nodes[N("ByteStringNode")] = await add(N("ByteStringNode"), V(gen_bytestring(s, 0), T.ByteString))
        text, locale = gen_localized(s, 0)
        nodes[N("LocalizedTextNode")] = await add(
            N("LocalizedTextNode"), V(ua.LocalizedText(text, locale), T.LocalizedText))

        # Enum: Int32 value, DataType = the registered BenchMode enum.
        nodes[N("EnumNode")] = await add(N("EnumNode"), V(gen_enum(s, 0), T.Int32),
                                         datatype=enum_dtype)

        # Abstract DataType: value is a concrete Double variant, but the node's
        # declared DataType is the ABSTRACT ua Number (i=26). Past bug specimen:
        # writes to such a node null-checked and answered "unknown" in-process.
        nodes[N("AbstractNode")] = await add(
            N("AbstractNode"), V(gen_abstract(s, 0), T.Double),
            datatype=ua.NodeId(ua.ObjectIds.Number))

        nodes[N("ArrayDouble")] = await add(N("ArrayDouble"), V(gen_array_double(s, 0), T.Double))
        nodes[N("ArrayInt32")]  = await add(N("ArrayInt32"),  V(gen_array_int32(s, 0), T.Int32))
        nodes[N("ArrayString")] = await add(N("ArrayString"), V(gen_array_string(s, 0), T.String))
        nodes[N("ArrayBool")]   = await add(N("ArrayBool"),   V(gen_array_bool(s, 0), T.Boolean))
        nodes[N("ArrayEmpty")]  = await add(N("ArrayEmpty"),  V([], T.Double))

        low, high = gen_range(s, 0)
        nodes[N("StructRange")] = await add(
            N("StructRange"), V(ua.Range(Low=low, High=high), T.ExtensionObject))
        st = gen_struct(s, 0)
        nodes[N("StructCustom")] = await add(
            N("StructCustom"),
            V(BenchStruct(Flag=st["Flag"], Count=st["Count"], Value=st["Value"], Note=st["Note"]),
              T.ExtensionObject))

        # Dead at source: exists, has an address-space default, NEVER published.
        # The rig specimen: its initial read answers 0.0 quality GOOD.
        nodes[N("Dead")] = await add(N("Dead"), V(0.0, T.Double))

        # Constant: healthy but never changes. Must not decay to badStale.
        nodes[N("Constant")] = await add(N("Constant"), V(gen_constant(s), T.Double))

        nodes[N("Fast")] = await add(N("Fast"), V(0.0, T.Double))

    return server, {
        "name": name, "seed": seed, "port": port, "idx": idx,
        "nodes": nodes, "BenchStruct": BenchStruct, "tick": 0, "fast_tick": 0,
        "replicate": replicate,
    }


def variant_for(ua, ctx, node_name, value):
    """Wrap a generator value in the right ua.Variant. [node_name] may carry a
    replica suffix (Int16_c3) — the variant type depends only on the base."""
    T = ua.VariantType
    V = ua.Variant
    base, _ = parse_replica(node_name)
    match base:
        case "Counter": return V(value, T.UInt32)
        case "Bool": return V(value, T.Boolean)
        case "Int16": return V(value, T.Int16)
        case "Int32": return V(value, T.Int32)
        case "Int64": return V(value, T.Int64)
        case "UInt16": return V(value, T.UInt16)
        case "UInt32": return V(value, T.UInt32)
        case "Float": return V(value, T.Float)
        case "Double" | "DoubleHazard" | "AbstractNode" | "Fast": return V(value, T.Double)
        case "StringUtf8" | "StringLatin1": return V(value, T.String)
        case "DateTimeNode": return V(value, T.DateTime)
        case "GuidNode": return V(value, T.Guid)
        case "ByteStringNode": return V(value, T.ByteString)
        case "LocalizedTextNode": return V(ua.LocalizedText(value[0], value[1]), T.LocalizedText)
        case "EnumNode": return V(value, T.Int32)
        case "ArrayDouble": return V(value, T.Double)
        case "ArrayInt32": return V(value, T.Int32)
        case "ArrayString": return V(value, T.String)
        case "ArrayBool": return V(value, T.Boolean)
        case "StructRange":
            return V(ua.Range(Low=value[0], High=value[1]), T.ExtensionObject)
        case "StructCustom":
            B = ctx["BenchStruct"]
            return V(B(Flag=value["Flag"], Count=value["Count"],
                       Value=value["Value"], Note=value["Note"]), T.ExtensionObject)
    raise KeyError(node_name)


async def tick_sync(server, ctx):
    """One base tick: rewrite every sync node from its generator, atomically
    within one event-loop turn (no await between value computations), so a
    reader that sees Counter==c sees every other node at tick c."""
    from asyncua import ua
    ctx["tick"] += 1
    t = ctx["tick"]
    now = dt.datetime.now(dt.timezone.utc)
    writes = []
    for r in range(ctx.get("replicate", 1)):
        s = replica_seed(ctx["seed"], r)
        for base in SYNC_NODES:
            node_name = replica_node_name(base, r)
            gen = NODE_MATRIX[base][1]
            variant = variant_for(ua, ctx, node_name, gen(s, t))
            writes.append((ctx["nodes"][node_name].nodeid,
                           ua.DataValue(variant, SourceTimestamp=now)))
    for nodeid, dv in writes:
        await server.write_attribute_value(nodeid, dv)


async def tick_fast(server, ctx):
    from asyncua import ua
    ctx["fast_tick"] += 1
    now = dt.datetime.now(dt.timezone.utc)
    for r in range(ctx.get("replicate", 1)):
        dv = ua.DataValue(
            ua.Variant(gen_fast(replica_seed(ctx["seed"], r), ctx["fast_tick"]),
                       ua.VariantType.Double),
            SourceTimestamp=now)
        await server.write_attribute_value(
            ctx["nodes"][replica_node_name("Fast", r)].nodeid, dv)


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--count", type=int, default=1, help="servers in this process")
    ap.add_argument("--seed", type=int, default=1, help="base seed; server i uses seed+offset+i")
    ap.add_argument("--hz", type=float, default=1.0, help="sync-group update rate per server")
    ap.add_argument("--fast-hz", type=float, default=20.0, help="Fast node update rate")
    ap.add_argument("--prefix", default="ua", help="server name prefix")
    ap.add_argument("--offset", type=int, default=0, help="first server index (names + seeds)")
    ap.add_argument("--port", type=int, default=None,
                    help="fixed port (restart arm only; requires --count 1)")
    ap.add_argument("--replicate", type=int, default=1,
                    help="matrix copies per server (replica r suffixes _c{r} "
                         "and derives seed+7919*r; the matrix is never padded, "
                         "always copied whole)")
    args = ap.parse_args()
    if args.port is not None and args.count != 1:
        ap.error("--port requires --count 1")
    if args.replicate < 1:
        ap.error("--replicate must be >= 1")

    servers = []
    for i in range(args.count):
        n = args.offset + i
        name = f"{args.prefix}{n:02d}"
        server, ctx = await build_server(name, args.seed + n, fixed_port=args.port,
                                         replicate=args.replicate)
        servers.append((server, ctx))
        print(f"SERVER {name} opc.tcp://127.0.0.1:{ctx['port']} ns={ctx['idx']} seed={args.seed + n}",
              flush=True)
    print(f"READY {len(servers)}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    async def sync_loop():
        while not stop.is_set():
            t0 = loop.time()
            for server, ctx in servers:
                await tick_sync(server, ctx)
            elapsed = loop.time() - t0
            behind = elapsed > 1.0 / args.hz
            if behind:
                print(f"LAG sync tick took {elapsed:.3f}s > {1.0/args.hz:.3f}s budget", flush=True)
            await asyncio.sleep(max(0.0, 1.0 / args.hz - elapsed))

    async def fast_loop():
        while not stop.is_set():
            t0 = loop.time()
            for server, ctx in servers:
                await tick_fast(server, ctx)
            await asyncio.sleep(max(0.0, 1.0 / args.fast_hz - (loop.time() - t0)))

    tasks = [asyncio.create_task(sync_loop()), asyncio.create_task(fast_loop())]
    await stop.wait()
    for t in tasks:
        t.cancel()
    for server, _ in servers:
        try:
            await server.stop()
        except Exception:
            pass
    print("STOPPED", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
