"""reclie usage examples — every form the client currently supports.

Run it::

    # from the repo root (source checkout)
    PYTHONPATH=. python example/main.py

    # or after `pip install reclie`
    python example/main.py

Most examples hit the public test API https://dummyjson.com over HTTPS, so a
network connection is required.

Current capabilities (v0.1):
  * HTTP/1.1 over http:// and https:// (TLS 1.3, cert-verified)
  * GET / POST / PUT / PATCH / DELETE
  * query params, custom headers, JSON and raw-bytes bodies
  * connection pooling + keep-alive (plain HTTP), one Client = one origin
  * asyncio-native: real awaitables, works with asyncio.gather

Not yet available (planned): HTTP/2, SSE, WebSocket, streaming bodies, and
enforced timeouts. `version=2` is accepted but the wire protocol is HTTP/1.1
for now.
"""

from __future__ import annotations

import asyncio

import reclie


# ---------------------------------------------------------------------------
# 1. Quickstart — a single GET, decode JSON.
# ---------------------------------------------------------------------------
async def quickstart() -> None:
    print("\n[1] quickstart")
    client = reclie.Client("dummyjson.com")  # https on 443 inferred
    resp = await client.get("/products/1")
    print("  status:", resp.status_code, "ok:", resp.ok)
    data = await resp.json()
    print("  title:", data["title"])


# ---------------------------------------------------------------------------
# 2. All HTTP verbs.
# ---------------------------------------------------------------------------
async def all_methods() -> None:
    print("\n[2] all HTTP methods")
    client = reclie.Client("dummyjson.com")

    got = await client.get("/products/1")
    print("  GET    ->", got.status_code)

    made = await client.post("/products/add", json={"title": "reclie widget"})
    print("  POST   ->", made.status_code)

    put = await client.put("/products/1", json={"title": "renamed"})
    print("  PUT    ->", put.status_code)

    patched = await client.patch("/products/1", json={"title": "tweaked"})
    print("  PATCH  ->", patched.status_code)

    gone = await client.delete("/products/1")
    print("  DELETE ->", gone.status_code)


# ---------------------------------------------------------------------------
# 3. Query parameters — passed as a dict, URL-encoded for you.
# ---------------------------------------------------------------------------
async def query_params() -> None:
    print("\n[3] query params")
    client = reclie.Client("dummyjson.com")
    resp = await client.get("/products/search", params={"q": "phone", "limit": 5})
    data = await resp.json()
    print("  results for 'phone':", len(data["products"]))


# ---------------------------------------------------------------------------
# 4. Custom request headers.
# ---------------------------------------------------------------------------
async def custom_headers() -> None:
    print("\n[4] custom headers")
    client = reclie.Client("dummyjson.com")
    resp = await client.get(
        "/products/1",
        headers={"Accept": "application/json", "X-Demo": "reclie"},
    )
    print("  status:", resp.status_code)


# ---------------------------------------------------------------------------
# 5. Request bodies — JSON (auto Content-Type) vs raw bytes.
# ---------------------------------------------------------------------------
async def request_bodies() -> None:
    print("\n[5] request bodies")
    client = reclie.Client("dummyjson.com")

    # `json=` serializes and sets Content-Type: application/json.
    j = await client.post("/products/add", json={"title": "json body", "price": 9})
    print("  json body   ->", j.status_code)

    # `data=` sends raw bytes; set your own Content-Type.
    raw = await client.post(
        "/products/add",
        data=b'{"title":"raw body"}',
        headers={"Content-Type": "application/json"},
    )
    print("  raw  body   ->", raw.status_code)


# ---------------------------------------------------------------------------
# 6. Inspecting the response — status, ok, headers, and the three body reads.
# ---------------------------------------------------------------------------
async def response_object() -> None:
    print("\n[6] response object")
    client = reclie.Client("dummyjson.com")
    resp = await client.get("/products/1")

    print("  status_code:", resp.status_code)
    print("  ok:", resp.ok)  # True when status_code < 400
    # Headers are case-insensitive.
    print("  content-type:", resp.headers["Content-Type"])
    print("  CONTENT-TYPE:", resp.headers["CONTENT-TYPE"])
    print("  'content-length' in headers:", "content-length" in resp.headers)

    # Body reads are lazy and awaitable. Pick the representation you need:
    text = await resp.text()          # decoded str
    print("  text length:", len(text))
    # (await resp.bytes() gives raw bytes; await resp.json() parses JSON)


