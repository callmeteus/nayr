#!/bin/sh
# Run formatting check and ZLint for nayr.
#
# Set ZLINT to the full path of the zlint binary, or leave unset to use PATH.
# Pin: v0.8.1 (see docs/LINTING.md).

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

zig fmt --check src tests build.zig tests.zig

ZLINT_BIN="${ZLINT:-}"
if [ -z "$ZLINT_BIN" ]; then
    ZLINT_BIN="$(command -v zlint 2>/dev/null || true)"
fi
if [ -z "$ZLINT_BIN" ] && [ -x "$ROOT/.zlint-bin/zlint" ]; then
    ZLINT_BIN="$ROOT/.zlint-bin/zlint"
fi
if [ -z "$ZLINT_BIN" ]; then
    printf "lint: zlint not found. Install v0.8.1 from https://github.com/DonIsaac/zlint/releases\n" >&2
    printf "lint: or run: sh scripts/zlint-install.sh\n" >&2
    exit 1
fi

exec "$ZLINT_BIN"
