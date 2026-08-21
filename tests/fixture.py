import base64, sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 1x1 JPEG
JPG = base64.b64decode(
 b"/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
 b"HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
 b"AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")
CRED = base64.b64encode(b"user:pass").decode()

class H(BaseHTTPRequestHandler):
    ZOOM_STEPS = list(range(100, 1001, 9))
    state = {"zoom": "100"}
    log = []
    def log_message(self, *a): pass
    def _img(self):
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(JPG)))
        self.end_headers(); self.wfile.write(JPG)
    def _text(self, body, code=200):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        q = self.path.split("?")[1] if "?" in self.path else ""

        # --- IP Webcam control surface (verified against a real device) -------
        if p == "/status.json":
            zoom = H.state["zoom"]
            body = '{"curvals":{"zoom":"%s","focusmode":"continuous-video"}' % zoom
            if "show_avail=1" in q:
                body += ',"avail":{"zoom":[%s],"focusmode":["off","auto","macro"]}' % (
                    ",".join('"%d"' % v for v in H.ZOOM_STEPS))
            body += "}"
            b = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        if p == "/settings/zoom":
            val = q.split("set=")[-1] if "set=" in q else ""
            if val.isdigit() and int(val) in H.ZOOM_STEPS:
                H.state["zoom"] = val
                H.log.append("zoom=%s" % val)
                self._text('<?xml version="1.0"?><result>Ok</result>'); return
            self._text('<?xml version="1.0"?><result>Fail</result>'); return
        if p == "/focus":
            H.log.append("focus")
            self._text('<?xml version="1.0"?><result>Ok</result>'); return
        if p == "/nofocus":
            H.log.append("nofocus")
            self._text('<?xml version="1.0"?><result>Ok</result>'); return
        if p == "/_log":                        # test introspection
            self._text("\n".join(H.log)); return
        if p == "/_reset":
            H.state["zoom"] = "100"; H.log[:] = []
            self._text("ok"); return
        if p == "/_nozoom":                     # simulate a camera without zoom
            H.ZOOM_STEPS = []
            self._text("ok"); return
        if p == "/html":                       # 200 but not an image
            body = b"<html><body>not an image</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        if p == "/forbidden":                  # how a proxy refuses -> curl exit 22
            self.send_response(403); self.end_headers(); self.wfile.write(b"denied"); return
        if p == "/proxyblock":                 # a proxy that names its own verdict
            body = b"Connection blocked by network allowlist"
            self.send_response(403)
            self.send_header("X-Proxy-Error", "blocked-by-allowlist")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        if p == "/auth":
            got = self.headers.get("Authorization", "")
            if got != "Basic " + CRED:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="cam"')
                self.end_headers(); return
            self._img(); return
        self._img()                            # /shot.jpg, /snapshot, anything else

# argv: PORT [BIND].  BIND defaults to loopback; the proxy-bypass test needs
# 0.0.0.0 because curl never routes loopback through a proxy.
ThreadingHTTPServer((sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1",
                     int(sys.argv[1])), H).serve_forever()
