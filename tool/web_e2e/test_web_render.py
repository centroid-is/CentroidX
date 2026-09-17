"""Drive the browser build of the HMI and assert that assets actually render.

    python tool/web_e2e/test_web_render.py            # plain runner
    python -m pytest tool/web_e2e/test_web_render.py  # if pytest is installed

Build the bundle first:

    cd centroid-hmi && flutter build web -t lib/main.dart --release

Each case starts its own static server (`serve_web.py`) on its own port, so a
run leaves nothing behind and two runs do not collide. The browser is the
machine's installed Chrome (`channel="chrome"`), so nothing is downloaded on a
plant laptop.

## What this suite is for

A bundle can serve every file with HTTP 200 and still paint nothing, because a
boot-time exception held inside a provider reaches no console, and because
dart2js minifies type names — which is how every asset on every page once
resolved to nothing at all, silently, in a release web build and only there.

So the checks assert what an operator would see: pixels, and the text the
semantics tree carries. The console is collected for the diagnosis rather than
used as the verdict.

## Two things learned the hard way

**Flutter paints into a canvas, so the DOM carries no text** until the
semantics tree is built. Flutter builds it when its placeholder is activated —
and that placeholder is parked one pixel wide at -1,-1, so Playwright refuses
to click it *forever* (it waits for an actionable element that will never
become one). The click has to go through JS. See [reveal_semantics].

**`locator.fill` sets the DOM value without the events Flutter's text input
listens for**, so the framework's field stays empty while the box looks filled.
Type with `keyboard.type(delay=...)`, read back with `input_value()`, and
retype on mismatch. See [type_into].
"""

import contextlib
import io
import os
import re
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
BOOT_TIMEOUT_MS = 120_000

# How long to let the app settle before judging it. It builds a page, fails to
# reach a plant, and settles into the "last known layout" state; on a cold
# machine that has taken up to fifteen seconds.
SETTLE_MS = int(os.environ.get("WEB_SETTLE_MS", "20000"))

# The two assets on the built-in default page (`lib/page_creator/page.dart`),
# by the text they draw beside themselves. Their rows carry
# `"asset_name": "ButtonConfig"` and `"asset_name": "LEDConfig"`, so seeing
# these two strings on screen is the whole registry path working end to end in
# a minified build: stored name -> factory -> a rendered asset.
DEFAULT_PAGE_ASSETS = ("A button", "A light")

# The same two names as they must appear *in the compiled bundle*. The registry
# resolves a row by comparing against these literals; before they existed it
# compared against `Type.toString()`, which dart2js minifies, and the bundle
# contained the string "ButtonConfig" zero times.
ASSET_NAME_LITERALS = ("ButtonConfig", "LEDConfig", "BpmConfig")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def served():
    """A static server for one case, on a port nothing else is using."""
    port = _free_port()
    env = dict(os.environ, WEB_ROOT=WEB_ROOT, WEB_PORT=str(port))
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "serve_web.py")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}"
    try:
        for _ in range(60):
            try:
                urllib.request.urlopen(url, timeout=1).read(1)
                break
            except Exception:
                time.sleep(0.3)
        else:
            raise AssertionError(f"server never came up on {url}")
        yield url
    finally:
        proc.terminate()
        proc.wait(timeout=10)


class PageProbe:
    """One page load, with everything the browser complained about."""

    def __init__(self, page):
        self.console = []
        self.page_errors = []
        self.failed_requests = []
        page.on("console", self._console)
        page.on("pageerror", lambda e: self.page_errors.append(str(e)))
        page.on("requestfailed",
                lambda r: self.failed_requests.append(f"{r.url} {r.failure}"))

    def _console(self, msg):
        if msg.type in ("error", "warning"):
            self.console.append(f"[{msg.type}] {msg.text}")

    def report(self):
        lines = []
        for label, items in (
            ("page errors (uncaught exceptions)", self.page_errors),
            ("console", self.console),
            ("failed requests", self.failed_requests),
        ):
            if items:
                lines.append(f"--- {label} ---")
                lines.extend(items)
        return "\n".join(lines) or "(browser reported nothing)"


@contextlib.contextmanager
def opened(url, settle_ms=SETTLE_MS, semantics=True):
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome", headless=True)
        page = browser.new_page(viewport={"width": 1500, "height": 950})
        probe = PageProbe(page)
        try:
            page.goto(url, wait_until="load", timeout=BOOT_TIMEOUT_MS)
            page.wait_for_timeout(settle_ms)
            if semantics:
                reveal_semantics(page)
            yield page, probe
        finally:
            browser.close()


