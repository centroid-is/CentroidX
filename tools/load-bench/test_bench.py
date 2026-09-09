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

    def _spawn(self, script, seed):
        p = subprocess.Popen(
            [PY, os.path.join(HERE, script), "--count", "1", "--seed", str(seed),
             "--hz", "5"],
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
