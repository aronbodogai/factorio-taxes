#!/usr/bin/env bash
# Deploy the scenario, boot the headless server on it, drive it over RCON with a
# command file, then shut down and report. Run inside WSL.
#
#   tools/headless_test.sh tests/smoke.rcon
#
# Exit status is non-zero if the server logged a Lua error or the command file
# printed a line starting with "FAIL".
set -uo pipefail

REPO="${REPO:-/mnt/b/repos/factorio-taxes}"
SERVER="${SERVER:-$HOME/factorio-taxes-server/factorio}"
BIN="$SERVER/bin/x64/factorio"
RCON_PORT="${RCON_PORT:-27015}"
RCON_PASSWORD="${RCON_PASSWORD:-taxes}"
RUN_DIR="${RUN_DIR:-$HOME/factorio-taxes-server/run}"
SCENARIO="${SCENARIO:-factorio-taxes}"
COMMAND_FILE="${1:-}"

if [ -z "$COMMAND_FILE" ]; then
  echo "usage: $0 <rcon-command-file>" >&2
  exit 2
fi
if [ ! -f "$COMMAND_FILE" ]; then
  COMMAND_FILE="$REPO/$COMMAND_FILE"
fi
if [ ! -f "$COMMAND_FILE" ]; then
  echo "command file not found: ${1}" >&2
  exit 2
fi

"$REPO/tools/deploy.sh" >/dev/null

mkdir -p "$RUN_DIR"
SETTINGS="$RUN_DIR/server-settings.json"
cat > "$SETTINGS" <<'JSON'
{
  "name": "factorio-taxes-test",
  "description": "automated test server",
  "visibility": { "public": false, "lan": false },
  "require_user_verification": false,
  "auto_pause": false,
  "autosave_interval": 0,
  "non_blocking_saving": true
}
JSON

# The headless install ships the DLC alongside base and enables it by default.
# This scenario is base-game only, so pin an explicit mod list that turns it off.
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

LOG="$RUN_DIR/server.log"
OUT="$RUN_DIR/rcon.out"
rm -f "$LOG" "$OUT"

"$BIN" --start-server-load-scenario "$SCENARIO" \
       --server-settings "$SETTINGS" \
       --mod-directory "$MODS_DIR" \
       --rcon-port "$RCON_PORT" \
       --rcon-password "$RCON_PASSWORD" \
       >"$LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -INT "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 20); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$SERVER_PID" 2>/dev/null
  fi
  wait "$SERVER_PID" 2>/dev/null
}
trap cleanup EXIT

python3 "$REPO/tools/rcon.py" "$RCON_PORT" "$RCON_PASSWORD" --file "$COMMAND_FILE" \
  | tee "$OUT"
RCON_STATUS=${PIPESTATUS[0]}

cleanup
trap - EXIT

STATUS=0
if [ "$RCON_STATUS" -ne 0 ]; then
  echo "RESULT: FAIL (rcon client exited $RCON_STATUS)"
  STATUS=1
fi
if grep -qE '^FAIL|ERROR in /' "$OUT"; then
  echo "RESULT: FAIL (assertion)"
  grep -E '^FAIL|ERROR in /' "$OUT"
  STATUS=1
fi
# Match genuine failures only. A plain "control.lua:37:" line is what log()
# prints on success, so it must not be treated as an error.
LUA_ERROR_PATTERN='Error while running|non-recoverable error|stack traceback|Cannot execute command|Unknown key:|attempt to (index|call|compare|perform)'
if grep -qE "$LUA_ERROR_PATTERN" "$LOG"; then
  echo "RESULT: FAIL (lua error in server log)"
  grep -E "$LUA_ERROR_PATTERN" "$LOG" | head -20
  STATUS=1
fi
if [ "$STATUS" -eq 0 ]; then
  echo "RESULT: PASS"
fi
echo "server log: $LOG"
exit "$STATUS"
