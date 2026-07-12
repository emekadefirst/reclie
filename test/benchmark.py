"""Benchmark: requests, httpx, aiohttp, http.client, and reclie.

This measures raw client overhead against a local HTTP/1.1 keep-alive server
(zero network latency), so every client hits the same workload:

    1. GET  /products
    2. POST /auth/login   {username, password}
    3. GET  /auth/me
    4. GET  /products/search?q=phone

For a real-network HTTPS comparison (reclie now supports pooled TLS), see
`example/bench_remote.py`.

Two modes are measured:
  * sequential  - one request at a time over a reused connection/pool
  * concurrent  - many requests in flight (asyncio.gather for the async
                  clients, a thread pool for the sync ones)
"""

import asyncio
import concurrent.futures
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import aiohttp
import http.client
import httpx
import requests

import reclie

LOGIN = {"username": "emilys", "password": "emilyspass"}

# Workload sizing.
SEQ_ROUNDS = 150       # rounds of 4 requests, one at a time
CONC_ROUNDS = 400      # rounds of 4 requests, run concurrently
CONCURRENCY = 50       # max in-flight rounds for the concurrent mode
REQS_PER_ROUND = 4


class BenchServer(ThreadingHTTPServer):
    # Default backlog is 5, which a concurrent burst of connects overruns
    # (WinError 10061 / connection refused). Give it room.
    request_queue_size = 512
    daemon_threads = True


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


# ---------------------------------------------------------------------------
# Per-client "one round" implementations (4 requests each).
# ---------------------------------------------------------------------------

def round_requests(session: requests.Session, base: str) -> None:
    session.get(f"{base}/products").json()
    session.post(f"{base}/auth/login", json=LOGIN).json()
    session.get(f"{base}/auth/me").json()
    session.get(f"{base}/products/search", params={"q": "phone"}).json()


def round_httpx(client: httpx.Client) -> None:
    client.get("/products").json()
    client.post("/auth/login", json=LOGIN).json()
    client.get("/auth/me").json()
    client.get("/products/search", params={"q": "phone"}).json()


def round_httpclient(conn: http.client.HTTPConnection) -> None:
    def do(method, path, body=None, headers=None):
        conn.request(method, path, body, headers or {})
        resp = conn.getresponse()
        resp.read()

    do("GET", "/products")
    do("POST", "/auth/login", json.dumps(LOGIN), {"Content-Type": "application/json"})
    do("GET", "/auth/me")
    do("GET", "/products/search?q=phone")


async def round_aiohttp(session: aiohttp.ClientSession) -> None:
    async with session.get("/products") as r:
        await r.json()
    async with session.post("/auth/login", json=LOGIN) as r:
        await r.json()
    async with session.get("/auth/me") as r:
        await r.json()
    async with session.get("/products/search", params={"q": "phone"}) as r:
        await r.json()


async def round_reclie(client: "reclie.Client") -> None:
    await (await client.get("/products")).json()
    await (await client.post("/auth/login", json=LOGIN)).json()
    await (await client.get("/auth/me")).json()
    await (await client.get("/products/search", params={"q": "phone"})).json()


# ---------------------------------------------------------------------------
# Runners: sequential and concurrent, for sync and async clients.
# ---------------------------------------------------------------------------

def time_it(fn) -> float:
    start = time.perf_counter()
    fn()
    return time.perf_counter() - start


def run_sync_seq(make_client, one_round, rounds: int) -> float:
    client = make_client()
    try:
        one_round(client)  # warm-up (not timed)
        return time_it(lambda: [one_round(client) for _ in range(rounds)])
    finally:
        _close(client)


def run_sync_conc(make_client, one_round, rounds: int, workers: int) -> float:
    # Each worker thread gets its own client (connections aren't shareable).
    local = threading.local()

    def task(_):
        client = getattr(local, "client", None)
        if client is None:
            client = make_client()
            local.client = client
        one_round(client)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        start = time.perf_counter()
        list(ex.map(task, range(rounds)))
        return time.perf_counter() - start


