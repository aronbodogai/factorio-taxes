#!/usr/bin/env bash
# Build the mod, load it over a plain freeplay map, and run a command file.
set -uo pipefail
REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
BIN="$SERVER/bin/x64/factorio"
RCON_PORT="${RCON_PORT:-27019}"
RCON_PASSWORD="${RCON_PASSWORD:-taxes}"
RUN_DIR="${RUN_DIR:-$HOME/factorio-taxes-server/run-mod}"
COMMANDS="${1:-tests/mod_smoke.rcon}"
[ -f "$COMMANDS" ] || COMMANDS="$REPO/$COMMANDS"

MOD_VERSION="${MOD_VERSION:-0.1.0}" "$REPO/tools/build_mod.sh" >/dev/null

MODS_DIR="$RUN_DIR/mods"
mkdir -p "$MODS_DIR"
rm -rf "$MODS_DIR/factorio-taxes"*
cp -r "$REPO/build/factorio-taxes_${MOD_VERSION:-0.1.0}" "$MODS_DIR/"
cat > "$MODS_DIR/mod-list.json" <<'JSON'
{ "mods": [
  { "name": "base", "enabled": true },
  { "name": "factorio-taxes", "enabled": true },
  { "name": "elevated-rails", "enabled": false },
  { "name": "quality", "enabled": false },
  { "name": "space-age", "enabled": false }
] }
JSON
cat > "$RUN_DIR/server-settings.json" <<'JSON'
{ "name": "mod-test", "description": "", "visibility": { "public": false, "lan": false },
  "require_user_verification": false, "auto_pause": false, "autosave_interval": 0 }
JSON

LOG="$RUN_DIR/server.log"; OUT="$RUN_DIR/rcon.out"; rm -f "$LOG" "$OUT"
"$BIN" --start-server-load-scenario vanilla-freeplay --server-settings "$RUN_DIR/server-settings.json" \
  --mod-directory "$MODS_DIR" --rcon-port "$RCON_PORT" --rcon-password "$RCON_PASSWORD" >"$LOG" 2>&1 &
PID=$!
python3 "$REPO/tools/rcon.py" "$RCON_PORT" "$RCON_PASSWORD" --file "$COMMANDS" | tee "$OUT"
kill -INT "$PID" 2>/dev/null; sleep 2; kill -9 "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

STATUS=0
grep -qE '^FAIL|ERROR in /' "$OUT" && { echo "RESULT: FAIL (assertion)"; grep -E '^FAIL|ERROR in /' "$OUT"; STATUS=1; }
grep -qE 'Error while running|non-recoverable error|stack traceback|Unknown key:' "$LOG" && { echo "RESULT: FAIL (lua error)"; grep -E 'Error while running|non-recoverable error|stack traceback|Unknown key:' "$LOG" | head -10; STATUS=1; }
[ "$STATUS" -eq 0 ] && echo "RESULT: PASS"
exit "$STATUS"
