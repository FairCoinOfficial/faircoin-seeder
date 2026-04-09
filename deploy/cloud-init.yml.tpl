#cloud-config
#
# Cloud-init template for a FairCoin seeder host.
# Variables substituted at droplet creation time:
#   {{HOSTNAME}}    FQDN to assign to the droplet (vps1.fairco.in / vps2.fairco.in)
#   {{SEED_HOST}}   Hostname the DNS seed serves (seed1.fairco.in / seed2.fairco.in)
#   {{NS_HOST}}     Same as HOSTNAME (nameserver hostname reported in SOA)
#   {{MBOX}}        Admin e-mail for SOA records (admin.fairco.in)

hostname: {{HOSTNAME}}
fqdn: {{HOSTNAME}}
manage_etc_hosts: true

package_update: true
package_upgrade: false

packages:
  - ca-certificates
  - curl
  - git

runcmd:
  - |
    set -eux
    curl -fsSL https://raw.githubusercontent.com/FairCoinOfficial/faircoin-seeder/main/deploy/install.sh -o /root/install.sh
    chmod +x /root/install.sh
    SEED_HOST={{SEED_HOST}} NS_HOST={{NS_HOST}} MBOX={{MBOX}} /root/install.sh 2>&1 | tee /var/log/faircoin-seeder-install.log
