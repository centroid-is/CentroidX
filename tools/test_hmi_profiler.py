#!/usr/bin/env python3
"""Tests for tools/hmi_profiler.py.

    python3 -m unittest discover -s tools -p 'test_*.py'

The websocket client is hand-rolled, so it gets an end-to-end test against a
real loopback server that speaks enough of RFC 6455 to answer it — including
the fragmentation and >64 KiB payloads that a CPU-sample response actually
hits in practice.
"""

import base64
import collections
import hashlib
import json
import os
import shutil
import socket
import struct
import tempfile
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hmi_profiler as hp  # noqa: E402


# --------------------------------------------------------------------------
# A server that speaks just enough websocket to answer our client.
# --------------------------------------------------------------------------


class FakeVmServer(threading.Thread):
    """Serves one connection; replies to JSON-RPC from a canned script."""

    def __init__(self, handler, fragment=False):
        super().__init__(daemon=True)
        self._handler = handler
        self._fragment = fragment
        self._listener = socket.socket()
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(1)
        self.port = self._listener.getsockname()[1]
        self.error = None
        self.conn = None

    @property
    def url(self):
        return f"ws://127.0.0.1:{self.port}/ws"

    def run(self):
        try:
            self.conn, _ = self._listener.accept()
            self._handshake()
            self._handler(self)
        except Exception as exc:  # surfaced by the test through self.error
            self.error = exc
        finally:
            if self.conn:
                self.conn.close()
            self._listener.close()

    def _handshake(self):
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.conn.recv(4096)
            if not chunk:
                raise AssertionError("client hung up during handshake")
            request += chunk
        key = ""
        for line in request.decode("latin-1").split("\r\n"):
            name, _, value = line.partition(":")
            if name.strip().lower() == "sec-websocket-key":
                key = value.strip()
        accept = base64.b64encode(
            hashlib.sha1((key + hp._WS_GUID).encode()).digest()
        ).decode()
        self.conn.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode()
        )

    # -- framing ----------------------------------------------------------

    def _recv_exactly(self, count):
        buf = b""
        while len(buf) < count:
            chunk = self.conn.recv(count - len(buf))
            if not chunk:
                raise AssertionError("client hung up")
            buf += chunk
        return buf

    def recv_json(self):
        while True:
            first = self._recv_exactly(1)[0]
            opcode = first & 0x0F
            second = self._recv_exactly(1)[0]
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._recv_exactly(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._recv_exactly(8))[0]
            mask = self._recv_exactly(4) if second & 0x80 else None
            payload = self._recv_exactly(length) if length else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x1:
                return json.loads(payload)
            if opcode == 0x8:
                raise AssertionError("client closed")

    def _frame(self, opcode, payload, fin=True):
        header = bytearray([(0x80 if fin else 0x00) | opcode])
        length = len(payload)
        if length < 126:
            header.append(length)
        elif length < 1 << 16:
            header.append(126)
            header += struct.pack(">H", length)
        else:
            header.append(127)
            header += struct.pack(">Q", length)
        return bytes(header) + payload

    def send_json(self, message):
        payload = json.dumps(message).encode()
        if self._fragment and len(payload) > 8:
            half = len(payload) // 2
            self.conn.sendall(self._frame(0x1, payload[:half], fin=False))
            self.conn.sendall(self._frame(0x0, payload[half:], fin=True))
        else:
            self.conn.sendall(self._frame(0x1, payload))

    def send_ping(self):
        self.conn.sendall(self._frame(0x9, b"hi"))


def serve(handler, fragment=False):
    server = FakeVmServer(handler, fragment=fragment)
    server.start()
    return server


# --------------------------------------------------------------------------


class WebSocketTransportTest(unittest.TestCase):
    def test_round_trip(self):
        def handler(server):
            request = server.recv_json()
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {"major": 4}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            self.assertEqual(service.call("getVersion"), {"major": 4})
        finally:
            service.close()
        server.join(5)
        self.assertIsNone(server.error)

    def test_fragmented_and_large_messages(self):
        payload = {"blob": "x" * 200_000}

        def handler(server):
            request = server.recv_json()
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": payload})

        server = serve(handler, fragment=True)
        service = hp.VmService.connect(server.url)
        try:
            self.assertEqual(service.call("getVM"), payload)
        finally:
            service.close()
        server.join(5)
        self.assertIsNone(server.error)

    def test_answers_ping_while_waiting(self):
        def handler(server):
            request = server.recv_json()
            server.send_ping()
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            self.assertEqual(service.call("getVersion"), {"ok": True})
        finally:
            service.close()
        server.join(5)
        self.assertIsNone(server.error)

    def test_events_arriving_before_the_response_are_kept(self):
        def handler(server):
            request = server.recv_json()
            server.send_json(
                {
                    "jsonrpc": "2.0",
                    "method": "streamNotify",
                    "params": {
                        "streamId": "Extension",
                        "event": {"extensionKind": "Flutter.Frame", "extensionData": {"build": 1}},
                    },
                }
            )
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            service.call("getVersion")
            self.assertEqual(len(service.events), 1)
            self.assertEqual(service.events[0]["extensionKind"], "Flutter.Frame")
        finally:
            service.close()
        server.join(5)

    def test_error_response_raises_but_try_call_swallows_it(self):
        def handler(server):
            for _ in range(2):
                request = server.recv_json()
                server.send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "error": {"code": 112, "message": "Cannot get CPU samples"},
                    }
                )

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            with self.assertRaises(hp.VmServiceError):
                service.call("getCpuSamples")
            self.assertIsNone(service.try_call("getCpuSamples"))
        finally:
            service.close()
        server.join(5)

    def test_connect_failure_is_a_profiler_error(self):
        # Port 1 on loopback refuses connections; no wait, so it gives up at once.
        with self.assertRaises(hp.ProfilerError):
            hp.VmService.connect("ws://127.0.0.1:1/ws")

    def test_reconnect_replaces_the_socket_in_place(self):
        def handler(server):
            request = server.recv_json()
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {"ok": 1}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            service.call("getVersion")
            # Nothing is listening on port 1, so reconnect gives up cleanly
            # instead of leaving a half-open service behind.
            with self.assertRaises(hp.ProfilerError):
                service.reconnect("ws://127.0.0.1:1/ws")
        finally:
            service.close()

    def test_rejects_a_non_websocket_url(self):
        with self.assertRaises(hp.ProfilerError):
            hp.WebSocket("http://127.0.0.1:1/")


class CollectFramesTest(unittest.TestCase):
    def test_subscribes_collects_and_unsubscribes(self):
        seen = []

        def handler(server):
            request = server.recv_json()  # streamListen
            seen.append(request["method"])
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {}})
            for build in (2000, 40000):
                server.send_json(
                    {
                        "jsonrpc": "2.0",
                        "method": "streamNotify",
                        "params": {
                            "streamId": "Extension",
                            "event": {
                                "extensionKind": "Flutter.Frame",
                                "extensionData": {"build": build, "raster": 1000},
                            },
                        },
                    }
                )
            # An unrelated extension event must not be counted as a frame.
            server.send_json(
                {
                    "jsonrpc": "2.0",
                    "method": "streamNotify",
                    "params": {
                        "streamId": "Extension",
                        "event": {"extensionKind": "Flutter.Navigation", "extensionData": {}},
                    },
                }
            )
            request = server.recv_json()  # streamCancel
            seen.append(request["method"])
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            frames = hp.collect_frames(service, 0.3)
        finally:
            service.close()
        server.join(5)
        self.assertIsNone(server.error)
        self.assertEqual(seen, ["streamListen", "streamCancel"])
        self.assertEqual([f["build"] for f in frames], [2000, 40000])
        self.assertEqual(hp.frame_stats(frames)["janky"], 1)


