# faircoin-monitor

Detects, within minutes, the three failures that went unnoticed for weeks or
months before 2026-11-16:

- **Chain split.** A node whose active chain no longer contains our block at
  `lowest tip - 6`. FairCoin's `nMaxReorganizationDepth` is 100: once a
  split is 100 blocks deep, the minority node can never reorg back. fcnode2 (a
  large staker) split at height 166299 on 2026-09-24 and crossed that line in
  about two hours. This check catches a split while it is still a few blocks
  deep.
- **Stall or lag.** A node more than 10 blocks behind the best one, on two
  consecutive runs.
- **Down.** No P2P handshake. A full disk or a crash-looping daemon shows up
  this way.

It runs on **fcexplorer** every 5 minutes (systemd timer). It talks to the
other nodes only over the public P2P port, so they need no credentials and no
install. The local node is also checked over RPC (tip age).

## Install / update (on fcexplorer)

```bash
scp ops/monitor/faircoin-monitor.py root@187.33.154.215:/usr/local/bin/faircoin-monitor
scp ops/monitor/faircoin-monitor.{service,timer} root@187.33.154.215:/etc/systemd/system/
# first time only: create /etc/faircoin-monitor.env from faircoin-monitor.env.example (chmod 600)
ssh root@187.33.154.215 'systemctl daemon-reload && systemctl enable --now faircoin-monitor.timer'
```

## Alerts

Every problem is logged to the journal (`journalctl -t faircoin-monitor`). Set
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `/etc/faircoin-monitor.env` to
also get Telegram messages: one when a problem appears, a reminder every 6h
while it persists, and one when it recovers.

## If it reports "DIFFERENT CHAIN"

1. On that node, stop staking right away (`staking=0`, restart `faircoind`).
   Every block it stakes makes the split deeper.
2. Back up `wallet.dat`, move `blocks/` and `chainstate/` aside, start the node,
   and let it resync from the majority nodes.
3. Re-enable staking once it is at the tip and the monitor reports it on the
   same chain.
