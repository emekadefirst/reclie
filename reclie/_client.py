"""The reclie Client facade.

A single, long-lived ``Client`` exposes HTTP, SSE, and WebSocket over one
connection pool. The Python layer is intentionally thin: each protocol's
orchestration lives in :mod:`reclie.src.core`; this class just owns the pool
and dispatches to those engines.
"""

from __future__ import annotations

from typing import Any, Optional

from .core import Headers, Method, Params, SSEStream, WSConnect, request
from .utils import RecliResponse, extension

__all__ = ["Client", "Method"]


def _default_ca_bundle_bytes() -> bytes:
    """Read a CA bundle and return its bytes. Tries ``certifi`` first, then
    ``ssl.get_default_verify_paths().cafile``. Returns ``b""`` if neither is
    available — Client will then refuse to construct with ``tls=True``."""
    path: Optional[str] = None
    try:
        import certifi

        path = certifi.where()
    except ImportError:
        try:
            import ssl

            path = ssl.get_default_verify_paths().cafile
        except Exception:
            path = None
    if not path:
        return b""
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


class Client:
    """Origin-bound, reusable async client for HTTP, SSE, and WebSocket.

    Instantiating a ``Client`` allocates the native connection pool. Keep it
    alive for the lifetime of your application; do not create one per request.
    """

    __slots__ = ("host", "port", "tls", "version", "pool_size", "ttl", "timeout", "_ca_bundle", "_pool")

    def __init__(
        self,
        host: str,
        *,
        port: Optional[int] = None,
        tls: Optional[bool] = None,
        version: int = 2,
        pool_size: int = 64,
        ttl: int = 60,
        timeout: float = 30.0,
        ca_bundle: Optional[bytes] = None,
        ca_bundle_path: Optional[str] = None,
    ) -> None:
        if version not in (1, 2):
            raise ValueError("version must be 1 or 2")

        # Scheme/port inference: https on 443, http otherwise.
        if tls is None:
            tls = port is None or port == 443
        if port is None:
            port = 443 if tls else 80

        self.host = host
        self.port = port
        self.tls = tls
        self.version = version
        self.pool_size = pool_size
        self.ttl = ttl
        self.timeout = timeout

        # Resolve CA bundle bytes for TLS. Precedence:
        #   1. Caller-supplied ``ca_bundle`` (raw PEM bytes)
        #   2. Caller-supplied ``ca_bundle_path`` (file we read)
        #   3. ``certifi.where()`` if installed
        #   4. ``ssl.get_default_verify_paths().cafile``
        if not tls:
            self._ca_bundle = b""
        elif ca_bundle is not None:
            self._ca_bundle = ca_bundle
        elif ca_bundle_path is not None:
            with open(ca_bundle_path, "rb") as f:
                self._ca_bundle = f.read()
        else:
            self._ca_bundle = _default_ca_bundle_bytes()

        self._pool = extension().pool_create(
            host, port, tls, version, pool_size, ttl, self._timeout_ms,
            self._ca_bundle,
        )

    @property
    def _timeout_ms(self) -> int:
        return int(self.timeout * 1000)

    # ---- HTTP -----------------------------------------------------------

    async def get(
        self,
        path: str,
        *,
        headers: Optional[Headers] = None,
        params: Optional[Params] = None,
    ) -> RecliResponse:
        return await request(
            self._pool, Method.GET, path,
            version=self.version, timeout_ms=self._timeout_ms,
            headers=headers, params=params,
        )

    async def post(
        self,
        path: str,
        *,
        json: Optional[Any] = None,
        data: Optional[bytes] = None,
        headers: Optional[Headers] = None,
        params: Optional[Params] = None,
    ) -> RecliResponse:
        return await request(
            self._pool, Method.POST, path,
            version=self.version, timeout_ms=self._timeout_ms,
            headers=headers, params=params, json=json, data=data,
        )

    async def put(
        self,
        path: str,
        *,
        json: Optional[Any] = None,
        data: Optional[bytes] = None,
        headers: Optional[Headers] = None,
        params: Optional[Params] = None,
    ) -> RecliResponse:
        return await request(
            self._pool, Method.PUT, path,
            version=self.version, timeout_ms=self._timeout_ms,
            headers=headers, params=params, json=json, data=data,
        )

    async def patch(
        self,
        path: str,
        *,
        json: Optional[Any] = None,
        data: Optional[bytes] = None,
        headers: Optional[Headers] = None,
        params: Optional[Params] = None,
    ) -> RecliResponse:
        return await request(
            self._pool, Method.PATCH, path,
            version=self.version, timeout_ms=self._timeout_ms,
            headers=headers, params=params, json=json, data=data,
        )

    async def delete(
        self,
        path: str,
        *,
        headers: Optional[Headers] = None,
        params: Optional[Params] = None,
    ) -> RecliResponse:
        return await request(
            self._pool, Method.DELETE, path,
            version=self.version, timeout_ms=self._timeout_ms,
            headers=headers, params=params,
        )
