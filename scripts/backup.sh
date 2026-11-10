#!/usr/bin/env bash
# Backs up both databases and, unless called with "database", the uploaded files.
# Kept here for two weeks, and copied to BACKUP_RSYNC_TARGET if that's set. A backup that stays on
# the same server won't survive losing it, so set that.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KEEP_DAYS="${KEEP_DAYS:-14}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$BACKUP_DIR/$stamp"
mkdir -p "$target.partial"
trap 'rm -rf "$target.partial"' EXIT
chmod 700 "$target.partial"

docker compose exec -T postgres pg_dumpall --username=picagrid --clean --if-exists | gzip >"$target.partial/databases.sql.gz"
# An empty dump gzips to almost nothing, and pg_dump failing inside a pipe is easy to miss.
gzip -t "$target.partial/databases.sql.gz"
[ "$(gzip -dc "$target.partial/databases.sql.gz" | grep -c '^CREATE DATABASE\|^\\connect')" -gt 0 ] || { alert "a database backup came out empty"; exit 1; }

if [ "${1:-}" != "database" ]; then
  # Not uploads/: those are files still on their way in.
  rclone_run copy "store:$(storage_bucket)" "/backups/$stamp.partial/assets" --exclude 'uploads/**'
  tar -C "$target.partial" -czf "$target.partial/assets.tar.gz" assets
  rm -rf "$target.partial/assets"
fi

mv "$target.partial" "$target"
trap - EXIT
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_DAYS" -exec rm -rf {} +
log "backed up to $target ($(du -sh "$target" | cut -f1))"

remote="$(env_value BACKUP_RSYNC_TARGET)"
if [ -n "$remote" ]; then
  # Port 23 is how Hetzner's Storage Boxes take rsync. Set BACKUP_RSYNC_SSH to use another.
  if ! rsync -a --delete -e "${BACKUP_RSYNC_SSH:-ssh -p 23}" "$BACKUP_DIR/" "$remote/"; then
    alert "a backup couldn't be copied off the server"
    exit 1
  fi
  log "copied to $remote"
fi
