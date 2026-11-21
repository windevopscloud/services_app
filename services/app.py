import base64, json, os, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = os.environ.get("SERVICE", "unknown")
DOWNSTREAM = os.environ.get("DOWNSTREAM", "")
CLIENT_ID = os.environ.get("CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
SCOPE = os.environ.get("SCOPE", "")
TOKEN_URL = os.environ.get("TOKEN_URL", "")
FORWARD = ("x-origin", "x-request-id", "authorization")

_tok = {"v": None, "exp": 0}


def service_token():
    if _tok["v"] and time.time() < _tok["exp"] - 30:
        return _tok["v"]
    basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": SCOPE}).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, headers={
        "Authorization": f"Basic {basic}",
        "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=5) as r:
        j = json.load(r)
    _tok["v"] = j["access_token"]
    _tok["exp"] = time.time() + int(j.get("expires_in", 3600))
    return _tok["v"]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"ok": True})
        body = {"service": SERVICE, "path": self.path, "x-origin": self.headers.get("x-origin")}
        if DOWNSTREAM:
            hdrs = {h: self.headers[h] for h in FORWARD if self.headers.get(h)}
            try:
                if self.headers.get("x-origin") == "ext" and CLIENT_ID and TOKEN_URL:
                    hdrs["authorization"] = "Bearer " + service_token()
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