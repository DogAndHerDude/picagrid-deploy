#!/usr/bin/env bash
# What's running, the last deploys and backups, and whether each address answers.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

docker compose ps --all --format 'table {{.Service}}\t{{.Status}}'
echo
domain="$(env_value DOMAIN)"
for url in "https://$domain/" "https://app.$domain/" "https://api.$domain/healthz" "https://app.$domain/kratos/health/ready"; do
  printf '%s %s\n' "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || true)" "$url"
done
echo
if [ -s "$STATE_DIR/held-images" ]; then echo "Builds being skipped after failing: $(wc -l <"$STATE_DIR/held-images")"; fi
echo "Latest backup: $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1 || true)"
if command -v journalctl >/dev/null; then
  echo; journalctl -u picagrid-deploy.service -n 10 --no-pager -o cat 2>/dev/null || true
fi
