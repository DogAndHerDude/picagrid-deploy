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

# Adds what storage needs to a .env written before it existed, as an update can't ask anyone.
ensure_storage_settings() {
  [ -f .env ] || return 0
  local name value
  for name in GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN S3_ACCESS_KEY S3_SECRET_KEY; do
    [ -z "$(env_value "$name")" ] || continue
    value="$(openssl rand -hex 32)"
    # Garage only takes access keys in this form.
    [ "$name" = S3_ACCESS_KEY ] && value="GK$(openssl rand -hex 12)"
    printf '%s=%s\n' "$name" "$value" >>.env
  done
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

# Runs rclone next to storage, with a folder of backups at /backups: rclone_run sync store:… /backups/…
rclone_run() {
  docker compose run --rm -T --user "$(id -u):$(id -g)" -v "$BACKUP_DIR:/backups" rclone "$@"
}

storage_bucket() {
  local bucket
  bucket="$(env_value S3_BUCKET)"
  printf '%s' "${bucket:-picagrid}"
}
