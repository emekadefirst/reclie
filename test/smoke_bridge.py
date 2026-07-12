"""Smoke test for the C-ABI bridge skeleton.

Verifies:
  1. The native `_reclie` extension imports.
  2. `pool_create` returns a capsule-backed pool (via reclie.Client).
  3. `submit` is callable and raises NotImplementedError (no I/O path yet).
"""

import asyncio
import reclie
from reclie.utils import extension


def main() -> None:
    ext = extension()
    print("ext loaded:", ext)
    print("has pool_create:", hasattr(ext, "pool_create"))
    print("has submit:", hasattr(ext, "submit"))

    # pool_create through the real Client (tls=False avoids CA bundle needs).
    client = reclie.Client("example.com", port=80, tls=False, version=1)
    print("pool created:", client._pool)

    # submit should be callable and raise NotImplementedError for now.
    async def call() -> None:
        try:
            await client.get("/")
        except NotImplementedError as exc:
            print("submit raised NotImplementedError as expected:", exc)
        else:
            raise SystemExit("expected NotImplementedError from submit()")

    asyncio.run(call())
    print("OK")


if __name__ == "__main__":
    main()
