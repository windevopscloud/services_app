import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = os.environ.get("SERVICE", "unknown")
DOWNSTREAM = os.environ.get("DOWNSTREAM", "")
FORWARD = ("x-origin", "x-request-id", "authorization")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"ok": True})
        body = {"service": SERVICE, "path": self.path, "x-origin": self.headers.get("x-origin")}
        if DOWNSTREAM:
            hdrs = {h: self.headers[h] for h in FORWARD if self.headers.get(h)}
            try:
                with urllib.request.urlopen(urllib.request.Request(DOWNSTREAM, headers=hdrs), timeout=5) as r:
                    body["downstream"] = json.load(r)
            except Exception as e:
                body["downstream_error"] = str(e)
        self.reply(200, body)

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
