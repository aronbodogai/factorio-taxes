#!/usr/bin/env bash
# Does the scenario survive with the DLC enabled? It targets the base game, so
# this establishes whether the DLC must be turned off rather than assuming.
set -uo pipefail
REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
RUN_DIR="$HOME/factorio-taxes-server/run-dlc"
PORT=27021
"$REPO/tools/deploy.sh" >/dev/null
mkdir -p "$RUN_DIR/mods"
cat > "$RUN_DIR/mods/mod-list.json" <<'JSON'
{ "mods": [ { "name": "base", "enabled": true }, { "name": "elevated-rails", "enabled": true },
            { "name": "quality", "enabled": true }, { "name": "space-age", "enabled": true } ] }
JSON
cat > "$RUN_DIR/server-settings.json" <<'JSON'
{ "name": "dlc", "description": "", "visibility": { "public": false, "lan": false },
  "require_user_verification": false, "auto_pause": false, "autosave_interval": 0 }
JSON
LOG="$RUN_DIR/server.log"; rm -f "$LOG"
"$SERVER/bin/x64/factorio" --start-server-load-scenario factorio-taxes \
  --server-settings "$RUN_DIR/server-settings.json" --mod-directory "$RUN_DIR/mods" \
  --port 34250 --rcon-port $PORT --rcon-password taxes >"$LOG" 2>&1 &
PID=$!
python3 "$REPO/tools/rcon.py" $PORT taxes --file "$REPO/tests/dlc_check.rcon"
kill -INT $PID 2>/dev/null; sleep 2; kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
echo "--- log errors ---"
grep -iE 'Error while running|non-recoverable|Unknown key|stack traceback' "$LOG" | head -8 || echo "(none)"