class GatherTest(unittest.TestCase):
    class _Args:
        pass

    def test_one_unavailable_section_does_not_lose_the_others(self):
        calls = []

        def failing():
            calls.append("cpu")
            raise hp.VmServiceError("getCpuSamples", {"message": "Feature is disabled"})

        def working():
            calls.append("memory")

        problems = []

        # Exercised through the same shape gather() uses.
        def attempt(section, work):
            try:
                work()
            except hp.ConnectionClosed:
                raise
            except (hp.ProfilerError, TimeoutError) as exc:
                problems.append(f"{section}: {exc}")

        attempt("cpu", failing)
        attempt("memory", working)
        self.assertEqual(calls, ["cpu", "memory"])
        self.assertEqual(len(problems), 1)
        self.assertIn("Feature is disabled", problems[0])

    def test_gather_reports_a_dead_section_and_keeps_going(self):
        def handler(server):
            while True:
                request = server.recv_json()
                method = request["method"]
                if method == "getVM":
                    result = {"isolates": [{"id": "isolates/1", "name": "main"}]}
                elif method == "getVersion":
                    result = {"major": 4, "minor": 20}
                elif method in ("clearCpuSamples", "getCpuSamples"):
                    server.send_json(
                        {
                            "jsonrpc": "2.0",
                            "id": request["id"],
                            "error": {"code": 100, "message": "Feature is disabled"},
                        }
                    )
                    continue
                elif method == "getMemoryUsage":
                    result = {"heapUsage": 1_000_000, "heapCapacity": 2_000_000}
                elif method == "getAllocationProfile":
                    result = {
                        "members": [{"class": {"name": "Foo"}, "bytesCurrent": 10, "instancesCurrent": 1}]
                    }
                else:
                    result = {"type": "Success"}
                server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            data = hp.gather(service, 0.0, 5, want=("cpu", "memory"))
        finally:
            service.close()
        self.assertEqual(data["cpu"]["samples"], 0)
        self.assertEqual(data["memory_classes"][0]["name"], "Foo")
        self.assertEqual(len(data["problems"]), 1)
        self.assertIn("cpu:", data["problems"][0])

    def test_a_dropped_connection_stops_the_whole_window(self):
        def handler(server):
            request = server.recv_json()  # getVM
            server.send_json(
                {
                    "jsonrpc": "2.0",
                    "id": request["id"],
                    "result": {"isolates": [{"id": "isolates/1", "name": "main"}]},
                }
            )
            request = server.recv_json()  # getVersion
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {}})
            server.conn.close()  # the app goes away mid-window

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            with self.assertRaises(hp.ConnectionClosed):
                hp.gather(service, 0.0, 5, want=("cpu", "memory"))
        finally:
            service.close()


class EnableProfilerTest(unittest.TestCase):
    """The sampling profiler is switched on over the service, before sampling.

    The backend's `-profile` image runs under `dart run`, which starts the
    standalone VM with the profiler off and no command-line way to turn it
    on; DevTools sets the `profiler` flag on attach, and so do we. Both
    collectors have to do it, and before `clearCpuSamples`, or the first
    window of a report against a fresh backend is always empty.
    """

    def serve_recording(self, clock=(1_000_000, 3_000_000)):
        self.seen = []
        clock_values = list(clock)

        def handler(server):
            while True:
                request = server.recv_json()
                method = request["method"]
                params = request.get("params", {})
                self.seen.append((method, params))
                if method == "getVMTimelineMicros":
                    result = {"timestamp": clock_values.pop(0) if clock_values else 0}
                elif method == "getCpuSamples":
                    result = {"samplePeriod": 250, "functions": [], "samples": []}
                else:
                    result = {"type": "Success"}
                server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

        server = serve(handler)
        return hp.VmService.connect(server.url)

    def assert_profiler_enabled_before_clearing(self):
        methods = [method for method, _ in self.seen]
        flags = [params for method, params in self.seen if method == "setFlag"]
        self.assertIn({"name": "profiler", "value": "true"}, flags)
        self.assertLess(methods.index("setFlag"), methods.index("clearCpuSamples"))

    def test_collect_window_turns_the_profiler_on_first(self):
        service = self.serve_recording()
        try:
            hp.collect_window(service, "isolates/1", 0.0)
        finally:
            service.close()
        self.assert_profiler_enabled_before_clearing()

    def test_collect_cpu_multi_turns_the_profiler_on_first(self):
        service = self.serve_recording()
        try:
            hp.collect_cpu_multi(
                service, [{"id": "isolates/1", "name": "main", "number": "1"}], 0.0, 250, top=5
            )
        finally:
            service.close()
        self.assert_profiler_enabled_before_clearing()

    def test_a_vm_that_refuses_the_flag_still_gets_sampled(self):
        # A refused setFlag is the VM's problem to report through getCpuSamples,
        # not a reason to abandon the window: try_call swallows it and the
        # clear/sample pair still goes out.
        def handler(server):
            while True:
                request = server.recv_json()
                method = request["method"]
                if method == "setFlag":
                    server.send_json(
                        {
                            "jsonrpc": "2.0",
                            "id": request["id"],
                            "error": {"code": 102, "message": "Cannot set flag"},
                        }
                    )
                    continue
                if method == "getCpuSamples":
                    result = {"samplePeriod": 250, "functions": [], "samples": []}
                elif method == "getVMTimelineMicros":
                    result = {"timestamp": 0}
                else:
                    result = {"type": "Success"}
                server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            window = hp.collect_window(service, "isolates/1", 0.0)
        finally:
            service.close()
        self.assertEqual(window["cpu"]["samples"], [])


class MainIsolateTest(unittest.TestCase):
    def test_prefers_the_isolate_named_main(self):
        def handler(server):
            request = server.recv_json()
            server.send_json(
                {
                    "jsonrpc": "2.0",
                    "id": request["id"],
                    "result": {
                        "isolates": [
                            {"id": "isolates/7", "name": "worker"},
                            {"id": "isolates/1", "name": "main"},
                        ]
                    },
                }
            )

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            self.assertEqual(service.main_isolate(), "isolates/1")
        finally:
            service.close()

    def test_no_isolates_is_an_error(self):
        def handler(server):
            request = server.recv_json()
            server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": {"isolates": []}})

        server = serve(handler)
        service = hp.VmService.connect(server.url)
        try:
            with self.assertRaises(hp.ProfilerError):
                service.main_isolate()
        finally:
            service.close()


#: What `getVM` reports on a station: one `main`, one worker, and seven OPC UA
#: clients that all answer to the same name. The numbers are 64-bit randoms,
#: copied in shape from 10.104.60.81 — which is exactly why the labels index
#: rather than number.
_STATION_NUMBERS = [
    "5607576650870723",
    "3975690221634659",
    "3292723241152127",
    "3709576604754131",
    "5433281937290743",
    "534454051032775",
    "241244344469503",
    "7879263934861371",
    "1156428723197779",
]
_STATION_NAMES = ["main", "PdfrxEngineWorker"] + ["_isolateEntryPoint"] * 7
STATION_ISOLATES = [
    {"id": f"isolates/{number}", "name": name, "number": number}
    for name, number in zip(_STATION_NAMES, _STATION_NUMBERS)
]


class SelectIsolatesTest(unittest.TestCase):
    def test_nothing_selected_is_main_as_it_always_was(self):
        chosen = hp.select_isolates(STATION_ISOLATES, None)
        self.assertEqual([i["name"] for i in chosen], ["main"])

    def test_blank_selector_is_also_main(self):
        self.assertEqual(hp.select_isolates(STATION_ISOLATES, "  ")[0]["name"], "main")

    def test_main_falls_back_to_the_first_isolate(self):
        isolates = [{"id": "isolates/5", "name": "worker", "number": "5"}]
        self.assertEqual(hp.select_isolates(isolates, None)[0]["id"], "isolates/5")

    def test_all_takes_every_isolate_in_vm_order(self):
        chosen = hp.select_isolates(STATION_ISOLATES, "all")
        self.assertEqual([i["id"] for i in chosen], [i["id"] for i in STATION_ISOLATES])

    def test_a_name_substring_takes_all_seven_clients(self):
        chosen = hp.select_isolates(STATION_ISOLATES, "entryPoint")
        self.assertEqual(len(chosen), 7)
        self.assertEqual({i["name"] for i in chosen}, {"_isolateEntryPoint"})

    def test_a_bare_integer_is_the_vm_isolate_number_not_the_index(self):
        chosen = hp.select_isolates(STATION_ISOLATES, _STATION_NUMBERS[1])
        self.assertEqual(chosen[0]["name"], "PdfrxEngineWorker")
        # ...and a small integer that is nobody's number is an error, not
        # a quietly-reinterpreted index.
        with self.assertRaises(hp.ProfilerError):
            hp.select_isolates(STATION_ISOLATES, "1")

    def test_hash_is_the_index_into_the_vm_list(self):
        chosen = hp.select_isolates(STATION_ISOLATES, "#1")
        self.assertEqual(chosen[0]["number"], _STATION_NUMBERS[1])
        self.assertEqual(hp.isolate_label(chosen[0]), "PdfrxEngineWorker#1")

    def test_a_full_isolate_id_matches(self):
        chosen = hp.select_isolates(STATION_ISOLATES, f"isolates/{_STATION_NUMBERS[4]}")
        self.assertEqual(hp.isolate_label(chosen[0]), "_isolateEntryPoint#4")

    def test_terms_union_in_the_order_given_without_repeating(self):
        chosen = hp.select_isolates(STATION_ISOLATES, "main,all,main")
        self.assertEqual(chosen[0]["name"], "main")
        self.assertEqual(len(chosen), len(STATION_ISOLATES))

    def test_no_match_names_what_is_available(self):
        with self.assertRaises(hp.ProfilerError) as caught:
            hp.select_isolates(STATION_ISOLATES, "raster")
        self.assertIn("PdfrxEngineWorker", str(caught.exception))

    def test_an_index_past_the_end_is_an_error(self):
        with self.assertRaises(hp.ProfilerError):
            hp.select_isolates(STATION_ISOLATES, "#99")

    def test_no_isolates_is_an_error(self):
        with self.assertRaises(hp.ProfilerError):
            hp.select_isolates([], "all")

    def test_labels_disambiguate_the_seven_that_share_a_name(self):
        labels = [hp.isolate_label(i) for i in hp.index_isolates(STATION_ISOLATES)]
        self.assertEqual(len(set(labels)), len(labels))
        self.assertIn("_isolateEntryPoint#5", labels)

    def test_a_label_without_an_index_or_number_is_just_the_name(self):
        self.assertEqual(hp.isolate_label({"name": "main"}), "main")

    def test_describing_a_subset_keeps_the_indices_you_would_type(self):
        chosen = hp.select_isolates(STATION_ISOLATES, "entryPoint")
        described = hp.describe_isolates(chosen)
        self.assertIn("_isolateEntryPoint#2", described)
        self.assertIn("_isolateEntryPoint#8", described)
        self.assertNotIn("#0", described)


