#!/bin/bash
# Installs the Zigcube toolchain in Claude Code cloud sessions:
# pinned Zig, libpq headers for the Postgres backend, and PATH entries.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Keep in step with build.zig.zon (minimum_zig_version) and CI.
ZIG_VERSION=0.17.0
ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ZIG_DIR=/opt/zig-x86_64-linux-${ZIG_VERSION}

if [ ! -x "$ZIG_DIR/zig" ]; then
  tmp=$(mktemp -d)
  curl -sSfL -o "$tmp/zig.tar.xz" \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
  echo "${ZIG_SHA256}  $tmp/zig.tar.xz" | sha256sum -c --quiet
  tar -xJf "$tmp/zig.tar.xz" -C /opt
  rm -rf "$tmp"
fi

# SQLite headers ship with the image; libpq headers do not.
if [ ! -f /usr/include/postgresql/libpq-fe.h ]; then
  apt-get install -y -q libpq-dev >/dev/null 2>&1 \
    || { apt-get update -q >/dev/null && apt-get install -y -q libpq-dev >/dev/null; }
fi

PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$ZIG_DIR:${PG_BIN:+$PG_BIN:}\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
