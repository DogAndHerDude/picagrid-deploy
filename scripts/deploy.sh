#!/usr/bin/env bash
# Picks up new images. The timer runs this every minute, and it does nothing when nothing has changed.
#
# When something has: the database is backed up if the API changed, then everything is brought up and
# has to pass its health checks. If it doesn't, the old images go back, and that build is skipped
# until a newer one arrives, so a broken build isn't retried every minute.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || exit 0

HELD="$STATE_DIR/held-images"
WAIT_SECONDS="${WAIT_SECONDS:-240}"
touch "$HELD"

# Settings and compose changes in this repository arrive this way too. Its address is optional
# so a checkout without one still deploys.
config_before="$(git rev-parse HEAD 2>/dev/null || true)"
if git remote get-url origin >/dev/null 2>&1; then
  git pull --quiet --ff-only || log "couldn't update the deploy repository, carrying on with what's here"
fi
config_after="$(git rev-parse HEAD 2>/dev/null || true)"

images() { docker compose config --images | sort -u; }
image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

declare -A before
for image in $(images); do before[$image]="$(image_id "$image")"; done

if ! docker compose pull --quiet 2>"$STATE_DIR/pull.log"; then
  # Usually a registry hiccup. The next run tries again, so only say so in the log.
  log "pull failed: $(tail -n 1 "$STATE_DIR/pull.log")"
  exit 0
fi

changed=()
for image in $(images); do
  now="$(image_id "$image")"
  [ "$now" = "${before[$image]}" ] && continue
  if grep -qxF "$now" "$HELD"; then
    # The same build that failed before. Back to what's running.
    [ -n "${before[$image]}" ] && docker tag "${before[$image]}" "$image"
    continue
  fi
  changed+=("$image")
done

running="$(docker compose ps --status running --services | wc -l | tr -d ' ')"
if [ "${#changed[@]}" -eq 0 ] && [ "$config_before" = "$config_after" ] && [ "$running" -gt 0 ]; then
  exit 0
fi

log "updating: ${changed[*]:-settings}"
if printf '%s\n' "${changed[@]:-}" | grep -q 'picagrid-api\|picagrid-kratos' && [ "$running" -gt 0 ]; then
  # Their migrations run next, and those can't be undone by going back to an old image.
  scripts/backup.sh database || { alert "the backup before a deploy failed, so nothing was updated"; for image in "${changed[@]}"; do [ -n "${before[$image]}" ] && docker tag "${before[$image]}" "$image"; done; exit 1; }
fi

if docker compose up -d --wait --wait-timeout "$WAIT_SECONDS" --remove-orphans; then
  # Old images stay a week, so going back doesn't need the registry.
  docker image prune -f --filter 'until=168h' >/dev/null
  : >"$HELD"
  log "up to date"
  exit 0
fi

log "health checks failed: $(docker compose ps --all --format '{{.Service}}={{.Status}}' | tr '\n' ' ')"
for image in "${changed[@]:-}"; do
  [ -n "$image" ] || continue
  image_id "$image" >>"$HELD"
  if [ -n "${before[$image]}" ]; then docker tag "${before[$image]}" "$image"; fi
done
if docker compose up -d --wait --wait-timeout "$WAIT_SECONDS" --remove-orphans; then
  alert "a deploy failed its health checks and was rolled back: ${changed[*]:-settings}"
else
  alert "a deploy failed, and so did going back to the previous images. It needs looking at now"
fi
exit 1
