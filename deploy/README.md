# Deployment

The seeder is deployed as a Docker container (`docker-compose.yml` at the repo
root). Each host runs one container serving a single seed hostname.

## Layout

- `install.sh` – idempotent bootstrap script. Installs Docker if missing,
  frees port 53 (stops `systemd-resolved`), clones this repo, writes
  `.env`, builds and starts the container, and installs a cron job that
  polls `main` for new commits every 5 minutes.
- `update.sh` – polled by cron; `git reset --hard` to `origin/main` and
  rebuild when a new commit is detected.
- `cloud-init.yml.tpl` – cloud-init user-data template used when
  provisioning a DigitalOcean droplet. Placeholders (`{{HOSTNAME}}`, …)
  are filled in by the caller.

## Environment variables (`.env`)

| Variable      | Example              | Purpose                                    |
|---------------|----------------------|--------------------------------------------|
| `SEED_HOST`   | `seed1.fairco.in`    | Hostname the DNS seeder answers queries for |
| `NS_HOST`     | `vps1.fairco.in`     | Nameserver hostname reported in SOA records |
| `MBOX`        | `admin.fairco.in`    | Contact mailbox reported in SOA records     |

## DNS (must be configured externally, e.g. Cloudflare)

For each host:

```
vps1.fairco.in.   A   <public ipv4 of droplet 1>
vps2.fairco.in.   A   <public ipv4 of droplet 2>

seed1.fairco.in.  NS  vps1.fairco.in.
seed2.fairco.in.  NS  vps2.fairco.in.
```

The `NS` delegation is what makes DNS clients contact the `dnsseed`
process running on the droplet when they resolve `seedN.fairco.in`.

## Manual install on an existing host

```bash
sudo SEED_HOST=seed1.fairco.in \
     NS_HOST=vps1.fairco.in \
     MBOX=admin.fairco.in \
     bash deploy/install.sh
```

## Auto-update

A cron job under `/etc/cron.d/faircoin-seeder-update` runs
`/usr/local/bin/faircoin-seeder-update` (a copy of `update.sh`) every
5 minutes. Logs are written to `/var/log/faircoin-seeder-update.log`.
