#!/usr/bin/env bash
#
# FairCoin seeder bootstrap / install script.
#
# Idempotent: safe to re-run. Intended to be invoked by cloud-init on first
# boot and by a human operator to (re)configure a host.
#
# On DigitalOcean droplets, SEED_HOST and NS_HOST are auto-detected from
# the droplet hostname (e.g. vps1.fairco.in -> seed1.fairco.in). Override
# with environment variables if needed.
#
# Required environment variables (auto-detected on DigitalOcean):
#   SEED_HOST   Hostname the DNS seed serves (e.g. seed1.fairco.in)
#   NS_HOST     Hostname of this nameserver  (e.g. vps1.fairco.in)
#
# Optional:
#   MBOX        E-mail address reported in SOA records (default: admin.fairco.in)
#   REPO_URL    Git repo to deploy from   (default: FairCoinOfficial/faircoin-seeder)
#   REPO_BRANCH Branch to track           (default: main)
#   INSTALL_DIR Local checkout location   (default: /opt/faircoin-seeder)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/FairCoinOfficial/faircoin-seeder.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/faircoin-seeder}"
MBOX="${MBOX:-admin.fairco.in}"

log() { printf '[install %(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Auto-detect SEED_HOST and NS_HOST from DigitalOcean droplet metadata.
# Mapping: vps1.fairco.in -> seed1.fairco.in, vps2.fairco.in -> seed2.fairco.in
# ---------------------------------------------------------------------------
auto_detect_from_metadata() {
  local hostname
  hostname=$(curl -sf --connect-timeout 2 http://169.254.169.254/metadata/v1/hostname 2>/dev/null || true)
  if [[ -z "$hostname" ]]; then
    return 1
  fi
  log "Detected DigitalOcean hostname: $hostname"

  NS_HOST="${NS_HOST:-$hostname}"

  if [[ -z "${SEED_HOST:-}" ]]; then
    # Derive seed hostname: vps1.fairco.in -> seed1.fairco.in
    if [[ "$hostname" =~ ^vps([0-9]+)\.(.*) ]]; then
      SEED_HOST="seed${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      log "Auto-detected SEED_HOST=$SEED_HOST from hostname"
    fi
  fi
  return 0
}

auto_detect_from_metadata || log "Not running on DigitalOcean (metadata unavailable), using env vars"

: "${SEED_HOST:?SEED_HOST is required (set env var or run on a DO droplet named vpsN.fairco.in)}"
: "${NS_HOST:?NS_HOST is required (set env var or run on a DO droplet named vpsN.fairco.in)}"

log "Configuration: SEED_HOST=$SEED_HOST NS_HOST=$NS_HOST MBOX=$MBOX"

# ---------------------------------------------------------------------------
# Free port 53 (systemd-resolved stub listener conflicts with dnsseed)
# ---------------------------------------------------------------------------
log "Freeing UDP/TCP port 53 (stop systemd-resolved stub resolver)"
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved.service || true
fi
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# ---------------------------------------------------------------------------
# Firewall: allow DNS (port 53), FairCoin P2P (port 46372), RPC (port 40405)
# ---------------------------------------------------------------------------
log "Configuring firewall rules"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 53/udp   comment "dnsseed DNS"   || true
  ufw allow 53/tcp   comment "dnsseed DNS"   || true
  ufw allow 46372/tcp comment "faircoin P2P"  || true
  ufw allow 40405/tcp comment "faircoin RPC"  || true
  ufw reload
fi

# ---------------------------------------------------------------------------
# Install Docker and Git
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Clone or update the repository
# ---------------------------------------------------------------------------
log "Cloning or updating $REPO_URL at $INSTALL_DIR"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
else
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
fi

# ---------------------------------------------------------------------------
# Write .env for docker-compose
# ---------------------------------------------------------------------------
log "Writing $INSTALL_DIR/.env"
cat > "$INSTALL_DIR/.env" <<EOF
SEED_HOST=$SEED_HOST
NS_HOST=$NS_HOST
MBOX=$MBOX
RPC_PORT=${RPC_PORT:-40405}
RPC_USER=${RPC_USER:-fair}
RPC_PASS=${RPC_PASS:-change_me}
REPO_BRANCH=$REPO_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF
chmod 0644 "$INSTALL_DIR/.env"

# ---------------------------------------------------------------------------
# Auto-update cron job
# ---------------------------------------------------------------------------
log "Installing auto-update cron job"
install -m 0755 "$INSTALL_DIR/deploy/update.sh" /usr/local/bin/faircoin-seeder-update
cat > /etc/cron.d/faircoin-seeder-update <<EOF
# Poll the repo every 5 minutes and redeploy if there are new commits.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/faircoin-seeder-update >> /var/log/faircoin-seeder-update.log 2>&1
EOF
chmod 0644 /etc/cron.d/faircoin-seeder-update

# ---------------------------------------------------------------------------
# Build and start the container
# ---------------------------------------------------------------------------
log "Building and starting the container"
cd "$INSTALL_DIR"
docker compose up -d --build

log "Install complete. Container status:"
docker compose ps
