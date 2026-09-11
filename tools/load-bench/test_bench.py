#!/usr/bin/env python3
"""Self-tests for the load bench — the tests that prove the BENCH does not lie.

    .venv/bin/python -m unittest test_bench -v

Three claims are worth guarding:
  1. the seeded values really are deterministic (same inputs, same outputs,
     and a LIVE server publishes exactly generator(seed, Counter)),
  2. the type matrix really covers what it claims (categories asserted, so a
     deleted node fails a test instead of quietly shrinking the matrix),
  3. a killed server really is detected (in-run assertion; here we prove the
     kill lever kills: the process dies and its port stops answering).
"""

import asyncio
import os
import re
import signal
import socket
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

import ua_server as UA
import mb_server as MB


class TestDeterminism(unittest.TestCase):
    def test_generators_are_pure(self):
        for name, (cat, gen) in UA.NODE_MATRIX.items():
            if gen is None:
                continue
            for tick in (0, 1, 7, 12345):
                a, b = gen(42, tick), gen(42, tick)
                self.assertEqual(repr(a), repr(b), f"{name} impure at tick {tick}")

    def test_seeds_differ(self):
        # Two servers must not accidentally publish identical strings.
        self.assertNotEqual(UA.gen_string_utf8(1, 3), UA.gen_string_utf8(2, 3))

    def test_extremes_are_in_the_cycles(self):
        int16 = {UA.gen_int16(9, t) for t in range(6)}
        self.assertLessEqual({0, -32768, 32767, -1}, int16)
        int64 = {UA.gen_int64(9, t) for t in range(5)}
        self.assertIn(9223372036854775807, int64)
        self.assertIn(-9223372036854775808, int64)
        dbl = {UA.gen_double(9, t) for t in range(5)}
        self.assertIn(UA.F64_MAX, dbl)
        self.assertIn(-UA.F64_MAX, dbl)

    def test_hazards_really_are_hazards(self):
        import math
        vals = [UA.gen_double_hazard(1, t) for t in range(5)]
        self.assertTrue(any(math.isnan(v) for v in vals), "no NaN in hazard cycle")
        self.assertTrue(any(math.isinf(v) for v in vals), "no Inf in hazard cycle")

    def test_latin1_is_not_valid_utf8(self):
        # The whole point of the Latin-1 specimen: raw bytes that a UTF-8
        # decoder must trip on. If this ever passes UTF-8, the specimen is
        # proving nothing.
        raw = UA.gen_string_latin1(1, 0)
        self.assertIsInstance(raw, bytes)
        with self.assertRaises(UnicodeDecodeError):
            raw.decode("utf-8")

    def test_word_order_lever_does_something(self):
        abcd = MB.encode_words(-2147483648, "int32", "abcd")
        cdab = MB.encode_words(-2147483648, "int32", "cdab")
        self.assertNotEqual(abcd, cdab)
        self.assertEqual(abcd, list(reversed(cdab)))
        # And float64 round-trips through ABCD registers.
        import struct
        words = MB.encode_words(-2.5, "float64", "abcd")
        raw = b"".join(w.to_bytes(2, "big") for w in words)
        self.assertEqual(struct.unpack(">d", raw)[0], -2.5)


class TestReplication(unittest.TestCase):
    """Replication must scale KEY COUNT without touching the matrix: whole
    copies, distinct deterministic seeds, non-colliding register addresses."""

    def test_replica_names_roundtrip(self):
        self.assertEqual(UA.replica_node_name("Int16", 0), "Int16")
        self.assertEqual(UA.replica_node_name("Int16", 3), "Int16_c3")
        self.assertEqual(UA.parse_replica("Int16_c3"), ("Int16", 3))
        self.assertEqual(UA.parse_replica("Int16"), ("Int16", 0))
        # A base name that happens to end in _c<digits>-ish text must not
        # be misparsed — none exist in the matrix, asserted:
        for n in UA.NODE_MATRIX:
            self.assertEqual(UA.parse_replica(n), (n, 0))

    def test_replica_seeds_are_distinct_and_replica0_is_the_original(self):
        self.assertEqual(UA.replica_seed(42, 0), 42)
        seeds = {UA.replica_seed(42, r) for r in range(50)}
        self.assertEqual(len(seeds), 50)

    def test_replicated_nodes_is_whole_copies(self):
        nodes = UA.replicated_nodes(3)
        self.assertEqual(len(nodes), 3 * len(UA.NODE_MATRIX))
        self.assertEqual(len(set(nodes)), len(nodes))
        for base in UA.NODE_MATRIX:      # every copy carries the WHOLE matrix
            for r in range(3):
                self.assertIn(UA.replica_node_name(base, r), nodes)

    def test_mb_replicated_addresses_do_not_collide(self):
        keys = MB.replicated_keys(5)
        self.assertEqual(len(keys), 5 * len(MB.MB_KEYS))
        seen = {}
        for name, (cat, rtype, addr, dtype, mask, shift, gen) in keys.items():
            if mask is not None:        # packed keys legitimately share a register
                continue
            slot = (rtype, addr)
            self.assertNotIn(slot, seen, f"{name} collides with {seen.get(slot)}")
            seen[slot] = name

    def test_mb_illegal_stays_illegal_at_max_replication(self):
        keys = MB.replicated_keys(MB.MAX_REPLICATE)
        store_end = MB.BLOCK_HR * MB.MAX_REPLICATE
        for name, (cat, rtype, addr, *_rest) in keys.items():
            if cat == "illegal-address":
                self.assertGreaterEqual(addr, store_end,
                                        f"{name} at {addr} is INSIDE the store")
            elif rtype == "holdingRegister":
                self.assertLess(addr, store_end)


