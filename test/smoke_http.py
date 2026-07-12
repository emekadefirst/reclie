"""End-to-end HTTP/1.1 smoke test through the native engine.

Spins up a throwaway HTTP server in a thread, then issues GET and POST
requests via reclie.Client and checks the responses come back through the
asyncio Future settlement path.
"""

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import reclie


class Handler(BaseHTTPRequestHandler):
    # Speak HTTP/1.1 so connections stay alive and the pool can reuse them.
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # silence
        pass

    def do_GET(self):
        body = json.dumps({"path": self.path, "method": "GET"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        received = self.rfile.read(n)
        body = json.dumps({"echo": received.decode(), "method": "POST"}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    async def run() -> None:
        client = reclie.Client("127.0.0.1", port=port, tls=False, version=1)

        resp = await client.get("/products", params={"page": 1})
        print("GET status:", resp.status_code, "ok:", resp.ok)
        data = await resp.json()
        print("GET json:", data)
        assert resp.status_code == 200
        assert data["path"] == "/products?page=1"

        resp2 = await client.post("/items", json={"title": "hi"})
        print("POST status:", resp2.status_code)
        data2 = await resp2.json()
        print("POST json:", data2)
        assert resp2.status_code == 201
        assert json.loads(data2["echo"]) == {"title": "hi"}

        # Concurrency: many requests over the pool at once.
        results = await asyncio.gather(*(client.get(f"/n/{i}") for i in range(20)))
        assert all(r.status_code == 200 for r in results)
        print("gather of 20 GETs: all 200")

        # Sequential reuse: hammer the same pool so keep-alive sockets recycle.
        for i in range(50):
            r = await client.get(f"/seq/{i}")
            assert r.status_code == 200, (i, r.status_code)
        print("50 sequential GETs: all 200 (keep-alive reuse)")

    asyncio.run(run())
    server.shutdown()
    print("OK")


if __name__ == "__main__":
    main()
