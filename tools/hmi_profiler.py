#!/usr/bin/env python3
"""Read the Dart VM Service of a running CentroidX and report on performance.

The `latest-profile` container image is a Flutter *profile* build: AOT-compiled
like release, but with the Dart VM Service, the sampling CPU profiler and the
`Flutter.Frame` timing events still compiled in. (`latest-release` remains a
release build, which strips all three; `latest` is debug/JIT and does expose a
service, but its timings are a JIT build's.) This script talks to that service
and turns it into something a person — or an LLM asked to "find where the app
is slow" — can read without opening DevTools.

No third-party packages. The WebSocket client below is deliberately small so
the script runs anywhere python3 does, including a stock `python:alpine`.

Three layers, because a slow HMI is not always a slow *Dart* HMI: the Dart VM
Service (call trees, frames, heap), the OS (per-thread CPU, RSS — the engine,
Skia, pdfium and open62541 all allocate outside the Dart heap), and the rest of
the stack (every container against its memory limit, and what the database is
doing). `report` puts all of them in one document over one wall-clock window.

Within the Dart layer, two questions, two mechanisms. "What is this app always doing?" is answered by
folding CPU samples into a call tree. "What was that 80 ms hiccup?" is answered
by finding timeline blocks that ran far longer than the median for their own
name, then folding only the samples taken *inside that block's window*. The
second is possible because the timeline and the CPU profiler share the VM's
monotonic clock, so a block's [ts, ts+dur] selects the samples that were taken
while it ran.

A Flutter app is also not one isolate, and `main` is not where all of the CPU
is. Ours runs ten: `main`, a `compute()` worker or two, and one open62541 OPC
UA client per server — seven of them, every one named `_isolateEntryPoint`
after the function it was spawned on. Every isolate-scoped RPC here takes an
`isolateId`, so profiling only `main` left that work as an unattributed lump in
the container's CPU. `--isolate` picks by name substring, VM isolate number,
`#index`, or `all`; `cpu` and `memory` accept several and sample them over one
shared window, so the numbers can be compared to each other.

Subcommands
    status     one-shot: version, isolates, heap, uptime.
    frames     collect `Flutter.Frame` events, report jank percentiles.
    cpu        hot functions (self/inclusive) plus the call tree behind them.
    slow       find blocks that ran unusually long and dump the stack that was
               on the CPU during each. --repeat to keep hunting.
    system     the view from outside the VM: every container's CPU and memory
               against its limit, the app's per-thread CPU and RSS, and the
               database's live queries and scan counts. Needs no VM service,
               so it still answers when the app is wedged.
    timeline   aggregate VM timeline events by name (BUILD/LAYOUT/PAINT/GC...).
    memory     heap usage plus the largest classes by retained size.
    report     all of the above, as one markdown document, led by a
               "Where to look" summary.
    watch      run `report` forever on an interval, writing files to --out-dir.

Examples
    # against a station, from a machine on the same network
    python3 tools/hmi_profiler.py report --url ws://10.50.10.11:8181/ws

    # against `flutter run --profile` on this machine (auth codes are on, so
    # paste the whole URI the tool printed)
    python3 tools/hmi_profiler.py cpu --url ws://127.0.0.1:53309/cbGW2JoeB_M=/ws

    # inside the compose stack
    docker compose run --rm profiler report --seconds 60

    # hunt for hiccups while an operator drives the screen
    docker compose run --rm profiler slow --seconds 20 --repeat

    # every isolate at once, to see which of them owns the container's CPU
    docker compose run --no-deps --rm profiler cpu --isolate all --seconds 30

    # just the seven OPC UA clients, or just one of them
    python3 tools/hmi_profiler.py cpu --isolate _isolateEntryPoint
    python3 tools/hmi_profiler.py cpu --isolate '#4'

Running *this* copy against a station without touching its image
    The sidecar is a stock python3 plus this one file, so the file can come
    down the pipe instead of out of the image. Nothing is written anywhere:

        ssh centroid@<station> 'cd ~/sildarvinnsla && docker compose run \\
            --no-deps --rm -T --entrypoint python3 profiler - cpu \\
            --isolate all --seconds 30' < tools/hmi_profiler.py

    `--no-deps` is not optional. Without it compose recreates the `flutter`
    service this container depends on, and a live plant screen goes black.
    `-T` keeps stdin attached with no TTY, which is what `python3 -` needs.
"""

from __future__ import annotations

import argparse
import base64
import collections
import errno
import hashlib
import http.client
import json
import os
import socket
import ssl
import shutil
import struct
import subprocess
import sys
import time
import urllib.parse

# Loopback, not a compose service name: the profiler container shares the app
# container's network namespace, so the VM service never has to bind anywhere
# another container could reach it.
DEFAULT_URL = os.environ.get("HMI_VM_SERVICE_URI", "ws://127.0.0.1:8181/ws")

# A frame is "janky" when it misses its budget. 60 Hz is the panel refresh on
# every station we ship, so the budget is 16.67 ms; the engine reports build
# and raster separately and either one blowing it drops the frame.
FRAME_BUDGET_US = 16667
SEVERE_FRAME_BUDGET_US = FRAME_BUDGET_US * 3

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class ProfilerError(Exception):
    """Anything that stops us producing a report."""


class ConnectionClosed(ProfilerError):
    pass


class VmServiceError(ProfilerError):
    def __init__(self, method, error):
        self.method = method
        self.error = error
        super().__init__(f"{method}: {error.get('message', error)}")


# --------------------------------------------------------------------------
# Minimal RFC 6455 client. Text frames only, which is all the VM Service uses.
# --------------------------------------------------------------------------


class WebSocket:
    #: Once a frame header has started arriving the rest of it must follow, so
    #: reads after the first byte use this timeout rather than the caller's
    #: deadline — timing out mid-frame would desynchronise the stream.
    body_timeout = 60.0

    def __init__(self, url, connect_timeout=10.0):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("ws", "wss"):
            raise ProfilerError(f"not a WebSocket URL: {url!r}")
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        host = parsed.hostname
        if not host:
            raise ProfilerError(f"no host in URL: {url!r}")
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        self._buf = b""
        self._sock = socket.create_connection((host, port), timeout=connect_timeout)
        if parsed.scheme == "wss":
            self._sock = ssl.create_default_context().wrap_socket(
                self._sock, server_hostname=host
            )
        self._handshake(host, port, path)

    def _handshake(self, host, port, path):
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self._sock.sendall(request.encode("ascii"))

        header = b""
        while b"\r\n\r\n" not in header:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionClosed("server closed during handshake")
            header += chunk
        head, _, rest = header.partition(b"\r\n\r\n")
        self._buf = rest

        lines = head.decode("latin-1").split("\r\n")
        if "101" not in lines[0]:
            raise ProfilerError(f"handshake refused: {lines[0]}")
        accept = ""
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "sec-websocket-accept":
                accept = value.strip()
        expected = base64.b64encode(
            hashlib.sha1((key + _WS_GUID).encode("ascii")).digest()
        ).decode()
        if accept != expected:
            raise ProfilerError("handshake accept key mismatch")

    def _recv_exactly(self, count):
        while len(self._buf) < count:
            try:
                chunk = self._sock.recv(max(4096, count - len(self._buf)))
            except socket.timeout as exc:
                raise TimeoutError("timed out reading from the VM service") from exc
            except OSError as exc:
                if exc.errno == errno.EINTR:
                    continue
                raise ConnectionClosed(str(exc)) from exc
            if not chunk:
                raise ConnectionClosed("server closed the connection")
            self._buf += chunk
        out, self._buf = self._buf[:count], self._buf[count:]
        return out

    def _read_frame(self, timeout):
        # Between frames the buffer sits on a frame boundary, so the caller's
        # deadline only has to cover the wait for the first byte.
        self._sock.settimeout(max(timeout, 0.0))
        first = self._recv_exactly(1)[0]
        self._sock.settimeout(self.body_timeout)

        fin = bool(first & 0x80)
        opcode = first & 0x0F
        second = self._recv_exactly(1)[0]
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exactly(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exactly(8))[0]
        mask = self._recv_exactly(4) if masked else None
        payload = self._recv_exactly(length) if length else b""
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def _send_frame(self, opcode, payload):
        header = bytearray()
        header.append(0x80 | opcode)
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._sock.settimeout(self.body_timeout)
        self._sock.sendall(bytes(header) + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def recv_text(self, timeout=30.0):
        """Return the next text message, answering pings while it waits."""
        deadline = time.monotonic() + timeout
        chunks = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 and not chunks:
                raise TimeoutError("timed out waiting for a VM service message")
            fin, opcode, payload = self._read_frame(max(remaining, 0.0))
            if opcode == 0x8:
                raise ConnectionClosed("server sent close")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x0, 0x1, 0x2):
                chunks.append(payload)
                if fin:
                    return b"".join(chunks).decode("utf-8")
                continue
            raise ProfilerError(f"unexpected websocket opcode {opcode:#x}")

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        finally:
            self._sock.close()


# --------------------------------------------------------------------------
# VM Service JSON-RPC
# --------------------------------------------------------------------------


class VmService:
    """JSON-RPC over the socket, with stream events buffered out of the way."""

    def __init__(self, ws):
        self._ws = ws
        self._next_id = 0
        self.events = collections.deque()

    @classmethod
    def connect(cls, url, wait=0.0, connect_timeout=10.0):
        """Connect, retrying for `wait` seconds — containers restart."""
        return cls(cls._open(url, wait, connect_timeout))

    @staticmethod
    def _open(url, wait, connect_timeout):
        deadline = time.monotonic() + wait
        attempt = 0
        while True:
            attempt += 1
            try:
                return WebSocket(url, connect_timeout=connect_timeout)
            except (OSError, ProfilerError) as exc:
                if time.monotonic() >= deadline:
                    raise ProfilerError(
                        f"could not reach the VM service at {url} "
                        f"({exc}). Is the container a profile build, with "
                        "FLUTTER_ENGINE_SWITCHES (panel) or DART_VM_SWITCHES "
                        "(backend) set?"
                    ) from exc
                time.sleep(min(2.0 * attempt, 5.0))

    def reconnect(self, url, wait=0.0, connect_timeout=10.0):
        """Swap in a fresh socket, keeping this object identity — callers
        (and `main`'s cleanup) hold on to the service, not the socket."""
        try:
            self._ws.close()
        except OSError:
            pass
        self._ws = self._open(url, wait, connect_timeout)
        self.events.clear()

    def call(self, method, params=None, timeout=60.0):
        self._next_id += 1
        request_id = str(self._next_id)
        self._ws.send_text(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": method,
                    "params": params or {},
                }
            )
        )
        deadline = time.monotonic() + timeout
        while True:
            message = json.loads(self._ws.recv_text(max(deadline - time.monotonic(), 0.0)))
            if message.get("id") == request_id:
                if "error" in message:
                    raise VmServiceError(method, message["error"])
                return message.get("result", {})
            self._buffer(message)

    def _buffer(self, message):
        if message.get("method") == "streamNotify":
            event = message.get("params", {}).get("event")
            if event is not None:
                self.events.append(event)

    def try_call(self, method, params=None, timeout=60.0):
        """Like `call`, but `None` instead of raising. For optional extras."""
        try:
            return self.call(method, params, timeout)
        except (VmServiceError, TimeoutError):
            return None

    def listen(self, stream_id):
        try:
            self.call("streamListen", {"streamId": stream_id})
            return True
        except VmServiceError as exc:
            # Already subscribed is fine; anything else means no such stream.
            return "already" in str(exc.error.get("message", "")).lower()

    def cancel(self, stream_id):
        self.try_call("streamCancel", {"streamId": stream_id}, timeout=10.0)

    def collect_events(self, seconds, kinds=None):
        """Drain events for `seconds`, returning the ones we asked for."""
        collected = list(self.events)
        self.events.clear()
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                message = json.loads(self._ws.recv_text(remaining))
            except TimeoutError:
                break
            self._buffer(message)
            collected.extend(self.events)
            self.events.clear()
        if kinds is None:
            return collected
        return [e for e in collected if e.get("extensionKind") in kinds or e.get("kind") in kinds]

    def isolates(self, include_system=False):
        """Every isolate the VM admits to, in the VM's own order.

        A Flutter app is not one isolate. Ours runs ten: `main`, whatever
        `compute()` happens to be alive, and one open62541 OPC UA client per
        server connection — all seven of those named `_isolateEntryPoint`,
        because that is the name of the function they were spawned on. Work
        done there is invisible to every RPC that takes an `isolateId` of
        `main`, which is most of this script's, so it used to show up only as
        an unattributed lump in the container's CPU.
        """
        vm = self.call("getVM")
        found = list(vm.get("isolates") or [])
        if include_system:
            found.extend(vm.get("systemIsolates") or [])
        if not found:
            raise ProfilerError("the VM reports no isolates")
        return found

    def main_isolate(self):
        isolates = self.isolates()
        for isolate in isolates:
            if isolate.get("name") == "main":
                return isolate["id"]
        return isolates[0]["id"]

    def close(self):
        self._ws.close()


