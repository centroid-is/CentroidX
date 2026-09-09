#!/usr/bin/env python3
"""Modbus TCP load-bench server fleet (pymodbus, pinned 3.12.x).

Same shape as ua_server.py: one process hosts --count servers on ephemeral
ports, values are pure functions of (seed, tick), Counter16 (hr 14) carries
the tick so exact values are assertable.

Modbus has no type system — everything below is 16-bit registers and bits —
so the matrix here is about INTERPRETATION: sign, register-pair word order,
bit masks/shifts, scaling, packed Latin-1 text, a dead register, and an
illegal address that answers a Modbus exception instead of data.

stdout protocol:

    SERVER <name> 127.0.0.1:<port> seed=<seed>
    READY <count>

Register layout (per server) — MB_KEYS below is the single source of truth
the supervisor generates key mappings from and the self-test asserts on.
"""

from __future__ import annotations

import argparse
import asyncio
import signal
import socket
import struct
import sys

# --------------------------------------------------------------------------
# Deterministic generators: pure functions of (seed, tick).
# --------------------------------------------------------------------------

def gen_huint16(seed, tick): return [0, 1, 1234, 65535, seed % 65536][tick % 5]
def gen_hint16(seed, tick):  return [0, -1, 32767, -32768, (seed % 100) - 50][tick % 5]
def gen_hint32(seed, tick):  return [0, -1, 2147483647, -2147483648, (seed * 7919) % 1000000][tick % 5]
def gen_huint32(seed, tick): return [0, 1, 4294967295, (seed * 2654435761) % 4294967296][tick % 4]
def gen_hfloat32(seed, tick): return [0.0, -1.5, 12.5, float(seed % 100) + 0.5][tick % 4]  # exact in f32
def gen_hfloat64(seed, tick): return [0.0, -2.5, seed * 1.25, 1e100][tick % 4]
def gen_packed(seed, tick):
    running = 1 if tick % 2 == 0 else 0
    fault = 1 if tick % 7 == 0 else 0
    mode = tick % 4
    return running | (fault << 1) | (mode << 8)
def gen_scaled(seed, tick):  return 1200 + (tick % 100)          # raw ×100 → 12.00..12.99 °C
def gen_counter16(seed, tick): return tick % 65536
def gen_iuint16(seed, tick): return (seed + tick) % 65536
def gen_coil0(seed, tick):   return tick % 2 == 0
def gen_disc0(seed, tick):   return tick % 3 == 0
def gen_fast(seed, fast_tick): return fast_tick % 65536
def gen_dead(seed):          return seed % 65536                 # written at init, never again
STRING_LATIN1 = "Þorskur þæð "                                   # packed 2 chars/register, init only

# key suffix -> (category, register_type, address, data_type, bit_mask, bit_shift, generator)
# register_type / data_type spellings are EXACTLY the keymapping JSON's.
MB_KEYS = {
    "HUint16":   ("uint16-extremes",   "holdingRegister", 0,  "uint16",  None, None, gen_huint16),
    "HInt16":    ("int16-extremes",    "holdingRegister", 1,  "int16",   None, None, gen_hint16),
    "HInt32":    ("int32-span",        "holdingRegister", 2,  "int32",   None, None, gen_hint32),
    "HUint32":   ("uint32-span",       "holdingRegister", 4,  "uint32",  None, None, gen_huint32),
    "HFloat32":  ("float32-span",      "holdingRegister", 6,  "float32", None, None, gen_hfloat32),
    "HFloat64":  ("float64-span",      "holdingRegister", 8,  "float64", None, None, gen_hfloat64),
    "PackedRunning": ("bitmask-bool",  "holdingRegister", 12, "uint16",  0x0001, 0, None),
    "PackedFault":   ("bitmask-bool",  "holdingRegister", 12, "uint16",  0x0002, 1, None),
    "PackedMode":    ("bitmask-multi", "holdingRegister", 12, "uint16",  0x0F00, 8, None),
    "Scaled":    ("scaled-raw",        "holdingRegister", 13, "uint16",  None, None, gen_scaled),
    "Counter16": ("uint16-monotonic",  "holdingRegister", 14, "uint16",  None, None, gen_counter16),
    "Fast":      ("high-frequency",    "holdingRegister", 15, "uint16",  None, None, None),
    "DeadReg":   ("dead-at-source",    "holdingRegister", 16, "uint16",  None, None, None),
    "StringRaw0":("string-latin1-packed-gap", "holdingRegister", 300, "uint16", None, None, None),
    "IUint16":   ("input-register",    "inputRegister",   0,  "uint16",  None, None, gen_iuint16),
    "Coil0":     ("coil-bool",         "coil",            0,  "bit",     None, None, gen_coil0),
    "CoilConst": ("coil-constant",     "coil",            1,  "bit",     None, None, None),
    "Disc0":     ("discrete-input",    "discreteInput",   0,  "bit",     None, None, gen_disc0),
    # Address far beyond the datastore: the server answers IllegalDataAddress.
    # A Modbus exception is a DIFFERENT failure than a dead socket, and it must
    # surface as bad quality, never as silence.
    "Illegal":   ("illegal-address",   "holdingRegister", 60000, "uint16", None, None, None),
}