# ---------------------------------------------------------------------------
# 7. Token-auth flow — login, then use the returned bearer token.
# ---------------------------------------------------------------------------
async def auth_flow() -> None:
    print("\n[7] auth flow")
    client = reclie.Client("dummyjson.com")

    login = await client.post(
        "/auth/login",
        json={"username": "emilys", "password": "emilyspass"},
    )
    token = (await login.json())["accessToken"]
    print("  logged in:", login.status_code)

    me = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    print("  /auth/me ->", me.status_code, "user:", (await me.json())["username"])


# ---------------------------------------------------------------------------
# 8. Concurrency — a single Client, many requests in flight via gather.
# ---------------------------------------------------------------------------
async def concurrency() -> None:
    print("\n[8] concurrency")
    client = reclie.Client("dummyjson.com")

    async def fetch(pid: int) -> int:
        resp = await client.get(f"/products/{pid}")
        return resp.status_code

    statuses = await asyncio.gather(*(fetch(i) for i in range(1, 11)))
    print("  10 concurrent GETs:", statuses)


# ---------------------------------------------------------------------------
# 9. Long-lived client — create once, reuse everywhere (do NOT make one per
#    request; construction allocates the native connection pool).
# ---------------------------------------------------------------------------
async def reuse_client() -> None:
    print("\n[9] reuse a long-lived client")
    client = reclie.Client("dummyjson.com")
    for pid in (1, 2, 3):
        resp = await client.get(f"/products/{pid}")
        print(f"  /products/{pid} ->", resp.status_code)


# ---------------------------------------------------------------------------
# 10. Plain HTTP (no TLS) — e.g. a local service. `tls=False` is inferred for
#     non-443 ports but can be set explicitly.
# ---------------------------------------------------------------------------
async def plain_http() -> None:
    print("\n[10] plain HTTP (local server)")
    import json
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # silence
            pass

        def do_GET(self):
            body = json.dumps({"ok": True, "path": self.path}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    client = reclie.Client("127.0.0.1", port=port, tls=False)
    resp = await client.get("/hello")
    print("  local GET ->", resp.status_code, await resp.json())
    server.shutdown()


# ---------------------------------------------------------------------------
# 11. Configuration — timeout, pool size, connection TTL, version.
# ---------------------------------------------------------------------------
async def configuration() -> None:
    print("\n[11] configuration")
    client = reclie.Client(
        "dummyjson.com",
        port=443,
        tls=True,
        version=1,        # 1 or 2 (HTTP/1.1 on the wire today)
        pool_size=32,     # max concurrent connections to this origin
        ttl=60,           # connection time-to-live (seconds)
        timeout=15.0,     # request timeout in seconds (not yet enforced)
    )
    resp = await client.get("/products/1")
    print("  configured client ->", resp.status_code)


# ---------------------------------------------------------------------------
# 12. Custom CA bundle — verify TLS against your own trust store.
# ---------------------------------------------------------------------------
async def custom_ca() -> None:
    print("\n[12] custom CA bundle")
    # Provide a PEM file path...
    #   client = reclie.Client("internal.example.com", ca_bundle_path="/etc/ssl/corp.pem")
    # ...or raw PEM bytes:
    #   client = reclie.Client("internal.example.com", ca_bundle=pem_bytes)
    # By default reclie uses certifi's bundle, so this is only needed for
    # private/self-hosted CAs.
    print("  (see source — uses certifi by default)")


# ---------------------------------------------------------------------------
# 13. Error handling — every failure is a typed exception under RecliError,
#     and the network ones also subclass the matching builtins.
# ---------------------------------------------------------------------------
async def error_handling() -> None:
    print("\n[13] error handling")

    # Connection refused -> reclie.ConnectionError (also a builtins.ConnectionError).
    client = reclie.Client("127.0.0.1", port=9, tls=False)
    try:
        await client.get("/")
    except reclie.ConnectionError as exc:
        print("  caught ConnectionError:", exc)

    # The full hierarchy (all derive from reclie.RecliError):
    print("  exception types:", [
        reclie.RecliError.__name__,
        reclie.ConnectionError.__name__,
        reclie.TimeoutError.__name__,
        reclie.TlsError.__name__,
        reclie.ProtocolError.__name__,
        reclie.PoolExhaustedError.__name__,
    ])


EXAMPLES = [
    quickstart,
    all_methods,
    query_params,
    custom_headers,
    request_bodies,
    response_object,
    auth_flow,
    concurrency,
    reuse_client,
    plain_http,
    configuration,
    custom_ca,
    error_handling,
]


async def main() -> None:
    for example in EXAMPLES:
        try:
            await example()
        except Exception as exc:  # keep going so one network hiccup isn't fatal
            print(f"  ! {example.__name__} failed: {type(exc).__name__}: {exc}")


if __name__ == "__main__":
    asyncio.run(main())