def index_isolates(isolates):
    """Stamp each isolate with its position in the VM's own list.

    That position is what `--isolate #2` means and what every label below
    prints, so the two cannot drift apart. The obvious alternative — the VM's
    `number` — is a 64-bit random on a real station
    (`_isolateEntryPoint#3292723241152127`), which is unusable as a column and
    unusable as something a person types.
    """
    # Idempotent: an already-stamped list keeps its original positions, so
    # describing a *subset* still names the indices `--isolate` would take.
    return [
        isolate if isolate.get("vm_index") is not None else dict(isolate, vm_index=index)
        for index, isolate in enumerate(isolates)
    ]


def isolate_label(isolate):
    """`_isolateEntryPoint#2` — a name alone does not identify an isolate.

    Seven of ours answer to `_isolateEntryPoint`, so every table that prints a
    name prints its index beside it or the rows are indistinguishable. The
    full `number`/`id` still appears in each section heading, because the
    index is only stable for as long as the VM's list is.
    """
    name = isolate.get("name") or "?"
    index = isolate.get("vm_index")
    if index is not None:
        return f"{name}#{index}"
    number = isolate.get("number")
    return f"{name}#{number}" if number not in (None, "") else name


def describe_isolates(isolates):
    """Every isolate on one line, for an error message or `status`."""
    return ", ".join(isolate_label(isolate) for isolate in index_isolates(isolates))


def select_isolates(isolates, selector):
    """Resolve a `--isolate` selector against the VM's isolate list.

    Accepted, comma-separated and unioned in the order given:

        (nothing)   the isolate named `main`, or the first one — what every
                    version of this script did before the flag existed.
        all         every isolate.
        #3          the isolate at index 3 of the VM's list — the number the
                    labels print, and the only one worth typing.
        3292723241152127
                    the isolate whose VM *number* that is, or its full id.
        entryPoint  case-insensitive substring of the name; matches all seven
                    OPC UA clients at once.

    Index and number are deliberately different syntaxes rather than "try both
    and take whatever hits". On a station they are wildly different orders of
    magnitude, and a selector that silently profiled the wrong isolate would
    produce a plausible, wrong answer instead of an error.
    """
    if not isolates:
        raise ProfilerError("the VM reports no isolates")
    isolates = index_isolates(isolates)
    if selector is None or not str(selector).strip():
        for isolate in isolates:
            if isolate.get("name") == "main":
                return [isolate]
        return [isolates[0]]

    chosen = []

    def take(isolate):
        if all(isolate.get("id") != seen.get("id") for seen in chosen):
            chosen.append(isolate)

    for raw in str(selector).split(","):
        term = raw.strip()
        if not term:
            continue
        if term.lower() == "all":
            for isolate in isolates:
                take(isolate)
            continue
        matches = []
        if term.startswith("#") and term[1:].isdigit():
            index = int(term[1:])
            if index >= len(isolates):
                raise ProfilerError(
                    f"no isolate at index {index}; the VM has {len(isolates)}: "
                    f"{describe_isolates(isolates)}"
                )
            matches = [isolates[index]]
        else:
            exact = [
                isolate
                for isolate in isolates
                if str(isolate.get("number")) == term or isolate.get("id") == term
            ]
            matches = exact or [
                isolate
                for isolate in isolates
                if term.lower() in str(isolate.get("name") or "").lower()
            ]
        if not matches:
            raise ProfilerError(
                f"no isolate matches {term!r}. The VM has: {describe_isolates(isolates)}"
            )
        for isolate in matches:
            take(isolate)
    return chosen


def one_isolate(isolates, selector, command):
    """Same resolution, but for the commands that profile exactly one.

    `report`, `slow` and `watch` correlate the CPU profile against a single
    timeline; there is no honest way to fold seven isolates into that. Picking
    the first match silently would mean `--isolate entryPoint` reporting on
    whichever of the seven the VM happened to list first, so it is an error.
    """
    chosen = select_isolates(isolates, selector)
    if len(chosen) > 1:
        raise ProfilerError(
            f"`{command}` profiles one isolate; {selector!r} matched "
            f"{len(chosen)}: {describe_isolates(chosen)}. Narrow it (`#2`, a "
            "number, a longer substring) or use `cpu`, which takes many."
        )
    return chosen[0]


# --------------------------------------------------------------------------
# The view from outside the VM: the container and the OS.
#
# The Dart heap is not the memory that gets a container OOM-killed. The engine,
# Skia, pdfium and open62541 all allocate outside it, so `getMemoryUsage` can
# report a healthy 80 MB while RSS sits at 950 MB of a 1 GB limit. And no VM
# Service RPC can tell you the raster thread is pegged while the UI thread
# idles. Both need looking at from outside.
# --------------------------------------------------------------------------


class _UnixHTTPConnection(http.client.HTTPConnection):
    """http.client over an AF_UNIX socket — the Docker API, without docker-py."""

    def __init__(self, socket_path, timeout=10.0):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._socket_path)
        self.sock = sock


class DockerClient:
    """Just enough of the Docker API to list containers and read their stats."""

    def __init__(self, socket_path="/var/run/docker.sock", timeout=30.0):
        self.socket_path = socket_path
        self.timeout = timeout

    def available(self):
        return os.path.exists(self.socket_path)

    def get(self, path):
        conn = _UnixHTTPConnection(self.socket_path, timeout=self.timeout)
        try:
            conn.request("GET", path, headers={"Host": "localhost"})
            response = conn.getresponse()
            body = response.read()
            if response.status != 200:
                raise ProfilerError(f"docker API {path} -> {response.status}: {body[:200]!r}")
            return json.loads(body)
        except OSError as exc:
            raise ProfilerError(f"docker API {path}: {exc}") from exc
        finally:
            conn.close()

    def containers(self):
        return self.get("/containers/json")

    def stats(self, container_id):
        # stream=false makes the daemon sample twice about a second apart and
        # return both, which is what the CPU percentage needs.
        return self.get(f"/containers/{container_id}/stats?stream=false")


def container_cpu_percent(stats):
    """Docker's own CPU formula, over the two samples `stream=false` returns."""
    cpu = stats.get("cpu_stats") or {}
    pre = stats.get("precpu_stats") or {}
    usage = (cpu.get("cpu_usage") or {}).get("total_usage")
    pre_usage = (pre.get("cpu_usage") or {}).get("total_usage")
    system = cpu.get("system_cpu_usage")
    pre_system = pre.get("system_cpu_usage")
    if None in (usage, pre_usage, system, pre_system):
        return None
    cpu_delta = usage - pre_usage
    system_delta = system - pre_system
    if system_delta <= 0 or cpu_delta < 0:
        return 0.0
    cpus = cpu.get("online_cpus") or len((cpu.get("cpu_usage") or {}).get("percpu_usage") or []) or 1
    return 100.0 * cpu_delta / system_delta * cpus


def container_memory(stats):
    """Usage minus page cache, which is what the OOM killer actually counts."""
    memory = stats.get("memory_stats") or {}
    usage = memory.get("usage")
    if usage is None:
        return None, memory.get("limit")
    detail = memory.get("stats") or {}
    # cgroup v2 calls it inactive_file; v1 called it total_inactive_file.
    cache = detail.get("inactive_file", detail.get("total_inactive_file", 0)) or 0
    return max(usage - cache, 0), memory.get("limit")


def summarise_container(name, stats):
    used, limit = container_memory(stats)
    percent_of_limit = 100.0 * used / limit if used is not None and limit else None
    return {
        "name": name,
        "cpu_percent": container_cpu_percent(stats),
        "memory_bytes": used,
        "memory_limit": limit,
        "memory_percent": percent_of_limit,
        "pids": (stats.get("pids_stats") or {}).get("current"),
    }


def collect_containers(client, names=None):
    """One row per running container, or per named container if given.

    A socket we cannot read is reported as a row, not raised: the container
    view is the least important of the three and must never take the thread
    and database sections down with it.
    """
    rows = []
    try:
        listing = client.containers()
    except ProfilerError as exc:
        return [{"name": "(docker)", "error": str(exc)}]
    for container in listing:
        name = (container.get("Names") or ["/?"])[0].lstrip("/")
        if names and name not in names:
            continue
        try:
            rows.append(summarise_container(name, client.stats(container["Id"])))
        except ProfilerError as exc:
            rows.append({"name": name, "error": str(exc)})
    rows.sort(key=lambda row: -(row.get("cpu_percent") or 0))
    return rows


# ------------------------------------------------------------------ /proc

def _clock_ticks():
    try:
        return os.sysconf("SC_CLK_TCK") or 100
    except (ValueError, OSError, AttributeError):
        return 100


CLOCK_TICKS = _clock_ticks()  # 100 on every Linux we ship to, but ask anyway.


def _read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def find_process(root="/proc", match=("centroidx",)):
    """The pid whose comm or cmdline mentions one of `match`.

    Only meaningful when this container shares the target's PID namespace
    (`pid: "service:flutter"` in compose); otherwise /proc shows us only
    ourselves and this finds nothing, which is reported rather than guessed at.
    """
    best = None
    for entry in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        if not entry.isdigit():
            continue
        comm = (_read(f"{root}/{entry}/comm") or "").strip()
        cmdline = (_read(f"{root}/{entry}/cmdline") or "").replace("\0", " ")
        for needle in match:
            if needle in comm or needle in cmdline:
                # Prefer an exact comm match over a cmdline mention, which
                # would otherwise match the shell that launched it.
                if needle in comm:
                    return int(entry)
                best = best or int(entry)
    return best


