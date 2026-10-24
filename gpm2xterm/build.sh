#!/usr/bin/env bash
# Build gpm2xterm (console mouse/clipboard wrapper) without root.
# Fetches libgpm headers+lib from the Ubuntu pool into ./prefix on first run.
# For non-amd64: adjust the .deb suffix (arm64) and lib path.
set -euo pipefail
cd "$(dirname "$0")"
ARCH="${1:-amd64}"
LIBDIR="lib/x86_64-linux-gnu"
[ "$ARCH" = "arm64" ] && LIBDIR="lib/aarch64-linux-gnu"
POOL="http://archive.ubuntu.com/ubuntu/pool/main/g/gpm"

if [ ! -f prefix/usr/include/gpm.h ]; then
  echo "fetching libgpm-dev/libgpm2 ($ARCH) ..."
  mkdir -p prefix
  mapfile -t files < <(
    curl -s "$POOL/" |
    grep -oE "libgpm(-dev|2)_[^\"]+${ARCH}\.deb" |
    sort -u | tail -2
  )
  for f in "${files[@]}"; do
    curl -sO "$POOL/$f" && dpkg -x "$f" prefix && rm -f "$f"
  done
fi

gcc -O2 -Wall -Wextra -o gpm2xterm gpm2xterm.c \
  -I prefix/usr/include -L "prefix/usr/${LIBDIR}" -lgpm -lutil
echo "built: ./gpm2xterm   (deploy: sudo install -m755 gpm2xterm /usr/local/bin/)"