class OneIsolateTest(unittest.TestCase):
    def test_a_single_match_passes_through(self):
        self.assertEqual(
            hp.isolate_label(hp.one_isolate(STATION_ISOLATES, "#3", "report")),
            "_isolateEntryPoint#3",
        )

    def test_an_ambiguous_selector_is_refused_rather_than_guessed(self):
        with self.assertRaises(hp.ProfilerError) as caught:
            hp.one_isolate(STATION_ISOLATES, "entryPoint", "report")
        message = str(caught.exception)
        self.assertIn("matched 7", message)
        self.assertIn("report", message)

    def test_the_default_is_still_main(self):
        self.assertEqual(hp.one_isolate(STATION_ISOLATES, None, "watch")["name"], "main")


class ClipSamplesTest(unittest.TestCase):
    def payload(self, stamps):
        return {"samples": [{"timestamp": s, "stack": [0]} for s in stamps]}

    def test_samples_after_the_window_are_dropped(self):
        # The trailing one is the profiler's own getCpuSamples RPC.
        clipped, dropped = hp.clip_samples(self.payload([100, 200, 5_000]), (50, 300))
        self.assertEqual(dropped, 1)
        self.assertEqual([s["timestamp"] for s in clipped["samples"]], [100, 200])

    def test_samples_before_the_window_are_dropped(self):
        clipped, dropped = hp.clip_samples(self.payload([10, 100]), (50, 300))
        self.assertEqual(dropped, 1)

    def test_no_window_keeps_everything(self):
        payload = self.payload([1, 2, 3])
        clipped, dropped = hp.clip_samples(payload, None)
        self.assertEqual(dropped, 0)
        self.assertIs(clipped, payload)

    def test_a_sample_with_no_timestamp_is_kept_not_silently_deleted(self):
        payload = {"samples": [{"stack": [0]}]}
        clipped, dropped = hp.clip_samples(payload, (50, 300))
        self.assertEqual(dropped, 0)
        self.assertEqual(len(clipped["samples"]), 1)

    def test_the_original_payload_is_not_mutated(self):
        payload = self.payload([100, 5_000])
        hp.clip_samples(payload, (50, 300))
        self.assertEqual(len(payload["samples"]), 2)


class MultiIsolateCpuTest(unittest.TestCase):
    """`cpu --isolate all` end to end, against the loopback VM."""

    ISOLATES = [
        {"id": "isolates/1", "name": "main", "number": "1"},
        {"id": "isolates/2", "name": "_isolateEntryPoint", "number": "2"},
        {"id": "isolates/3", "name": "_isolateEntryPoint", "number": "3"},
    ]

    def serve_vm(self, samples_by_isolate, clock=(1_000_000, 3_000_000)):
        self.cleared = []
        self.sampled = []
        clock_values = list(clock)

        def handler(server):
            while True:
                request = server.recv_json()
                method = request["method"]
                params = request.get("params", {})
                if method == "getVM":
                    result = {"isolates": self.ISOLATES}
                elif method == "getVMTimelineMicros":
                    result = {"timestamp": clock_values.pop(0) if clock_values else 0}
                elif method == "clearCpuSamples":
                    self.cleared.append(params["isolateId"])
                    result = {"type": "Success"}
                elif method == "getCpuSamples":
                    self.sampled.append(params["isolateId"])
                    result = {
                        "samplePeriod": 250,
                        "functions": SAMPLE_FUNCTIONS,
                        "samples": samples_by_isolate[params["isolateId"]],
                    }
                else:
                    result = {"type": "Success"}
                server.send_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

        server = serve(handler)
        return hp.VmService.connect(server.url)

    def test_one_window_covers_every_isolate_and_costs_them_separately(self):
        inside = 2_000_000
        service = self.serve_vm(
            {
                "isolates/1": [{"timestamp": inside, "stack": [1]}] * 4,
                "isolates/2": [{"timestamp": inside, "stack": [0]}] * 8,
                # The trailing sample is this isolate answering our own RPC:
                # a nameless native leaf, taken after the window closed.
                "isolates/3": [{"timestamp": inside, "stack": [0]}] * 2
                + [{"timestamp": 9_000_000, "stack": [2]}] * 40,
            }
        )
        try:
            isolates = hp.select_isolates(service.isolates(), "all")
            collected = hp.collect_cpu_multi(service, isolates, 0.0, 250, top=5)
        finally:
            service.close()

        # Every isolate is cleared before the sleep, none after.
        self.assertEqual(self.cleared, [i["id"] for i in self.ISOLATES])
        self.assertEqual(self.sampled, [i["id"] for i in self.ISOLATES])
        # The raw rings are folded and released as we go; a 512 MB sidecar
        # cannot hold nine of a station's at once.
        self.assertNotIn("payload", collected["entries"][0])

        summary = hp.summarise_isolate_cpu(collected)
        by_label = {row["label"]: row for row in summary["isolates"]}
        self.assertEqual(
            sorted(by_label), ["_isolateEntryPoint#1", "_isolateEntryPoint#2", "main#0"]
        )
        self.assertEqual(by_label["_isolateEntryPoint#1"]["samples"], 8)
        # 40 self-observation samples clipped, 2 real ones left.
        self.assertEqual(by_label["_isolateEntryPoint#2"]["samples"], 2)
        self.assertEqual(by_label["_isolateEntryPoint#2"]["dropped_samples"], 40)
        self.assertEqual(summary["total_samples"], 14)
        self.assertAlmostEqual(by_label["main#0"]["share_percent"], 100 * 4 / 14.0)
        # 8 samples x 250 µs = 2 ms of CPU.
        self.assertAlmostEqual(by_label["_isolateEntryPoint#1"]["cpu_ms"], 2.0)

    def test_idle_samples_are_counted_but_never_folded(self):
        # An idle isolate's stack is the futex its thread is parked in. Left
        # in, it is 67 % of a station OPC UA isolate's "self time".
        busy = {"timestamp": 2_000_000, "vmTag": "Dart", "stack": [0]}
        idle = {"timestamp": 2_000_000, "vmTag": "Idle", "stack": [2]}
        service = self.serve_vm(
            {
                "isolates/1": [busy] * 4,
                "isolates/2": [busy] * 1 + [idle] * 9,
                "isolates/3": [idle] * 8,
            }
        )
        try:
            isolates = hp.select_isolates(service.isolates(), "all")
            collected = hp.collect_cpu_multi(service, isolates, 0.0, 250)
        finally:
            service.close()
        rows = {r["label"]: r for r in hp.summarise_isolate_cpu(collected)["isolates"]}

        parked = rows["_isolateEntryPoint#1"]
        self.assertEqual(parked["samples"], 10)
        self.assertEqual(parked["idle_samples"], 9)
        self.assertEqual(parked["busy_samples"], 1)
        self.assertAlmostEqual(parked["idle_percent"], 90.0)
        # memcpy is the idle stack's leaf here; it must not reach any table.
        self.assertNotIn(
            "memcpy", [row["name"] for row in parked["folded"]["self"]]
        )
        self.assertEqual(parked["vm_tags"], {"Idle": 9, "Dart": 1})

        # A wholly idle isolate costs nothing and says so.
        self.assertEqual(rows["_isolateEntryPoint#2"]["cpu_ms"], 0.0)
        self.assertEqual(rows["_isolateEntryPoint#2"]["core_percent"], 0.0)
        # Shares are of busy time, so idle cannot dilute anybody.
        self.assertAlmostEqual(rows["main#0"]["share_percent"], 80.0)

    def test_a_vm_that_reports_no_tag_loses_nothing(self):
        payload = {"samples": [{"stack": [0]}] * 3}
        self.assertEqual(hp.fold_vm_tags(payload), {"unknown": 3})

    def test_the_rendered_section_says_how_much_was_slept_through(self):
        entry = self.entry(hp.index_isolates(self.ISOLATES)[0], samples=4)
        entry["samples"] = 10
        entry["vm_tags"] = collections.Counter({"Idle": 6, "Dart": 4})
        body = hp.render_isolate_cpu(
            hp.summarise_isolate_cpu({"elapsed_s": 1.0, "entries": [entry]})
        )
        self.assertIn("10 samples, 6 of them idle", body)
        self.assertIn("Idle 6", body)

    @staticmethod
    def entry(isolate, samples, period=250, dropped=0):
        """The shape [collect_cpu_multi] hands to [summarise_isolate_cpu]."""
        payload = {
            "samplePeriod": period,
            "functions": SAMPLE_FUNCTIONS,
            "samples": [{"stack": [0]}] * samples,
        }
        return {
            "isolate": isolate,
            "label": hp.isolate_label(isolate),
            "id": isolate["id"],
            "sample_period_us": period,
            "dropped_samples": dropped,
            "folded": hp.fold_cpu_samples(payload),
            "tree": hp.build_call_tree(SAMPLE_FUNCTIONS, payload["samples"]),
        }

    def test_the_core_percentage_divides_by_the_measured_window(self):
        collected = {
            "elapsed_s": 2.0,
            "entries": [self.entry(self.ISOLATES[0], samples=1000, period=1000)],
        }
        row = hp.summarise_isolate_cpu(collected)["isolates"][0]
        # 1000 samples x 1000 µs = 1 s of CPU in a 2 s window.
        self.assertAlmostEqual(row["core_percent"], 50.0)

    def test_an_empty_window_does_not_divide_by_zero(self):
        collected = {"elapsed_s": 0.0, "entries": []}
        summary = hp.summarise_isolate_cpu(collected)
        self.assertEqual(summary["total_samples"], 0)
        self.assertEqual(summary["isolates"], [])

    def test_the_rendered_table_names_each_isolate_and_the_clipping(self):
        indexed = hp.index_isolates(self.ISOLATES)
        collected = {
            "elapsed_s": 1.0,
            "entries": [
                self.entry(iso, samples=1, dropped=3 if iso["vm_index"] == 2 else 0)
                for iso in indexed
            ],
        }
        body = hp.render_isolate_cpu(hp.summarise_isolate_cpu(collected))
        self.assertIn("_isolateEntryPoint#1", body)
        self.assertIn("_isolateEntryPoint#2", body)
        self.assertIn("3 samples fell outside the window", body)
        self.assertIn("ConveyorPainter.paint", body)

    def test_a_single_isolate_gets_no_summary_table(self):
        collected = {"elapsed_s": 1.0, "entries": [self.entry(self.ISOLATES[0], samples=1)]}
        body = hp.render_isolate_cpu(hp.summarise_isolate_cpu(collected))
        self.assertNotIn("### Isolates", body)


