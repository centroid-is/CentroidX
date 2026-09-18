"""End-to-end checks for the browser build of the HMI (`lib/main_web.dart`).

    python tool/web_e2e/test_web_client.py            # plain runner
    python -m pytest tool/web_e2e/test_web_client.py  # if pytest is installed

Each case starts its own static server (`serve_web.py`) on its own port with
its own gateway declaration, so the deployment shapes -- declared, undeclared,
misdeclared -- are properties of the test rather than of how somebody happened
to launch a server. `WEB_ROOT` points at a built bundle; `GATEWAY_URL` is the
relay these tests expect a browser to reach.

The browser is the machine's installed Chrome (`channel="chrome"`), so nothing
is downloaded on a plant laptop.

Reproduction first: the bundle can serve every asset with HTTP 200 and still
paint nothing, because a boot-time exception held in a provider reaches no
console. So the checks assert what an operator sees -- pixels -- and collect
the console for the diagnosis.
"""

import contextlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
WEB_ROOT = os.environ.get(
    "WEB_ROOT",
    os.path.abspath(os.path.join(HERE, "..", "..", "centroid-hmi", "build", "web")),
)
GATEWAY_URL = os.environ.get("GATEWAY_URL", "wss://10.104.60.84:9443")
BOOT_TIMEOUT_MS = 30_000

# The template's inert value. A bundle serving this must behave exactly as it
# did before there was a declaration.
PLACEHOLDER = "$CENTROIDX_GATEWAY"


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def served(declaration=None):
    """A static server for one case, declaring `declaration` (or nothing)."""
    port = _free_port()
    env = dict(os.environ, WEB_ROOT=WEB_ROOT, WEB_PORT=str(port),
               GATEWAY_URL=declaration or "")
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "serve_web.py")],
                            env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}"
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(url, timeout=1).read(1)
                break
            except Exception:
                time.sleep(0.2)
        else:
            raise AssertionError(f"server never came up on {url}")
        yield url
    finally:
        proc.terminate()
        proc.wait(timeout=10)


class PageProbe:
    """One page load, with everything the browser complained about."""

    def __init__(self, page):
        self.console_errors = []
        self.page_errors = []
        self.failed_requests = []
        self.sockets = []
        page.on("console", self._console)
        page.on("pageerror", lambda e: self.page_errors.append(str(e)))
        page.on("requestfailed",
                lambda r: self.failed_requests.append(f"{r.url} {r.failure}"))
        page.on("websocket", lambda ws: self.sockets.append(ws.url))

    def _console(self, msg):
        if msg.type in ("error", "warning"):
            self.console_errors.append(f"[{msg.type}] {msg.text}")

    def report(self):
        lines = []
        for label, items in (
            ("page errors (uncaught exceptions)", self.page_errors),
            ("console", self.console_errors),
            ("failed requests", self.failed_requests),
            ("websockets", self.sockets),
        ):
            if items:
                lines.append(f"--- {label} ---")
                lines.extend(items)
        return "\n".join(lines) or "(browser reported nothing)"


@contextlib.contextmanager
def opened(url, seed_row=None, settle_ms=12_000):
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome", headless=True)
        page = browser.new_page(viewport={"width": 1400, "height": 900})
        probe = PageProbe(page)
        if seed_row is not None:
            # Stringified IN the page: a Python-side double encode loses one
            # level to JS string-literal quoting and stores the inner JSON,
            # which `readGatewayConfig` reads as corrupt and silently falls
            # back from -- a green-looking seed that configures nothing.
            page.add_init_script(
                "localStorage.setItem('gateway_transport',"
                f" JSON.stringify(JSON.stringify({json.dumps(seed_row)})));")
        try:
            page.goto(url, wait_until="load", timeout=BOOT_TIMEOUT_MS)
            page.wait_for_timeout(settle_ms)
            yield page, probe
        finally:
            browser.close()


def _distinct_colours(page):
    """How many colours are on screen.

    A Flutter app that boots paints its theme, text and controls; one that threw
    during boot leaves the canvas untouched. Sampling the screenshot is the only
    check a bundle that merely loads cannot satisfy.
    """
    from PIL import Image
    import io as _io

    img = Image.open(_io.BytesIO(page.screenshot(type="png"))).convert("RGB")
    px = img.load()
    w, h = img.size
    return len({px[x, y] for y in range(0, h, 8) for x in range(0, w, 8)})


