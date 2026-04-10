#cloud-config
#
# Cloud-init template for a FairCoin seeder host.
#
# The install script auto-detects SEED_HOST and NS_HOST from the droplet
# hostname via DigitalOcean metadata. Just name the droplet correctly
# (vps1.fairco.in / vps2.fairco.in) and everything configures itself.
#
# Variables substituted at droplet creation time:
#   {{HOSTNAME}}    FQDN to assign to the droplet (vps1.fairco.in / vps2.fairco.in)

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
    /root/install.sh 2>&1 | tee /var/log/faircoin-seeder-install.log
