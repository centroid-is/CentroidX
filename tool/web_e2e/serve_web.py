"""Serve a built web bundle locally, the way a real deployment would.

    WEB_ROOT=C:\\wt\\webmain\\centroid-hmi\\build\\web python tool/web_e2e/serve_web.py

Two things this does that `python -m http.server` does not, and both of them
are the difference between a bundle that works here and a bundle that works
where it is deployed:

  * **SPA fallback.** Beamer routes are real paths, so a deep link or a reload
    asks for a file that does not exist. nginx does this with `try_files`;
    without the same fallback a bench server 404s exactly the addresses an
    operator bookmarks, and the difference would only show up in production.

  * **No-store on the entry documents.** `index.html`,
    `flutter_bootstrap.js` and `version.json` name the hashed asset bundle. A
    browser that caches them serves yesterday's app from today's assets, which
    presents as a blank screen with nothing in the console.
"""
import functools
import http.server
import os
import socketserver
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get(
    "WEB_ROOT",
    os.path.abspath(os.path.join(HERE, "..", "..", "centroid-hmi", "build", "web")),
)
PORT = int(os.environ.get("WEB_PORT", "8771"))

NO_STORE = ("/", "/index.html", "/flutter_bootstrap.js", "/version.json")


class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.path.split("?")[0]
        on_disk = os.path.join(ROOT, path.lstrip("/").replace("/", os.sep))
        if path not in ("/", "/index.html") and not os.path.exists(on_disk):
            path = "/"
            self.path = "/"
        return super().send_head()

    def end_headers(self):
        if self.path.split("?")[0] in NO_STORE:
            self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def log_message(self, fmt, *args):
        # `sys.stderr` is None when this runs without a console (pythonw, a
        # detached service). The base class writes there unconditionally, so
        # every request would die in its own logging and the browser would see
        # a closed connection rather than a page.
        if sys.stderr is not None:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    handler = functools.partial(Handler, directory=ROOT)
    with socketserver.TCPServer(("127.0.0.1", PORT), handler) as httpd:
        if sys.stdout is not None:
            print(f"serving {ROOT} on http://127.0.0.1:{PORT}", flush=True)
        httpd.serve_forever()