# --------------------------------------------------------------------------
# Analysis
# --------------------------------------------------------------------------


SAMPLE_FUNCTIONS = [
    {
        "resolvedUrl": "package:tfc/page_creator/assets/conveyor.dart",
        "function": {"name": "paint", "owner": {"type": "@Class", "name": "ConveyorPainter"}},
    },
    {
        "resolvedUrl": "package:flutter/src/rendering/object.dart",
        "function": {"name": "_paintWithContext", "owner": {"type": "@Class", "name": "RenderObject"}},
    },
    {"resolvedUrl": "", "function": {"name": "memcpy"}},
]


class FunctionLabelTest(unittest.TestCase):
    def test_qualifies_with_the_owning_class(self):
        self.assertEqual(
            hp.function_label(SAMPLE_FUNCTIONS, 0), "ConveyorPainter.paint [conveyor.dart]"
        )

    def test_unresolved_url_reads_as_native(self):
        self.assertEqual(hp.function_label(SAMPLE_FUNCTIONS, 2), "memcpy [native]")

    def test_out_of_range_index_does_not_raise(self):
        self.assertEqual(hp.function_label(SAMPLE_FUNCTIONS, 99), "???")
        self.assertEqual(hp.function_label(SAMPLE_FUNCTIONS, None), "???")

    def test_package_grouping(self):
        self.assertEqual(hp.package_of(SAMPLE_FUNCTIONS, 0), "tfc")
        self.assertEqual(hp.package_of(SAMPLE_FUNCTIONS, 1), "flutter")
        self.assertEqual(hp.package_of(SAMPLE_FUNCTIONS, 2), "native")


class FoldCpuSamplesTest(unittest.TestCase):
    def payload(self, stacks):
        return {
            "samplePeriod": 250,
            "timeExtentMicros": 1_000_000,
            "functions": SAMPLE_FUNCTIONS,
            "samples": [{"stack": stack} for stack in stacks],
        }

    def test_self_time_counts_only_the_leaf(self):
        folded = hp.fold_cpu_samples(self.payload([[0, 1], [0, 1], [1]]))
        self_by_name = {row["name"]: row["samples"] for row in folded["self"]}
        self.assertEqual(self_by_name["ConveyorPainter.paint [conveyor.dart]"], 2)
        self.assertEqual(self_by_name["RenderObject._paintWithContext [object.dart]"], 1)

    def test_inclusive_time_counts_a_recursive_frame_once(self):
        folded = hp.fold_cpu_samples(self.payload([[1, 1, 1, 0]]))
        inclusive = {row["name"]: row["samples"] for row in folded["inclusive"]}
        self.assertEqual(inclusive["RenderObject._paintWithContext [object.dart]"], 1)

    def test_empty_stacks_are_skipped_and_do_not_divide_by_zero(self):
        folded = hp.fold_cpu_samples(self.payload([[], []]))
        self.assertEqual(folded["samples"], 0)
        self.assertEqual(folded["self"], [])

    def test_missing_payload_is_tolerated(self):
        folded = hp.fold_cpu_samples({})
        self.assertEqual(folded["samples"], 0)

    def test_percentages_are_relative_to_counted_samples(self):
        folded = hp.fold_cpu_samples(self.payload([[0], [0], [1], []]))
        top = folded["self"][0]
        self.assertEqual(top["name"], "ConveyorPainter.paint [conveyor.dart]")
        self.assertAlmostEqual(top["percent"], 200 / 3.0)

    def test_top_limits_rows(self):
        folded = hp.fold_cpu_samples(self.payload([[0], [1], [2]]), top=1)
        self.assertEqual(len(folded["self"]), 1)


class CallTreeTest(unittest.TestCase):
    def tree(self, stacks, functions=None):
        return hp.build_call_tree(
            functions if functions is not None else SAMPLE_FUNCTIONS,
            [{"stack": stack} for stack in stacks],
        )

    def test_builds_root_first_from_a_leaf_first_stack(self):
        # stack [0, 1] means 0 is the leaf and 1 called it.
        tree = self.tree([[0, 1]])
        caller = tree["children"]["RenderObject._paintWithContext [object.dart]"]
        self.assertEqual(caller["total"], 1)
        leaf = caller["children"]["ConveyorPainter.paint [conveyor.dart]"]
        self.assertEqual(leaf["self"], 1)

    def test_self_lands_on_the_leaf_only(self):
        tree = self.tree([[0, 1], [1]])
        caller = tree["children"]["RenderObject._paintWithContext [object.dart]"]
        self.assertEqual(caller["total"], 2)
        self.assertEqual(caller["self"], 1)  # the sample whose leaf IS the caller

    def test_tid_filter(self):
        samples = [{"stack": [0], "tid": 1}, {"stack": [1], "tid": 2}]
        tree = hp.build_call_tree(SAMPLE_FUNCTIONS, samples, tid=2)
        self.assertEqual(tree["total"], 1)
        self.assertIn("RenderObject._paintWithContext [object.dart]", tree["children"])

    def test_dominant_path_follows_the_heaviest_child(self):
        tree = self.tree([[0, 1]] * 9 + [[2, 1]])
        self.assertEqual(
            hp.dominant_path(tree),
            [
                "RenderObject._paintWithContext [object.dart]",
                "ConveyorPainter.paint [conveyor.dart]",
            ],
        )

    def test_dominant_path_stops_at_the_threshold(self):
        tree = self.tree([[0, 1]] + [[1]] * 99)
        # The 1% branch is below the default 5% floor.
        self.assertEqual(hp.dominant_path(tree), ["RenderObject._paintWithContext [object.dart]"])

    def test_empty_tree_renders_a_message_not_a_crash(self):
        self.assertIn("no samples", hp.render_call_tree(hp._tree_node("<all>")))

    def test_render_prunes_below_the_threshold(self):
        tree = self.tree([[0]] * 99 + [[1]])
        rendered = hp.render_call_tree(tree, min_percent=5.0)
        self.assertIn("ConveyorPainter.paint", rendered)
        self.assertNotIn("RenderObject._paintWithContext", rendered)


