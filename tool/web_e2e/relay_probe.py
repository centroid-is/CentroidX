"""A read-only conformance sweep of a live relay gateway.

    python tool/web_e2e/relay_probe.py wss://10.104.60.84:9443 <ca.pem> <user> <pw>

Drives the wire the way a panel does -- hello, sign in, read, subscribe --
and reports what each family answers. Faster and far more precise than driving
a browser: a failure names a method and a payload instead of a blank rectangle.

**Read-only by construction.** The mutating half of the surface is listed in
`FORBIDDEN` and never called, because a `write` on this wire is an actuation on
a real machine and `accessAdmin.*` / `preferences.set*` would edit the plant's
configuration. The sweep checks that they are *refused* for an anonymous
session by reading the policy's answer, never by attempting one signed in.

Two sessions are opened: one that never signs in (which must be refused
everything that carries plant data) and one that does (which must be served).
"""

import asyncio
import json
import ssl
import sys

import websockets

PROTOCOL = "2026-08-13"

# Never called. A write actuates a machine; the rest edit the plant's
# configuration or its accounts.
FORBIDDEN = {
    "write", "ackAlarm", "bye",
    "preferences.setString", "preferences.setBool", "preferences.setInt",
    "preferences.setDouble", "preferences.setStringList", "preferences.remove",
    "preferences.clear",
    "backendConfig.write", "backendConfig.restorePrevious",
    "historyViews.createHistoryView", "historyViews.updateHistoryView",
    "historyViews.deleteHistoryView", "historyViews.addHistoryViewPeriod",
    "historyViews.deleteHistoryViewPeriod",
    "accessTemplates.create", "accessTemplates.update", "accessTemplates.delete",
    "accessTemplates.rename", "accessTemplates.bind", "accessTemplates.unbind",
}

# method -> params, for everything the sweep does call.
READS = [
    ("ping", {}),
    ("configItems.fingerprint", {"kinds": ["page", "asset"]}),
    ("configItems.items", {"kind": "page"}),
    ("preferences.getKeys", {}),
    ("preferences.getString", {"key": "alarm_man_config"}),
    ("preferences.containsKey", {"key": "shift_config"}),
    ("alarmHistory", {"limit": 5}),
    ("audit.entries", {"query": {"limit": 5}}),
    ("audit.distinctWho", {}),
    ("accessAdmin.listUsers", {}),
    ("accessAdmin.roles", {}),
    ("accessTemplates.list", {}),
    ("accessTemplates.bindings", {}),
    ("historyViews.selectHistoryViews", {}),
    ("historyViews.getGlobalRetentionHorizon", {}),
    ("browse.fetchRoots", {}),
]


class Wire:
    def __init__(self, ws):
        self.ws = ws
        self._id = 0
        self.updates = []
        self._hb = None

    async def send(self, method, params=None):
        self._id += 1
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self._id,
                                       "method": method, "params": params or {}}))
        return self._id

    async def call(self, method, params=None, timeout=25):
        want = await self.send(method, params)
        loop = asyncio.get_event_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            msg = json.loads(await asyncio.wait_for(self.ws.recv(), 10))
            if msg.get("method") == "u":
                self.updates.append(msg)
            if msg.get("id") == want:
                return msg
        return {"error": {"message": "no answer within %ss" % timeout}}

    async def drain(self, seconds):
        loop = asyncio.get_event_loop()
        end = loop.time() + seconds
        while loop.time() < end:
            try:
                msg = json.loads(await asyncio.wait_for(self.ws.recv(), 2))
            except asyncio.TimeoutError:
                continue
            if msg.get("method") == "u":
                self.updates.append(msg)

    def heartbeat(self):
        async def beat():
            while True:
                await asyncio.sleep(2)
                await self.send("ping")
        self._hb = asyncio.create_task(beat())
        return self._hb

    def stop(self):
        if self._hb:
            self._hb.cancel()


def outcome(answer):
    if "error" in answer:
        msg = answer["error"].get("message", "")
        return "REFUSED", msg.split("—")[0].strip()[:90]
    result = answer.get("result")
    if isinstance(result, list):
        return "ok", f"{len(result)} rows"
    if isinstance(result, dict):
        return "ok", ", ".join(list(result)[:4])[:70]
    return "ok", str(result)[:60]


