#!/usr/bin/env bash
# Apply on every FairCoin host as root:  ssh root@HOST bash -s < ops/hardening/apply.sh
# Idempotent. See ops/hardening/README.md for why each piece exists.
set -e
# 1) faircoind already logs to the capped journal and its own rotated debug.log;
#    copying it into /var/log/syslog as well filled fcnode3's disk (4 GB/day).
cat > /etc/rsyslog.d/30-faircoind.conf <<'R'
# 2026-11-16: faircoind is logged by journald (capped) and ~/.faircoin/debug.log
# (logrotate, maxsize 20M). Do not duplicate it here: on fcnode3 a stuck staker
# wrote 4 GB/day to /var/log/syslog, filled the disk and stopped the node.
if $programname == 'faircoind' then stop
R
# 2) Cap syslog by size, not just weekly.
if [ -f /etc/logrotate.d/rsyslog ] && ! grep -q "maxsize" /etc/logrotate.d/rsyslog; then
  sed -i '0,/{/s//{\n\tmaxsize 200M/' /etc/logrotate.d/rsyslog
fi
rsyslogd -N1 >/dev/null 2>&1 && systemctl restart rsyslog
logrotate -d /etc/logrotate.d/rsyslog >/dev/null 2>&1 && echo "logrotate ok"
grep -n maxsize /etc/logrotate.d/rsyslog | head -2
# 3) faircoind: stop cleanly, never be the OOM victim.
mkdir -p /etc/systemd/system/faircoind.service.d
cat > /etc/systemd/system/faircoind.service.d/hardening.conf <<'H'
# 2026-11-16: a daemon killed mid-write (OOM killer, or SIGKILL after the 90s
# default stop timeout) tears LevelDB/blk files; fcbridge sat corrupted for 3 months.
[Service]
TimeoutStopSec=300
KillSignal=SIGTERM
OOMScoreAdjust=-900
H
systemctl daemon-reload
echo "hardened $(hostname)"