def run_async_seq(make_client, one_round, rounds: int) -> float:
    async def go():
        client = make_client()
        try:
            await one_round(client)  # warm-up
            start = time.perf_counter()
            for _ in range(rounds):
                await one_round(client)
            return time.perf_counter() - start
        finally:
            await _aclose(client)

    return asyncio.run(go())


def run_async_conc(make_client, one_round, rounds: int, concurrency: int) -> float:
    async def go():
        client = make_client()
        sem = asyncio.Semaphore(concurrency)

        async def guarded():
            async with sem:
                await one_round(client)

        try:
            await one_round(client)  # warm-up
            start = time.perf_counter()
            await asyncio.gather(*(guarded() for _ in range(rounds)))
            return time.perf_counter() - start
        finally:
            await _aclose(client)

    return asyncio.run(go())


def _close(client) -> None:
    for attr in ("close",):
        function = getattr(client, attr, None)
        if callable(function):
            try:
                function()
            except Exception:
                pass


async def _aclose(client) -> None:
    close = getattr(client, "close", None)
    if close is None:
        return
    try:
        res = close()
        if asyncio.iscoroutine(res):
            await res
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    server = BenchServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    base = f"http://127.0.0.1:{port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()

    # (name, kind, make_client, one_round)
    clients = [
        ("http.client", "sync", lambda: http.client.HTTPConnection("127.0.0.1", port), round_httpclient),
        ("requests", "sync", lambda: _requests_session(base), lambda c: round_requests(c, base)),
        ("httpx", "sync", lambda: httpx.Client(base_url=base), round_httpx),
        ("aiohttp", "async", lambda: aiohttp.ClientSession(base_url=base), round_aiohttp),
        ("reclie", "async", lambda: reclie.Client("127.0.0.1", port=port, tls=False, version=1), round_reclie),
    ]

    print(f"target: {base}  (local HTTP/1.1 keep-alive server)")
    print("note: reclie is HTTP-only for now; the https://dummyjson.com leg is")
    print("      pending TLS support and is omitted so the comparison stays fair.\n")

    seq_reqs = SEQ_ROUNDS * REQS_PER_ROUND
    conc_reqs = CONC_ROUNDS * REQS_PER_ROUND

    print(f"=== Sequential: {SEQ_ROUNDS} rounds x {REQS_PER_ROUND} = {seq_reqs} requests ===")
    _header()
    for name, kind, make, rnd in clients:
        elapsed = (run_async_seq if kind == "async" else run_sync_seq)(make, rnd, SEQ_ROUNDS)
        _row(name, seq_reqs, elapsed)

    print(f"\n=== Concurrent: {CONC_ROUNDS} rounds x {REQS_PER_ROUND} = {conc_reqs} requests, "
          f"concurrency {CONCURRENCY} ===")
    _header()
    for name, kind, make, rnd in clients:
        if kind == "async":
            elapsed = run_async_conc(make, rnd, CONC_ROUNDS, CONCURRENCY)
        else:
            elapsed = run_sync_conc(make, rnd, CONC_ROUNDS, CONCURRENCY)
        _row(name, conc_reqs, elapsed)

    server.shutdown()


def _requests_session(base: str) -> requests.Session:
    s = requests.Session()
    return s


def _header() -> None:
    print(f"  {'client':<14}{'requests':>10}{'time (s)':>12}{'req/s':>12}{'avg ms':>10}")


def _row(name: str, reqs: int, elapsed: float) -> None:
    rps = reqs / elapsed if elapsed else 0.0
    avg_ms = (elapsed / reqs) * 1000 if reqs else 0.0
    print(f"  {name:<14}{reqs:>10}{elapsed:>12.3f}{rps:>12.0f}{avg_ms:>10.3f}")


if __name__ == "__main__":
    main()
