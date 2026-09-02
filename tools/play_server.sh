#!/usr/bin/env bash
# Run a headless server for playtesting. Unlike the test harness this one is not
# meant to exit: it autosaves, keeps RCON open so the scenario can be inspected
# or nudged while you play, and disables the DLC so the scenario runs against the
# base game it was written for.
#
#   tools/play_server.sh            fresh map from the scenario
#   tools/play_server.sh resume     continue the last playtest save
set -uo pipefail

REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
BIN="$SERVER/bin/x64/factorio"
RUN_DIR="${RUN_DIR:-$HOME/factorio-taxes-server/play}"
RCON_PORT="${RCON_PORT:-27100}"
RCON_PASSWORD="${RCON_PASSWORD:-taxes}"
GAME_PORT="${GAME_PORT:-34197}"
SAVE="$SERVER/saves/playtest.zip"
MODE="${1:-fresh}"

"$REPO/tools/deploy.sh" >/dev/null || exit 1
mkdir -p "$RUN_DIR" "$SERVER/saves"

cat > "$RUN_DIR/server-settings.json" <<'JSON'
{
  "name": "Factorio Taxes playtest",
  "description": "Pay your taxes.",
  "tags": ["taxes"],
  "visibility": { "public": false, "lan": true },
  "require_user_verification": false,
  "auto_pause": true,
  "autosave_interval": 5,
  "autosave_slots": 6,
  "non_blocking_saving": true,
  "allow_commands": "true"
}
JSON

MODS_DIR="$RUN_DIR/mods"
mkdir -p "$MODS_DIR"
cat > "$MODS_DIR/mod-list.json" <<'JSON'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": false },
    { "name": "quality", "enabled": false },
    { "name": "space-age", "enabled": false }
  ]
}
JSON

if [ "$MODE" = "resume" ] && [ -f "$SAVE" ]; then
  echo "resuming $SAVE"
  START=(--start-server "$SAVE")
else
  echo "starting a fresh map from the scenario"
  rm -f "$SAVE"
  START=(--start-server-load-scenario factorio-taxes)
fi

echo "game port  : udp/$GAME_PORT   (connect to localhost:$GAME_PORT)"
echo "rcon port  : tcp/$RCON_PORT"
echo "server log : $RUN_DIR/server.log"

exec "$BIN" "${START[@]}" \
  --server-settings "$RUN_DIR/server-settings.json" \
  --mod-directory "$MODS_DIR" \
  --port "$GAME_PORT" \
  --rcon-port "$RCON_PORT" \
  --rcon-password "$RCON_PASSWORD" \
  >> "$RUN_DIR/server.log" 2>&1
