"""Every configured page, driven in a browser, until nothing is broken.

The unit of judgement is the browser's own console. A Flutter widget that
throws while building — `Bad state: Key "p_stat_Batches" not found` is the one
that started this — is drawn as a grey box and says nothing on screen; the
exception is the only place it is named. So this walks the plant's real
navigation, page by page, and fails on:

  * an uncaught exception on any page (the defect above, by name),
  * "unknown" violet, which is a value the screen could not resolve,
  * a page that renders nothing at all.

It signs in once and navigates by clicking, exactly as an operator does: a
`goto` per page would re-boot the app and lose the session, and it would also
stop proving that the configured menu is reachable.

    WEB_USER=Frystir WEB_PASSWORD=1234 python tool/web_e2e/test_every_page.py

`--page "Baader>Sensors"` limits the walk while iterating on one fault.
"""

import argparse
import io
import json
import os
import sys

from PIL import Image
from playwright.sync_api import sync_playwright

WEB_URL = os.environ.get("WEB_URL", "http://127.0.0.1:8771/")
USER = os.environ.get("WEB_USER", "Frystir")
PASSWORD = os.environ.get("WEB_PASSWORD", "1234")
HERE = os.path.dirname(os.path.abspath(__file__))

# MutedColors.unknownViolet and SolarizedColors.magenta: the two spellings of
# "this did not resolve".
VIOLETS = {(0x95, 0x88, 0xA7), (0xD3, 0x36, 0x82), (108, 113, 196)}

# Exceptions that are not this suite's business. Kept tiny and each one
# justified, because a permissive filter is how a page goes quiet.
IGNORED = (
    # Inline SVG editor metadata the renderer does not implement; it is a
    # parser notice about a <sodipodi:namedview/> element, not a value fault.
    "unhandled element <sodipodi:",
)

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


def violet_share(png):
    im = Image.open(io.BytesIO(png)).convert("RGB")
    px, (w, h) = im.load(), im.size
    hits = 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            if any(abs(r - vr) < 14 and abs(g - vg) < 14 and abs(b - vb) < 14
                   for vr, vg, vb in VIOLETS):
                hits += 1
    return hits, (w // 2) * (h // 2)


def distinct_colours(png):
    im = Image.open(io.BytesIO(png)).convert("RGB")
    px, (w, h) = im.load(), im.size
    return len({px[x, y] for y in range(0, h, 8) for x in range(0, w, 8)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", action="append", default=[],
                    help='Limit the walk, e.g. --page "Baader>Sensors"')
    ap.add_argument("--settle", type=int, default=12_000,
                    help="ms to let a page settle before judging it")
    args = ap.parse_args()

    faults = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        page = browser.new_page(viewport={"width": 1600, "height": 950})
        seen = []
        page.on("console", lambda m: seen.append((m.type, m.text))
                if m.type == "error" else None)
        page.on("pageerror", lambda e: seen.append(("pageerror", str(e))))

        page.goto(WEB_URL, wait_until="load", timeout=120_000)
        page.wait_for_timeout(16_000)
        page.eval_on_selector("flt-semantics-placeholder", "el => el.click()")
        page.wait_for_timeout(4_000)

        if not page.evaluate(JS_CLICK, "Sign in"):
            print("!! no sign-in offered; is the gateway reachable?")
            return 1
        page.wait_for_timeout(3_000)
        boxes = page.locator("input")
        for index, text in ((0, USER), (1, PASSWORD)):
            for _ in range(4):
                boxes.nth(index).click()
                page.keyboard.press("Control+a")
                page.keyboard.press("Delete")
                page.keyboard.type(text, delay=140)
                page.wait_for_timeout(400)
                if boxes.nth(index).input_value() == text:
                    break
        page.keyboard.press("Enter")
        page.wait_for_timeout(20_000)

        labels = page.evaluate(JS_LABELS)
        if not labels:
            print("!! signed in but the screen offers nothing")
            return 1

        # The plant's own navigation, read off the screen rather than listed
        # here: a page added to the config is walked on the day it is added.
        top = [l for l in labels if l in (
            "Speedbatchers", "Boxes", "Roe", "Baader", "Diagnostics",
            "Palet Wagons", "Alarm View")]
        walk = args.page or top
        print(f"signed in as {USER}; walking {len(walk)} destination(s): "
              f"{', '.join(walk)}\n")

        for entry in walk:
            # Not cleared: Flutter prints a widget's exception IN FULL once and
            # then reports every repeat as "Another exception was thrown:
            # Instance of ...". Clearing between pages threw away the only copy
            # that names the fault and kept the copy that names nothing. So the
            # log runs continuously and each page takes the slice it caused.
            mark = len(seen)
            # A submenu left open from the last destination sits over the
            # navigation bar and eats the next click, which reads here as
            # "page not reachable" — the harness's own fault, not the plant's.
            page.keyboard.press("Escape")
            page.wait_for_timeout(300)
            page.mouse.click(1560, 480)
            page.wait_for_timeout(500)
            steps = entry.split(">")
            reached = True
            if page.query_selector("flt-semantics-placeholder"):
                page.eval_on_selector("flt-semantics-placeholder",
                                      "el => el.click()")
                page.wait_for_timeout(1_500)
            for step in steps:
                if not page.evaluate(JS_CLICK, step):
                    print(f"  {entry:22} NOT REACHABLE (no '{step}' on screen)")
                    faults.append(f"{entry}: no menu entry '{step}'")
                    reached = False
                    break
                page.wait_for_timeout(2_500)
            if not reached:
                continue
            page.wait_for_timeout(args.settle)

            shot = page.screenshot()
            open(os.path.join(HERE, "page-%s.png"
                              % "".join(c if c.isalnum() else "_" for c in entry)),
                 "wb").write(shot)
            hits, total = violet_share(shot)
            colours = distinct_colours(shot)
            errors = [t for kind, t in seen[mark:]
                      if not any(skip in t for skip in IGNORED)]
            # One line per distinct message: a widget that throws once per
            # frame would otherwise bury everything else.
            distinct = []
            for text in errors:
                head = text.strip().splitlines()[0][:160]
                if head not in distinct:
                    distinct.append(head)

            verdict = []
            if distinct:
                verdict.append(f"{len(distinct)} exception(s)")
                faults.append(f"{entry}: " + " | ".join(distinct[:4]))
            if hits:
                verdict.append(f"violet {100 * hits / total:.2f}%")
                faults.append(f"{entry}: {hits} unknown-violet pixels")
            if colours < 8:
                verdict.append(f"only {colours} colours — blank?")
                faults.append(f"{entry}: rendered {colours} colours")
            print(f"  {entry:22} {'OK' if not verdict else ', '.join(verdict)}")
            for head in distinct[:4]:
                print(f"      {head}")

        # Flutter names an exception once and reports every recurrence as
        # "Another exception was thrown: Instance of ...". The named ones are
        # the only actionable text in a run, so they are collected across the
        # whole walk and printed whole: a repeat marker attributed to a page
        # says something is wrong there, never what.
        named = []
        for kind, text in seen:
            if text.startswith("Another exception was thrown"):
                continue
            if any(skip in text for skip in IGNORED):
                continue
            head = text.strip().splitlines()[0][:200]
            if head not in named:
                named.append(head)
        if named:
            print("\n== exceptions the browser NAMED (%d)" % len(named))
            for head in named:
                print("   *", head)

        browser.close()

    print(f"\n== {len(faults)} fault(s)")
    for f in faults:
        print("   !", f)
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main())