class RecursionCollapseTest(unittest.TestCase):
    def test_compress_chain_squashes_consecutive_duplicates(self):
        self.assertEqual(hp._compress_chain(["a", "fib", "fib", "fib", "b"]),
                         ["a", "fib x3 deep", "b"])

    def test_compress_chain_leaves_singles_alone(self):
        self.assertEqual(hp._compress_chain(["a", "b", "a"]), ["a", "b", "a"])

    def test_compress_chain_empty(self):
        self.assertEqual(hp._compress_chain([]), [])

    def test_fold_recursion_sums_self_across_the_run(self):
        # fib -> fib -> fib, each with one self tick.
        leaf = hp._tree_node("fib")
        leaf["self"], leaf["total"] = 1, 1
        mid = hp._tree_node("fib")
        mid["self"], mid["total"], mid["children"] = 1, 2, {"fib": leaf}
        top = hp._tree_node("fib")
        top["self"], top["total"], top["children"] = 1, 3, {"fib": mid}
        depth, self_ticks, deepest = hp._fold_recursion(top)
        self.assertEqual((depth, self_ticks), (3, 3))
        self.assertIs(deepest, leaf)

    def test_fold_recursion_stops_at_a_different_name(self):
        other = hp._tree_node("paint")
        other["total"] = 1
        top = hp._tree_node("fib")
        top["total"], top["children"] = 1, {"paint": other}
        depth, _, deepest = hp._fold_recursion(top)
        self.assertEqual(depth, 1)
        self.assertIs(deepest, top)

    def test_a_deep_recursion_renders_as_one_row(self):
        # 30 nested frames of the same function must not become 30 lines.
        stack = [0] * 30
        tree = hp.build_call_tree(SAMPLE_FUNCTIONS, [{"stack": stack}])
        rendered = hp.render_call_tree(tree)
        self.assertEqual(len(rendered.strip().splitlines()), 1)
        self.assertIn("x30 deep", rendered)


class TimelineBlocksTest(unittest.TestCase):
    def test_keeps_each_block_window(self):
        payload = {
            "traceEvents": [
                {"ph": "B", "name": "PAINT", "ts": 100, "pid": 1, "tid": 7},
                {"ph": "E", "name": "PAINT", "ts": 400, "pid": 1, "tid": 7},
                {"ph": "X", "name": "GC", "ts": 500, "dur": 50, "pid": 1, "tid": 7},
            ]
        }
        blocks = hp.timeline_blocks(payload)
        self.assertEqual(
            sorted((b["name"], b["ts"], b["dur"]) for b in blocks),
            [("GC", 500, 50), ("PAINT", 100, 300)],
        )

    def test_unmatched_end_is_ignored(self):
        payload = {"traceEvents": [{"ph": "E", "name": "PAINT", "ts": 9, "pid": 1, "tid": 1}]}
        self.assertEqual(hp.timeline_blocks(payload), [])

    def test_the_profilers_own_getcpusamples_block_is_excluded(self):
        # The regression this guards: `clearCpuSamples` and `getCpuSamples` are
        # isolate-scoped RPCs, so the isolate handles them inside a
        # `DartIsolate::HandleMessage` block. Reported as app behaviour they
        # look like one ~750 ms isolate stall per run, at any window length.
        payload = {
            "traceEvents": [
                # clearCpuSamples, handled before the window opened.
                {"ph": "B", "name": "DartIsolate::HandleMessage", "ts": 500, "pid": 1, "tid": 7},
                {"ph": "E", "name": "DartIsolate::HandleMessage", "ts": 700, "pid": 1, "tid": 7},
                # A real message inside the window.
                {"ph": "B", "name": "DartIsolate::HandleMessage", "ts": 2000, "pid": 1, "tid": 7},
                {"ph": "E", "name": "DartIsolate::HandleMessage", "ts": 2300, "pid": 1, "tid": 7},
                # getCpuSamples, handled after the window closed.
                {"ph": "B", "name": "DartIsolate::HandleMessage", "ts": 9500, "pid": 1, "tid": 7},
                {"ph": "E", "name": "DartIsolate::HandleMessage", "ts": 9500 + 750_000, "pid": 1, "tid": 7},
            ]
        }
        blocks = hp.timeline_blocks(payload, window=(1000, 9000))
        self.assertEqual([(b["ts"], b["dur"]) for b in blocks], [(2000, 300)])

    def test_no_window_keeps_everything(self):
        payload = {
            "traceEvents": [
                {"ph": "X", "name": "GC", "ts": 5, "dur": 50, "pid": 1, "tid": 7},
            ]
        }
        self.assertEqual(len(hp.timeline_blocks(payload, window=None)), 1)

    def test_complete_events_outside_the_window_are_dropped(self):
        payload = {
            "traceEvents": [
                {"ph": "X", "name": "GC", "ts": 5, "dur": 50, "pid": 1, "tid": 7},
                {"ph": "X", "name": "GC", "ts": 5000, "dur": 50, "pid": 1, "tid": 7},
            ]
        }
        blocks = hp.timeline_blocks(payload, window=(1000, 9000))
        self.assertEqual([b["ts"] for b in blocks], [5000])

    def test_a_half_open_window_still_filters(self):
        # `getVMTimelineMicros` answered once but not the other time.
        payload = {
            "traceEvents": [
                {"ph": "X", "name": "GC", "ts": 5, "dur": 50, "pid": 1, "tid": 7},
                {"ph": "X", "name": "GC", "ts": 5000, "dur": 50, "pid": 1, "tid": 7},
            ]
        }
        self.assertEqual(
            [b["ts"] for b in hp.timeline_blocks(payload, window=(1000, None))], [5000]
        )
        self.assertEqual(
            [b["ts"] for b in hp.timeline_blocks(payload, window=(None, 1000))], [5]
        )


class SlowBlockTest(unittest.TestCase):
    def blocks(self, name, durations, tid=1):
        return [
            {"name": name, "tid": tid, "ts": i * 100_000, "dur": d}
            for i, d in enumerate(durations)
        ]

    def test_flags_a_block_far_above_its_own_median(self):
        blocks = self.blocks("RENDER", [1000] * 20 + [50_000])
        slow = hp.find_slow_blocks(blocks)
        self.assertEqual(len(slow), 1)
        self.assertEqual(slow[0]["dur"], 50_000)
        self.assertGreater(slow[0]["ratio"], 3)

    def test_a_uniformly_slow_block_is_not_an_outlier(self):
        # Everything takes 50 ms. That is a hot path, not an outlier, and the
        # CPU section is where it belongs.
        self.assertEqual(hp.find_slow_blocks(self.blocks("RENDER", [50_000] * 20)), [])

    def test_the_floor_suppresses_tiny_blocks_with_huge_ratios(self):
        # 200 us is 20x a 10 us median, and completely irrelevant.
        blocks = self.blocks("TICK", [10] * 20 + [200])
        self.assertEqual(hp.find_slow_blocks(blocks), [])

    def test_a_rare_block_is_judged_against_the_floor_alone(self):
        # Seen twice, so there is no meaningful median — but 300 ms is worth
        # reporting on its own.
        blocks = self.blocks("STARTUP", [1000, 300_000])
        slow = hp.find_slow_blocks(blocks, min_count=5)
        self.assertEqual([b["dur"] for b in slow], [300_000])

    def test_names_are_compared_against_themselves_not_each_other(self):
        blocks = self.blocks("FAST", [100] * 20) + self.blocks("SLOW", [40_000] * 20)
        # SLOW is 400x FAST's median but perfectly consistent for itself.
        self.assertEqual(hp.find_slow_blocks(blocks), [])

    def test_keep_limits_and_orders_by_duration(self):
        blocks = self.blocks("RENDER", [1000] * 20 + [30_000, 90_000, 60_000])
        slow = hp.find_slow_blocks(blocks, keep=2)
        self.assertEqual([b["dur"] for b in slow], [90_000, 60_000])