class TestHistogram(unittest.TestCase):
    def test_bucket_edges(self):
        import bench
        self.assertEqual(bench.hist_bucket(0.0), 0)
        self.assertEqual(bench.hist_bucket(5.0), 0)      # <=5 inclusive
        self.assertEqual(bench.hist_bucket(5.01), 1)
        self.assertEqual(bench.hist_bucket(5000.0), 9)
        self.assertEqual(bench.hist_bucket(5000.1), 10)  # the >5 s tail bucket
        self.assertEqual(bench.hist_bucket(1e9), 10)
        self.assertEqual(len(bench.hist_labels()), len(bench.HIST_EDGES_MS) + 1)

    def test_keys_per_server_maps_to_whole_copies(self):
        import bench
        self.assertEqual(bench.replicates_for(1), (1, 1))
        r_ua, r_mb = bench.replicates_for(200)
        self.assertEqual(r_ua, round(200 / len(UA.NODE_MATRIX)))
        self.assertEqual(r_mb, round(200 / len(MB.MB_KEYS)))
        # monotonic: more requested keys never means fewer copies
        prev = (1, 1)
        for k in range(1, 900, 50):
            cur = bench.replicates_for(k)
            self.assertGreaterEqual(cur[0], prev[0])
            self.assertGreaterEqual(cur[1], prev[1])
            prev = cur

    def test_curve_spec_parses(self):
        import bench
        self.assertEqual(bench.parse_curve("2500,10000x5"), [(2500, 1), (10000, 5)])


class TestMatrixCoverage(unittest.TestCase):
    REQUIRED_UA = {
        "boolean", "int16-extremes", "int32-extremes", "int64-extremes",
        "uint16-extremes", "uint32-extremes", "float-extremes",
        "double-extremes", "nan-inf-hazard", "string-utf8-icelandic",
        "string-latin1-icelandic", "datetime", "guid", "bytestring",
        "localizedtext", "enum", "abstract-datatype", "array-double-large",
        "array-int32", "array-string", "array-bool", "array-empty",
        "struct-builtin", "struct-custom", "dead-at-source", "constant",
        "high-frequency", "uint32-monotonic",
    }
    REQUIRED_MB = {
        "uint16-extremes", "int16-extremes", "int32-span", "uint32-span",
        "float32-span", "float64-span", "bitmask-bool", "bitmask-multi",
        "scaled-raw", "uint16-monotonic", "high-frequency", "dead-at-source",
        "input-register", "coil-bool", "coil-constant", "discrete-input",
        "illegal-address", "string-latin1-packed-gap",
    }

    def test_ua_matrix_covers_the_claim(self):
        got = {cat for cat, _ in UA.NODE_MATRIX.values()}
        self.assertEqual(self.REQUIRED_UA - got, set(),
                         "type matrix silently shrank")

    def test_mb_matrix_covers_the_claim(self):
        got = {cat for cat, *_ in MB.MB_KEYS.values()}
        self.assertEqual(self.REQUIRED_MB - got, set(),
                         "modbus matrix silently shrank")


