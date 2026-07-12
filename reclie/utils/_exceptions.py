"""reclie exception hierarchy.

All errors raised by reclie derive from :class:`RecliError`. Zig-side errors
are mapped to these explicit types in the C-API settlement layer; there is no
catch-all fallback for errors that have a specific class.

The network-related exceptions also subclass the matching Python builtins
(``ConnectionError``, ``TimeoutError``) so existing ``except`` blocks keep
working when migrating from ``httpx``/``aiohttp``.
"""

from __future__ import annotations

import builtins

__all__ = [
    "RecliError",
    "ConnectionError",
    "TimeoutError",
    "TlsError",
    "ProtocolError",
    "PoolExhaustedError",
]


class RecliError(Exception):
    """Base class for every error raised by reclie."""


class ConnectionError(RecliError, builtins.ConnectionError):
    """TCP connect failed, refused, or reset."""


class TimeoutError(RecliError, builtins.TimeoutError):
    """A request exceeded its configured timeout."""


class TlsError(RecliError):
    """TLS handshake or certificate verification failed."""


class PoolExhaustedError(RecliError):
    """Connection pool is at ``max_size`` with no waiter slot available."""
