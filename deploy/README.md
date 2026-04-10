# Deployment

Each seed VPS runs two Docker containers:

- **faircoin-node** -- full FairCoin node (`faircoind`) on port 46372 (P2P)
  and port 40405 (RPC). Provides blockchain data and peers.
- **faircoin-seeder** -- DNS seeder (`dnsseed`) on port 53. Crawls the
  network and answers DNS queries with healthy peer addresses.

## Zero-config on DigitalOcean

Name your droplets `vps1.fairco.in` and `vps2.fairco.in`. The install script
auto-detects `SEED_HOST` and `NS_HOST` from the droplet hostname via the
DigitalOcean metadata API. No environment variables needed.

```bash
# SSH into the droplet and run:
sudo bash deploy/install.sh
```

That's it. The script will:
1. Stop `systemd-resolved` to free port 53
2. Open firewall ports 53 (DNS), 46372 (P2P), and 40405 (RPC)
3. Install Docker if missing
4. Clone the repo and write `.env`
5. Build and start both containers (faircoind + dnsseed)
6. Install a cron job that auto-updates from `main` every 5 minutes

## Architecture

```
                     FairCoin Wallet
                          |
                    DNS query: seed1.fairco.in
                          |
                    Cloudflare NS delegation
                          |
              +-----------+-----------+
              |                       |
        vps1.fairco.in          vps2.fairco.in
        146.190.235.89          104.248.207.35
              |                       |
     +--------+--------+    +--------+--------+
     |  dnsseed (:53)  |    |  dnsseed (:53)  |
     | faircoind(:46372|    | faircoind(:46372|
     |          :40405)|    |          :40405)|
     +-----------------+    +-----------------+
              |                       |
              +--- P2P connection ----+
```

Wallets query `seed1.fairco.in` via DNS, get peer IPs back, and connect
directly to those peers on port 46372.

The Explorer (`explorer.fairco.in`) connects to `seed1.fairco.in:40405`
for RPC data (blocks, transactions, addresses).

## Layout

- `install.sh` -- idempotent bootstrap script with auto-detection.
- `update.sh` -- polled by cron; `git reset --hard` to `origin/main` and
  rebuild when a new commit is detected.
- `cloud-init.yml.tpl` -- cloud-init user-data template for provisioning
  new DigitalOcean droplets. Only `{{HOSTNAME}}` needs to be filled in.

## Environment variables (`.env`)

All are auto-detected on DigitalOcean. Override with env vars if needed.

| Variable      | Default              | Purpose                                     |
|---------------|----------------------|---------------------------------------------|
| `SEED_HOST`   | (auto-detected)      | Hostname the DNS seeder answers queries for  |
| `NS_HOST`     | (auto-detected)      | Nameserver hostname reported in SOA records  |
| `MBOX`        | `admin.fairco.in`    | Contact mailbox reported in SOA records      |
| `RPC_PORT`    | `40405`              | FairCoin RPC port                            |
| `RPC_USER`    | `fair`               | FairCoin RPC username                        |
| `RPC_PASS`    | `change_me`          | FairCoin RPC password                        |

## DNS configuration (Cloudflare)

The `fairco.in` domain is managed in Cloudflare. Required records:

```
vps1.fairco.in.       A   146.190.235.89     (DNS only, no proxy)
vps2.fairco.in.       A   104.248.207.35     (DNS only, no proxy)

seed1.fairco.in.      NS  vps1.fairco.in.
seed2.fairco.in.      NS  vps2.fairco.in.

explorer.fairco.in.   CNAME  faircoin-explorer-zbmjl.ondigitalocean.app  (proxied)
```

The `NS` delegation makes DNS clients contact the `dnsseed` process on the
droplet when they resolve `seedN.fairco.in`. Cloudflare proxy must be OFF
for the VPS and seed records (grey cloud / DNS only).

## Manual install on a non-DO host

```bash
sudo SEED_HOST=seed1.fairco.in \
     NS_HOST=vps1.fairco.in \
     bash deploy/install.sh
```

## Auto-update

A cron job under `/etc/cron.d/faircoin-seeder-update` runs
`/usr/local/bin/faircoin-seeder-update` (a copy of `update.sh`) every
5 minutes. Logs are written to `/var/log/faircoin-seeder-update.log`.
