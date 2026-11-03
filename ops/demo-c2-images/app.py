# demo-c2's python-app: a stdlib HTTP server that answers with its version.
import http.server

VERSION = "v1"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"python-app {VERSION}\n".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


print(f"python-app {VERSION} listening on :8080", flush=True)
http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
