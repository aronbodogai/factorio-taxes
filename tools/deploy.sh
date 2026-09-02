#!/usr/bin/env bash
# Sync the scenario from the repository into the WSL headless install.
# Run inside WSL. The deployed copy is disposable; never edit it directly.
set -euo pipefail

REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
TARGET="$SERVER/scenarios/factorio-taxes"

if [ ! -d "$SERVER" ]; then
  echo "headless install not found at $SERVER" >&2
  exit 1
fi

mkdir -p "$SERVER/scenarios"
rm -rf "$TARGET"
cp -r "$REPO/scenario/factorio-taxes" "$TARGET"

# Windows checkouts can carry CRLF; Factorio tolerates it but the logs do not.
find "$TARGET" -type f \( -name '*.lua' -o -name '*.cfg' -o -name '*.json' \) \
  -exec sed -i 's/\r$//' {} +

echo "deployed to $TARGET"
