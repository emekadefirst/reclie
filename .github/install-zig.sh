#!/usr/bin/env bash
# Install a pinned Zig into /opt/zig inside the manylinux build container.
# cibuildwheel runs this once per Linux container (CIBW before-all). macOS and
# Windows get Zig from the setup-zig action on the runner host instead.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
ARCH="$(uname -m)"   # x86_64 or aarch64

# Zig archives are named zig-<arch>-<os>-<version>.
TARBALL="zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz"
URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"

echo "Installing Zig ${ZIG_VERSION} for ${ARCH} from ${URL}"
curl -fsSL "${URL}" -o "/tmp/${TARBALL}"

# Verify the download when a checksum is provided (see ZIG_SHA256 in build.yml).
if [ -n "${ZIG_SHA256:-}" ]; then
  echo "${ZIG_SHA256}  /tmp/${TARBALL}" | sha256sum -c -
fi

mkdir -p /opt
tar -xJf "/tmp/${TARBALL}" -C /tmp
rm -rf /opt/zig
mv "/tmp/zig-${ARCH}-linux-${ZIG_VERSION}" /opt/zig

/opt/zig/zig version
