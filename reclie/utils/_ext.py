"""Loader for the compiled Zig core extension (``_reclie``).

The native engine is built by ``zig build`` and dropped next to this package
as ``_reclie.<abi-tag>.so`` / ``.pyd``. Importing it here keeps the guarded
import in one place (DRY) and gives a clear, actionable error when the
extension has not been built yet.
"""

from __future__ import annotations

from typing import Any

_ext: Any | None = None


def extension() -> Any:
    """Return the loaded ``_reclie`` C-extension module.

    Raises
    ------
    ImportError
        If the native engine has not been built. Run ``zig build`` from the
        repository root to produce it.
    """
    global _ext
    if _ext is not None:
        return _ext
    try:
        from .. import _reclie  # type: ignore[attr-defined]
    except ImportError as exc:  # pragma: no cover - depends on build state
        raise ImportError(
            "The reclie native engine (_reclie) is not built. "
            "Run `zig build -Doptimize=ReleaseFast` from the repository root, "
            "then reinstall the package."
        ) from exc
    _ext = _reclie
    return _ext