def _stat_times(text):
    """utime, stime from a /proc/<pid>/stat line.

    Split after the last ')' — a comm containing spaces or parens (and
    "io.flutter.raster" is close enough to that class of name) breaks naive
    whitespace splitting of the whole line.
    """
    if not text or ") " not in text:
        return 0, 0
    fields = text.rsplit(") ", 1)[1].split()
    if len(fields) < 13:
        return 0, 0
    return int(fields[11]), int(fields[12])


def process_snapshot(pid, root="/proc"):
    """RSS, thread count and per-thread CPU counters for one process."""
    status = _read(f"{root}/{pid}/status")
    if status is None:
        return None
    fields = {}
    for line in status.splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()

    def kb(name):
        raw = fields.get(name, "").split()
        return int(raw[0]) if raw and raw[0].isdigit() else 0

    threads = {}
    task_dir = f"{root}/{pid}/task"
    for tid in sorted(os.listdir(task_dir)) if os.path.isdir(task_dir) else []:
        utime, stime = _stat_times(_read(f"{task_dir}/{tid}/stat"))
        threads[tid] = {
            "name": (_read(f"{task_dir}/{tid}/comm") or "?").strip(),
            "ticks": utime + stime,
        }
    return {
        "pid": pid,
        "name": fields.get("Name", "?"),
        "rss_kb": kb("VmRSS"),
        "vm_kb": kb("VmSize"),
        "threads": int(fields.get("Threads", "0") or 0),
        "thread_detail": threads,
    }


def thread_cpu(before, after, seconds, ticks_per_second=CLOCK_TICKS):
    """Per-thread CPU percent between two snapshots, busiest first.

    A thread that appeared or vanished between snapshots is reported from
    whatever it did while it existed rather than dropped — a thread that
    spawned, burned a core and exited is exactly the thing worth seeing.
    """
    if not before or not after or seconds <= 0:
        return []
    rows = []
    for tid, end in after["thread_detail"].items():
        start = before["thread_detail"].get(tid, {"ticks": 0})
        delta = end["ticks"] - start.get("ticks", 0)
        if delta < 0:
            continue
        rows.append(
            {
                "tid": tid,
                "name": end["name"],
                "percent": 100.0 * (delta / ticks_per_second) / seconds,
            }
        )
    rows.sort(key=lambda row: -row["percent"])
    return rows


# --------------------------------------------------------------------------
# TimescaleDB. Shelling out to psql rather than taking a driver dependency:
# it keeps this file importable anywhere python3 is, and psql is 2 MB in the
# image against ~15 for a wheel that has to match the interpreter.
# --------------------------------------------------------------------------

PG_QUERIES = {
    "activity": (
        "Live queries",
        ["state", "waiting on", "seconds", "query"],
        """
        SELECT state,
               coalesce(wait_event_type || ':' || wait_event, '-'),
               round(extract(epoch from (now() - query_start))::numeric, 1),
               left(regexp_replace(query, '\\s+', ' ', 'g'), 120)
          FROM pg_stat_activity
         WHERE datname = current_database()
           AND pid <> pg_backend_pid()
           AND state <> 'idle'
         ORDER BY query_start
         LIMIT 15
        """,
    ),
    "database": (
        "Database",
        ["metric", "value"],
        """
        SELECT * FROM (
          SELECT 'cache hit %',
                 round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2)::text
            FROM pg_stat_database WHERE datname = current_database()
          UNION ALL
          SELECT 'commits', xact_commit::text
            FROM pg_stat_database WHERE datname = current_database()
          UNION ALL
          SELECT 'rollbacks', xact_rollback::text
            FROM pg_stat_database WHERE datname = current_database()
          UNION ALL
          SELECT 'deadlocks', deadlocks::text
            FROM pg_stat_database WHERE datname = current_database()
          UNION ALL
          SELECT 'temp files written', temp_files::text
            FROM pg_stat_database WHERE datname = current_database()
          UNION ALL
          SELECT 'connections', count(*)::text FROM pg_stat_activity
        ) t
        """,
    ),
    # These are lifetime totals, not rates -- which the title has to say,
    # because read as rates they invert the conclusion. 21 770 sequential
    # scans of a five-row preferences table reads as a table under constant
    # load; the same counter six minutes later had moved by one. The
    # "counters" section below gives the divisor.
    "scans": (
        "Sequential scans, cumulative since the counters were last reset "
        "(a missing index looks like this)",
        ["table", "seq scans", "rows read per scan", "index scans"],
        """
        SELECT relname,
               seq_scan,
               CASE WHEN seq_scan = 0 THEN 0 ELSE seq_tup_read / seq_scan END,
               coalesce(idx_scan, 0)
          FROM pg_stat_user_tables
         WHERE seq_scan > 0
         ORDER BY seq_tup_read DESC
         LIMIT 10
        """,
    ),
    # Its own section on purpose: every other number psql reports here is a
    # total since this instant, and a total with no divisor is what turns
    # "read eleven times an hour" into "read eighty-eight times an hour".
    # Kept separate so that if this query is the one that fails, it fails
    # alone -- `collect_postgres` catches per section, and the scan counts
    # are worth more than the epoch that divides them.
    "counters": (
        "Counters",
        ["metric", "value"],
        """
        SELECT 'counting since', coalesce(stats_reset::text, 'never reset')
          FROM pg_stat_database WHERE datname = current_database()
        UNION ALL
        SELECT 'counting for (hours)',
               coalesce(round(
                 (extract(epoch from (now() - stats_reset)) / 3600.0)::numeric,
                 1)::text, '?')
          FROM pg_stat_database WHERE datname = current_database()
        """,
    ),
    "sizes": (
        "Largest tables",
        ["table", "size"],
        """
        SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
          FROM pg_stat_user_tables
         ORDER BY pg_total_relation_size(relid) DESC
         LIMIT 10
        """,
    ),
    # Only works when pg_stat_statements is in shared_preload_libraries. The
    # timescaledb image does not preload it by default, so this is expected to
    # be absent and is reported as such rather than as an error.
    "statements": (
        "Slowest statements (needs pg_stat_statements)",
        ["total ms", "calls", "mean ms", "query"],
        """
        SELECT round(total_exec_time::numeric, 1),
               calls,
               round(mean_exec_time::numeric, 2),
               left(regexp_replace(query, '\\s+', ' ', 'g'), 120)
          FROM pg_stat_statements
         ORDER BY total_exec_time DESC
         LIMIT 10
        """,
    ),
}


def pg_url_from_env(env=None):
    """Build a libpq URL from the same variables the backend service uses."""
    env = os.environ if env is None else env
    if env.get("HMI_PG_URL"):
        return env["HMI_PG_URL"]
    host = env.get("CENTROID_PGHOST") or env.get("PGHOST")
    if not host:
        return None
    user = env.get("CENTROID_PGUSER") or env.get("PGUSER") or "postgres"
    password = env.get("CENTROID_PGPASSWORD") or env.get("PGPASSWORD") or ""
    port = env.get("CENTROID_PGPORT") or env.get("PGPORT") or "5432"
    database = env.get("CENTROID_PGDATABASE") or env.get("PGDATABASE") or "postgres"
    sslmode = env.get("CENTROID_PGSSLMODE") or env.get("PGSSLMODE") or "prefer"
    auth = urllib.parse.quote(user, safe="")
    if password:
        auth += ":" + urllib.parse.quote(password, safe="")
    return f"postgresql://{auth}@{host}:{port}/{database}?sslmode={sslmode}"


