"""HTTP request orchestration.

Builds the request descriptor (path + query, flat header list, byte body),
creates the ``asyncio.Future``, and hands everything to the native engine. The
engine performs all I/O off the GIL and settles the Future via
``loop.call_soon_threadsafe``.
"""

from __future__ import annotations

import asyncio
import enum
import json as _json
from typing import Any, Mapping, Optional, Union
from urllib.parse import urlencode

from ..utils import (
    ConnectionError,
    ProtocolError,
    RecliError,
    RecliResponse,
    TimeoutError,
    TlsError,
    extension,
)

__all__ = ["Method", "Headers", "Params", "request"]

# Error-kind ordinals shared with the Zig engine (src/root.zig). 0 == success.
_ERR_CLASSES = {
    1: ConnectionError,
    2: TimeoutError,
    3: TlsError,
    4: ProtocolError,
}


def _settle(
    future: "asyncio.Future[RecliResponse]",
    status: int,
    headers: dict,
    body: bytes,
    err_kind: int,
    err_msg: str,
) -> None:
    """Resolve ``future`` from the engine callback.

    Scheduled via ``loop.call_soon_threadsafe`` from the Zig I/O thread, so this
    always runs on the event-loop thread — the only safe place to touch a Future.
    """
    if future.cancelled():
        return
    if err_kind:
        exc_cls = _ERR_CLASSES.get(err_kind, RecliError)
        future.set_exception(exc_cls(err_msg))
    else:
        future.set_result(RecliResponse(status, headers, body=body))

Headers = Mapping[str, str]
Params = Mapping[str, Union[str, int, float, bool]]


class Method(enum.IntEnum):
    """HTTP methods, matching the Zig ``Method`` enum ordinals."""

    GET = 0
    POST = 1
    PUT = 2
    PATCH = 3
    DELETE = 4
    HEAD = 5
    OPTIONS = 6


def _build_path(path: str, params: Optional[Params]) -> str:
    if not params:
        return path
    query = urlencode({k: str(v) for k, v in params.items()})
    sep = "&" if "?" in path else "?"
    return f"{path}{sep}{query}"


def _prepare_body(
    headers: Optional[Headers],
    json: Optional[Any],
    data: Optional[bytes],
) -> tuple[list[tuple[str, str]], bytes]:
    """Normalize headers + body into a flat header list and raw byte body."""
    if json is not None and data is not None:
        raise ValueError("Pass either `json` or `data`, not both.")

    header_list: list[tuple[str, str]] = []
    has_content_type = False
    if headers:
        for key, value in headers.items():
            if key.lower() == "content-type":
                has_content_type = True
            header_list.append((key, str(value)))

    if json is not None:
        body = _json.dumps(json, separators=(",", ":")).encode("utf-8")
        if not has_content_type:
            header_list.append(("Content-Type", "application/json"))
    elif data is not None:
        body = data
    else:
        body = b""

    return header_list, body


async def request(
    pool: Any,
    method: Method,
    path: str,
    *,
    version: int,
    timeout_ms: int,
    headers: Optional[Headers] = None,
    params: Optional[Params] = None,
    json: Optional[Any] = None,
    data: Optional[bytes] = None,
) -> RecliResponse:
    """Issue a single HTTP request and await its response."""
    loop = asyncio.get_running_loop()
    future: asyncio.Future[RecliResponse] = loop.create_future()

    full_path = _build_path(path, params)
    header_list, body = _prepare_body(headers, json, data)

    # Non-blocking hand-off: the engine drops the GIL, performs all I/O,
    # then settles `future` via loop.call_soon_threadsafe.
    extension().submit(
        pool,
        int(method),
        full_path,
        header_list,
        body,
        version,
        timeout_ms,
        future,
        loop,
    )
    return await future
