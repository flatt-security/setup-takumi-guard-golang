"""Mock HTTP server for the retry tests.

Two roles:

  --oidc            always 200 with a fake {"value": ...} OIDC token body
  --codes 503,200   STS exchange: return each status once, in order, then
                    repeat the last one forever

`/__ready` and `/__count` are answered without advancing the script, so the
harness can poll for startup and read the number of scripted requests served
without consuming one. The count is what lets a test assert that a retry
actually reached the server: an implementation that only printed the expected
warnings would pass every other assertion.
"""

import argparse
import http.server

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--oidc", action="store_true")
parser.add_argument("--codes", default="200")
args = parser.parse_args()

codes = [int(c) for c in args.codes.split(",")]
served = [0]

OIDC_BODY = b'{"value":"header.payload.signature"}'
STS_OK = b'{"access_token":"sts-access-token","expires_in":1800}'
STS_ERR = b'{"message":"mock error"}'


class Handler(http.server.BaseHTTPRequestHandler):
    def _respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        if self.path.startswith("/__ready"):
            self._respond(200, b"{}")
            return
        if self.path.startswith("/__count"):
            self._respond(200, ('{"served":%d}' % served[0]).encode())
            return
        if args.oidc:
            served[0] += 1
            self._respond(200, OIDC_BODY)
            return
        index = min(served[0], len(codes) - 1)
        served[0] += 1
        status = codes[index]
        self._respond(status, STS_OK if status == 200 else STS_ERR)

    do_GET = _handle
    do_POST = _handle

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