def run_psql(url, sql, timeout=30.0):
    """Rows as lists of strings. Raises ProfilerError with psql's own message."""
    result = subprocess.run(
        ["psql", url, "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise ProfilerError((result.stderr or "psql failed").strip().splitlines()[-1])
    return [line.split("\t") for line in result.stdout.splitlines() if line.strip()]


def collect_postgres(url, timeout=30.0):
    """Every query, each failing independently — pg_stat_statements is
    routinely absent and must not take the other four sections with it."""
    if not shutil.which("psql"):
        return {"error": "psql is not installed in this image"}
    sections = {}
    for key, (title, headers, sql) in PG_QUERIES.items():
        try:
            sections[key] = {"title": title, "headers": headers, "rows": run_psql(url, sql, timeout)}
        except (ProfilerError, subprocess.SubprocessError, OSError) as exc:
            sections[key] = {"title": title, "headers": headers, "error": str(exc)}
    return sections


# --------------------------------------------------------------------------
# Analysis — pure functions over VM Service payloads, so they can be tested
# without a running app.
# --------------------------------------------------------------------------


def percentile(values, fraction):
    """Nearest-rank percentile. `fraction` is 0..1. Empty list -> 0."""
    if not values:
        return 0
    ordered = sorted(values)
    index = int(round(fraction * (len(ordered) - 1)))
    return ordered[index]


def function_label(functions, index):
    """A readable `Class.method [file.dart]` for a profile function index."""
    if not isinstance(index, int) or index < 0 or index >= len(functions):
        return "???"
    entry = functions[index] or {}
    function = entry.get("function")
    if isinstance(function, dict):
        name = function.get("name") or "???"
        owner = function.get("owner")
        if isinstance(owner, dict):
            owner_name = owner.get("name")
            owner_type = owner.get("type", "")
            if owner_name and "Class" in owner_type:
                name = f"{owner_name}.{name}"
    else:
        name = function or "???"
    url = entry.get("resolvedUrl") or ""
    where = url.rsplit("/", 1)[-1] if url else "native"
    return f"{name} [{where}]"


def package_of(functions, index):
    """`package:tfc/...` -> `tfc`; anything else grouped coarsely."""
    if not isinstance(index, int) or index < 0 or index >= len(functions):
        return "unknown"
    url = (functions[index] or {}).get("resolvedUrl") or ""
    if url.startswith("package:"):
        return url.split(":", 1)[1].split("/", 1)[0]
    if "/packages/" in url:
        return url.split("/packages/", 1)[1].split("/", 1)[0]
    if url.startswith("dart:"):
        return url.split("/", 1)[0]
    if not url:
        return "native"
    return "app"


def fold_cpu_samples(payload, top=25):
    """Fold `getCpuSamples` into self/inclusive/per-package tallies."""
    functions = payload.get("functions", []) or []
    samples = payload.get("samples", []) or []
    self_ticks = collections.Counter()
    inclusive_ticks = collections.Counter()
    package_ticks = collections.Counter()
    counted = 0

    for sample in samples:
        stack = sample.get("stack") or []
        if not stack:
            continue
        counted += 1
        self_ticks[function_label(functions, stack[0])] += 1
        package_ticks[package_of(functions, stack[0])] += 1
        # A recursive frame must not count twice towards inclusive time.
        for index in set(stack):
            inclusive_ticks[function_label(functions, index)] += 1

    def as_rows(counter):
        return [
            {"name": name, "samples": count, "percent": 100.0 * count / counted if counted else 0.0}
            for name, count in counter.most_common(top)
        ]

    return {
        "samples": counted,
        "sample_period_us": payload.get("samplePeriod"),
        "time_span_s": (payload.get("timeExtentMicros") or 0) / 1e6,
        "self": as_rows(self_ticks),
        "inclusive": as_rows(inclusive_ticks),
        "packages": as_rows(package_ticks),
    }


#: The VM tag the profiler stamps on a sample it took while the isolate had
#: nothing to run. Its thread is parked in a futex wait inside libc, which is
#: where the *stack* says the time went — one nameless native frame, no Dart
#: caller, and on a station it is the single biggest row in every OPC UA
#: isolate's self time. It is not CPU. Counting it as CPU turns seven idle
#: clients into a 19 % "unattributed block" that /proc flatly contradicts.
IDLE_VM_TAG = "Idle"


def fold_vm_tags(payload):
    """Count samples by the VM tag they were taken under.

    The Dart profiler is a wall-clock sampler: a dedicated thread interrupts
    every mounted isolate on a fixed period whether or not that isolate is on
    a CPU. So `samples x period` is the isolate's *elapsed* time, and only the
    non-`Idle` part of it is time the machine actually spent. This is the
    field that tells the two apart, and it is why every CPU figure below is
    reported twice.
    """
    tags = collections.Counter()
    for sample in payload.get("samples") or []:
        tags[sample.get("vmTag") or "unknown"] += 1
    return tags


def _tree_node(name):
    return {"name": name, "self": 0, "total": 0, "children": {}}


def build_call_tree(functions, samples, tid=None):
    """Fold samples into a root-first call tree.

    A flat "top functions" list tells you *what* is hot; it cannot tell you
    *how you got there*, which is the only thing you can act on. `stack` is
    leaf-first, so the tree is built from the reversed stack.
    """
    root = _tree_node("<all>")
    for sample in samples:
        if tid is not None and sample.get("tid") != tid:
            continue
        stack = sample.get("stack") or []
        if not stack:
            continue
        root["total"] += 1
        node = root
        for index in reversed(stack):
            name = function_label(functions, index)
            child = node["children"].get(name)
            if child is None:
                child = _tree_node(name)
                node["children"][name] = child
            child["total"] += 1
            node = child
        node["self"] += 1
    return root


def dominant_path(tree, min_percent=5.0):
    """The heaviest root-to-leaf chain — where the time actually goes."""
    path = []
    node = tree
    total = tree["total"] or 1
    while node["children"]:
        node = max(node["children"].values(), key=lambda child: child["total"])
        if 100.0 * node["total"] / total < min_percent:
            break
        path.append(node["name"])
    return path


def _fold_recursion(node):
    """Merge a run of same-named nested frames into one row.

    Recursion turns a call tree into a ladder: `fib -> fib -> fib -> ...` for
    twenty levels, each its own indented line, none of them telling you
    anything the first one did not. Flutter does this constantly — the render
    tree walk, `RenderObject.visitChildren`, the element tree — so without
    this the interesting branch point is pushed off the bottom of the page.

    Returns (depth, summed self ticks, deepest node in the run).
    """
    depth = 1
    self_ticks = node["self"]
    current = node
    while len(current["children"]) == 1:
        only = next(iter(current["children"].values()))
        if only["name"] != node["name"]:
            break
        depth += 1
        self_ticks += only["self"]
        current = only
    return depth, self_ticks, current


def _compress_chain(names):
    """`a -> fib -> fib -> fib -> b` becomes `a -> fib x3 deep -> b`.

    The straight-line collapse walks single children regardless of name, so a
    recursive run can still appear inside one chain. Squash it there too, or
    the first line of every tree is a wall of one repeated frame.
    """
    out = []
    for name in names:
        if out and out[-1][0] == name:
            out[-1][1] += 1
        else:
            out.append([name, 1])
    return [name if count == 1 else f"{name} x{count} deep" for name, count in out]


def render_call_tree(tree, min_percent=2.0, max_depth=40):
    """Indented tree, pruned, with straight runs and recursion collapsed.

    Flutter stacks are mostly linear — twenty frames of build/layout plumbing
    that each carry the identical sample count. Printing one line each buries
    the branch points, which are the only interesting rows.
    """
    total = tree["total"]
    if not total:
        return "_(no samples)_\n"
    lines = []

    def walk(node, depth):
        if depth > max_depth:
            return
        children = sorted(node["children"].values(), key=lambda c: -c["total"])
        children = [c for c in children if 100.0 * c["total"] / total >= min_percent]
        for child in children:
            recursion, self_ticks, walker = _fold_recursion(child)
            chain = [child["name"]] * recursion
            # Collapse a run of single children that all carry the same weight.
            while (
                len(walker["children"]) == 1
                and walker["self"] == 0
                and next(iter(walker["children"].values()))["total"] == walker["total"]
            ):
                walker = next(iter(walker["children"].values()))
                chain.append(walker["name"])
                self_ticks = walker["self"]
            percent = 100.0 * child["total"] / total
            self_percent = 100.0 * self_ticks / total
            marker = f" (self {self_percent:.0f}%)" if self_ticks else ""
            lines.append(
                "  " * depth + f"{percent:5.1f}%  " + " -> ".join(_compress_chain(chain)) + marker
            )
            walk(walker, depth + 1)

    walk(tree, 0)
    return "\n".join(lines) + "\n" if lines else "_(nothing above the threshold)_\n"


def frame_stats(frames):
    """Turn `Flutter.Frame` extensionData payloads into jank statistics."""
    builds = [f.get("build", 0) for f in frames]
    rasters = [f.get("raster", 0) for f in frames]
    elapsed = [f.get("elapsed", 0) for f in frames]
    janky = [
        f
        for f in frames
        if f.get("build", 0) > FRAME_BUDGET_US or f.get("raster", 0) > FRAME_BUDGET_US
    ]
    severe = [
        f
        for f in frames
        if f.get("build", 0) > SEVERE_FRAME_BUDGET_US
        or f.get("raster", 0) > SEVERE_FRAME_BUDGET_US
    ]
    worst = max(frames, key=lambda f: f.get("elapsed", 0)) if frames else None
    return {
        "frames": len(frames),
        "janky": len(janky),
        "janky_percent": 100.0 * len(janky) / len(frames) if frames else 0.0,
        "severe": len(severe),
        "build_us": {
            "p50": percentile(builds, 0.50),
            "p90": percentile(builds, 0.90),
            "p99": percentile(builds, 0.99),
            "max": max(builds) if builds else 0,
        },
        "raster_us": {
            "p50": percentile(rasters, 0.50),
            "p90": percentile(rasters, 0.90),
            "p99": percentile(rasters, 0.99),
            "max": max(rasters) if rasters else 0,
        },
        "elapsed_us": {
            "p50": percentile(elapsed, 0.50),
            "p90": percentile(elapsed, 0.90),
            "p99": percentile(elapsed, 0.99),
            "max": max(elapsed) if elapsed else 0,
        },
        "worst_frame": worst,
        # Which half of the pipeline to blame: UI thread (build) or GPU (raster).
        "bottleneck": (
            "raster"
            if percentile(rasters, 0.90) > percentile(builds, 0.90)
            else "build"
        )
        if frames
        else "unknown",
    }


def in_window(start_us, window):
    """Whether a block starting at `start_us` belongs to the recorded window.

    `window` is the `(from_us, to_us)` pair [collect_window] reads off the VM's
    own timeline clock, or None when the VM would not give one — in which case
    everything is kept, exactly as before.

    This exists because of a specific false positive. `clearCpuSamples` and
    `getCpuSamples` are *isolate-scoped* service RPCs: the VM delivers them to
    the target isolate as out-of-band messages, so the isolate handles them
    inside a `DartIsolate::HandleMessage` block like any other message. Building
    the `getCpuSamples` reply walks the whole sample ring in C++ with no Dart
    frames on the stack, and the ring is a fixed size, so it costs the same
    ~750 ms whether the window was 30 s or 300 s. Left in, it appears as one
    enormous, perfectly reproducible "isolate stall" — 100 % native, no Dart
    frames, exactly one per run — that the app never had. It is the profiler's
    own footprint, and it is bracketed out here rather than reported.
    """
    if not window:
        return True
    from_us, to_us = window
    if from_us is not None and start_us < from_us:
        return False
    if to_us is not None and start_us > to_us:
        return False
    return True


def summarise_timeline(payload, top=25, window=None):
    """Total/mean/max duration per timeline event name.

    The Dart VM writes `Timeline.startSync`/`finishSync` — which is what the
    framework's BUILD, LAYOUT and PAINT blocks are — as separate `B` and `E`
    trace events, one pair per thread. Only the embedder emits pre-durationed
    `X` events. Both are folded here; anything still open when the buffer ends
    is dropped rather than guessed at.

    Blocks that started outside `window` are dropped — see [in_window].
    """
    totals = collections.Counter()
    counts = collections.Counter()
    peaks = {}
    open_blocks = collections.defaultdict(list)

    def record(name, duration):
        totals[name] += duration
        counts[name] += 1
        peaks[name] = max(peaks.get(name, 0), duration)

    for event in payload.get("traceEvents", []) or []:
        phase = event.get("ph")
        if phase == "X":
            if in_window(event.get("ts") or 0, window):
                record(event.get("name") or "?", event.get("dur") or 0)
        elif phase == "B":
            open_blocks[(event.get("pid"), event.get("tid"))].append(
                (event.get("name") or "?", event.get("ts") or 0)
            )
        elif phase == "E":
            stack = open_blocks[(event.get("pid"), event.get("tid"))]
            if stack:
                name, start = stack.pop()
                if in_window(start, window):
                    record(name, max((event.get("ts") or 0) - start, 0))

    return [
        {
            "name": name,
            "count": counts[name],
            "total_us": total,
            "mean_us": total // counts[name] if counts[name] else 0,
            "max_us": peaks.get(name, 0),
        }
        for name, total in totals.most_common(top)
    ]


def timeline_blocks(payload, window=None):
    """Every completed timeline block as {name, tid, ts, dur}.

    Same B/E pairing as summarise_timeline, but keeping each block's own
    window instead of totalling them — that window is what lets us ask which
    samples were taken *during* one specific slow block.

    Blocks that started outside `window` are dropped — see [in_window].
    """
    blocks = []
    open_blocks = collections.defaultdict(list)
    for event in payload.get("traceEvents", []) or []:
        phase = event.get("ph")
        key = (event.get("pid"), event.get("tid"))
        if phase == "X":
            if in_window(event.get("ts") or 0, window):
                blocks.append(
                    {
                        "name": event.get("name") or "?",
                        "tid": event.get("tid"),
                        "ts": event.get("ts") or 0,
                        "dur": event.get("dur") or 0,
                    }
                )
        elif phase == "B":
            open_blocks[key].append((event.get("name") or "?", event.get("ts") or 0))
        elif phase == "E":
            if open_blocks[key]:
                name, start = open_blocks[key].pop()
                if in_window(start, window):
                    blocks.append(
                        {
                            "name": name,
                            "tid": event.get("tid"),
                            "ts": start,
                            "dur": max((event.get("ts") or 0) - start, 0),
                        }
                    )
    return blocks


def find_slow_blocks(blocks, factor=3.0, floor_us=8000, min_count=5, keep=5):
    """Blocks that are slow *for their own name*.

    An absolute threshold alone is useless across a mixed workload: 12 ms is
    catastrophic for a paint and unremarkable for a page load. So compare each
    block against the median of its own name, and require an absolute floor as
    well so a 0.2 ms block being 5x its median does not get reported.

    `min_count` keeps a name from being judged against a median drawn from two
    samples. Names below it are still checked against the floor, since a block
    that ran once for 300 ms is worth seeing regardless.
    """
    by_name = collections.defaultdict(list)
    for block in blocks:
        by_name[block["name"]].append(block)

    found = []
    for name, group in by_name.items():
        durations = [b["dur"] for b in group]
        median = percentile(durations, 0.5)
        for block in group:
            if block["dur"] < floor_us:
                continue
            ratio = block["dur"] / median if median else float("inf")
            if len(group) >= min_count and ratio < factor:
                continue
            found.append({**block, "median_us": median, "ratio": ratio, "seen": len(group)})

    found.sort(key=lambda b: -b["dur"])
    return found[:keep]


def samples_in_window(samples, start_us, end_us, tid=None):
    """The samples taken while one block was on the stack."""
    return [
        sample
        for sample in samples
        if start_us <= (sample.get("timestamp") or 0) <= end_us
        and (tid is None or sample.get("tid") == tid)
    ]


def summarise_allocations(payload, top=25):
    """Largest classes on the heap.

    Current VMs report one flat `ClassHeapStats` per class; older ones split
    it into `newSpace`/`oldSpace`. Read whichever is there.
    """
    rows = []
    for member in payload.get("members", []) or []:
        size = member.get("bytesCurrent")
        instances = member.get("instancesCurrent")
        if size is None:
            old = member.get("oldSpace") or {}
            new = member.get("newSpace") or {}
            size = (old.get("bytesCurrent") or 0) + (new.get("bytesCurrent") or 0)
            instances = (old.get("instancesCurrent") or 0) + (new.get("instancesCurrent") or 0)
        if not size:
            continue
        instances = instances or 0
        name = (member.get("class") or {}).get("name") or "?"
        rows.append({"name": name, "bytes": size, "instances": instances})
    rows.sort(key=lambda row: row["bytes"], reverse=True)
    return rows[:top]


# --------------------------------------------------------------------------
# Collection
# --------------------------------------------------------------------------


def collect_frames(service, seconds):
    listening = service.listen("Extension")
    if not listening:
        raise ProfilerError("the VM refused the Extension stream")
    try:
        events = service.collect_events(seconds, kinds={"Flutter.Frame"})
    finally:
        service.cancel("Extension")
    return [e.get("extensionData") or {} for e in events]


def clip_samples(payload, window):
    """Drop samples taken outside the measured window, and say how many.

    The same self-observation that [in_window] brackets out of the timeline
    reaches the *samples* too, and gets worse the more isolates you ask for.
    `clearCpuSamples` and `getCpuSamples` are isolate-scoped: the VM hands
    them to the target isolate as out-of-band messages, and building the reply
    walks the whole sample ring in C++ with no Dart frames on the stack. With
    one isolate that work happens after the last sample we care about. With
    seven, isolate #2 is still being sampled while isolate #1 spends ~750 ms
    of CPU answering — so the profiler's own RPC lands in the *other* six
    profiles as a fat, nameless native leaf that the app never ran.

    Clipping to the bracket the VM's own clock put around the sleep removes
    it. Samples with no timestamp are kept: an unjudgeable sample is a worse
    thing to silently delete than to report.
    """
    samples = payload.get("samples") or []
    if not window:
        return payload, 0
    from_us, to_us = window
    kept = []
    dropped = 0
    for sample in samples:
        stamp = sample.get("timestamp")
        if isinstance(stamp, (int, float)) and (
            (from_us is not None and stamp < from_us)
            or (to_us is not None and stamp > to_us)
        ):
            dropped += 1
            continue
        kept.append(sample)
    if not dropped:
        return payload, 0
    clipped = dict(payload)
    clipped["samples"] = kept
    return clipped, dropped


def enable_profiler(service):
    """Turn the VM's sampling profiler on, if it is not already.

    The Flutter engine starts it from the `enable-dart-profiling` switch. The
    standalone VM behind `dart run` — the backend's `-profile` image — has no
    such switch: `--profiler` is a VM flag `dart run` will not forward, and
    the launcher form that would (`dart --profiler bin/main.dart`) was
    measured to skip the native-asset build hooks, so it comes up with the
    profiler off and `getCpuSamples` answering "Feature is disabled".

    `profiler` is one of the flags the service lets a client set at runtime,
    and setting it on attach is exactly what DevTools does. On an engine that
    already has it on this is a no-op; a release/product build has no service
    to ask, so this is never reached there.

    try_call, not call: a VM that refuses the flag still answers
    getCpuSamples with the same "Feature is disabled" it always did, and the
    report already knows how to say that.
    """
    service.try_call("setFlag", {"name": "profiler", "value": "true"}, timeout=10.0)


def collect_cpu_multi(service, isolates, seconds, period_us=250, top=25):
    """Sample several isolates over one shared window.

    One window, not one per isolate, for two reasons. Seven sequential
    15-second windows take nearly two minutes, during which the plant does
    something else. And numbers from different windows cannot be added up:
    "which of the seven costs the most" is only answerable if they were all
    measured against the same wall clock and the same denominator.

    Each isolate's samples are folded and thrown away before the next one is
    asked for. Holding all of them would be tidier code and it does not fit:
    the sidecar has a 512 MB budget, a station's ring is tens of MB of JSON
    per isolate once parsed, and asking for nine at once got the container
    OOM-killed with no output at all.

    Returns per-isolate folded views plus the *measured* elapsed time. Never
    `seconds`: everything downstream divides by it, and the RPCs either side
    of the sleep are not free.
    """
    # 1000 µs is the VM default; 250 µs gives four times the resolution, which
    # matters when a paint pass is only a couple of milliseconds long. The flag
    # is VM-wide, so it is set once however many isolates were asked for.
    enable_profiler(service)
    service.try_call("setFlag", {"name": "profile_period", "value": str(period_us)}, timeout=10.0)
    for isolate in isolates:
        service.call("clearCpuSamples", {"isolateId": isolate["id"]})
    started = timeline_now(service)
    started_at = time.monotonic()

    time.sleep(seconds)

    elapsed = time.monotonic() - started_at
    ended = timeline_now(service)
    window = (started, ended) if (started is not None and ended is not None) else None

    entries = []
    for isolate in isolates:
        payload = service.call(
            "getCpuSamples",
            {"isolateId": isolate["id"], "timeOriginMicros": 0, "timeExtentMicros": 10**15},
            timeout=180.0,
        )
        payload, dropped = clip_samples(payload, window)
        functions = payload.get("functions", []) or []
        samples = payload.get("samples", []) or []
        tags = fold_vm_tags(payload)
        # Fold only what the isolate was awake for. An idle sample's stack is
        # the futex the thread is parked in, and it dominates every table it
        # is left in — 67 % of one station isolate's "self time" was a libc
        # offset that no code of ours ever calls. VMs that do not report a tag
        # lose nothing: `busy` is then every sample, exactly as before.
        busy = [sample for sample in samples if sample.get("vmTag") != IDLE_VM_TAG]
        entries.append(
            {
                "isolate": isolate,
                "label": isolate_label(isolate),
                "id": isolate.get("id"),
                "sample_period_us": payload.get("samplePeriod") or 0,
                "dropped_samples": dropped,
                "samples": len(samples),
                "vm_tags": tags,
                "folded": fold_cpu_samples(dict(payload, samples=busy), top),
                "tree": build_call_tree(functions, busy),
            }
        )
        del payload, functions, samples, busy
    return {"entries": entries, "elapsed_s": elapsed, "window": window}


def summarise_isolate_cpu(collected):
    """Put a CPU cost on each isolate's fold, and a share on each.

    The sampling profiler fires on a fixed period against whichever thread is
    running the isolate, so `samples x period` is that isolate's CPU time over
    the window, and dividing by the window gives its share of one core. That
    is an *estimate*, and only as good as the VM's honouring of
    `profile_period` — which is why the period actually used is reported back
    beside it rather than assumed.
    """
    elapsed = collected.get("elapsed_s") or 0.0
    rows = []
    total_samples = 0
    total_busy = 0
    for entry in collected["entries"]:
        folded = entry["folded"]
        period = entry["sample_period_us"] or 0
        # Counter() rather than the value as given: a summary rendered back
        # from a `--json` dump arrives with a plain dict here.
        tags = collections.Counter(entry.get("vm_tags") or {})
        # `folded` covers the busy samples only; the raw count is what the ring
        # actually held, and their difference is what the isolate slept through.
        busy = folded["samples"]
        taken = entry.get("samples", busy)
        idle = taken - busy
        total_samples += taken
        total_busy += busy
        rows.append(
            {
                "label": entry["label"],
                "id": entry["id"],
                "samples": taken,
                "idle_samples": idle,
                "busy_samples": busy,
                "dropped_samples": entry["dropped_samples"],
                "sample_period_us": period,
                "vm_tags": dict(tags.most_common()),
                "elapsed_ms": taken * period / 1000.0,
                "cpu_ms": busy * period / 1000.0,
                "core_percent": (100.0 * busy * period / (elapsed * 1e6)) if elapsed else 0.0,
                "idle_percent": (100.0 * idle / taken) if taken else 0.0,
                "top_self": folded["self"][0]["name"] if folded["self"] else "-",
                "folded": folded,
                "tree": entry["tree"],
            }
        )
    for row in rows:
        row["share_percent"] = 100.0 * row["busy_samples"] / total_busy if total_busy else 0.0
    return {
        "elapsed_s": elapsed,
        "total_samples": total_samples,
        "total_busy_samples": total_busy,
        "isolates": rows,
    }


def collect_timeline(service, seconds):
    streams = ["Dart", "Embedder", "GC"]
    if service.try_call("setVMTimelineFlags", {"recordedStreams": streams}) is None:
        return None
    service.try_call("clearVMTimeline")
    time.sleep(seconds)
    payload = service.try_call("getVMTimeline", timeout=180.0)
    service.try_call("setVMTimelineFlags", {"recordedStreams": []})
    return payload


def timeline_now(service):
    """The VM's own timeline clock in microseconds, or None if unavailable.

    Same clock as the `ts` field on every trace event, which is what makes it
    usable as a window boundary against the recorded blocks.
    """
    stamp = service.try_call("getVMTimelineMicros", timeout=10.0)
    return (stamp or {}).get("timestamp")


def collect_window(service, isolate, seconds, period_us=250):
    """Record the timeline and the CPU profiler over the *same* window.

    This is what makes "which call path was slow" answerable rather than just
    "something was slow". Both clocks are the VM's monotonic microseconds —
    verified against a live VM: of 7302 samples taken alongside a timeline
    recording, 7144 fell inside the recorded span, and the two ranges
    interleave. So a block's [ts, ts+dur] can be used to select the samples
    taken while that block was running.

    Recording the timeline does add overhead to the samples. That is the price
    of correlating them at all, and it is the same overhead DevTools imposes.

    The returned `window` is the VM-clock bracket around the sleep alone. The
    two `*CpuSamples` RPCs either side of it are isolate-scoped, so the isolate
    handles them as ordinary messages and they land in the timeline as
    `DartIsolate::HandleMessage` blocks of their own — the profiler measuring
    itself. Callers pass the window to [summarise_timeline] and
    [timeline_blocks] to exclude them; see [in_window] for what that cost
    looked like when it was not excluded.
    """
    streams = ["Dart", "Embedder", "GC"]
    timeline_on = service.try_call("setVMTimelineFlags", {"recordedStreams": streams}) is not None
    if timeline_on:
        service.try_call("clearVMTimeline")
    enable_profiler(service)
    service.try_call("setFlag", {"name": "profile_period", "value": str(period_us)}, timeout=10.0)
    service.call("clearCpuSamples", {"isolateId": isolate})
    started = timeline_now(service)

    time.sleep(seconds)

    ended = timeline_now(service)
    cpu = service.call(
        "getCpuSamples",
        {"isolateId": isolate, "timeOriginMicros": 0, "timeExtentMicros": 10**15},
        timeout=180.0,
    )
    timeline = service.try_call("getVMTimeline", timeout=180.0) if timeline_on else None
    if timeline_on:
        service.try_call("setVMTimelineFlags", {"recordedStreams": []})
    window = (started, ended) if (started is not None or ended is not None) else None
    return {"cpu": cpu, "timeline": timeline or {}, "window": window}


def collect_memory(service, isolate):
    usage = service.try_call("getMemoryUsage", {"isolateId": isolate}) or {}
    allocations = service.try_call("getAllocationProfile", {"isolateId": isolate}, timeout=120.0)
    return usage, allocations or {}


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def ms(micros):
    return f"{(micros or 0) / 1000.0:.1f}"


def render_table(headers, rows):
    if not rows:
        return "_(nothing recorded)_\n"
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(cell) for cell in row) + " |")
    return "\n".join(out) + "\n"


