#!/usr/bin/env python3
"""An HTTP listener that notes each request's method and path, never its content."""
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self):
        with open(sys.argv[2], "a") as log:
            print(self.command, self.path, file=log)
        self.rfile.read(int(self.headers.get("content-length", 0)))
        body = json.dumps({"initialized": False, "keys": [], "keys_base64": [], "root_token": ""}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_PUT = answer

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
