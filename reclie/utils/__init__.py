"""Internal helpers: extension loader, response types, exceptions.

This subpackage aggregates the implementation details so the top-level
package can re-export the public surface from one place.
"""

from ._exceptions import (
    ConnectionError,
    PoolExhaustedError,
    ProtocolError,
    RecliError,
    TimeoutError,
    TlsError,
)
from ._ext import extension
from ._response import RecliHeaders, RecliRespons

__all__ = [
    "extension",
    "RecliHeaders",
    "RecliResponse",
    "RecliError",
    "ConnectionError",
    "TimeoutError",
    "TlsError",
    "ProtocolError",
    "PoolExhaustedError",
]