def render_frames(stats):
    lines = ["### Frames\n"]
    if not stats["frames"]:
        lines.append(
            "No `Flutter.Frame` events arrived. Either the UI is idle (nothing "
            "is animating and no state changed) or this is a release build, "
            "which does not post them.\n"
        )
        return "\n".join(lines)
    lines.append(
        f"{stats['frames']} frames, {stats['janky']} over the 16.7 ms budget "
        f"({stats['janky_percent']:.1f} %), {stats['severe']} over 50 ms. "
        f"Slower half of the pipeline: **{stats['bottleneck']}**.\n"
    )
    lines.append(
        render_table(
            ["phase", "p50 ms", "p90 ms", "p99 ms", "max ms"],
            [
                [
                    phase,
                    ms(stats[key]["p50"]),
                    ms(stats[key]["p90"]),
                    ms(stats[key]["p99"]),
                    ms(stats[key]["max"]),
                ]
                for phase, key in (
                    ("build (UI thread)", "build_us"),
                    ("raster (GPU thread)", "raster_us"),
                    ("total", "elapsed_us"),
                )
            ],
        )
    )
    return "\n".join(lines)


def render_cpu(folded):
    lines = ["### CPU\n"]
    if not folded["samples"]:
        lines.append(
            "No CPU samples. The isolate was idle, or the VM refused to turn "
            "its profiler on (`setFlag profiler` is sent before every window; "
            "a release/product build has no profiler to turn on).\n"
        )
        return "\n".join(lines)
    lines.append(
        f"{folded['samples']} samples at {folded['sample_period_us'] or '?'} µs.\n"
    )
    lines.append("**Self time** — where the CPU actually burns:\n")
    lines.append(
        render_table(
            ["%", "samples", "function"],
            [[f"{r['percent']:.1f}", r["samples"], r["name"]] for r in folded["self"]],
        )
    )
    lines.append("**Inclusive time** — functions that contain the cost:\n")
    lines.append(
        render_table(
            ["%", "samples", "function"],
            [[f"{r['percent']:.1f}", r["samples"], r["name"]] for r in folded["inclusive"]],
        )
    )
    lines.append("**By package** (self time):\n")
    lines.append(
        render_table(
            ["%", "samples", "package"],
            [[f"{r['percent']:.1f}", r["samples"], r["name"]] for r in folded["packages"]],
        )
    )
    return "\n".join(lines)


