"""Remote HTTPS benchmark against dummyjson.com — reclie vs httpx vs aiohttp.

This is the honest, real-network test (vs the localhost micro-benchmark):
network latency dominates, and it exposes that reclie currently opens a fresh
TLS connection per request while httpx/aiohttp reuse a kept-alive one.

dummyjson rate-limits (~100 req/window), so counts are kept modest and any
non-200s are reported. Latency percentiles matter more than throughput here.
"""

import asyncio
import statistics
import time

import aiohttp
import httpx

import reclie

HOST = "dummyjson.com"
PATH = "/products/1"
URL = f"https://{HOST}{PATH}"

SEQ_N = 12          # sequential requests
CONC_N = 24         # concurrent requests
CONC = 8            # max in flight
PAUSE_BETWEEN = 12  # seconds between clients, to ease rate limiting


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return 0.0
    k = max(0, min(len(xs) - 1, round((p / 100) * (len(xs) - 1))))
    return xs[k]


def report(name, mode, lats_ms, errors, elapsed):
    n = len(lats_ms)
    rps = n / elapsed if elapsed else 0
    if n:
        print(f"  {name:<9}{mode:<12}{n:>4} ok {errors:>3} err "
              f"{rps:>8.1f} rps   p50 {pct(lats_ms,50):>7.1f}  "
              f"p95 {pct(lats_ms,95):>7.1f}  p99 {pct(lats_ms,99):>7.1f} ms")
    else:
        print(f"  {name:<9}{mode:<12}   0 ok {errors:>3} err  (all failed)")


# ---- reclie ----
async def bench_reclie(mode):
    client = reclie.Client(HOST)
    await (await client.get(PATH)).json()  # warm-up

    async def one():
        t = time.perf_counter()
        r = await client.get(PATH)
        await r.json()
        return (time.perf_counter() - t) * 1000, r.status_code

    return await _run(mode, one)


# ---- httpx (HTTP/1.1, keep-alive) ----
async def bench_httpx(mode):
    async with httpx.AsyncClient(base_url=f"https://{HOST}") as client:
        await (await client.get(PATH)).aread()  # warm-up (opens connection)

        async def one():
            t = time.perf_counter()
            r = await client.get(PATH)
            r.json()
            return (time.perf_counter() - t) * 1000, r.status_code

        return await _run(mode, one)


# ---- aiohttp (keep-alive) ----
async def bench_aiohttp(mode):
    async with aiohttp.ClientSession(base_url=f"https://{HOST}") as session:
        async with session.get(PATH) as r:  # warm-up
            await r.read()

        async def one():
            t = time.perf_counter()
            async with session.get(PATH) as r:
                await r.read()
            return (time.perf_counter() - t) * 1000, r.status

        return await _run(mode, one)


async def _run(mode, one):
    lats, errors = [], 0

    async def call():
        nonlocal errors
        try:
            ms, status = await one()
            if status == 200:
                lats.append(ms)
            else:
                errors += 1
        except Exception:
            errors += 1

    start = time.perf_counter()
    if mode == "sequential":
        for _ in range(SEQ_N):
            await call()
    else:
        sem = asyncio.Semaphore(CONC)

        async def guarded():
            async with sem:
                await call()

        await asyncio.gather(*(guarded() for _ in range(CONC_N)))
    return lats, errors, time.perf_counter() - start


async def main():
    print(f"target: {URL}")
    print(f"sequential={SEQ_N}, concurrent={CONC_N} @ {CONC}, "
          f"latency in ms (lower is better)\n")

    clients = [("reclie", bench_reclie), ("httpx", bench_httpx), ("aiohttp", bench_aiohttp)]

    for mode in ("sequential", "concurrent"):
        print(f"=== {mode} ===")
        for name, fn in clients:
            lats, errors, elapsed = await fn(mode)
            report(name, mode, lats, errors, elapsed)
            await asyncio.sleep(PAUSE_BETWEEN)  # ease rate limiting
        print()


if __name__ == "__main__":
    asyncio.run(main())