# --------------------------------------------------------------------------
# The bundle itself


def test_every_asset_loads():
    with served(GATEWAY_URL) as url, opened(url, settle_ms=5_000) as (_, probe):
        assert not probe.failed_requests, (
            "assets failed to load:\n" + probe.report())


def test_page_boots_without_uncaught_errors():
    with served(GATEWAY_URL) as url, opened(url, settle_ms=8_000) as (_, probe):
        assert not probe.page_errors, (
            "the web bundle threw during boot:\n" + probe.report())


def test_flutter_paints_something():
    with served(GATEWAY_URL) as url, opened(url) as (page, probe):
        page.wait_for_selector("flt-glass-pane, flutter-view, canvas",
                               timeout=BOOT_TIMEOUT_MS)
        assert _distinct_colours(page) > 3, (
            "the page is blank\n" + probe.report())


def test_tab_icon_is_not_the_flutter_default():
    """The tab must carry the Centroid mark, the way the noVNC tab does.

    Pinned by size rather than by hash: the stock template favicon is the
    917-byte Flutter logo, and anything the project puts there is a different
    file.
    """
    with served() as url:
        with urllib.request.urlopen(f"{url}/favicon.png") as r:
            body = r.read()
    assert len(body) != 917, (
        "favicon.png is still Flutter's default 917-byte logo")


def test_tab_title_names_the_system_before_routing():
    """What a tab reads while loading, or when the app never boots.

    Beamer overwrites the title once the router runs, so this is only
    observable early -- exactly when somebody with a wall of tabs needs to know
    which system they are looking at.
    """
    import re

    with served() as url:
        with urllib.request.urlopen(url) as r:
            html = r.read().decode("utf-8", "replace")
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    assert title and title.group(1).strip() == "CentroidX", (
        f"index.html carries the title {title and title.group(1)!r}")


# --------------------------------------------------------------------------
# The gateway declaration: how a served bundle knows which plant it belongs to


def test_undeclared_bundle_keeps_its_placeholder():
    """A server that knows nothing of the declaration changes nothing."""
    with served() as url:
        with urllib.request.urlopen(url) as r:
            html = r.read().decode("utf-8", "replace")
    assert PLACEHOLDER in html, (
        "the built bundle lost its inert placeholder, so a plain file server "
        "can no longer serve it unchanged")


def test_declaration_is_served_in_the_page():
    with served(GATEWAY_URL) as url:
        with urllib.request.urlopen(url) as r:
            html = r.read().decode("utf-8", "replace")
    assert f'content="{GATEWAY_URL}"' in html, (
        "the server did not stamp the gateway into index.html")
    assert PLACEHOLDER not in html, "the placeholder survived the rewrite"


def test_declared_gateway_dials_without_any_configuration():
    """The deployment shape: open the address, and it connects.

    Empty browser storage, nobody visiting Server Config -- this is what the
    container in `docker/web` buys.
    """
    with served(GATEWAY_URL) as url, opened(url, settle_ms=20_000) as (_, probe):
        assert any(GATEWAY_URL in s for s in probe.sockets), (
            f"expected a dial to {GATEWAY_URL}; saw "
            f"{probe.sockets or 'nothing'}\n" + probe.report())


def test_undeclared_page_renders_and_refuses_to_dial():
    """No declaration, served over plain http: render, and refuse by name.

    The default is then the page's own origin, which is `ws://` -- a browser
    cannot pin a private CA, so the client refuses it at the field rather than
    dialling something that could never work. What must not happen is the two
    failure modes together: a silent link AND a blank screen.
    """
    with served() as url, opened(url) as (page, probe):
        assert _distinct_colours(page) > 3, (
            "an unconfigured browser paints nothing\n" + probe.report())
        assert not probe.sockets, (
            f"a browser dialled {probe.sockets} from an http page")