class SamplesInWindowTest(unittest.TestCase):
    SAMPLES = [
        {"timestamp": 100, "tid": 1, "stack": [0]},
        {"timestamp": 250, "tid": 1, "stack": [1]},
        {"timestamp": 250, "tid": 2, "stack": [1]},
        {"timestamp": 900, "tid": 1, "stack": [0]},
    ]

    def test_selects_by_time(self):
        got = hp.samples_in_window(self.SAMPLES, 200, 300)
        self.assertEqual(len(got), 2)

    def test_selects_by_thread_too(self):
        got = hp.samples_in_window(self.SAMPLES, 200, 300, tid=1)
        self.assertEqual(len(got), 1)

    def test_boundaries_are_inclusive(self):
        self.assertEqual(len(hp.samples_in_window(self.SAMPLES, 100, 100)), 1)

    def test_empty_window(self):
        self.assertEqual(hp.samples_in_window(self.SAMPLES, 400, 500), [])


class SlowRenderTest(unittest.TestCase):
    def test_no_outliers_reads_as_a_good_result(self):
        text = hp.render_slow_blocks([], SAMPLE_FUNCTIONS, [])
        self.assertIn("good result", text)

    def test_a_blocked_window_is_called_out_rather_than_left_blank(self):
        # A block with no samples in it was waiting, not computing — that is a
        # different bug and the report must not imply it was idle CPU.
        slow = [{"name": "IO", "tid": 1, "ts": 0, "dur": 50_000, "median_us": 1000,
                 "ratio": 50.0, "seen": 10}]
        text = hp.render_slow_blocks(slow, SAMPLE_FUNCTIONS, [])
        self.assertIn("blocked, not", text)

    def test_includes_the_stack_from_the_window(self):
        slow = [{"name": "PAINT", "tid": 1, "ts": 0, "dur": 50_000, "median_us": 1000,
                 "ratio": 50.0, "seen": 10}]
        samples = [{"timestamp": 100, "tid": 1, "stack": [0, 1]}]
        text = hp.render_slow_blocks(slow, SAMPLE_FUNCTIONS, samples)
        self.assertIn("ConveyorPainter.paint", text)
        self.assertIn("50.0x", text)


class ActionsTest(unittest.TestCase):
    def base(self):
        return {
            "frames": hp.frame_stats([]),
            "cpu": hp.fold_cpu_samples({}),
            "hot_path": [],
            "slow": [],
        }

    def test_says_so_when_nothing_stands_out(self):
        self.assertIn("Nothing stands out", hp.render_actions(self.base()))

    def test_names_the_bottleneck_thread(self):
        data = self.base()
        data["frames"] = hp.frame_stats(
            [{"build": 1000, "raster": 40_000, "elapsed": 41_000}] * 10
        )
        self.assertIn("raster", hp.render_actions(data))

    def test_compresses_a_recursive_dominant_chain(self):
        data = self.base()
        data["hot_path"] = ["main", "fib", "fib", "fib", "fib", "fib"]
        text = hp.render_actions(data)
        self.assertIn("fib x5 deep", text)


# --------------------------------------------------------------------------
# The view from outside the VM
# --------------------------------------------------------------------------


def docker_stats(usage=200, pre_usage=100, system=10000, pre_system=5000, cpus=4,
                 mem_usage=500_000_000, mem_limit=1_000_000_000, cache=0, pids=42):
    return {
        "cpu_stats": {
            "cpu_usage": {"total_usage": usage},
            "system_cpu_usage": system,
            "online_cpus": cpus,
        },
        "precpu_stats": {
            "cpu_usage": {"total_usage": pre_usage},
            "system_cpu_usage": pre_system,
        },
        "memory_stats": {
            "usage": mem_usage,
            "limit": mem_limit,
            "stats": {"inactive_file": cache},
        },
        "pids_stats": {"current": pids},
    }


class ContainerStatsTest(unittest.TestCase):
    def test_cpu_percent_uses_dockers_own_formula(self):
        # 100/5000 of total system time, across 4 cpus -> 8%.
        self.assertAlmostEqual(hp.container_cpu_percent(docker_stats()), 8.0)

    def test_cpu_percent_falls_back_to_percpu_length(self):
        stats = docker_stats(cpus=None)
        stats["cpu_stats"]["cpu_usage"]["percpu_usage"] = [1, 2]
        self.assertAlmostEqual(hp.container_cpu_percent(stats), 4.0)

    def test_cpu_percent_survives_a_missing_precpu_sample(self):
        stats = docker_stats()
        stats["precpu_stats"] = {}
        self.assertIsNone(hp.container_cpu_percent(stats))

    def test_cpu_percent_of_a_stopped_container_is_zero_not_negative(self):
        self.assertEqual(hp.container_cpu_percent(docker_stats(system=5000, pre_system=5000)), 0.0)

    def test_memory_excludes_page_cache(self):
        used, limit = hp.container_memory(docker_stats(mem_usage=600, mem_limit=1000, cache=100))
        self.assertEqual((used, limit), (500, 1000))

    def test_memory_accepts_the_cgroup_v1_field_name(self):
        stats = docker_stats(mem_usage=600, mem_limit=1000)
        stats["memory_stats"]["stats"] = {"total_inactive_file": 100}
        self.assertEqual(hp.container_memory(stats), (500, 1000))

    def test_memory_of_a_container_with_no_stats(self):
        self.assertEqual(hp.container_memory({"memory_stats": {}}), (None, None))

    def test_summarise_computes_percent_of_limit(self):
        row = hp.summarise_container("flutter", docker_stats(mem_usage=900_000_000))
        self.assertEqual(row["name"], "flutter")
        self.assertAlmostEqual(row["memory_percent"], 90.0)
        self.assertEqual(row["pids"], 42)

    def test_render_warns_when_close_to_the_limit(self):
        rows = [hp.summarise_container("flutter", docker_stats(mem_usage=950_000_000))]
        text = hp.render_containers(rows)
        self.assertIn("OOM kill", text)

    def test_render_without_the_socket_explains_itself(self):
        self.assertIn("Docker socket", hp.render_containers([]))


