#!/usr/bin/env bash
#
# install.sh — install the FairCoin node auto-updater on this host.
#
# Usage (run on each node, as root):
#   ROLE=observer ./install.sh                       # explorer / seed nodes (the canary)
#   ROLE=producer CANARY_URL=https://explorer.fairco.in/api/network-info ./install.sh
#
# Optional env written into /etc/faircoin-autoupdate.env:
#   ROLE, PINNED_VERSION, MIN_RELEASE_AGE_HOURS, CANARY_URL, COMPOSE_DIR
#
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m0755 "$HERE/faircoin-autoupdate.sh" /usr/local/bin/faircoin-autoupdate.sh

# Persist per-node config (only keys that were provided).
ENVF=/etc/faircoin-autoupdate.env
: >"$ENVF.tmp"
for k in ROLE PINNED_VERSION MIN_RELEASE_AGE_HOURS CANARY_URL COMPOSE_DIR FAIRCOIN_REPO; do
  v="${!k:-}"; [ -n "$v" ] && echo "$k=$v" >>"$ENVF.tmp"
done
mv "$ENVF.tmp" "$ENVF"; chmod 0600 "$ENVF"
echo "wrote $ENVF:"; sed 's/^/  /' "$ENVF"

install -m0644 "$HERE/faircoin-autoupdate.service" /etc/systemd/system/faircoin-autoupdate.service
install -m0644 "$HERE/faircoin-autoupdate.timer"   /etc/systemd/system/faircoin-autoupdate.timer
systemctl daemon-reload
systemctl enable --now faircoin-autoupdate.timer
echo "installed. next runs:"; systemctl list-timers faircoin-autoupdate.timer --no-pager || true
echo "dry-run now with:  systemctl start faircoin-autoupdate.service && journalctl -u faircoin-autoupdate -n 40 --no-pager"
