"""The reclie Client facade.

A single, long-lived ``Client`` exposes HTTP/1.1 and HTTP/2 over one
connection pool. The Python layer is intentionally thin: request
orchestration lives in :mod:`reclie.core`; this class just owns the pool and
dispatches to it. (SSE and WebSocket are deferred to a later phase.)
"""

from __future__ import annotations

from typing import Any, Optional

from .core import Headers, Method, Params, request
from .utils import RecliResponse, TlsError, extension

__all__ = ["Client", "Method"]


def _default_ca_bundle_path() -> Optional[str]:
    """Return a path to a CA bundle file. Tries ``certifi`` first, then
    ``ssl.get_default_verify_paths().cafile``. Returns ``None`` if neither is
    available — Client then refuses to construct with ``tls=True``."""
    try:
        import certifi

        return certifi.where()
    except ImportError:
        try:
            import ssl

            return ssl.get_default_verify_paths().cafile
        except Exception:
            return None


class Client:
    """Origin-bound, reusable async client for HTTP/1.1 and HTTP/2.

    Instantiating a ``Client`` allocates the native connection pool. Keep it
    alive for the lifetime of your application; do not create one per request.
    """

    __slots__ = ("host", "port", "tls", "version", "pool_size", "ttl", "timeout", "_ca_path", "_pool")

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

        # Resolve a CA bundle *file path* for TLS (the native engine loads it).
        # Precedence:
        #   1. Caller-supplied ``ca_bundle_path``
        #   2. Caller-supplied ``ca_bundle`` (raw PEM bytes -> temp file)
        #   3. ``certifi.where()`` if installed
        #   4. ``ssl.get_default_verify_paths().cafile``
        if not tls:
            self._ca_path = ""
        elif ca_bundle_path is not None:
            self._ca_path = ca_bundle_path
        elif ca_bundle is not None:
            import tempfile

            tmp = tempfile.NamedTemporaryFile(
                prefix="reclie-ca-", suffix=".pem", delete=False
            )
            tmp.write(ca_bundle)
            tmp.close()
            self._ca_path = tmp.name
        else:
            self._ca_path = _default_ca_bundle_path() or ""

        if tls and not self._ca_path:
            raise TlsError(
                "No CA bundle available for TLS. Install `certifi` or pass "
                "`ca_bundle`/`ca_bundle_path` to Client(...)."
            )

        self._pool = extension().pool_create(
            host, port, tls, version, pool_size, ttl, self._timeout_ms,
            self._ca_path,
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