class FakeProcTest(unittest.TestCase):
    """/proc parsing, against a directory tree shaped like the real thing."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as handle:
            handle.write(text)

    def make_process(self, pid, comm, rss_kb, threads, cmdline=None):
        self.write(f"{pid}/comm", comm + "\n")
        self.write(f"{pid}/cmdline", (cmdline or comm) + "\0")
        self.write(
            f"{pid}/status",
            f"Name:\t{comm}\nVmRSS:\t{rss_kb} kB\nVmSize:\t{rss_kb * 3} kB\n"
            f"Threads:\t{len(threads)}\n",
        )
        for tid, (name, utime, stime) in threads.items():
            self.write(f"{pid}/task/{tid}/comm", name + "\n")
            self.write(
                f"{pid}/task/{tid}/stat",
                f"{tid} ({name}) S 0 1 1 0 -1 4194304 100 0 0 0 {utime} {stime} 0 0 20 0 4 0\n",
            )

    def test_finds_the_app_by_comm(self):
        self.make_process(1, "sh", 100, {1: ("sh", 0, 0)}, cmdline="/bin/sh -c ./centroidx")
        self.make_process(9, "centroidx", 950_000, {9: ("centroidx", 5, 1)})
        # The shell's cmdline mentions centroidx too; comm must win.
        self.assertEqual(hp.find_process(self.root, ("centroidx",)), 9)

    def test_returns_none_without_a_shared_pid_namespace(self):
        self.make_process(1, "python3", 100, {1: ("python3", 0, 0)})
        self.assertIsNone(hp.find_process(self.root, ("centroidx",)))

    def test_missing_proc_root_does_not_raise(self):
        self.assertIsNone(hp.find_process(os.path.join(self.root, "nope"), ("x",)))

    def test_snapshot_reads_rss_and_threads(self):
        self.make_process(
            9, "centroidx", 950_000,
            {9: ("centroidx", 10, 2), 11: ("io.flutter.ui", 400, 20),
             12: ("io.flutter.raster", 30, 3)},
        )
        snapshot = hp.process_snapshot(9, self.root)
        self.assertEqual(snapshot["rss_kb"], 950_000)
        self.assertEqual(snapshot["threads"], 3)
        self.assertEqual(snapshot["thread_detail"]["11"]["name"], "io.flutter.ui")
        self.assertEqual(snapshot["thread_detail"]["11"]["ticks"], 420)

    def test_snapshot_of_a_dead_process(self):
        self.assertIsNone(hp.process_snapshot(999, self.root))

    def test_a_thread_name_with_a_space_does_not_break_stat_parsing(self):
        # comm sits in parens precisely because it can contain spaces; a naive
        # whitespace split of the whole line shifts every field after it.
        self.make_process(9, "centroidx", 100, {9: ("my thread", 77, 3)})
        snapshot = hp.process_snapshot(9, self.root)
        self.assertEqual(snapshot["thread_detail"]["9"]["ticks"], 80)


class ThreadCpuTest(unittest.TestCase):
    def snap(self, threads):
        return {"thread_detail": {tid: {"name": n, "ticks": t} for tid, (n, t) in threads.items()}}

    def test_percent_of_a_core_over_the_window(self):
        before = self.snap({"1": ("io.flutter.ui", 0)})
        after = self.snap({"1": ("io.flutter.ui", 500)})   # 500 ticks = 5 s of cpu
        rows = hp.thread_cpu(before, after, seconds=10.0)
        self.assertAlmostEqual(rows[0]["percent"], 50.0)

    def test_orders_busiest_first(self):
        before = self.snap({"1": ("ui", 0), "2": ("raster", 0)})
        after = self.snap({"1": ("ui", 10), "2": ("raster", 900)})
        self.assertEqual([r["name"] for r in hp.thread_cpu(before, after, 10.0)], ["raster", "ui"])

    def test_a_thread_that_appeared_mid_window_counts_from_zero(self):
        before = self.snap({"1": ("ui", 0)})
        after = self.snap({"1": ("ui", 0), "2": ("worker", 100)})
        rows = {r["name"]: r["percent"] for r in hp.thread_cpu(before, after, 10.0)}
        self.assertAlmostEqual(rows["worker"], 10.0)

    def test_a_recycled_tid_with_a_lower_count_is_skipped_not_negative(self):
        before = self.snap({"1": ("ui", 900)})
        after = self.snap({"1": ("something-else", 5)})
        self.assertEqual(hp.thread_cpu(before, after, 10.0), [])

    def test_the_divisor_is_the_measured_window_not_the_requested_one(self):
        # Collecting container stats takes seconds of its own, so the elapsed
        # time is longer than the requested sleep. Dividing by the request
        # reported one busy thread at 352% of a core against a live container.
        before = self.snap({"1": ("raster", 0)})
        after = self.snap({"1": ("raster", 1400)})       # 14 s of cpu
        self.assertAlmostEqual(hp.thread_cpu(before, after, 4.0)[0]["percent"], 350.0)
        self.assertAlmostEqual(hp.thread_cpu(before, after, 14.0)[0]["percent"], 100.0)

    def test_missing_snapshots(self):
        self.assertEqual(hp.thread_cpu(None, self.snap({}), 10.0), [])
        self.assertEqual(hp.thread_cpu(self.snap({}), self.snap({}), 0), [])

    def test_render_explains_a_missing_pid_namespace(self):
        self.assertIn("PID namespace", hp.render_threads(None, []))

    def test_render_splits_dart_heap_from_native(self):
        snapshot = {"pid": 9, "name": "centroidx", "rss_kb": 900_000, "threads": 20,
                    "thread_detail": {}}
        text = hp.render_threads(snapshot, [], dart_heap_bytes=80_000_000)
        self.assertIn("native", text)
        self.assertIn("842 MB", text)  # 900000 kB = 921.6 MB RSS, less the 80 MB heap


class PgUrlTest(unittest.TestCase):
    def test_builds_from_the_backend_environment(self):
        url = hp.pg_url_from_env({
            "CENTROID_PGHOST": "timescaledb", "CENTROID_PGUSER": "centroid",
            "CENTROID_PGPASSWORD": "FooBarHelloWorld", "CENTROID_PGDATABASE": "hmi",
            "CENTROID_PGSSLMODE": "require",
        })
        self.assertEqual(
            url, "postgresql://centroid:FooBarHelloWorld@timescaledb:5432/hmi?sslmode=require"
        )

    def test_percent_encodes_a_password_with_url_characters(self):
        url = hp.pg_url_from_env({"CENTROID_PGHOST": "db", "CENTROID_PGUSER": "u",
                                  "CENTROID_PGPASSWORD": "p@ss/word"})
        self.assertIn("p%40ss%2Fword", url)

    def test_explicit_url_wins(self):
        self.assertEqual(
            hp.pg_url_from_env({"HMI_PG_URL": "postgresql://x/y", "CENTROID_PGHOST": "db"}),
            "postgresql://x/y",
        )

    def test_no_host_means_no_database(self):
        self.assertIsNone(hp.pg_url_from_env({}))


class PgRenderTest(unittest.TestCase):
    def test_a_missing_extension_does_not_hide_the_other_sections(self):
        sections = {
            "database": {"title": "Database", "headers": ["m", "v"], "rows": [["cache hit %", "99"]]},
            "statements": {"title": "Slowest", "headers": ["a"],
                           "error": 'relation "pg_stat_statements" does not exist'},
        }
        text = hp.render_postgres(sections)
        self.assertIn("cache hit %", text)
        self.assertIn("pg_stat_statements", text)

    def test_no_database_configured(self):
        self.assertIn("no database configured", hp.render_postgres(None))

    def test_psql_missing(self):
        self.assertIn("psql", hp.render_postgres({"error": "psql is not installed in this image"}))


class SystemActionsTest(unittest.TestCase):
    def base(self):
        return {"frames": hp.frame_stats([]), "cpu": hp.fold_cpu_samples({}),
                "hot_path": [], "slow": []}

    def test_flags_a_container_near_its_memory_limit(self):
        data = self.base()
        data["containers"] = [hp.summarise_container("flutter", docker_stats(mem_usage=950_000_000))]
        self.assertIn("OOM kill", hp.render_actions(data))

    def test_flags_native_memory_dwarfing_the_dart_heap(self):
        data = self.base()
        data["process"] = {"rss_kb": 900_000, "pid": 1, "name": "c", "threads": 1,
                           "thread_detail": {}}
        data["memory_usage"] = {"heapUsage": 50_000_000}
        self.assertIn("outside the Dart heap", hp.render_actions(data))

    def test_flags_a_long_running_query(self):
        data = self.base()
        data["postgres"] = {"activity": {"rows": [["active", "-", "4.2", "SELECT ..."]]}}
        self.assertIn("longer than a second", hp.render_actions(data))

    def test_as_float_is_forgiving(self):
        self.assertEqual(hp._as_float("x"), 0.0)
        self.assertEqual(hp._as_float(None), 0.0)
        self.assertEqual(hp._as_float("2.5"), 2.5)


class PercentileTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(hp.percentile([], 0.9), 0)

    def test_nearest_rank(self):
        values = list(range(1, 101))
        self.assertEqual(hp.percentile(values, 0.0), 1)
        self.assertEqual(hp.percentile(values, 1.0), 100)
        self.assertEqual(hp.percentile(values, 0.5), 51)

    def test_single_value(self):
        self.assertEqual(hp.percentile([7], 0.99), 7)


class FrameStatsTest(unittest.TestCase):
    def frames(self, pairs):
        return [
            {"build": build, "raster": raster, "elapsed": build + raster, "number": i}
            for i, (build, raster) in enumerate(pairs)
        ]

    def test_counts_frames_over_budget(self):
        stats = hp.frame_stats(self.frames([(2000, 3000), (20000, 3000), (2000, 90000)]))
        self.assertEqual(stats["frames"], 3)
        self.assertEqual(stats["janky"], 2)
        self.assertEqual(stats["severe"], 1)
        self.assertAlmostEqual(stats["janky_percent"], 200 / 3.0)

    def test_a_frame_exactly_on_budget_is_not_jank(self):
        stats = hp.frame_stats(self.frames([(hp.FRAME_BUDGET_US, 1000)]))
        self.assertEqual(stats["janky"], 0)

    def test_blames_the_slower_thread(self):
        raster_bound = hp.frame_stats(self.frames([(1000, 30000)] * 10))
        self.assertEqual(raster_bound["bottleneck"], "raster")
        build_bound = hp.frame_stats(self.frames([(30000, 1000)] * 10))
        self.assertEqual(build_bound["bottleneck"], "build")

    def test_no_frames(self):
        stats = hp.frame_stats([])
        self.assertEqual(stats["frames"], 0)
        self.assertEqual(stats["bottleneck"], "unknown")
        self.assertIsNone(stats["worst_frame"])
        self.assertEqual(stats["janky_percent"], 0.0)

    def test_worst_frame_is_the_longest(self):
        stats = hp.frame_stats(self.frames([(1000, 1000), (1000, 40000)]))
        self.assertEqual(stats["worst_frame"]["number"], 1)

    def test_missing_keys_default_to_zero(self):
        stats = hp.frame_stats([{"number": 1}])
        self.assertEqual(stats["build_us"]["max"], 0)


class TimelineSummaryTest(unittest.TestCase):
    def test_pairs_begin_and_end_events(self):
        # This is what the Dart VM actually writes for Timeline.startSync,
        # which is how the framework marks BUILD / LAYOUT / PAINT.
        payload = {
            "traceEvents": [
                {"ph": "B", "name": "BUILD", "ts": 1000, "pid": 1, "tid": 7},
                {"ph": "B", "name": "PAINT", "ts": 1100, "pid": 1, "tid": 7},
                {"ph": "E", "name": "PAINT", "ts": 1400, "pid": 1, "tid": 7},
                {"ph": "E", "name": "BUILD", "ts": 1900, "pid": 1, "tid": 7},
            ]
        }
        rows = {row["name"]: row for row in hp.summarise_timeline(payload)}
        self.assertEqual(rows["BUILD"]["total_us"], 900)
        self.assertEqual(rows["PAINT"]["total_us"], 300)

    def test_threads_do_not_pair_with_each_other(self):
        payload = {
            "traceEvents": [
                {"ph": "B", "name": "UI", "ts": 0, "pid": 1, "tid": 1},
                {"ph": "B", "name": "RASTER", "ts": 10, "pid": 1, "tid": 2},
                {"ph": "E", "name": "RASTER", "ts": 60, "pid": 1, "tid": 2},
                {"ph": "E", "name": "UI", "ts": 100, "pid": 1, "tid": 1},
            ]
        }
        rows = {row["name"]: row for row in hp.summarise_timeline(payload)}
        self.assertEqual(rows["UI"]["total_us"], 100)
        self.assertEqual(rows["RASTER"]["total_us"], 50)

    def test_unmatched_events_are_dropped_not_guessed(self):
        payload = {
            "traceEvents": [
                {"ph": "E", "name": "OPENED_BEFORE_THE_BUFFER", "ts": 5, "pid": 1, "tid": 1},
                {"ph": "B", "name": "STILL_RUNNING", "ts": 10, "pid": 1, "tid": 1},
            ]
        }
        self.assertEqual(hp.summarise_timeline(payload), [])

    def test_aggregates_complete_events_only(self):
        payload = {
            "traceEvents": [
                {"ph": "X", "name": "PAINT", "dur": 100},
                {"ph": "X", "name": "PAINT", "dur": 300},
                {"ph": "B", "name": "PAINT", "dur": 9999},
                {"ph": "X", "name": "LAYOUT", "dur": 50},
            ]
        }
        rows = hp.summarise_timeline(payload)
        by_name = {row["name"]: row for row in rows}
        self.assertEqual(by_name["PAINT"]["count"], 2)
        self.assertEqual(by_name["PAINT"]["total_us"], 400)
        self.assertEqual(by_name["PAINT"]["mean_us"], 200)
        self.assertEqual(by_name["PAINT"]["max_us"], 300)
        self.assertEqual(rows[0]["name"], "PAINT")  # ordered by total time

    def test_empty_payload(self):
        self.assertEqual(hp.summarise_timeline({}), [])

    def test_a_block_outside_the_window_does_not_reach_the_summary(self):
        # Same false positive as TimelineBlocksTest, on the aggregate table:
        # the 750 ms `getCpuSamples` reply must not become the `max ms` column.
        payload = {
            "traceEvents": [
                {"ph": "B", "name": "DartIsolate::HandleMessage", "ts": 2000, "pid": 1, "tid": 7},
                {"ph": "E", "name": "DartIsolate::HandleMessage", "ts": 2300, "pid": 1, "tid": 7},
                {"ph": "B", "name": "DartIsolate::HandleMessage", "ts": 9500, "pid": 1, "tid": 7},
                {"ph": "E", "name": "DartIsolate::HandleMessage", "ts": 9500 + 750_000, "pid": 1, "tid": 7},
            ]
        }
        rows = {r["name"]: r for r in hp.summarise_timeline(payload, window=(1000, 9000))}
        self.assertEqual(rows["DartIsolate::HandleMessage"]["count"], 1)
        self.assertEqual(rows["DartIsolate::HandleMessage"]["max_us"], 300)


class PostgresSectionTest(unittest.TestCase):
    def test_every_query_is_rendered(self):
        # A section added to PG_QUERIES but not to render_postgres's key list
        # is collected and then silently dropped.
        rendered_keys = set()
        for const in hp.render_postgres.__code__.co_consts:
            if isinstance(const, tuple) and "scans" in const:
                rendered_keys = set(const)
        self.assertEqual(set(hp.PG_QUERIES) - rendered_keys, set())

    def test_the_scan_counts_are_labelled_cumulative(self):
        # The counter is a lifetime total. A title that does not say so was
        # read as a rate, and the rate that implied was ~8x the real one.
        self.assertIn("cumulative", hp.PG_QUERIES["scans"][0])

    def test_a_failing_section_does_not_take_the_others_with_it(self):
        sections = {
            "scans": {"title": "Scans", "headers": ["t"], "rows": [["alarm_history"]]},
            "counters": {"title": "Counters", "error": "no such column"},
        }
        rendered = hp.render_postgres(sections)
        self.assertIn("alarm_history", rendered)
        self.assertIn("no such column", rendered)


class AllocationSummaryTest(unittest.TestCase):
    def test_reads_the_flat_class_heap_stats_current_vms_send(self):
        payload = {
            "members": [
                {
                    "class": {"name": "_List"},
                    "bytesCurrent": 774_000_000,
                    "instancesCurrent": 20715,
                },
                {"class": {"name": "Function"}, "bytesCurrent": 872_704, "instancesCurrent": 6818},
            ]
        }
        rows = hp.summarise_allocations(payload)
        self.assertEqual([row["name"] for row in rows], ["_List", "Function"])
        self.assertEqual(rows[0]["instances"], 20715)

    def test_sums_both_spaces_and_sorts_by_size(self):
        payload = {
            "members": [
                {
                    "class": {"name": "Uint8List"},
                    "oldSpace": {"bytesCurrent": 1000, "instancesCurrent": 2},
                    "newSpace": {"bytesCurrent": 500, "instancesCurrent": 1},
                },
                {
                    "class": {"name": "Widget"},
                    "oldSpace": {"bytesCurrent": 4000, "instancesCurrent": 40},
                    "newSpace": {},
                },
                {"class": {"name": "Empty"}, "oldSpace": {}, "newSpace": {}},
            ]
        }
        rows = hp.summarise_allocations(payload)
        self.assertEqual([row["name"] for row in rows], ["Widget", "Uint8List"])
        self.assertEqual(rows[1]["bytes"], 1500)
        self.assertEqual(rows[1]["instances"], 3)

    def test_empty_payload(self):
        self.assertEqual(hp.summarise_allocations({}), [])


class RenderTest(unittest.TestCase):
    def test_idle_app_says_so_rather_than_printing_an_empty_table(self):
        text = hp.render_frames(hp.frame_stats([]))
        self.assertIn("No `Flutter.Frame` events", text)

    def test_report_renders_every_section(self):
        data = {
            "collected_at": "2026-08-28 10:00:00 +0000",
            "url": "ws://flutter:8181/ws",
            "isolate": "isolates/1",
            "seconds": 15,
            "vm_version": "4.19",
            "frames": hp.frame_stats([{"build": 20000, "raster": 1000, "elapsed": 21000}]),
            "cpu": hp.fold_cpu_samples(
                {"functions": SAMPLE_FUNCTIONS, "samples": [{"stack": [0, 1]}]}
            ),
            "timeline": hp.summarise_timeline({"traceEvents": [{"ph": "X", "name": "BUILD", "dur": 5}]}),
            "memory_usage": {"heapUsage": 12_000_000, "heapCapacity": 20_000_000},
            "memory_classes": hp.summarise_allocations(
                {"members": [{"class": {"name": "Foo"}, "oldSpace": {"bytesCurrent": 9}}]}
            ),
        }
        report = hp.render_report(data)
        for heading in ("### Frames", "### CPU", "### Timeline", "### Memory"):
            self.assertIn(heading, report)
        self.assertIn("ConveyorPainter.paint", report)
        self.assertIn("BUILD", report)

    def test_table_escapes_nothing_but_still_lines_up(self):
        table = hp.render_table(["a", "b"], [[1, 2], [3, 4]])
        self.assertEqual(table.splitlines()[0], "| a | b |")
        self.assertEqual(table.splitlines()[1], "|---|---|")

    def test_empty_table(self):
        self.assertIn("nothing recorded", hp.render_table(["a"], []))


class ParserTest(unittest.TestCase):
    def test_defaults(self):
        args = hp.build_parser().parse_args(["report"])
        self.assertEqual(args.command, "report")
        self.assertEqual(args.seconds, 15.0)
        self.assertEqual(args.url, hp.DEFAULT_URL)

    def test_every_command_is_wired_up(self):
        for name in hp.COMMANDS:
            self.assertEqual(hp.build_parser().parse_args([name]).command, name)

    def test_isolate_defaults_to_none_which_means_main(self):
        self.assertIsNone(hp.build_parser().parse_args(["cpu"]).isolate)

    def test_isolate_is_taken_verbatim_for_select_isolates_to_parse(self):
        args = hp.build_parser().parse_args(["cpu", "--isolate", "main,#3"])
        self.assertEqual(args.isolate, "main,#3")


if __name__ == "__main__":
    unittest.main()
