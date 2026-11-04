#!/usr/bin/env bash
# Stays on one build of a service, until told to follow main again:
#   scripts/rollback.sh api <commit sha>     pins it
#   scripts/rollback.sh api main             follows main again
#   scripts/rollback.sh                      shows what's pinned
#
# Database migrations aren't undone. If the build you're going back to can't run on the newer
# database, restore the backup taken before the update instead: see scripts/restore.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ $# -eq 0 ]; then
  grep -E '^(API|UI|WEBSITE|KRATOS)_TAG=' .env || true
  exit 0
fi
service="${1:?}"
tag="${2:?Which build? A commit sha, or main.}"
case "$service" in
  api) name=API_TAG ;;
  ui) name=UI_TAG ;;
  website) name=WEBSITE_TAG ;;
  kratos) name=KRATOS_TAG ;;
  *) echo "Unknown service: $service. Use api, ui, website or kratos." >&2; exit 1 ;;
esac
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "That doesn't look like a build: $tag" >&2; exit 1; }

value="$tag"
[ "$tag" = "main" ] && value=""
if grep -qE "^$name=" .env; then
  sed -i.bak -E "s/^$name=.*/$name=$value/" .env && rm -f .env.bak
else
  echo "$name=$value" >>.env
fi
log "$service now on ${tag}"
# The deploy lock, so the timer can't run in the middle of this.
exec 9>"$STATE_DIR/deploy.lock"
flock 9
docker compose pull --quiet "$service"
[ "$service" = "api" ] && docker compose pull --quiet api-migrate
[ "$service" = "kratos" ] && docker compose pull --quiet kratos-migrate
docker compose up -d --wait --wait-timeout "${WAIT_SECONDS:-240}" "$service"
log "done"