HR_SIZE = 400          # holding registers 0..399, so 60000 is genuinely illegal
IR_SIZE = 100
BIT_SIZE = 16


def encode_words(value, kind: str, word_order: str) -> list[int]:
    """Value -> list of 16-bit register ints. ABCD = most-significant word
    first (the classic 'big-endian words' order the plant uses); CDAB swaps
    the 16-bit words. Bytes inside each register are always big-endian —
    pymodbus handles the byte layer."""
    fmt = {"int16": ">h", "uint16": ">H", "int32": ">i", "uint32": ">I",
           "float32": ">f", "float64": ">d"}[kind]
    raw = struct.pack(fmt, value)
    words = [int.from_bytes(raw[i:i + 2], "big") for i in range(0, len(raw), 2)]
    if word_order == "cdab" and len(words) > 1:
        # swap adjacent word pairs: [A,B]->[B,A], [A,B,C,D]->[B,A,D,C]
        swapped = []
        for i in range(0, len(words), 2):
            pair = words[i:i + 2]
            swapped.extend(reversed(pair))
        words = swapped
    return words


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def build_context(seed: int, word_order: str):
    from pymodbus.datastore import (ModbusDeviceContext,
                                    ModbusSequentialDataBlock,
                                    ModbusServerContext)
    hr = [0] * HR_SIZE
    hr[16] = gen_dead(seed)
    packed = STRING_LATIN1.encode("latin-1")
    if len(packed) % 2:
        packed += b"\x00"
    for i in range(0, len(packed), 2):
        hr[300 + i // 2] = int.from_bytes(packed[i:i + 2], "big")
    # MEASURED off-by-one (pymodbus 3.12.1): wire address n reads the block's
    # init-list index n+1 — the legacy zero_mode=False skew. setValues and the
    # server's reads share the skew, so ticked values line up either way; only
    # the INIT lists need the one-slot pad below. Verified against a real
    # client: without the pad, DeadReg/CoilConst/StringRegs all appeared one
    # address high.
    device = ModbusDeviceContext(
        hr=ModbusSequentialDataBlock(0, [0] + hr),
        ir=ModbusSequentialDataBlock(0, [0] + [0] * IR_SIZE),
        co=ModbusSequentialDataBlock(0, [0] + [0, 1] + [0] * (BIT_SIZE - 2)),  # CoilConst=1
        di=ModbusSequentialDataBlock(0, [0] + [0] * BIT_SIZE),
    )
    return ModbusServerContext(devices=device, single=True), device


def tick_sync(device, seed: int, tick: int, word_order: str):
    """One base tick. setValues(fc, addr, values): fc 3 holding, 4 input,
    1 coils, 2 discrete."""
    device.setValues(3, 0, encode_words(gen_huint16(seed, tick), "uint16", word_order))
    device.setValues(3, 1, encode_words(gen_hint16(seed, tick), "int16", word_order))
    device.setValues(3, 2, encode_words(gen_hint32(seed, tick), "int32", word_order))
    device.setValues(3, 4, encode_words(gen_huint32(seed, tick), "uint32", word_order))
    device.setValues(3, 6, encode_words(gen_hfloat32(seed, tick), "float32", word_order))
    device.setValues(3, 8, encode_words(gen_hfloat64(seed, tick), "float64", word_order))
    device.setValues(3, 12, [gen_packed(seed, tick)])
    device.setValues(3, 13, [gen_scaled(seed, tick)])
    device.setValues(3, 14, [gen_counter16(seed, tick)])
    device.setValues(4, 0, [gen_iuint16(seed, tick)])
    device.setValues(1, 0, [1 if gen_coil0(seed, tick) else 0])
    device.setValues(2, 0, [1 if gen_disc0(seed, tick) else 0])


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--hz", type=float, default=1.0)
    ap.add_argument("--fast-hz", type=float, default=20.0)
    ap.add_argument("--prefix", default="mb")
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--word-order", choices=["abcd", "cdab"], default="abcd",
                    help="register-pair order for 32/64-bit values. The gateway "
                         "decodes ABCD only today (UpstreamLinkConfig exposes no "
                         "endianness); cdab exists to prove the difference shows.")
    ap.add_argument("--port", type=int, default=None,
                    help="fixed port (restart arm only; requires --count 1)")
    args = ap.parse_args()
    if args.port is not None and args.count != 1:
        ap.error("--port requires --count 1")

    from pymodbus.server import ModbusTcpServer

    servers = []   # (name, seed, server, device, task)
    for i in range(args.count):
        n = args.offset + i
        name = f"{args.prefix}{n:02d}"
        seed = args.seed + n
        context, device = build_context(seed, args.word_order)
        last_err = None
        for _ in range(3):   # free-port draw race: redraw, never a literal
            port = args.port if args.port is not None else free_port()
            server = ModbusTcpServer(context, address=("127.0.0.1", port))
            try:
                task = asyncio.create_task(server.serve_forever())
                await asyncio.sleep(0)     # let it bind
                # serve_forever binds asynchronously; probe until connectable
                for _ in range(50):
                    try:
                        r, w = await asyncio.open_connection("127.0.0.1", port)
                        w.close()
                        await w.wait_closed()
                        break
                    except OSError:
                        await asyncio.sleep(0.05)
                else:
                    raise OSError(f"{name}: server did not come up on {port}")
                break
            except OSError as e:
                last_err = e
                task.cancel()
        else:
            raise RuntimeError(f"{name}: no free port in 3 draws: {last_err}")
        servers.append((name, seed, server, device, task))
        print(f"SERVER {name} 127.0.0.1:{port} seed={seed}", flush=True)
    print(f"READY {len(servers)}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    async def sync_loop():
        tick = 0
        while not stop.is_set():
            t0 = loop.time()
            tick += 1
            for name, seed, server, device, task in servers:
                tick_sync(device, seed, tick, args.word_order)
            elapsed = loop.time() - t0
            if elapsed > 1.0 / args.hz:
                print(f"LAG sync tick took {elapsed:.3f}s", flush=True)
            await asyncio.sleep(max(0.0, 1.0 / args.hz - elapsed))

    async def fast_loop():
        fast_tick = 0
        while not stop.is_set():
            t0 = loop.time()
            fast_tick += 1
            for name, seed, server, device, task in servers:
                device.setValues(3, 15, [gen_fast(seed, fast_tick)])
            await asyncio.sleep(max(0.0, 1.0 / args.fast_hz - (loop.time() - t0)))

    loops = [asyncio.create_task(sync_loop()), asyncio.create_task(fast_loop())]
    await stop.wait()
    for t in loops:
        t.cancel()
    for name, seed, server, device, task in servers:
        try:
            await server.shutdown()
        except Exception:
            pass
        task.cancel()
    print("STOPPED", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
