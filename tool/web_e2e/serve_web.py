"""Serve the browser client locally, declaring the gateway it should dial.

The bench counterpart of `docker/web`: same contract, same `index.html`
rewrite, no container. Production uses the image; this is for a laptop with a
`build/web` directory and a gateway on the plant network.

    WEB_ROOT=C:\\wt\\relay\\centroid-hmi\\build\\web \\
    GATEWAY_URL=wss://10.104.60.84:9443 python tool/web_e2e/serve_web.py

Leave `GATEWAY_URL` unset to serve the bundle exactly as built -- the template's
`$CENTROIDX_GATEWAY` placeholder stays, which the client reads as "no
declaration" and falls back to the origin it was served from.
"""
import functools
import http.server
import io
import os
import re
import socketserver
import sys

ROOT = os.environ.get("WEB_ROOT", r"C:\wt\relay\centroid-hmi\build\web")
PORT = int(os.environ.get("WEB_PORT", "8771"))
GATEWAY = os.environ.get("GATEWAY_URL", "")

# Matched and replaced whole, like the container's entrypoint: a bundle already
# rewritten once must not collect a second declaration for the page to choose
# between.
META_RE = re.compile(rb'<meta\s+name="centroidx-gateway"[^>]*>', re.IGNORECASE)
NO_STORE = ("/", "/index.html", "/flutter_bootstrap.js", "/version.json")


class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.path.split("?")[0]
        # Beamer routes are real paths, so a deep link or a reload asks for a
        # file that does not exist. nginx does this with `try_files`; without
        # the same fallback here a bench server 404s exactly the addresses an
        # operator bookmarks, and the difference would only show up in
        # production.
        if path not in ("/", "/index.html") and not os.path.exists(
                os.path.join(ROOT, path.lstrip("/").replace("/", os.sep))):
            path = "/"
            self.path = "/"
        if path in ("/", "/index.html"):
            return self._declared_index() if GATEWAY else super().send_head()
        return super().send_head()

    def _declared_index(self):
        with open(os.path.join(ROOT, "index.html"), "rb") as f:
            html = f.read()
        tag = b'<meta name="centroidx-gateway" content="%s">' % GATEWAY.encode()
        html = META_RE.sub(tag, html) if META_RE.search(html) else html.replace(
            b"</head>", tag + b"\n</head>", 1)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.end_headers()
        return io.BytesIO(html)

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
            print(f"declaring gateway {GATEWAY or '(none)'}", flush=True)
        httpd.serve_forever()
