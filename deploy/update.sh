#!/usr/bin/env bash
#
# Poll the tracked branch and redeploy when a new commit appears.
# Invoked from /etc/cron.d/faircoin-seeder-update (see install.sh).

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/faircoin-seeder}"
REPO_BRANCH="${REPO_BRANCH:-main}"

if [[ -f "$INSTALL_DIR/.env" ]]; then
  # Load INSTALL_DIR / REPO_BRANCH overrides but ignore seeder args.
  # shellcheck disable=SC1091
  source "$INSTALL_DIR/.env"
fi

log() { printf '[update %(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*"; }

cd "$INSTALL_DIR"

git fetch --quiet origin "$REPO_BRANCH"
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse "origin/$REPO_BRANCH")

if [[ "$local_sha" == "$remote_sha" ]]; then
  exit 0
fi

log "new commit detected: ${local_sha:0:12} -> ${remote_sha:0:12}"
git reset --hard "origin/$REPO_BRANCH"

log "rebuilding and restarting container"
docker compose up -d --build

log "deploy complete"