async def sweep(url, ca, user, pw):
    ctx = ssl.create_default_context(cafile=ca)
    failures = []

    # --- the session nobody signed in on -------------------------------------
    async with websockets.connect(url, ssl=ctx, max_size=20_000_000) as ws:
        w = Wire(ws)
        w.heartbeat()
        hello = await w.call("hello", {"protocol": PROTOCOL, "supported": [PROTOCOL],
                                       "client": {"name": "probe", "version": "0"}})
        print("== anonymous session")
        print("   hello:", outcome(hello)[1])
        for method, params in READS:
            state, detail = outcome(await w.call(method, params))
            carries_plant_data = method != "ping"
            if carries_plant_data and state == "ok":
                failures.append(f"{method} served an anonymous session: {detail}")
            print(f"   {method:42} {state:8} {detail}")
        w.stop()

    # --- signed in ------------------------------------------------------------
    async with websockets.connect(url, ssl=ctx, max_size=20_000_000) as ws:
        w = Wire(ws)
        w.heartbeat()
        await w.call("hello", {"protocol": PROTOCOL, "supported": [PROTOCOL],
                               "client": {"name": "probe", "version": "0"}})
        login = await w.call("session.login", {"username": user, "password": pw})
        if "error" in login:
            print("!! sign-in refused:", login["error"].get("message", "")[:120])
            return 1
        print("\n== signed in as", user)
        for method, params in READS:
            state, detail = outcome(await w.call(method, params))
            if state == "REFUSED":
                failures.append(f"{method} refused a signed-in session: {detail}")
            print(f"   {method:42} {state:8} {detail}")

        # Quality and snapshot: the thing a mimic actually depends on.
        items = await w.call("configItems.items", {"kind": "key_mapping"})
        keys = [row["id"] for row in items["result"]][:120]
        sub = await w.call("subscribe", {"sub": "sweep", "keys": keys})
        snap = sub.get("result", {}).get("snapshot") or {}
        quality = {}
        for entry in snap.values():
            quality[entry.get("q", "none")] = quality.get(entry.get("q", "none"), 0) + 1
        print(f"\n== subscribe: {len(keys)} keys, snapshot carries {len(snap)}")
        print("   quality histogram (192 good, 516 badStale):", quality)
        if quality.get(516, 0) > len(snap) / 2:
            failures.append(f"{quality.get(516)} of {len(snap)} snapshot values are "
                            "badStale — a mimic draws those as unknown")

        await w.drain(12)
        changed = set()
        for frame in w.updates:
            changed.update((frame.get("params") or {}).get("c", {}))
        print(f"   update frames in 12 s: {len(w.updates)}, handles changed: {len(changed)}")

        # Negative cases: the wire's own guards.
        print("\n== guards")
        for method, params, expect in [
            ("nosuch.method", {}, "unknown method"),
            ("hello", {"protocol": PROTOCOL, "supported": [PROTOCOL],
                       "client": {"name": "x", "version": "0"}}, "second hello"),
            ("configItems.items", {"kind": "not_a_kind"}, "bad kind"),
            # An unknown key is reported in `rejected`, not refused outright:
            # one bad key must not cost a panel its whole subscription.
            ("readFresh", {"key": "NO.SUCH.KEY.AT.ALL"}, "unknown key (rejected ok)"),
        ]:
            state, detail = outcome(await w.call(method, params))
            if state == "ok" and expect not in ("second hello", "unknown key (rejected ok)"):
                failures.append(f"{expect}: accepted when it should be refused")
            print(f"   {expect:16} {state:8} {detail}")

        await w.call("unsubscribe", {"sub": "sweep"})
        w.stop()

    print("\n==", len(failures), "finding(s)")
    for f in failures:
        print("   !", f)
    return 1 if failures else 0


if __name__ == "__main__":
    url, ca, user, pw = sys.argv[1:5]
    sys.exit(asyncio.run(sweep(url, ca, user, pw)))
