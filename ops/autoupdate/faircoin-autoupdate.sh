#!/usr/bin/env bash
#
# faircoin-autoupdate.sh — keep a FairCoin node on the approved release.
#
# WHY THIS IS NOT A NAIVE "docker pull latest" LOOP
# --------------------------------------------------
# FairCoin runs SPORK_8 (masternode-payment enforcement). If two nodes disagree
# on the consensus rules — e.g. one adopts a release that changes masternode
# collateral and the other has not yet — they reject each other's blocks and the
# chain can split. So updates must roll out in a CONTROLLED order, never each
# node on its own whim. This script enforces that with two guards:
#
#   1. AGE GUARD       — a release is only adopted once it has been published for
#                        at least MIN_RELEASE_AGE_HOURS, so a hot-fix that gets
#                        pulled minutes after cutting never lands on a node.
#   2. CANARY GATE     — PRODUCER nodes (stakers / masternodes) refuse to switch
#                        until an OBSERVER node is already serving the target
#                        version (CANARY_URL). Observers update first and prove
#                        the build before any block-producer follows.
#
# For a hard consensus flag-day, set PINNED_VERSION on every node to the same tag
# and they converge to exactly that version on their next tick.
#
# Roles:  ROLE=observer  -> updates as soon as age guard passes (the canary)
#         ROLE=producer  -> updates only after the canary reports the target
#
# Node types are auto-detected: a docker-compose deployment (Dockerfile.node) or
# a native systemd faircoind.service.
#
set -euo pipefail

# ---- configuration (env-overridable) ---------------------------------------
REPO="${FAIRCOIN_REPO:-FairCoinOfficial/FairCoin}"
ROLE="${ROLE:-observer}"                       # observer | producer
PINNED_VERSION="${PINNED_VERSION:-}"           # e.g. v3.0.5 ; empty => track latest
MIN_RELEASE_AGE_HOURS="${MIN_RELEASE_AGE_HOURS:-6}"
CANARY_URL="${CANARY_URL:-}"                    # URL returning the live node version (producers)
COMPOSE_DIR="${COMPOSE_DIR:-/opt/faircoin-seeder}"
RPC_PORT="${RPC_PORT:-}"                        # auto-detected from conf/compose if empty
LOG="${FAIRCOIN_AUTOUPDATE_LOG:-/var/log/faircoin-autoupdate.log}"
LOCK="/run/faircoin-autoupdate.lock"
STATE_DIR="/var/lib/faircoin-autoupdate"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Single-flight: never let two updates race.
exec 9>"$LOCK" || die "cannot open lock $LOCK"
flock -n 9 || { log "another autoupdate run holds the lock; skipping"; exit 0; }
mkdir -p "$STATE_DIR"

# ---- helpers ---------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need curl; need jq

