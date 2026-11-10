#!/usr/bin/env bash
# Puts a backup back: scripts/restore.sh backups/20261104T030000Z
# This replaces everything now in the databases and uploaded files, so it asks first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

backup="${1:?Which backup? For example: scripts/restore.sh backups/20261104T030000Z}"
[ -f "$backup/databases.sql.gz" ] || { echo "$backup has no databases.sql.gz" >&2; exit 1; }
gzip -t "$backup/databases.sql.gz"

if [ "${2:-}" != "--yes" ]; then
  read -r -p "This replaces all current data with $backup. Type RESTORE to carry on: " answer
  [ "$answer" = "RESTORE" ] || { echo "Nothing changed."; exit 1; }
fi

log "stopping the app"
docker compose stop api kratos ui website
# Without this, a reader still connected would stop the databases being replaced.
docker compose exec -T postgres psql --username=picagrid --dbname=postgres --quiet --command \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname IN ('picagrid', 'kratos')" >/dev/null

log "restoring the databases"
# --clean also tries to drop the role it's connected as, which fails harmlessly, so errors don't stop it.
gzip -dc "$backup/databases.sql.gz" | docker compose exec -T postgres psql --username=picagrid --dbname=postgres --quiet >/dev/null

if [ -f "$backup/assets.tar.gz" ]; then
  log "restoring the uploaded files"
  unpacked="$(mktemp -d "$BACKUP_DIR/restore.XXXXXX")"
  trap 'rm -rf "$unpacked"' EXIT
  tar -C "$unpacked" -xzf "$backup/assets.tar.gz"
  docker compose up -d --wait --wait-timeout "${WAIT_SECONDS:-240}" garage
  rclone_run sync "/backups/$(basename "$unpacked")/assets" "store:$(storage_bucket)"
fi

log "starting the app"
docker compose up -d --wait --wait-timeout "${WAIT_SECONDS:-240}"
log "restored from $backup"
