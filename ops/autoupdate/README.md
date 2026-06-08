# FairCoin node auto-update

Keeps nodes on the **approved** FairCoin release without hand-SSHing each box —
the failure that left the explorer's node (`vps1`) stuck on a pre-fix v3.0.0
build while the rest of the network ran the fixed binary, so masternodes showed 0.

## Why it isn't a naive "pull latest" loop

FairCoin runs `SPORK_8` (masternode-payment enforcement). If nodes disagree on
consensus rules — e.g. one adopts a release that changes masternode collateral
before another does — they reject each other's blocks and the chain can split.
Uncoordinated per-node auto-update is therefore unsafe. Two guards prevent it:

1. **Age guard** (`MIN_RELEASE_AGE_HOURS`, default 6h) — a release is only adopted
   after it has been public long enough to be trusted, so a hot-fix that gets
   pulled minutes after cutting never lands.
2. **Canary gate** — `ROLE=producer` nodes (stakers, masternodes) refuse to switch
   until an `ROLE=observer` node is already serving the target version
   (`CANARY_URL`). Observers update first and prove the build; producers follow.

For a hard consensus flag-day, set the same `PINNED_VERSION` on every node.

## Rollout order

```
observers (explorer/seed)  ── update first, immediately on age guard ──►  prove build
                                                                              │
producers (fcnode1/2/3)  ── wait until CANARY_URL reports the target ──◄──────┘
```

## Install

Observer (the explorer node and any seed nodes):
```bash
sudo ROLE=observer ops/autoupdate/install.sh
```

Producer (stakers / masternode hosts), gated on an observer:
```bash
sudo ROLE=producer \
     CANARY_URL=https://explorer.fairco.in/api/network-info \
     ops/autoupdate/install.sh
```

Pin everyone to an exact tag for a coordinated consensus upgrade:
```bash
sudo ROLE=observer PINNED_VERSION=v3.0.6 ops/autoupdate/install.sh   # then the same on producers
```

## What it does each tick (every 15 min)

1. Resolves the target tag (pinned, or newest release past the age guard).
2. Reads the running daemon version; exits if already current.
3. Producers: confirms the canary already serves the target, else holds.
4. Applies: `docker compose build --build-arg FAIRCOIN_VERSION=<tag> && up -d`
   (docker nodes) or download + checksum + swap binary + `systemctl restart`
   (native nodes).
5. Health-checks (RPC answers, tip advances). Native nodes roll back to the
   previous binary on failure.

Logs: `/var/log/faircoin-autoupdate.log` and `journalctl -u faircoin-autoupdate`.

## Node-type detection

- **docker** — a `docker-compose.yml` under `COMPOSE_DIR` (default `/opt/faircoin-seeder`).
- **native** — a `faircoind.service` systemd unit (datadir `/root/.faircoin`).