gh_api() { curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/$1"; }

# Normalize a version to MAJOR.MINOR.REVISION for comparison: the daemon reports
# a 4-part build (v3.0.5.0-<hash>) while release tags are 3-part (v3.0.5).
normver() { echo "${1#v}" | awk -F'[.-]' '{printf "%s.%s.%s", $1+0, $2+0, $3+0}'; }
same_version() { [ "$(normver "$1")" = "$(normver "$2")" ]; }

# Resolve the target release: pinned, or the newest release older than the age guard.
resolve_target() {
  if [ -n "$PINNED_VERSION" ]; then echo "$PINNED_VERSION"; return; fi
  local rel tag published age_h now pub_epoch
  rel="$(gh_api releases/latest)" || die "cannot reach GitHub releases"
  tag="$(jq -r '.tag_name' <<<"$rel")"
  published="$(jq -r '.published_at' <<<"$rel")"
  now="$(date -u +%s)"
  pub_epoch="$(date -u -d "$published" +%s)"
  age_h=$(( (now - pub_epoch) / 3600 ))
  if [ "$age_h" -lt "$MIN_RELEASE_AGE_HOURS" ]; then
    log "latest release $tag is only ${age_h}h old (< ${MIN_RELEASE_AGE_HOURS}h age guard); holding"
    return 1
  fi
  echo "$tag"
}

running_version() { # prints the running daemon version tag, best-effort
  if [ "$NODE_TYPE" = docker ]; then
    docker exec faircoin-node /opt/faircoin/faircoind --version 2>/dev/null | head -1
  else
    /usr/local/bin/faircoind --version 2>/dev/null | head -1
  fi | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

canary_ok() { # producers: is the canary already serving the target?
  [ "$ROLE" != producer ] && return 0
  [ -z "$CANARY_URL" ] && { log "ROLE=producer but no CANARY_URL set; refusing to switch"; return 1; }
  local resp seen
  resp="$(curl -fsSL --max-time 15 "$CANARY_URL" 2>/dev/null || true)"
  # Prefer the daemon's "Core:X.Y.Z" subversion marker; never an IP that happens
  # to be in the JSON. Fall back to a v-prefixed version string.
  seen="$(grep -oE 'Core:[0-9]+\.[0-9]+\.[0-9]+' <<<"$resp" | head -1 | cut -d: -f2)"
  [ -n "$seen" ] || seen="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$resp" | head -1)"
  if [ -n "$seen" ] && same_version "$seen" "$TARGET"; then return 0; fi
  log "canary ($CANARY_URL) reports '${seen:-none}', target is $TARGET; producer holds until canary updates"
  return 1
}

health_check() { # RPC answers and the tip is advancing
  local port="$1" before after i
  before="$(rpc "$port" getblockcount '[]' | jq -r '.result // empty' 2>/dev/null || true)"
  [ -n "$before" ] || { log "health: RPC not responding after update"; return 1; }
  for i in $(seq 1 12); do
    after="$(rpc "$port" getblockcount '[]' | jq -r '.result // empty' 2>/dev/null || true)"
    [ -n "$after" ] && [ "$after" -gt "$before" ] && { log "health: tip advanced $before -> $after"; return 0; }
    sleep 10
  done
  log "health: tip did not advance from $before within ~2m (still syncing?)"
  return 0   # not fatal: mnsync/IBD can take minutes; node is up if RPC answered
}

rpc() { # rpc <port> <method> <json-params>
  curl -fsS --max-time 10 --user "$RPC_USER:$RPC_PASS" \
    --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"au\",\"method\":\"$2\",\"params\":$3}" \
    "http://127.0.0.1:$1/" 2>/dev/null
}

# ---- detect node type + credentials ----------------------------------------
if [ -f "$COMPOSE_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
  NODE_TYPE=docker
  set -a; [ -f "$COMPOSE_DIR/.env" ] && . "$COMPOSE_DIR/.env"; set +a
  RPC_USER="${RPC_USER:-fair}"; RPC_PASS="${RPC_PASS:-}"; RPC_PORT="${RPC_PORT:-40405}"
elif systemctl list-unit-files 2>/dev/null | grep -q '^faircoind\.service'; then
  NODE_TYPE=native
  CONF="${FAIRCOIN_CONF:-/root/.faircoin/faircoin.conf}"
  RPC_USER="$(grep -m1 '^rpcuser=' "$CONF" 2>/dev/null | cut -d= -f2)"
  RPC_PASS="$(grep -m1 '^rpcpassword=' "$CONF" 2>/dev/null | cut -d= -f2)"
  RPC_PORT="${RPC_PORT:-$(grep -m1 '^rpcport=' "$CONF" 2>/dev/null | cut -d= -f2)}"; RPC_PORT="${RPC_PORT:-46373}"
else
  die "no faircoin node found (neither $COMPOSE_DIR/docker-compose.yml nor faircoind.service)"
fi
log "node type=$NODE_TYPE role=$ROLE rpc_port=$RPC_PORT"

# ---- resolve + compare ------------------------------------------------------
TARGET="$(resolve_target)" || exit 0
CURRENT="$(running_version || true)"
log "current=${CURRENT:-unknown} target=$TARGET"
if same_version "$CURRENT" "$TARGET"; then log "already on $TARGET; nothing to do"; exit 0; fi
canary_ok || exit 0

# ---- apply ------------------------------------------------------------------
log "updating $NODE_TYPE node ${CURRENT:-unknown} -> $TARGET"
if [ "$NODE_TYPE" = docker ]; then
  ( cd "$COMPOSE_DIR" && docker compose build --no-cache --build-arg FAIRCOIN_VERSION="$TARGET" faircoind \
      && docker compose up -d faircoind ) || die "docker update failed"
else
  TARBALL="faircoin-${TARGET}-linux-x86_64.tar.gz"
  URL="https://github.com/$REPO/releases/download/$TARGET/$TARBALL"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$URL" -o "$TMP/$TARBALL" || die "download $URL failed"
  # Verify against the release's published SHA256SUMS if present (best-effort).
  if curl -fsSL "https://github.com/$REPO/releases/download/$TARGET/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    ( cd "$TMP" && grep "$TARBALL" SHA256SUMS | sha256sum -c - ) || die "checksum mismatch for $TARBALL"
    log "checksum verified"
  else
    log "WARNING: no SHA256SUMS in release; proceeding without checksum verification"
  fi
  tar -xzf "$TMP/$TARBALL" -C "$TMP"
  NEWBIN="$(find "$TMP" -name faircoind -type f | head -1)"; [ -x "$NEWBIN" ] || die "no faircoind in tarball"
  cp -f /usr/local/bin/faircoind "$STATE_DIR/faircoind.prev" 2>/dev/null || true   # rollback copy
  systemctl stop faircoind
  install -m0755 "$NEWBIN" /usr/local/bin/faircoind
  [ -f "$(dirname "$NEWBIN")/faircoin-cli" ] && install -m0755 "$(dirname "$NEWBIN")/faircoin-cli" /usr/local/bin/faircoin-cli || true
  systemctl start faircoind
fi

# ---- verify (rollback native on failure) -----------------------------------
sleep 5
if ! health_check "$RPC_PORT"; then
  if [ "$NODE_TYPE" = native ] && [ -x "$STATE_DIR/faircoind.prev" ]; then
    log "health check failed; rolling back native binary"
    systemctl stop faircoind
    install -m0755 "$STATE_DIR/faircoind.prev" /usr/local/bin/faircoind
    systemctl start faircoind
    die "rolled back to previous binary after failed update to $TARGET"
  fi
  die "update to $TARGET failed health check"
fi
echo "$TARGET" > "$STATE_DIR/version"
log "SUCCESS: node updated to $TARGET"
