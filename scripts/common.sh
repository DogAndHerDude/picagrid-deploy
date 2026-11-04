#!/usr/bin/env bash
# Shared by the other scripts. Runs from the deploy repository, wherever it's called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
STATE_DIR="${STATE_DIR:-$ROOT/state}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups}"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# The value of one setting in .env, without running the file: it holds JSON and passwords.
env_value() {
  # Not being there is fine: these are optional, and it mustn't stop a script running with set -e.
  { grep -E "^$1=" .env 2>/dev/null || true; } | tail -n 1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'$//"
}

alert() {
  log "ALERT: $*"
  local url
  url="$(env_value ALERT_WEBHOOK_URL)"
  if [ -n "$url" ]; then
    curl -fsS -m 10 -H 'Content-Type: application/json' \
      -d "$(printf '{"text":"Picagrid on %s: %s"}' "$(hostname)" "$*")" "$url" >/dev/null || log "the alert couldn't be sent"
  fi
}
