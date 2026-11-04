#!/usr/bin/env bash
# Runs production on this machine, on picagrid.localhost: real images, HTTPS and subdomains. It
# needs ports 80 and 443 free, so stop the dev stack first. test/down.sh removes it all again.
#
# It catches what development can't, as there the app and the API share one address and vite serves
# the files. Open https://app.picagrid.localhost and accept the certificate warning, once for each of
# app, api and the bare domain. Sign in as first@paper.test. Mail goes to http://localhost:8025.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ ! -f .env ] || grep -q picagridprod .env || { echo ".env isn't a test one, so this won't touch it." >&2; exit 1; }
PROJECTS="${PROJECTS:-..}"
PREFIX=localhost:5555/test

docker start picagrid-registry >/dev/null 2>&1 || docker run -d --name picagrid-registry -p 127.0.0.1:5555:5000 registry:2 >/dev/null
docker build -q -t "$PREFIX/picagrid-api:main" "$PROJECTS/api"
docker build -q -t "$PREFIX/picagrid-kratos:main" "$PROJECTS/ory-kratos"
docker build -q -f "$PROJECTS/ui/Dockerfile.prod" --build-arg VITE_API_URL=https://api.picagrid.localhost -t "$PREFIX/picagrid-ui:main" "$PROJECTS/ui"
docker build -q --build-arg PUBLIC_APP_URL=https://app.picagrid.localhost -t "$PREFIX/picagrid-website:main" "$PROJECTS/homepage"
for image in api kratos ui website; do docker push -q "$PREFIX/picagrid-$image:main" >/dev/null; done

if [ ! -f .env ]; then
  mapper="$(base64 <"$PROJECTS/ory-kratos/dev/oidc.mock.jsonnet" | tr -d '\n')"
  umask 077
  cat >.env <<ENV
COMPOSE_PROJECT_NAME=picagridprod
COMPOSE_FILE=compose.yaml:test/compose.test.yaml
IMAGE_PREFIX=$PREFIX
DOMAIN=picagrid.localhost
ACME_EMAIL=test@picagrid.test
ACME_CA_SERVER=https://127.0.0.1:1/directory
POSTGRES_PASSWORD=$(openssl rand -hex 32)
KRATOS_COOKIE_SECRET=$(openssl rand -hex 32)
KRATOS_CIPHER_SECRET=$(openssl rand -hex 16)
SIGNUP_ALLOWED_EMAILS=first@paper.test
SMTP_ADDR=mailpit:1025
SMTP_USERNAME=
SMTP_PASSWORD=
MAIL_FROM_ADDRESS=invites@picagrid.test
KRATOS_SMTP_URI=smtp://mailpit:1025/?disable_starttls=true
OIDC_PROVIDERS='[{"id":"google","provider":"generic","label":"Google","client_id":"x","client_secret":"x","issuer_url":"http://mock.picagrid.localhost:8090/google","mapper_url":"base64://$mapper","scope":["openid","email","profile"]}]'
ENV
fi
docker compose up -d --wait --wait-timeout 240
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
