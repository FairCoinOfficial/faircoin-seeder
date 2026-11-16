# Host hardening for FairCoin nodes

`apply.sh` is idempotent and safe to re-run on any host that runs `faircoind`
under systemd (`fcnode1-3`, `fcexplorer`, `fcbridge`).

| Piece | Why (2026-11-16 incident) |
|---|---|
| `/etc/rsyslog.d/30-faircoind.conf` drops `faircoind` from syslog | The daemon already logs to journald (capped at 40M) and to `~/.faircoin/debug.log` (logrotate, 20M). rsyslog duplicated everything into `/var/log/syslog`, which had no size cap: a stuck staker on fcnode3 wrote ~4 GB/day there, filled the disk and stopped the node. |
| `maxsize 200M` in `/etc/logrotate.d/rsyslog` | Weekly rotation alone does not bound size. |
| `faircoind.service.d/hardening.conf`: `TimeoutStopSec=300`, `OOMScoreAdjust=-900` | fcbridge's node tore its block files when it was killed mid-write (1 GB host, OOM kills on record; default 90s stop timeout then SIGKILL) and sat frozen at height 105451 for three months. |

On `fcexplorer` only, `faircoind.service.d/priority.conf` sets `Nice=0`: the
unit ran the node at `Nice=5`, below the web app that depends on it, so under
load the node starved first and its RPC stopped answering.
