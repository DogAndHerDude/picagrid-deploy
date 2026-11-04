#!/usr/bin/env bash
# Removes what test/up.sh made, data included.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
grep -q picagridprod .env || { echo ".env isn't a test one, so this won't touch it." >&2; exit 1; }
docker compose down -v
docker rm -f picagrid-registry >/dev/null
rm -rf .env state backups