def test_a_saved_row_outranks_the_declaration():
    """A person's own choice survives a redeploy that declares something else."""
    with served("wss://10.255.255.1:9443") as url:
        row = {"mode": "gateway", "url": GATEWAY_URL}
        with opened(url, seed_row=row, settle_ms=20_000) as (_, probe):
            assert any(GATEWAY_URL in s for s in probe.sockets), (
                f"the stored row did not win; saw {probe.sockets or 'nothing'}")
            assert not any("10.255.255.1" in s for s in probe.sockets), (
                "the declaration overrode a row saved from Server Config")


def test_a_malformed_declaration_is_refused_not_dialled():
    """A typo must read as a typo, not as a plant fault.

    A declaration nobody can dial is taken verbatim and refused by name, so the
    banner names it and Server Config stays reachable -- rather than a dial
    that burns the patience window and then blames the network.
    """
    with served("wss://10.104.60.84:9443 (the gateway)") as url:
        with opened(url) as (page, probe):
            assert _distinct_colours(page) > 3, (
                "a misdeclared browser paints nothing\n" + probe.report())
            assert not probe.sockets, (
                f"a malformed declaration was dialled anyway: {probe.sockets}")


def _semantics_text(page):
    """The screen's text, via Flutter's accessibility tree.

    Flutter paints text into a canvas, so the DOM carries none of it. Clicking
    the "Enable accessibility" placeholder Flutter puts in the page builds a
    semantics tree of real elements, which is the only way to assert on what
    the screen actually says rather than on how many colours it has.
    """
    # Clicked through JS rather than Playwright's click: Flutter parks the
    # placeholder one pixel wide at -1,-1, so a real click is refused as
    # "outside of the viewport" for ever.
    page.eval_on_selector("flt-semantics-placeholder", "el => el.click()")
    page.wait_for_timeout(4_000)
    return page.evaluate("document.body.innerText") or ""


def test_an_unsigned_browser_is_asked_to_sign_in():
    """Nobody signed in: a sign-in, not an empty shell with navigation.

    On this plant the `anonymous` row is role `NoOp` with an empty page
    whitelist, so a browser that presents no credential may see nothing --
    and the screen has to say so, rather than showing a bar and blank pages.
    """
    with served(GATEWAY_URL) as url, opened(url, settle_ms=18_000) as (page, probe):
        text = _semantics_text(page)
        assert "Sign in" in text, (
            "an unsigned browser does not offer sign-in; screen said: "
            f"{text!r}\n" + probe.report())
        for entry in ("Alarm View", "Advanced"):
            assert entry not in text, (
                f"{entry!r} is offered to a session the server grants nothing: "
                f"{text!r}")


def test_a_signed_in_browser_sees_the_plant_pages():
    """After sign-in the nav bar carries the plant's own pages.

    Skipped unless `WEB_USER`/`WEB_PASSWORD` name an account on the gateway:
    minting a credential on a plant database to make a test run is not a trade
    this suite gets to make. With them set it is the end-to-end proof that the
    config rows travel the relay -- without it a browser shows only the routes
    the web build registers for itself.
    """
    user = os.environ.get("WEB_USER")
    password = os.environ.get("WEB_PASSWORD")
    if not user:
        print("  (skipped: set WEB_USER/WEB_PASSWORD to run)", flush=True)
        return

    with served(GATEWAY_URL) as url, opened(url, settle_ms=18_000) as (page, probe):
        text = _semantics_text(page)
        assert "Sign in" in text, f"no sign-in offered: {text!r}"
        page.get_by_role("button", name="Sign in").first.click()
        page.wait_for_timeout(2_000)
        boxes = page.locator("input")
        boxes.nth(0).fill(user)
        if password:
            boxes.nth(1).fill(password)
        page.keyboard.press("Enter")
        page.wait_for_timeout(15_000)

        after = page.evaluate("document.body.innerText") or ""
        expected = os.environ.get("WEB_EXPECT_PAGE", "Speedbatchers")
        assert expected.lower() in after.lower(), (
            f"signed in as {user}, but {expected!r} is not in the navigation: "
            f"{after!r}\n" + probe.report())


def _main():
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}", flush=True)
            except AssertionError as e:
                failures += 1
                print(f"FAIL {name}\n{e}\n", flush=True)
            except Exception as e:  # a crash is also a reproduction
                failures += 1
                print(f"ERROR {name}: {type(e).__name__}: {e}\n", flush=True)
    print(f"\n{failures} failing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_main())