class TestLiveServer(unittest.TestCase):
    """One real server of each kind: published values match the generators at
    the tick the server itself reports, and a SIGKILLed server's port dies."""

    def _spawn(self, script, seed, extra=()):
        p = subprocess.Popen(
            [PY, os.path.join(HERE, script), "--count", "1", "--seed", str(seed),
             "--hz", "5", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            bufsize=1, cwd=HERE)
        self.addCleanup(lambda: (p.poll() is None and p.kill(), p.wait()))
        endpoint = None
        for _ in range(200):
            line = p.stdout.readline()
            m = re.match(r"SERVER (\S+) (\S+)", line or "")
            if m:
                endpoint = m.group(2)
            if (line or "").startswith("READY"):
                break
        self.assertIsNotNone(endpoint, f"{script} never printed SERVER")
        return p, endpoint

    def test_mb_publishes_its_generators(self):
        p, endpoint = self._spawn("mb_server.py", seed=31)
        host, port = endpoint.rsplit(":", 1)

        async def check():
            from pymodbus.client import AsyncModbusTcpClient
            c = AsyncModbusTcpClient(host, port=int(port))
            await c.connect()
            try:
                # One PDU carries hr 0..16 — atomic w.r.t. the tick loop.
                hr = (await c.read_holding_registers(0, count=17)).registers
                tick = hr[14]
                self.assertEqual(hr[13], MB.gen_scaled(31, tick))
                self.assertEqual(hr[12], MB.gen_packed(31, tick))
                self.assertEqual(
                    hr[0], MB.encode_words(MB.gen_huint16(31, tick), "uint16", "abcd")[0])
                self.assertEqual(hr[16], MB.gen_dead(31))
            finally:
                c.close()

        asyncio.run(check())

    def test_mb_replica_block_publishes_derived_seed(self):
        p, endpoint = self._spawn("mb_server.py", seed=7, extra=["--replicate", "2"])
        host, port = endpoint.rsplit(":", 1)

        async def check():
            from pymodbus.client import AsyncModbusTcpClient
            c = AsyncModbusTcpClient(host, port=int(port))
            await c.connect()
            try:
                base = MB.BLOCK_HR
                hr = (await c.read_holding_registers(base, count=17)).registers
                tick = hr[14]                      # replica 1's Counter16
                s1 = UA.replica_seed(7, 1)
                self.assertEqual(hr[13], MB.gen_scaled(s1, tick))
                self.assertEqual(hr[16], MB.gen_dead(s1))
            finally:
                c.close()

        asyncio.run(check())

    def test_ua_replica_nodes_publish_derived_seed(self):
        p, endpoint = self._spawn("ua_server.py", seed=11, extra=["--replicate", "2"])

        async def check():
            from asyncua import Client, ua
            async with Client(endpoint) as c:
                idx = 2
                def nid(n): return ua.NodeId(f"ua00.{n}", idx)
                s1 = UA.replica_seed(11, 1)
                for _ in range(10):
                    c1 = await c.get_node(nid("Counter_c1")).read_value()
                    i16 = await c.get_node(nid("Int16_c1")).read_value()
                    s = await c.get_node(nid("StringUtf8_c1")).read_value()
                    c2 = await c.get_node(nid("Counter_c1")).read_value()
                    if c1 == c2:
                        self.assertEqual(i16, UA.gen_int16(s1, c1))
                        self.assertEqual(s, UA.gen_string_utf8(s1, c1))
                        return
                self.fail("Counter_c1 never stable across reads")

        asyncio.run(check())

    def test_ua_publishes_its_generators_and_kill_is_real(self):
        p, endpoint = self._spawn("ua_server.py", seed=17)

        async def check():
            from asyncua import Client, ua
            async with Client(endpoint) as c:
                idx = 2
                def nid(n): return ua.NodeId(f"ua00.{n}", idx)
                # Retry until Counter is stable across the surrounding reads —
                # that is the race-free way to pin a tick.
                for _ in range(10):
                    c1 = await c.get_node(nid("Counter")).read_value()
                    i16 = await c.get_node(nid("Int16")).read_value()
                    s = await c.get_node(nid("StringUtf8")).read_value()
                    c2 = await c.get_node(nid("Counter")).read_value()
                    if c1 == c2:
                        self.assertEqual(i16, UA.gen_int16(17, c1))
                        self.assertEqual(s, UA.gen_string_utf8(17, c1))
                        return
                self.fail("Counter never stable across reads")

        asyncio.run(check())

        # The kill lever: SIGKILL, then the port must stop accepting.
        host, port = endpoint.replace("opc.tcp://", "").rsplit(":", 1)
        p.send_signal(signal.SIGKILL)
        p.wait(timeout=10)
        deadline = time.time() + 5
        refused = False
        while time.time() < deadline:
            try:
                s = socket.create_connection((host, int(port)), timeout=0.5)
                s.close()
                time.sleep(0.2)
            except OSError:
                refused = True
                break
        self.assertTrue(refused, "killed server's port still answers")


if __name__ == "__main__":
    unittest.main()