def render_hot_paths(folded, tree, min_percent=2.0):
    lines = ["### Hot paths\n"]
    if not tree["total"]:
        lines.append("_(no samples — the isolate was idle)_\n")
        return "\n".join(lines)
    path = dominant_path(tree)
    if path:
        lines.append("Heaviest chain:\n")
        lines.append("```\n" + "\n  -> ".join(_compress_chain(path)) + "\n```\n")
    lines.append(f"Full tree (>={min_percent:g}% of samples, straight runs collapsed):\n")
    lines.append("```\n" + render_call_tree(tree, min_percent=min_percent) + "```\n")
    return "\n".join(lines)


def render_isolate_summary(summary):
    """The across-isolates table: who is actually burning the container's CPU."""
    lines = ["### Isolates\n"]
    elapsed = summary["elapsed_s"]
    lines.append(
        f"{summary['total_samples']} samples over a measured {elapsed:.1f} s "
        f"window shared by every isolate below, {summary['total_busy_samples']} "
        "of them taken while the isolate had something to run.\n"
    )
    lines.append(
        render_table(
            [
                "isolate",
                "samples",
                "idle %",
                "CPU ms",
                "% of a core",
                "% of busy",
                "top self function",
            ],
            [
                [
                    row["label"],
                    row["samples"],
                    f"{row['idle_percent']:.0f}",
                    f"{row['cpu_ms']:.0f}",
                    f"{row['core_percent']:.1f}",
                    f"{row['share_percent']:.1f}",
                    row["top_self"],
                ]
                for row in summary["isolates"]
            ],
        )
    )
    lines.append(
        "_The Dart profiler is a wall-clock sampler, so a parked isolate is "
        "sampled as busily as a working one — its stack is one nameless libc "
        "frame with no Dart caller. `idle %` is the share of samples the VM "
        "tagged `Idle`; CPU ms and % of a core count only the rest, divided "
        "by the measured window and never by `--seconds`. Cross-check the "
        "total against `system`'s per-thread CPU._\n"
    )
    dropped = sum(row["dropped_samples"] for row in summary["isolates"])
    if dropped:
        lines.append(
            f"_{dropped} samples fell outside the window and were dropped — "
            "the profiler's own `getCpuSamples` RPC, which each isolate "
            "services itself. See [clip_samples]._\n"
        )
    return "\n".join(lines)


def render_isolate_cpu(summary, tree_min_percent=2.0):
    """Summary table, then the usual self/inclusive/tree per isolate."""
    parts = []
    if len(summary["isolates"]) > 1:
        parts.append(render_isolate_summary(summary))
    for row in summary["isolates"]:
        parts.append(f"## {row['label']} · `{row['id']}`\n")
        tags = ", ".join(f"{name} {count}" for name, count in row["vm_tags"].items())
        parts.append(
            f"{row['samples']} samples, {row['idle_samples']} of them idle. "
            f"Everything below is the other {row['busy_samples']} — "
            f"{row['cpu_ms']:.0f} ms of CPU, {row['core_percent']:.1f}% of a core."
            + (f" VM tags: {tags}.\n" if tags else "\n")
        )
        parts.append(render_hot_paths(row["folded"], row["tree"], tree_min_percent))
        parts.append(render_cpu(row["folded"]))
    return "\n".join(parts)


def render_slow_blocks(slow, functions, samples, tree_min_percent=8.0):
    """Each outlier with the stack that was on the CPU while it ran."""
    lines = ["### Slow outliers\n"]
    if not slow:
        lines.append(
            "_(no block ran unusually long for its own name — that is a good "
            "result, not a missing one)_\n"
        )
        return "\n".join(lines)
    lines.append(
        "Blocks that took far longer than the median for their own name. "
        "The tree under each is only the samples taken *during that block*.\n"
    )
    for block in slow:
        ratio = "n/a" if block["ratio"] == float("inf") else f"{block['ratio']:.1f}x"
        lines.append(
            f"**{block['name']}** — {ms(block['dur'])} ms, {ratio} its median "
            f"of {ms(block['median_us'])} ms (seen {block['seen']}x)\n"
        )
        window = samples_in_window(
            samples, block["ts"], block["ts"] + block["dur"], block.get("tid")
        )
        if not window:
            lines.append(
                "_(no CPU samples landed in this window — it was blocked, not "
                "computing: waiting on I/O, a lock, or the platform thread)_\n"
            )
            continue
        subtree = build_call_tree(functions, window)
        lines.append(f"```\n{render_call_tree(subtree, min_percent=tree_min_percent)}```\n")
    return "\n".join(lines)


def _as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def render_actions(data):
    """The short answer, first, so nothing has to read the tables to start."""
    actions = []
    frames = data["frames"]
    if frames["frames"] and frames["janky_percent"] > 5:
        actions.append(
            f"{frames['janky_percent']:.0f}% of frames missed 16.7 ms and the "
            f"**{frames['bottleneck']}** thread is the slower one "
            f"(p90 build {ms(frames['build_us']['p90'])} ms, "
            f"raster {ms(frames['raster_us']['p90'])} ms)."
        )
    if data["cpu"]["self"]:
        top = data["cpu"]["self"][0]
        actions.append(f"Hottest single function: `{top['name']}` at {top['percent']:.0f}% of samples.")
    packages = data["cpu"]["packages"]
    if packages and packages[0]["percent"] > 30:
        actions.append(
            f"{packages[0]['percent']:.0f}% of CPU is inside `{packages[0]['name']}`."
        )
    if data.get("hot_path"):
        # Compress first, then take the tail: the last four raw frames of a
        # recursive path are four copies of the same name and say nothing.
        tail = _compress_chain(data["hot_path"])[-4:]
        actions.append("Dominant chain: " + " -> ".join(tail) + ".")
    if data.get("slow"):
        worst = data["slow"][0]
        actions.append(
            f"Worst outlier: `{worst['name']}` at {ms(worst['dur'])} ms — see "
            "Slow outliers for the stack."
        )
    for row in data.get("containers", []):
        if (row.get("memory_percent") or 0) > 85:
            actions.append(
                f"`{row['name']}` is at {row['memory_percent']:.0f}% of its "
                "memory limit — an OOM kill is a restart, not a slow frame."
            )
        if (row.get("cpu_percent") or 0) > 150:
            actions.append(
                f"`{row['name']}` is using {row['cpu_percent']:.0f}% CPU "
                "(more than one core)."
            )
    process = data.get("process")
    heap = (data.get("memory_usage") or {}).get("heapUsage")
    if process and heap:
        native = process["rss_kb"] * 1024 - heap
        if native > 4 * heap and native > 200e6:
            actions.append(
                f"{native / 1e6:.0f} MB of RSS is outside the Dart heap "
                f"({heap / 1e6:.0f} MB) — look at native allocations, not Dart."
            )
    for row in (data.get("thread_cpu") or [])[:1]:
        if row["percent"] > 60:
            actions.append(f"Busiest thread is `{row['name']}` at {row['percent']:.0f}% of a core.")
    activity = ((data.get("postgres") or {}).get("activity") or {}).get("rows") or []
    slow_queries = [r for r in activity if len(r) > 2 and _as_float(r[2]) > 1.0]
    if slow_queries:
        actions.append(
            f"{len(slow_queries)} database quer{'y' if len(slow_queries) == 1 else 'ies'} "
            f"running longer than a second — slowest {slow_queries[-1][2]}s."
        )
    if not actions:
        actions.append(
            "Nothing stands out. If the app was idle during the window this "
            "says nothing — drive the UI and run it again."
        )
    return "### Where to look\n\n" + "\n".join(f"- {a}" for a in actions) + "\n"


