"""Python-side response and message types.

The native engine constructs these objects via the C-API after I/O completes.
The Python definitions here describe the contract and implement the lazy body
reads, which call back into the Zig arena only when ``.json()`` / ``.text()`` /
``.bytes()`` is awaited.
"""

from __future__ import annotations

import json as _json
from typing import Any, Iterator, Mapping, Optional, Union

from ._ext import extension

__all__ = ["RecliHeaders", "RecliResponse", "SSEEvent", "WSMessage"]


class RecliHeaders(Mapping[str, str]):
    """Case-insensitive, read-only view over response headers.

    Header names are compared case-insensitively per RFC 7230. The original
    casing of each name is preserved for iteration.
    """

    __slots__ = ("_store",)

    def __init__(self, raw: Optional[Mapping[str, str]] = None) -> None:
        # _store maps lowercased name -> (original_name, value)
        self._store: dict[str, tuple[str, str]] = {}
        if raw:
            for key, value in raw.items():
                self._store[key.lower()] = (key, value)

    def __getitem__(self, key: str) -> str:
        return self._store[key.lower()][1]

    def __iter__(self) -> Iterator[str]:
        return (original for original, _ in self._store.values())

    def __len__(self) -> int:
        return len(self._store)

    def __contains__(self, key: object) -> bool:
        return isinstance(key, str) and key.lower() in self._store

    def __repr__(self) -> str:
        items = ", ".join(f"{k!r}: {v!r}" for k, v in self.items())
        return f"RecliHeaders({{{items}}})"


class RecliResponse:
    """An HTTP response.

    The status line and headers are populated eagerly when the response is
    constructed. The body is **lazy**: it is not copied out of the Zig arena
    until ``bytes()``, ``text()``, or ``json()`` is awaited. Hold a reference
    to this object for as long as you need the body — the arena is freed when
    the response is garbage collected.
    """

    __slots__ = ("status_code", "headers", "_body_ptr", "_body_len", "_body_cache")

    def __init__(
        self,
        status_code: int,
        headers: Union[RecliHeaders, Mapping[str, str], None] = None,
        body_ptr: int = 0,
        body_len: int = 0,
        body: Optional[bytes] = None,
    ) -> None:
        self.status_code = status_code
        self.headers = headers if isinstance(headers, RecliHeaders) else RecliHeaders(headers)
        self._body_ptr = body_ptr
        self._body_len = body_len
        # If the engine already materialized the body (Phase 2 path), cache
        # it now and skip the lazy ``read_body`` call entirely.
        self._body_cache: Optional[bytes] = body

    @property
    def ok(self) -> bool:
        """``True`` when ``status_code < 400``."""
        return self.status_code < 400

    async def bytes(self) -> bytes:
        """Return the raw response body as ``bytes`` (copied from the arena once)."""
        if self._body_cache is None:
            if self._body_len == 0:
                self._body_cache = b""
            else:
                self._body_cache = extension().read_body(self._body_ptr, self._body_len)
        return self._body_cache

    async def text(self, encoding: str = "utf-8") -> str:
        """Decode the response body as a string (UTF-8 by default)."""
        return (await self.bytes()).decode(encoding)

    async def json(self) -> Any:
        """Deserialize the response body as JSON into a ``dict``/``list``."""
        return _json.loads(await self.bytes())

    def __repr__(self) -> str:
        return f"<RecliResponse [{self.status_code}]>"
