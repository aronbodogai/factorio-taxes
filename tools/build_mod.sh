#!/usr/bin/env bash
# Assemble the mod form of the scenario. The scenario is the single source of
# truth: every script and locale file is copied from it, and the only thing this
# script writes by hand is info.json and a control.lua that differs in one way.
#
#   tools/build_mod.sh            build into build/ and zip it
#   MOD_VERSION=0.2.0 tools/build_mod.sh
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION="${MOD_VERSION:-0.2.0}"
NAME="factorio-taxes"
SRC="$REPO/scenario/$NAME"
OUT="$REPO/build/${NAME}_${VERSION}"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$SRC/scripts" "$OUT/scripts"
cp -r "$SRC/locale" "$OUT/locale"
cp "$SRC/changelog.txt" "$OUT/changelog.txt"

cat > "$OUT/info.json" <<JSON
{
  "name": "$NAME",
  "version": "$VERSION",
  "title": "Factorio Taxes",
  "author": "ideku",
  "description": "A recurring tax you have to physically pay. An indestructible rail line and station exist from map generation; a tax train arrives on a cycle, demands items or fluids drawn from your own tech tree, and answers whatever you fail to deliver with a proportional biter attack.",
  "factorio_version": "2.0",
  "dependencies": ["base >= 2.0.0"]
}
JSON

# The scenario loads base freeplay underneath itself because a scenario replaces
# it. A mod runs alongside whatever scenario is already active, so loading
# freeplay here would register its handlers a second time.
cat > "$OUT/control.lua" <<'LUA'
-- Factorio Taxes, mod form.
--
-- Identical to the scenario apart from this file. The scenario has to load base
-- freeplay itself, because a scenario replaces it; a mod runs alongside the
-- active scenario, so loading freeplay here would double-register its handlers.

local handler = require("event_handler")
handler.add_lib(require("scripts.taxes"))
LUA

find "$OUT" -type f \( -name '*.lua' -o -name '*.cfg' -o -name '*.json' \) \
  -exec sed -i 's/\r$//' {} +

if command -v zip >/dev/null 2>&1; then
  (cd "$REPO/build" && rm -f "${NAME}_${VERSION}.zip" && zip -qr "${NAME}_${VERSION}.zip" "${NAME}_${VERSION}")
  echo "built $REPO/build/${NAME}_${VERSION}.zip"
else
  echo "built $OUT (zip not installed, directory form only)"
fi
