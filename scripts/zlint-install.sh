#!/bin/sh
# Download pinned ZLint v0.8.1 into .zlint-bin/ (gitignored).
#
# Usage: sh scripts/zlint-install.sh

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.zlint-bin"
VERSION="v0.8.1"

arch="$(uname -m)"
os="$(uname -s | tr '[:upper:]' '[:lower:]')"

case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
        printf "zlint-install: unsupported CPU: %s\n" "$arch" >&2
        exit 1
        ;;
esac

case "$os" in
    linux) name="zlint-linux-${arch}" ;;
    darwin) name="zlint-macos-${arch}" ;;
    *)
        printf "zlint-install: unsupported OS: %s\n" "$os" >&2
        exit 1
        ;;
esac

mkdir -p "$DEST"
url="https://github.com/DonIsaac/zlint/releases/download/${VERSION}/${name}"

printf "Downloading %s ...\n" "$url"
curl -fsSL -o "$DEST/zlint" "$url"
chmod +x "$DEST/zlint"
printf "Installed: %s\n" "$DEST/zlint"
