# Deployment

The seeder is deployed as a Docker container (`docker-compose.yml` at the repo
root). Each host runs one container serving a single seed hostname.

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
2. Open firewall ports 53 (DNS) and 46372 (FairCoin P2P)
3. Install Docker if missing
4. Clone the repo and write `.env`
5. Build and start the seeder container
6. Install a cron job that auto-updates from `main` every 5 minutes

## Layout

- `install.sh` -- idempotent bootstrap script with auto-detection.
- `update.sh` -- polled by cron; `git reset --hard` to `origin/main` and
  rebuild when a new commit is detected.
- `cloud-init.yml.tpl` -- cloud-init user-data template for provisioning
  new DigitalOcean droplets. Only `{{HOSTNAME}}` needs to be filled in.

## Environment variables (`.env`)

All are auto-detected on DigitalOcean. Override with env vars if needed.

| Variable      | Example              | Purpose                                    |
|---------------|----------------------|--------------------------------------------|
| `SEED_HOST`   | `seed1.fairco.in`    | Hostname the DNS seeder answers queries for |
| `NS_HOST`     | `vps1.fairco.in`     | Nameserver hostname reported in SOA records |
| `MBOX`        | `admin.fairco.in`    | Contact mailbox reported in SOA records     |

## DNS configuration (Cloudflare)

The `fairco.in` domain is managed in Cloudflare. Required records:

```
vps1.fairco.in.   A   167.71.2.184       (DNS only, no proxy)
vps2.fairco.in.   A   104.248.196.16     (DNS only, no proxy)

seed1.fairco.in.  NS  vps1.fairco.in.
seed2.fairco.in.  NS  vps2.fairco.in.
```

The `NS` delegation makes DNS clients contact the `dnsseed` process on the
droplet when they resolve `seedN.fairco.in`. Cloudflare proxy must be OFF
for these records (grey cloud / DNS only).

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
