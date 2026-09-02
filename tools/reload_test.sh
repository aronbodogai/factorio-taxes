#!/usr/bin/env bash
# Save/reload test. Boots the scenario, drives it into a mid-cycle state, saves,
# shuts the server down, boots again from that save, and asserts the state came
# back intact. Run inside WSL.
#
#   tools/reload_test.sh tests/before_reload.rcon tests/after_reload.rcon
set -uo pipefail

REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
BIN="$SERVER/bin/x64/factorio"
RCON_PORT="${RCON_PORT:-27016}"
RCON_PASSWORD="${RCON_PASSWORD:-taxes}"
RUN_DIR="${RUN_DIR:-$HOME/factorio-taxes-server/run-reload}"
SAVE_NAME="taxes-reload"
SAVE_PATH="$SERVER/saves/$SAVE_NAME.zip"

BEFORE="${1:-tests/before_reload.rcon}"
AFTER="${2:-tests/after_reload.rcon}"
[ -f "$BEFORE" ] || BEFORE="$REPO/$BEFORE"
[ -f "$AFTER" ] || AFTER="$REPO/$AFTER"

"$REPO/tools/deploy.sh" >/dev/null

mkdir -p "$RUN_DIR" "$SERVER/saves"
rm -f "$SAVE_PATH"

SETTINGS="$RUN_DIR/server-settings.json"
cat > "$SETTINGS" <<'JSON'
{
  "name": "factorio-taxes-reload-test",
  "description": "automated reload test",
  "visibility": { "public": false, "lan": false },
  "require_user_verification": false,
  "auto_pause": false,
  "autosave_interval": 0,
  "non_blocking_saving": true
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

SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 30); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$SERVER_PID" 2>/dev/null
  fi
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
trap stop_server EXIT

run_phase() {
  local label="$1" log="$2" commands="$3"
  shift 3
  "$BIN" "$@" \
    --server-settings "$SETTINGS" \
    --mod-directory "$MODS_DIR" \
    --rcon-port "$RCON_PORT" \
    --rcon-password "$RCON_PASSWORD" \
    >"$log" 2>&1 &
  SERVER_PID=$!
  echo "=== $label ==="
  python3 "$REPO/tools/rcon.py" "$RCON_PORT" "$RCON_PASSWORD" --file "$commands"
  local status=$?
  stop_server
  return $status
}

OUT="$RUN_DIR/combined.out"
: > "$OUT"

run_phase "before reload" "$RUN_DIR/before.log" "$BEFORE" \
  --start-server-load-scenario factorio-taxes | tee -a "$OUT"

if [ ! -f "$SAVE_PATH" ]; then
  echo "FAIL save-not-created at $SAVE_PATH" | tee -a "$OUT"
  echo "RESULT: FAIL (no save)"
  exit 1
fi
echo "PROBE save-size=$(stat -c%s "$SAVE_PATH")" | tee -a "$OUT"

run_phase "after reload" "$RUN_DIR/after.log" "$AFTER" \
  --start-server "$SAVE_PATH" | tee -a "$OUT"

STATUS=0
LUA_ERROR_PATTERN='Error while running|non-recoverable error|stack traceback|Cannot execute command|Unknown key:|attempt to (index|call|compare|perform)'
if grep -qE '^FAIL|ERROR in /' "$OUT"; then
  echo "RESULT: FAIL (assertion)"
  grep -E '^FAIL|ERROR in /' "$OUT"
  STATUS=1
fi
for log in "$RUN_DIR/before.log" "$RUN_DIR/after.log"; do
  if grep -qE "$LUA_ERROR_PATTERN" "$log"; then
    echo "RESULT: FAIL (lua error in $(basename "$log"))"
    grep -E "$LUA_ERROR_PATTERN" "$log" | head -10
    STATUS=1
  fi
done
[ "$STATUS" -eq 0 ] && echo "RESULT: PASS"
exit "$STATUS"
