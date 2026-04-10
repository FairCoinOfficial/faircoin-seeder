#!/bin/bash
# Entrypoint for dnsseed container.
# Converts PEER_IPS env var (comma-separated) into -s (seed) flags.

set -e

EXTRA_ARGS=""
if [ -n "${PEER_IPS:-}" ]; then
  IFS=',' read -ra PEERS <<< "$PEER_IPS"
  for peer in "${PEERS[@]}"; do
    EXTRA_ARGS="$EXTRA_ARGS -s $peer"
  done
fi

exec /usr/local/bin/dnsseed $EXTRA_ARGS "$@"
