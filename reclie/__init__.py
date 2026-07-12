"""reclie — a high-performance async HTTP client with a native Zig core.

v0.1 scope: HTTP/1.1 and HTTP/2 over ``http`` and ``https``

Public surface::

    import reclie

    client = reclie.Client("api.example.com")
    resp = await client.get("/products")
    data = await resp.json()
"""

from __future__ import annotations

from ._client import Client
from .core import Method
from .utils import (
    ConnectionError,
    PoolExhaustedError,
    ProtocolError,
    RecliError,
    RecliHeaders,
    RecliResponse,
    TimeoutError,
    TlsError,
)

__all__ = [
    "Client",
    "Method",
    "RecliResponse",
    "RecliHeaders",
    "RecliError",
    "ConnectionError",
    "TimeoutError",
    "TlsError",
    "ProtocolError",
    "PoolExhaustedError",
]
