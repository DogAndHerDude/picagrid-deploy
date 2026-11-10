#!/usr/bin/env bash
# Prepares a fresh Hetzner server for Picagrid. Copy it over and run it as root, on Ubuntu 24.04:
#
#   scp scripts/setup.sh root@SERVER:
#   ssh -t root@SERVER bash setup.sh
#
# It asks for what it needs. Running it again is safe: it keeps what's already there, including .env.
set -euo pipefail
# shellcheck disable=SC2153 # the settings below are filled in by ask, by name

APP_DIR=/opt/picagrid
DEPLOY_USER=deploy
REPO="${DEPLOY_REPO:-git@github.com:DogAndHerDude/picagrid-deploy.git}"
SWAP_SIZE=2G

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ask() { # ask VARIABLE "question" [default]. An answer in the environment is used without asking.
  local name="$1" question="$2" default="${3:-}" answer="${!1:-}"
  while [ -z "$answer" ]; do
    read -r -p "$question${default:+ [$default]}: " answer
    answer="${answer:-$default}"
    [ -n "$answer" ] || [ "${4:-}" = "optional" ] || continue
    [ -n "$answer" ] || break
  done
  printf -v "$name" '%s' "$answer"
}
ask_optional() { ask "$1" "$2" "${3:-}" optional; }
ask_secret() {
  local name="$1" question="$2" answer="${!1:-}"
  if [ -z "$answer" ]; then read -r -s -p "$question: " answer; echo; fi
  printf -v "$name" '%s' "$answer"
}
secret() { openssl rand -hex "$1"; }
# A value for .env, in single quotes so nothing in it is expanded, whatever a password holds.
dotenv_quote() { python3 -c 'import sys; print("\x27" + sys.argv[1].replace("\x27", "\\\x27") + "\x27")' "$1"; }
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

install_packages() {
  say "Installing updates and packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq ca-certificates curl git gnupg openssl python3 rsync ufw fail2ban unattended-upgrades dnsutils
  dpkg-reconfigure -f noninteractive unattended-upgrades
}

install_docker() {
  if command -v docker >/dev/null; then return; fi
  say "Installing Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
}

add_swap() {
  # A small server without swap gets its processes killed the first time something big runs.
  if swapon --show | grep -q .; then return; fi
  say "Adding $SWAP_SIZE of swap"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
}

add_user() {
  say "Setting up the $DEPLOY_USER user"
  id "$DEPLOY_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$DEPLOY_USER"
  # Being in this group amounts to root on this server, which is why this user has no password.
  usermod -aG docker "$DEPLOY_USER"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  if [ -f /root/.ssh/authorized_keys ] && [ ! -f "/home/$DEPLOY_USER/.ssh/authorized_keys" ]; then
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"
  fi
}

secure_server() {
  say "Locking down SSH and the firewall"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  systemctl enable --now fail2ban >/dev/null
  # Only with a key in place, or this would lock everyone out.
  if [ -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ] || [ -s /root/.ssh/authorized_keys ]; then
    cat >/etc/ssh/sshd_config.d/10-picagrid.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
    systemctl reload ssh
  else
    echo "No SSH key found, so password sign-in stays on. Add a key, then run this again."
  fi
  mkdir -p /etc/docker
  # Without a limit, container logs eventually fill the disk.
  if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"}}' >/etc/docker/daemon.json
    systemctl restart docker
  fi
}

get_repository() {
  say "Getting the deploy repository"
  local key="/home/$DEPLOY_USER/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    sudo -u "$DEPLOY_USER" ssh-keygen -q -t ed25519 -N "" -C "picagrid-deploy@$(hostname)" -f "$key"
  fi
  sudo -u "$DEPLOY_USER" sh -c "ssh-keyscan -q github.com >>~/.ssh/known_hosts 2>/dev/null; sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts"
  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"
  if [ -d "$APP_DIR/.git" ]; then return; fi
  echo
  echo "Add this as a read-only deploy key on $REPO"
  echo "(GitHub: the repository's Settings > Deploy keys > Add deploy key):"
  echo
  cat "$key.pub"
  echo
  until sudo -u "$DEPLOY_USER" git clone --quiet "$REPO" "$APP_DIR" 2>/dev/null; do
    read -r -p "Press Enter once it's added, to try again. "
  done
}

