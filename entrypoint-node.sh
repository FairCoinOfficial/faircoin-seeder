#!/bin/bash
# Entrypoint for faircoind container.
# Converts PEER_IPS env var (comma-separated) into -addnode flags.

set -e

EXTRA_ARGS=""
if [ -n "${PEER_IPS:-}" ]; then
  IFS=',' read -ra PEERS <<< "$PEER_IPS"
  for peer in "${PEERS[@]}"; do
    EXTRA_ARGS="$EXTRA_ARGS -addnode=$peer"
  done
fi

exec faircoind -datadir=/data -printtoconsole $EXTRA_ARGS "$@"
