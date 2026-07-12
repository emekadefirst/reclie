"""Packaging shim: build the native `_reclie` extension with Zig.

Metadata lives in ``pyproject.toml``. This file exists only to hook the build:
``build_ext`` shells out to ``zig build -Doptimize=ReleaseFast`` (the fast
production build), then drops the resulting shared library into the wheel.

Because the engine targets ``Py_LIMITED_API`` (3.11), the extension is declared
``py_limited_api`` and the wheel is tagged ``cp311-abi3-*`` — one wheel per
platform serves CPython 3.11+.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

HERE = Path(__file__).parent.resolve()


class ZigBuildExt(build_ext):
    """Build the extension via `zig build` instead of the C toolchain."""

    def build_extension(self, ext: Extension) -> None:  # noqa: ARG002
        include_dir = sysconfig.get_path("include")
        cmd = [
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            # Build for a portable baseline CPU, NOT the build machine's native
            # CPU. Without this, a CI runner with AVX-512 etc. produces a binary
            # that crashes with SIGILL / "Illegal instruction" on older CPUs.
            "-Dcpu=baseline",
            f"-Dpython-include={include_dir}",
        ]
        if sys.platform == "win32":
            # The limited-API import library ships under <base_prefix>/libs.
            cmd.append(f"-Dpython-libs={os.path.join(sys.base_prefix, 'libs')}")

        # On Linux, pin the glibc version so Zig doesn't emit modern relocations
        # (e.g. DT_RELR / GLIBC_ABI_DT_RELR@2.36) that would make auditwheel
        # reject the wheel for the manylinux policy. Set via RECLIE_ZIG_TARGET
        # in the CI environment, e.g. "x86_64-linux-gnu.2.28".
        target = os.environ.get("RECLIE_ZIG_TARGET")
        if target:
            cmd.append(f"-Dtarget={target}")

        self.announce(f"running: {' '.join(cmd)}", level=3)
        subprocess.check_call(cmd, cwd=str(HERE))

        # zig build drops the artifact into reclie/ under its abi3 name.
        built = None
        for name in ("_reclie.pyd", "_reclie.abi3.so"):
            candidate = HERE / "reclie" / name
            if candidate.exists():
                built = candidate
                break
        if built is None:
            raise RuntimeError(
                "zig build did not produce reclie/_reclie.(pyd|abi3.so)"
            )

        dest = Path(self.build_lib) / "reclie" / built.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(built, dest)
        self.announce(f"placed native engine at {dest}", level=3)


setup(
    ext_modules=[Extension("reclie._reclie", sources=[], py_limited_api=True)],
    cmdclass={"build_ext": ZigBuildExt},
    options={"bdist_wheel": {"py_limited_api": "cp311"}},
)