def reveal_semantics(page, settle_ms=4_000):
    """Make Flutter build its semantics tree, so the DOM carries text.

    Flutter renders into a canvas; `document.body.innerText` is empty until the
    semantics tree exists, and Flutter only builds it once an assistive
    technology asks. The ask is a click on `flt-semantics-placeholder`.

    It has to go through JS. Flutter parks that element one pixel wide at
    (-1, -1), and Playwright's own `click` waits for an element to become
    actionable — which this one never does, so `locator.click()` hangs until
    the test times out rather than failing with anything informative.
    """
    if not page.query_selector("flt-semantics-placeholder"):
        return False
    page.eval_on_selector("flt-semantics-placeholder", "el => el.click()")
    page.wait_for_timeout(settle_ms)
    return True


JS_CLICK = """
(label) => {
  const nodes = [...document.querySelectorAll('flt-semantics')];
  const exact = nodes.find(n => (n.getAttribute('aria-label') || n.textContent || '')
                                 .trim() === label);
  const hit = exact || nodes.find(n => (n.getAttribute('aria-label') || n.textContent || '')
                                        .trim().toLowerCase() === label.toLowerCase());
  if (!hit) return false;
  hit.click();
  return true;
}
"""

JS_LABELS = """
() => [...document.querySelectorAll('flt-semantics')]
        .map(n => (n.getAttribute('aria-label') || '').trim())
        .filter(Boolean)
"""


def click_label(page, label, settle_ms=3_000):
    """Click the semantics node whose label is [label]. Same JS-click reason as
    [reveal_semantics]: these nodes are positioned for a screen reader, not for
    a mouse."""
    hit = page.evaluate(JS_CLICK, label)
    if hit:
        page.wait_for_timeout(settle_ms)
    return hit


def type_into(page, box, text, attempts=4):
    """Put [text] into a Flutter text field and confirm it arrived.

    `locator.fill` sets the DOM input's value directly. Flutter's web text
    input listens for the key and composition events a real keystroke
    produces, so a filled box *looks* right while the framework's own field
    is still empty — and the failure surfaces much later, as a form that
    submits nothing.

    So: type with a delay, read the value back, and retype on a mismatch. The
    delay is not superstition either — below about 100ms Flutter drops
    characters, and 140ms is what has been reliable here.
    """
    for _ in range(attempts):
        box.click()
        page.keyboard.press("Control+a")
        page.keyboard.press("Delete")
        page.keyboard.type(text, delay=140)
        page.wait_for_timeout(400)
        if box.input_value() == text:
            return True
    return False


def distinct_colours(png, step=8):
    from PIL import Image
    im = Image.open(io.BytesIO(png)).convert("RGB")
    px, (w, h) = im.load(), im.size
    return len({px[x, y] for y in range(0, h, step) for x in range(0, w, step)})


# ---------------------------------------------------------------- the bundle


def test_every_asset_loads():
    with served() as url, opened(url, settle_ms=6_000, semantics=False) as (_, probe):
        assert not probe.failed_requests, (
            "assets failed to load:\n" + probe.report())


def test_page_boots_without_uncaught_errors():
    """The one that catches a provider throwing during boot.

    Everything `dart:io` — `Platform.isAndroid` on the app bar,
    `Platform.environment` in the log config, `stderr.writeln` inside a
    `catch` — compiles for the web and throws when it runs. A successful build
    proves none of it.
    """
    with served() as url, opened(url, settle_ms=10_000, semantics=False) as (_, probe):
        assert not probe.page_errors, (
            "the web bundle threw during boot:\n" + probe.report())


def test_flutter_paints_something():
    with served() as url, opened(url, semantics=False) as (page, probe):
        page.wait_for_selector("flt-glass-pane, flutter-view, canvas",
                               timeout=BOOT_TIMEOUT_MS)
        assert distinct_colours(page.screenshot(type="png")) > 3, (
            "the page is blank\n" + probe.report())


# ------------------------------------------------- assets actually rendering


def test_configured_assets_render():
    """The point of the whole exercise.

    The built-in default page carries two assets, stored as
    `"asset_name": "ButtonConfig"` and `"asset_name": "LEDConfig"`. Seeing the
    text they draw means the registry resolved both stored names to their
    factories and the page painted them — in a minified release build, which is
    the only place the old `Type.toString()` lookup failed.

    A failure here with the bundle otherwise healthy means the name table and
    the page rows have drifted apart.
    """
    with served() as url, opened(url) as (page, probe):
        text = page.evaluate("() => document.body.innerText")
        missing = [a for a in DEFAULT_PAGE_ASSETS if a not in text]
        assert not missing, (
            f"the default page rendered without {missing}. Every asset on it "
            "resolves through AssetRegistry's Map<Type, String> name table; if "
            "the page is otherwise drawn, the table and the stored rows have "
            "drifted apart.\n"
            f"--- what the page did say ---\n{text[:1500]}\n" + probe.report())


