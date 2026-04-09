#!/usr/bin/env bash
#
# FairCoin seeder bootstrap / install script.
#
# Idempotent: safe to re-run. Intended to be invoked by cloud-init on first
# boot and by a human operator to (re)configure a host.
#
# Required environment variables:
#   SEED_HOST   Hostname the DNS seed serves (e.g. seed1.fairco.in)
#   NS_HOST     Hostname of this nameserver  (e.g. vps1.fairco.in)
#   MBOX        E-mail address reported in SOA records (e.g. admin.fairco.in)
#
# Optional:
#   REPO_URL    Git repo to deploy from   (default: FairCoinOfficial/faircoin-seeder)
#   REPO_BRANCH Branch to track           (default: main)
#   INSTALL_DIR Local checkout location   (default: /opt/faircoin-seeder)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/FairCoinOfficial/faircoin-seeder.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/faircoin-seeder}"

: "${SEED_HOST:?SEED_HOST is required}"
: "${NS_HOST:?NS_HOST is required}"
: "${MBOX:?MBOX is required}"

log() { printf '[install %(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root" >&2
  exit 1
fi

log "Freeing UDP/TCP port 53 (stop systemd-resolved stub resolver)"
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved.service || true
fi
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

log "Opening UFW for DNS (port 53 udp+tcp)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 53/udp comment "dnsseed"
  ufw allow 53/tcp comment "dnsseed"
  ufw reload
fi

log "Ensuring docker and git are installed"
if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
if ! command -v git >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y git
fi
systemctl enable --now docker

log "Cloning or updating $REPO_URL at $INSTALL_DIR"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
else
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
fi

log "Writing $INSTALL_DIR/.env"
cat > "$INSTALL_DIR/.env" <<EOF
SEED_HOST=$SEED_HOST
NS_HOST=$NS_HOST
MBOX=$MBOX
REPO_BRANCH=$REPO_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF
chmod 0644 "$INSTALL_DIR/.env"

log "Installing auto-update cron job"
install -m 0755 "$INSTALL_DIR/deploy/update.sh" /usr/local/bin/faircoin-seeder-update
cat > /etc/cron.d/faircoin-seeder-update <<EOF
# Poll the repo every 5 minutes and redeploy if there are new commits.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/faircoin-seeder-update >> /var/log/faircoin-seeder-update.log 2>&1
EOF
chmod 0644 /etc/cron.d/faircoin-seeder-update

log "Building and starting the container"
cd "$INSTALL_DIR"
docker compose up -d --build

log "Install complete. Container status:"
docker compose ps
