# CI / release

`workflows/build.yml` builds the **production** (`ReleaseFast`) wheels and
publishes to PyPI.

## What it does

- **wheels**: matrix over Linux / Windows / macOS. Uses
  [`cibuildwheel`](https://cibuildwheel.pypa.io) to produce one **abi3** wheel
  per platform (`cp311-abi3-*`), which serves CPython 3.11+ because the engine
  targets `Py_LIMITED_API` 3.11. The extension is built by
  `zig build -Doptimize=ReleaseFast` (via `setup.py`).
- **sdist**: a source distribution (requires Zig on the machine to install).
- **publish**: on a `v*` tag, uploads everything to PyPI via
  [OIDC trusted publishing](https://docs.pypi.org/trusted-publishers/) — no API
  token stored in the repo.

## Dry runs (no publish)

Use the **Run workflow** button (Actions → build → Run workflow). It builds
wheels + sdist but never publishes. Pick a single OS from the dropdown to
iterate fast on the riskier platforms (macOS/Linux) instead of building all
three. Pushes to `main` and PRs also build-only.

## Zig version

Pinned via the `ZIG_VERSION` env in the workflow (`0.16.0`, released
2026-04-13). `ZIG_SHA256` pins the checksum of the x86_64 Linux tarball. It's
consumed two ways:

- Windows / macOS: `mlugg/setup-zig` installs it on the runner host.
- Linux: `install-zig.sh` downloads + verifies it into the manylinux container
  (cibuildwheel `before-all`).

When bumping Zig, update both `ZIG_VERSION` and `ZIG_SHA256` (grab the new
checksum from `https://ziglang.org/download/index.json`).

## Releasing to PyPI

1. Create a PyPI project named `reclie` and configure a **trusted publisher**
   pointing at this repo + the `pypi` environment (Settings → Environments).
2. Bump `version` in `pyproject.toml`.
3. Tag and push:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

The `publish` job runs only on `v*` tags.

## Local production build

```bash
zig build -Doptimize=ReleaseFast     # drops reclie/_reclie.pyd | _reclie.abi3.so
python -m build --wheel              # -> dist/reclie-*-cp311-abi3-*.whl
```