def test_asset_names_survive_minification():
    """The mechanism behind the test above, asserted directly on the bundle.

    dart2js rewrites class names, so `BpmConfig.toString()` in a release build
    is a couple of letters. The registry no longer asks: the names are string
    literals in a `Map<Type, String>`, and a literal survives. Measured on this
    bundle, 2026-09-17: each of these appears at least once.

    Separate from the render check so that a failure says which half broke —
    the names missing from the bundle, or the page failing to draw for some
    other reason.
    """
    main_js = os.path.join(WEB_ROOT, "main.dart.js")
    assert os.path.exists(main_js), (
        f"no built bundle at {main_js} — run `flutter build web` first")
    with open(main_js, "r", encoding="utf-8", errors="replace") as f:
        source = f.read()
    missing = [n for n in ASSET_NAME_LITERALS if n not in source]
    assert not missing, (
        f"{missing} do not appear in the compiled bundle at all. That is the "
        "original defect: the registry matched a page row's asset_name against "
        "a minified `Type.toString()`, nothing ever matched, and every plant "
        "page drew as an empty canvas with nothing on the console.")


def test_navigation_is_configured_and_reachable():
    """The menu the plant's own configuration defines, read off the screen."""
    with served() as url, opened(url) as (page, probe):
        labels = page.evaluate(JS_LABELS)
        assert labels, ("the semantics tree is empty — either the app never "
                        "booted or the placeholder click did not take\n"
                        + probe.report())
        for expected in ("Home", "Advanced"):
            assert expected in labels, (
                f"'{expected}' is not on screen. Labels: {labels}\n"
                + probe.report())


def test_a_dialog_opens_and_takes_typed_text():
    """Proves the two browser-driving techniques this file documents.

    The sign-in dialog is the one text field reachable without a plant behind
    the page, so it is what exercises [type_into]. Nothing is submitted: the
    assertion is that the characters reached Flutter's own field, which
    `locator.fill` would not have achieved.
    """
    with served() as url, opened(url) as (page, probe):
        assert click_label(page, "Sign in"), (
            "no 'Sign in' on screen to click\n" + probe.report())
        boxes = page.locator("input")
        assert boxes.count() >= 1, (
            "the sign-in dialog offered no text field\n" + probe.report())
        assert type_into(page, boxes.nth(0), "harness"), (
            "typed text never reached Flutter's own field — `input_value()` "
            f"read {boxes.nth(0).input_value()!r}\n" + probe.report())


# ----------------------------------------------------------------- the shell


def test_tab_title_names_the_system():
    """What a tab reads while loading, or when the app never boots.

    Beamer overwrites the title once the router runs, so this is only
    observable early — exactly when somebody with a wall of tabs needs to know
    which system they are looking at.
    """
    with served() as url:
        with urllib.request.urlopen(url) as r:
            html = r.read().decode("utf-8", "replace")
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    assert title and title.group(1).strip() == "CentroidX", (
        f"index.html carries the title {title and title.group(1)!r}")


def test_tab_icon_is_not_the_flutter_default():
    """The tab must carry the Centroid mark.

    Pinned by size rather than by hash: the stock template favicon is the
    917-byte Flutter logo, and anything the project puts there is a different
    file.
    """
    with served() as url:
        with urllib.request.urlopen(f"{url}/favicon.png") as r:
            body = r.read()
    assert len(body) != 917, (
        "favicon.png is still Flutter's default 917-byte logo")


def test_a_deep_link_serves_the_app():
    """Beamer routes are real paths, so a reload asks for a file that is not
    there. Production answers with index.html (`try_files`); a bench server
    that 404s would hide the difference until deployment."""
    with served() as url:
        with urllib.request.urlopen(f"{url}/some/deep/route") as r:
            assert r.status == 200
            assert b"flutter_bootstrap.js" in r.read()


def main():
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failures = []
    for name, fn in tests:
        started = time.time()
        try:
            fn()
            print(f"  {name:48} OK    ({time.time() - started:.0f}s)")
        except Exception as e:
            print(f"  {name:48} FAIL  ({time.time() - started:.0f}s)")
            failures.append((name, e))
    print(f"\n== {len(tests) - len(failures)}/{len(tests)} passed")
    for name, e in failures:
        print(f"\n!! {name}\n{e}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