write_env() {
  if [ -f "$APP_DIR/.env" ]; then
    echo "Keeping the existing $APP_DIR/.env"
    return
  fi
  say "Settings. Secrets are generated, and it all goes in $APP_DIR/.env"
  ask DOMAIN "Domain" picagrid.com
  ask ACME_EMAIL "Email for certificate notices"
  ask SIGNUP_ALLOWED_EMAILS "Who can sign up without an invite, comma-separated. Include yourself, or nobody can get in"
  echo
  echo "Mail, from a provider like Postmark, Brevo or Amazon SES:"
  ask SMTP_HOST "  SMTP host"
  ask SMTP_PORT "  SMTP port" 587
  ask SMTP_USERNAME "  SMTP username"
  ask_secret SMTP_PASSWORD "  SMTP password"
  ask MAIL_FROM_ADDRESS "  Send from" "invites@$DOMAIN"
  echo
  echo "Google sign-in. In Google Cloud's OAuth credentials, add this redirect address:"
  echo "  https://app.$DOMAIN/kratos/self-service/methods/oidc/callback/google"
  ask GOOGLE_CLIENT_ID "  Client ID"
  ask_secret GOOGLE_CLIENT_SECRET "  Client secret"
  echo
  echo "Microsoft sign-in, or leave these empty to add it later. Its app registration needs this redirect address:"
  echo "  https://app.$DOMAIN/kratos/self-service/methods/oidc/callback/microsoft"
  echo "and the optional xms_edov claim, or nobody can sign up with it."
  ask_optional MICROSOFT_CLIENT_ID "  Client ID"
  [ -z "${MICROSOFT_CLIENT_ID:-}" ] || ask_secret MICROSOFT_CLIENT_SECRET "  Client secret"
  echo
  ask_optional BACKUP_RSYNC_TARGET "Where to copy backups, like u1234@u1234.your-storagebox.de:picagrid. Strongly advised, can be added later"
  ask_optional ALERT_WEBHOOK_URL "Slack-style webhook for failed deploys and backups, optional"

  local google microsoft="" providers
  google=$(python3 -c 'import json,sys; print(json.dumps({"id":"google","provider":"google","label":"Google","client_id":sys.argv[1],"client_secret":sys.argv[2],"mapper_url":"file:///etc/config/kratos/prod/oidc.google.jsonnet","scope":["openid","email","profile"]},separators=(",",":")))' "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET")
  if [ -n "${MICROSOFT_CLIENT_ID:-}" ]; then
    microsoft=","$(python3 -c 'import json,sys; print(json.dumps({"id":"microsoft","provider":"microsoft","label":"Microsoft","microsoft_tenant":"common","client_id":sys.argv[1],"client_secret":sys.argv[2],"mapper_url":"file:///etc/config/kratos/prod/oidc.microsoft.jsonnet","scope":["openid","email","profile"]},separators=(",",":")))' "$MICROSOFT_CLIENT_ID" "$MICROSOFT_CLIENT_SECRET")
  fi
  providers="[$google$microsoft]"

  umask 077
  cat >"$APP_DIR/.env" <<ENV
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
POSTGRES_PASSWORD=$(secret 32)
KRATOS_COOKIE_SECRET=$(secret 32)
KRATOS_CIPHER_SECRET=$(secret 16)
SIGNUP_ALLOWED_EMAILS=$SIGNUP_ALLOWED_EMAILS
SMTP_ADDR=$SMTP_HOST:$SMTP_PORT
SMTP_USERNAME=$SMTP_USERNAME
SMTP_PASSWORD=$(dotenv_quote "$SMTP_PASSWORD")
MAIL_FROM_ADDRESS=$MAIL_FROM_ADDRESS
KRATOS_SMTP_URI='smtp://$(urlencode "$SMTP_USERNAME"):$(urlencode "$SMTP_PASSWORD")@$SMTP_HOST:$SMTP_PORT/'
OIDC_PROVIDERS=$(dotenv_quote "$providers")
SSO_DEFAULT_PROVIDER=
SSO_DOMAINS=
API_TAG=
UI_TAG=
WEBSITE_TAG=
KRATOS_TAG=
BACKUP_RSYNC_TARGET=${BACKUP_RSYNC_TARGET:-}
ALERT_WEBHOOK_URL=${ALERT_WEBHOOK_URL:-}
ENV
  chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
}

registry_login() {
  say "Signing in to GitHub's image registry"
  if sudo -u "$DEPLOY_USER" test -f "/home/$DEPLOY_USER/.docker/config.json" && sudo -u "$DEPLOY_USER" grep -q ghcr.io "/home/$DEPLOY_USER/.docker/config.json"; then
    echo "Already signed in."
    return
  fi
  echo "The images are private, so the server needs a read-only token: a GitHub classic personal"
  echo "access token with just the read:packages scope, from a machine account if you can."
  ask GHCR_USER "  GitHub username" DogAndHerDude
  ask_secret GHCR_TOKEN "  Token"
  printf '%s' "$GHCR_TOKEN" | sudo -u "$DEPLOY_USER" docker login ghcr.io --username "$GHCR_USER" --password-stdin >/dev/null
}

check_dns() {
  say "Checking DNS"
  local domain ip host found missing=0
  domain="$(grep -E '^DOMAIN=' "$APP_DIR/.env" | cut -d= -f2-)"
  ip="$(curl -fsS -4 -m 10 https://ifconfig.me || true)"
  for host in "$domain" "www.$domain" "app.$domain" "api.$domain" "s3.$domain"; do
    found="$(dig +short A "$host" | tail -n 1)"
    if [ "$found" = "$ip" ]; then echo "  ok      $host"; else echo "  WRONG   $host is '${found:-nothing}', should be $ip"; missing=1; fi
  done
  if [ "$missing" = 1 ]; then
    echo "Certificates can't be issued until these are right, and too many failures get you rate limited."
    read -r -p "Fix them, then press Enter to carry on. "
  fi
}

install_timers() {
  say "Installing the timers"
  install -m 644 "$APP_DIR"/systemd/picagrid-*.service "$APP_DIR"/systemd/picagrid-*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now picagrid-backup.timer >/dev/null
}

first_start() {
  say "Starting Picagrid. The first time takes a few minutes"
  sudo -u "$DEPLOY_USER" "$APP_DIR/scripts/deploy.sh"
  systemctl enable --now picagrid-deploy.timer >/dev/null
  sudo -u "$DEPLOY_USER" "$APP_DIR/scripts/status.sh"
}

main() {
  [ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
  # Without a terminal its questions wait for answers without ever being shown.
  [ -t 0 ] || { echo "This asks questions, so it needs a terminal: ssh -t root@SERVER bash setup.sh" >&2; exit 1; }
  install_packages
  install_docker
  add_swap
  add_user
  secure_server
  get_repository
  write_env
  registry_login
  check_dns
  install_timers
  first_start
  say "Done"
  echo "Updates arrive by themselves within a minute of an image being pushed."
  echo "See how it's doing with: sudo -u $DEPLOY_USER $APP_DIR/scripts/status.sh"
}

# Sourced, the functions can be tested on their own.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