def render_timeline(rows):
    lines = ["### Timeline\n"]
    if not rows:
        lines.append(
            "_(no completed timeline blocks — either the VM refused the "
            "timeline streams or nothing ran during the window)_\n"
        )
        return "\n".join(lines)
    lines.append(
        render_table(
            ["event", "count", "total ms", "mean ms", "max ms"],
            [
                [r["name"], r["count"], ms(r["total_us"]), ms(r["mean_us"]), ms(r["max_us"])]
                for r in rows
            ],
        )
    )
    return "\n".join(lines)


def render_memory(usage, classes):
    lines = ["### Memory\n"]
    heap = usage.get("heapUsage")
    if heap is not None:
        lines.append(
            f"Heap {heap / 1e6:.1f} MB of {usage.get('heapCapacity', 0) / 1e6:.1f} MB "
            f"capacity, external {usage.get('externalUsage', 0) / 1e6:.1f} MB.\n"
        )
    lines.append(
        render_table(
            ["class", "MB", "instances"],
            [[r["name"], f"{r['bytes'] / 1e6:.2f}", r["instances"]] for r in classes],
        )
    )
    return "\n".join(lines)


def render_containers(rows):
    lines = ["### Containers\n"]
    if not rows:
        lines.append(
            "_(no container stats — the Docker socket is not mounted into this "
            "container, so only the app it is attached to can be seen)_\n"
        )
        return "\n".join(lines)
    table = []
    for row in rows:
        if row.get("error"):
            table.append([row["name"], "-", "-", "-", row["error"][:40]])
            continue
        limit = row["memory_limit"]
        if row["memory_bytes"] is None:
            memory = "-"
        elif limit:
            memory = (
                f"{row['memory_bytes'] / 1e6:.0f} / {limit / 1e6:.0f} MB "
                f"({row['memory_percent']:.0f}%)"
            )
        else:
            memory = f"{row['memory_bytes'] / 1e6:.0f} MB"
        table.append(
            [
                row["name"],
                f"{row['cpu_percent']:.1f}" if row["cpu_percent"] is not None else "-",
                memory,
                row["pids"] if row["pids"] is not None else "-",
                "",
            ]
        )
    lines.append(render_table(["container", "CPU %", "memory", "tasks", "note"], table))
    if any("Permission denied" in (r.get("error") or "") for r in rows):
        lines.append(
            "The Docker socket is not readable by this container's user. Add "
            "the host's docker group to the profiler service — "
            "`group_add: [\"<gid>\"]`, where the gid comes from "
            "`getent group docker` **on that station**; it is not the same "
            "everywhere. Everything outside this section works without it.\n"
        )
    hot = [r for r in rows if (r.get("memory_percent") or 0) > 85]
    if hot:
        lines.append(
            "**"
            + ", ".join(r["name"] for r in hot)
            + "** is within 15% of its memory limit — the next allocation spike "
            "is an OOM kill, not a slowdown.\n"
        )
    return "\n".join(lines)


def render_threads(snapshot, cpu_rows, dart_heap_bytes=None):
    lines = ["### Process and threads\n"]
    if not snapshot:
        lines.append(
            "_(no process found in /proc — this container does not share the "
            "app's PID namespace. Add `pid: \"service:flutter\"` to see "
            "threads.)_\n"
        )
        return "\n".join(lines)
    rss = snapshot["rss_kb"] * 1024
    line = f"`{snapshot['name']}` pid {snapshot['pid']}: RSS {rss / 1e6:.0f} MB, {snapshot['threads']} threads."
    if dart_heap_bytes:
        native = rss - dart_heap_bytes
        line += (
            f" Dart heap is {dart_heap_bytes / 1e6:.0f} MB of that, so "
            f"**{native / 1e6:.0f} MB is native** — engine, Skia, pdfium, "
            "open62541. A leak there is invisible to the Memory section below."
        )
    lines.append(line + "\n")
    if cpu_rows:
        lines.append(
            render_table(
                ["thread", "CPU %", "tid"],
                [[r["name"], f"{r['percent']:.1f}", r["tid"]] for r in cpu_rows[:15]],
            )
        )
        lines.append(
            "`io.flutter.ui` is the Dart/build thread and `io.flutter.raster` "
            "the GPU one (the kernel truncates thread names at 15 characters, "
            "so it appears as `io.flutter.rast`). Which of the two is busy "
            "decides whether the fix is in your widgets or in what you are "
            "asking Skia to draw.\n"
        )
    return "\n".join(lines)


def render_postgres(sections):
    lines = ["### Database\n"]
    if not sections:
        lines.append("_(no database configured — set CENTROID_PGHOST or --pg-url)_\n")
        return "\n".join(lines)
    if sections.get("error"):
        lines.append(f"_({sections['error']})_\n")
        return "\n".join(lines)
    # "counters" sits next to "database" because it is what the numbers there
    # -- and in "scans" -- are counted over.
    for key in ("database", "counters", "activity", "scans", "sizes", "statements"):
        section = sections.get(key)
        if not section:
            continue
        lines.append(f"**{section['title']}**\n")
        if section.get("error"):
            lines.append(f"_({section['error']})_\n")
            continue
        lines.append(render_table(section["headers"], section["rows"]))
    return "\n".join(lines)


def render_report(data):
    lines = [
        f"# CentroidX profile — {data['collected_at']}",
        "",
        f"`{data['url']}` · isolate "
        f"`{data.get('isolate_label') or data['isolate']}` · "
        f"{data['seconds']} s window · Dart VM {data.get('vm_version', '?')}",
        "",
        render_actions(data),
        render_frames(data["frames"]),
        # `.get` throughout: a report can also be rendered from a JSON dump
        # written by an older version of this script, and a missing section
        # should read as empty rather than crash the whole document.
        render_slow_blocks(
            data.get("slow", []), data.get("_functions", []), data.get("_samples", [])
        ),
        render_hot_paths(data["cpu"], data.get("tree") or _tree_node("<all>")),
        render_cpu(data["cpu"]),
        render_timeline(data["timeline"]),
        render_threads(
            data.get("process"),
            data.get("thread_cpu", []),
            (data.get("memory_usage") or {}).get("heapUsage"),
        ),
        render_memory(data["memory_usage"], data["memory_classes"]),
        render_containers(data.get("containers", [])),
        render_postgres(data.get("postgres")),
    ]
    if data.get("problems"):
        lines.append("### Not collected\n")
        lines.extend(f"- {problem}" for problem in data["problems"])
        lines.append("")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def gather(
    service,
    seconds,
    top,
    want=("frames", "cpu", "timeline", "memory"),
    period=250,
    slow_factor=3.0,
    slow_floor_us=8000,
    keep=5,
    proc_root="/proc",
    proc_match=("centroidx",),
    docker_client=None,
    pg_url=None,
    isolate_selector=None,
):
    """Collect one window. Phases run in sequence so they do not perturb
    each other — a timeline recording distorts the CPU profile."""
    chosen = one_isolate(service.isolates(), isolate_selector, "report")
    isolate = chosen["id"]
    version = service.try_call("getVersion") or {}
    # Taken before the window so the thread CPU deltas cover it.
    proc_pid = find_process(proc_root, proc_match)
    proc_before = process_snapshot(proc_pid, proc_root) if proc_pid else None
    proc_before_at = time.monotonic()
    data = {
        "collected_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "seconds": seconds,
        "isolate": isolate,
        "isolate_label": isolate_label(chosen),
        "vm_version": f"{version.get('major', '?')}.{version.get('minor', '?')}",
        "frames": frame_stats([]),
        "cpu": fold_cpu_samples({}),
        "timeline": [],
        "memory_usage": {},
        "memory_classes": [],
        "tree": _tree_node("<all>"),
        "hot_path": [],
        "slow": [],
        "_functions": [],
        "_samples": [],
        "process": None,
        "thread_cpu": [],
        "containers": [],
        "postgres": None,
        "problems": [],
    }
    problems = []

    def attempt(section, work):
        # One unavailable section must not cost us the other three: a station
        # that answers `getVM` but refuses `getCpuSamples` still has frame
        # timings worth reading.
        if section not in want:
            return
        try:
            work()
        except ConnectionClosed:
            # The app went away. Collecting the remaining sections would only
            # produce three more identical failures; let the caller reconnect.
            raise
        except (ProfilerError, TimeoutError) as exc:
            problems.append(f"{section}: {exc}")

    attempt("frames", lambda: data.update(frames=frame_stats(collect_frames(service, seconds))))

    def do_window():
        # Timeline and CPU in ONE window, not two: sliced against each other
        # they answer "what was running during the slow block", which two
        # windows recorded minutes apart cannot.
        window = collect_window(service, isolate, seconds, period)
        cpu = window["cpu"]
        functions = cpu.get("functions", []) or []
        samples = cpu.get("samples", []) or []
        data["cpu"] = fold_cpu_samples(cpu, top)
        tree = build_call_tree(functions, samples)
        data["tree"] = tree
        data["hot_path"] = dominant_path(tree)
        data["timeline"] = summarise_timeline(window["timeline"], top, window=window.get("window"))
        blocks = timeline_blocks(window["timeline"], window=window.get("window"))
        data["slow"] = find_slow_blocks(
            blocks, factor=slow_factor, floor_us=slow_floor_us, keep=keep
        )
        data["_functions"] = functions
        data["_samples"] = samples

    attempt("cpu", do_window)

    def do_memory():
        usage, allocations = collect_memory(service, isolate)
        data["memory_usage"] = usage or (allocations.get("memoryUsage") or {})
        data["memory_classes"] = summarise_allocations(allocations, top)

    attempt("memory", do_memory)

    def do_system():
        # /proc is sampled either side of everything above, so the thread
        # percentages cover the same wall clock as the call trees. The divisor
        # is the MEASURED elapsed time, not `seconds`: the phases above take
        # longer than one window, and dividing by the requested sleep reported
        # a single busy thread at 352% of a core.
        after = process_snapshot(proc_pid, proc_root) if proc_pid else None
        data["process"] = after
        data["thread_cpu"] = thread_cpu(
            proc_before, after, time.monotonic() - proc_before_at
        )

    if proc_pid:
        attempt("threads", do_system)

    def do_containers():
        data["containers"] = collect_containers(docker_client)

    if docker_client is not None and docker_client.available():
        attempt("containers", do_containers)

    if pg_url:
        attempt("database", lambda: data.update(postgres=collect_postgres(pg_url)))

    data["problems"] = problems
    return data


def json_safe(data):
    """Drop the raw sample arrays; they are megabytes and say nothing on
    their own. The folded views above them carry the meaning."""
    if not isinstance(data, dict):
        return data
    return {key: value for key, value in data.items() if not key.startswith("_")}


def emit(args, data, body):
    if args.json:
        text = json.dumps(json_safe(data), indent=2, sort_keys=True, default=str)
    else:
        text = body
    print(text)
    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%S")
        suffix = "json" if args.json else "md"
        path = os.path.join(args.out_dir, f"profile-{stamp}.{suffix}")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"\n<!-- written to {path} -->", file=sys.stderr)


def cmd_status(service, args):
    version = service.try_call("getVersion") or {}
    vm = service.call("getVM")
    isolate_id = service.main_isolate()
    usage = service.try_call("getMemoryUsage", {"isolateId": isolate_id}) or {}
    data = {
        "url": args.url,
        "vm_version": f"{version.get('major', '?')}.{version.get('minor', '?')}",
        "name": vm.get("name"),
        "pid": vm.get("pid"),
        "uptime_s": round(vm.get("startTime", 0) and (time.time() - vm["startTime"] / 1000.0), 1),
        # Labelled, not just named: seven of ours answer to `_isolateEntryPoint`
        # and `--isolate` needs something that tells them apart.
        "isolates": [isolate_label(i) for i in index_isolates(vm.get("isolates") or [])],
        "main_isolate": isolate_id,
        "heap_mb": round(usage.get("heapUsage", 0) / 1e6, 1),
        "external_mb": round(usage.get("externalUsage", 0) / 1e6, 1),
    }
    body = "\n".join(f"{key:>14}: {value}" for key, value in data.items())
    emit(args, data, body)


def cmd_frames(service, args):
    stats = frame_stats(collect_frames(service, args.seconds))
    emit(args, stats, render_frames(stats))


def cmd_cpu(service, args):
    """Hot functions, for one isolate or for all ten over one window."""
    isolates = select_isolates(service.isolates(), args.isolate)
    collected = collect_cpu_multi(service, isolates, args.seconds, args.period, args.top)
    summary = summarise_isolate_cpu(collected)
    for row in summary["isolates"]:
        row["folded"]["hot_path"] = dominant_path(row["tree"])
    body = render_isolate_cpu(summary, args.tree_percent)
    # The call trees are megabytes and mean nothing outside the renderer; the
    # folded views beside them carry everything a reader acts on.
    data = {
        "elapsed_s": summary["elapsed_s"],
        "total_samples": summary["total_samples"],
        "isolates": [
            {key: value for key, value in row.items() if key != "tree"}
            for row in summary["isolates"]
        ],
    }
    emit(args, data, body)


def cmd_slow(service, args):
    """Long-running outlier hunt: keep recording windows, and every time a
    block runs far longer than its own median, print it with the stack that
    was on the CPU while it ran."""
    isolate = one_isolate(service.isolates(), args.isolate, "slow")["id"]
    while True:
        try:
            window = collect_window(service, isolate, args.seconds, args.period)
        except ConnectionClosed as exc:
            print(f"[{time.strftime('%H:%M:%S')}] lost the VM service: {exc}", file=sys.stderr)
            service.reconnect(args.url, wait=max(args.interval, 30.0))
            # Isolate ids do not survive a restart: re-resolve, never reuse.
            isolate = one_isolate(service.isolates(), args.isolate, "slow")["id"]
            continue
        cpu = window["cpu"]
        functions = cpu.get("functions", []) or []
        samples = cpu.get("samples", []) or []
        blocks = timeline_blocks(window["timeline"], window=window.get("window"))
        slow = find_slow_blocks(
            blocks,
            factor=args.slow_factor,
            floor_us=int(args.slow_floor_ms * 1000),
            keep=args.keep,
        )
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        data = {
            "collected_at": stamp,
            "url": args.url,
            "seconds": args.seconds,
            "blocks": len(blocks),
            "samples": len(samples),
            "slow": slow,
        }
        body = (
            f"## {stamp} — {len(blocks)} blocks, {len(samples)} samples "
            f"over {args.seconds:g} s\n\n"
            + render_slow_blocks(slow, functions, samples)
        )
        emit(args, data, body)
        if not args.repeat:
            return
        slack = args.interval - args.seconds
        if slack > 0:
            time.sleep(slack)


def cmd_timeline(service, args):
    payload = collect_timeline(service, args.seconds)
    rows = summarise_timeline(payload, args.top) if payload else []
    emit(args, rows, render_timeline(rows))


def cmd_memory(service, args):
    isolates = select_isolates(service.isolates(), args.isolate)
    sections = []
    body = []
    for isolate in isolates:
        usage, allocations = collect_memory(service, isolate["id"])
        classes = summarise_allocations(allocations, args.top)
        label = isolate_label(isolate)
        sections.append({"isolate": label, "usage": usage, "classes": classes})
        if len(isolates) > 1:
            body.append(f"## {label} · `{isolate['id']}`\n")
        body.append(render_memory(usage, classes))
    data = sections[0] if len(sections) == 1 else {"isolates": sections}
    emit(args, data, "\n".join(body))


def cmd_system(service, args):
    """Containers, threads and the database — the view from outside the VM.

    Useful on its own: when the app is wedged and the VM service will not
    answer, this still says whether it is pegged, swapping, or waiting on a
    query.
    """
    pid = find_process(args.proc_root, tuple(args.proc_match.split(",")))
    before = process_snapshot(pid, args.proc_root) if pid else None
    started = time.monotonic()
    client = None if args.no_docker else DockerClient(args.docker_socket)
    # Collecting container stats is not instant — the daemon samples each
    # container twice, about a second apart — so it counts towards the window
    # rather than being ignored.
    containers = collect_containers(client) if client and client.available() else []
    remaining = args.seconds - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)
    after = process_snapshot(pid, args.proc_root) if pid else None
    elapsed = time.monotonic() - started
    pg_url = None if args.no_database else (args.pg_url or pg_url_from_env())
    postgres = collect_postgres(pg_url) if pg_url else None
    data = {
        "collected_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "process": after,
        "thread_cpu": thread_cpu(before, after, elapsed),
        "containers": containers,
        "postgres": postgres,
    }
    body = "\n".join(
        [
            f"# System — {data['collected_at']}",
            "",
            render_containers(containers),
            render_threads(after, data["thread_cpu"]),
            render_postgres(postgres),
        ]
    )
    emit(args, data, body)


def cmd_report(service, args):
    data = gather(
        service,
        args.seconds,
        args.top,
        period=args.period,
        slow_factor=args.slow_factor,
        slow_floor_us=int(args.slow_floor_ms * 1000),
        keep=args.keep,
        proc_match=tuple(args.proc_match.split(",")),
        docker_client=None if args.no_docker else DockerClient(args.docker_socket),
        pg_url=None if args.no_database else (args.pg_url or pg_url_from_env()),
        isolate_selector=args.isolate,
    )
    data["url"] = args.url
    emit(args, data, render_report(data))


def cmd_watch(service, args):
    """One report per interval, until interrupted. Reconnects if the app
    restarts — a station that crashes is exactly when you want the log."""
    while True:
        started = time.monotonic()
        try:
            data = gather(
                service,
                args.seconds,
                args.top,
                period=args.period,
                slow_factor=args.slow_factor,
                slow_floor_us=int(args.slow_floor_ms * 1000),
                keep=args.keep,
                proc_match=tuple(args.proc_match.split(",")),
                docker_client=None if args.no_docker else DockerClient(args.docker_socket),
                pg_url=None if args.no_database else (args.pg_url or pg_url_from_env()),
                isolate_selector=args.isolate,
            )
            data["url"] = args.url
            emit(args, data, render_report(data))
        except (ProfilerError, TimeoutError) as exc:
            print(f"[{time.strftime('%H:%M:%S')}] lost the VM service: {exc}", file=sys.stderr)
            service.reconnect(args.url, wait=max(args.interval, 30.0))
            continue
        slack = args.interval - (time.monotonic() - started)
        if slack > 0:
            time.sleep(slack)


COMMANDS = {
    "status": cmd_status,
    "frames": cmd_frames,
    "cpu": cmd_cpu,
    "timeline": cmd_timeline,
    "memory": cmd_memory,
    "slow": cmd_slow,
    "system": cmd_system,
    "report": cmd_report,
    "watch": cmd_watch,
}


def build_parser():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("command", choices=sorted(COMMANDS), help="what to collect")
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"VM service WebSocket URI (default {DEFAULT_URL})",
    )
    parser.add_argument(
        "--seconds", type=float, default=15.0, help="length of each collection window"
    )
    parser.add_argument(
        "--interval", type=float, default=300.0, help="watch: seconds between reports"
    )
    parser.add_argument("--top", type=int, default=25, help="rows per table")
    parser.add_argument(
        "--tree-percent",
        type=float,
        default=2.0,
        help=(
            "cpu: prune call-tree branches below this share of samples "
            "(default 2). Lower it to find where a cost that the flat tables "
            "show is real reaches the tree by many small paths."
        ),
    )
    parser.add_argument(
        "--isolate",
        default=None,
        help=(
            "which isolate(s) to profile: a name substring, a VM isolate "
            "number, `#index`, `all`, or a comma-separated union of those. "
            "Default: `main`, as before. `cpu` and `memory` take many; "
            "`report`, `slow` and `watch` need exactly one. `status` lists them."
        ),
    )
    parser.add_argument(
        "--period", type=int, default=250, help="CPU sampling period in microseconds"
    )
    parser.add_argument(
        "--wait",
        type=float,
        default=0.0,
        help="keep retrying the connection for this many seconds",
    )
    parser.add_argument(
        "--slow-factor",
        type=float,
        default=3.0,
        help="a block is an outlier at this multiple of its own median (default 3)",
    )
    parser.add_argument(
        "--slow-floor-ms",
        type=float,
        default=8.0,
        help="never report a block shorter than this, whatever its ratio (default 8)",
    )
    parser.add_argument("--keep", type=int, default=5, help="outliers to report per window")
    parser.add_argument(
        "--repeat", action="store_true", help="slow: keep hunting instead of one window"
    )
    parser.add_argument(
        "--proc-root", default="/proc", help="where to look for the app's process"
    )
    parser.add_argument(
        "--proc-match",
        default="centroidx",
        help="comma-separated names to find the app process by (needs a shared PID namespace)",
    )
    parser.add_argument(
        "--docker-socket", default="/var/run/docker.sock", help="Docker API socket"
    )
    parser.add_argument("--no-docker", action="store_true", help="skip container stats")
    parser.add_argument(
        "--pg-url", default=None, help="libpq URL; defaults to the CENTROID_PG* environment"
    )
    parser.add_argument("--no-database", action="store_true", help="skip database stats")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    parser.add_argument("--out-dir", default=None, help="also write each report into this directory")
    return parser


#: These need no Dart VM at all, and must still work when the app is wedged
#: and the service will not answer — which is exactly when they matter most.
NO_VM_COMMANDS = {"system"}


def main(argv=None):
    args = build_parser().parse_args(argv)
    service = None
    if args.command not in NO_VM_COMMANDS:
        try:
            service = VmService.connect(args.url, wait=args.wait)
        except ProfilerError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    try:
        COMMANDS[args.command](service, args)
    except KeyboardInterrupt:
        return 130
    except ProfilerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    finally:
        if service is not None:
            service.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
