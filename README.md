# FairCoin-seeder

DNS seeder for the FairCoin network. Based on [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder).

FairCoin wallets query `seed1.fairco.in` and `seed2.fairco.in` to discover
peers. This seeder runs as a DNS server on those hostnames, crawls the
FairCoin P2P network, and returns healthy node addresses to connecting wallets.

## Quick start (Docker)

```bash
# On a DigitalOcean droplet named vps1.fairco.in or vps2.fairco.in:
sudo bash deploy/install.sh
```

The install script auto-detects configuration from DigitalOcean metadata.
See [deploy/README.md](deploy/README.md) for full deployment docs.

## Build from source

```bash
sudo apt-get install build-essential libboost-all-dev libssl-dev
make
```

## Usage

```bash
./dnsseed -h seed1.fairco.in -n vps1.fairco.in -m admin.fairco.in
```

## Network parameters

| Parameter     | Mainnet           | Testnet              |
|---------------|-------------------|----------------------|
| P2P port      | 46372             | 46374                |
| Magic bytes   | `a3 d7 e1 b4`    | `b5 2e 9c f3`       |
| DNS seeds     | seed1.fairco.in   | testnet-seed1.fairco.in |
|               | seed2.fairco.in   | testnet-seed2.fairco.in |
| Protocol ver  | 71000             | 71000                |

Use `--testnet` to switch to testnet mode.

## How it works

1. The seeder resolves its configured DNS seed hostnames to find initial peers.
2. It connects to each peer using the FairCoin P2P protocol, performs a
   version handshake, and requests their known addresses (`getaddr`).
3. Discovered peers are tracked, tested periodically, and scored by uptime.
4. When a wallet queries `seed1.fairco.in` (via DNS), the seeder returns
   IP addresses of healthy, high-uptime nodes.
5. The wallet connects to those nodes and joins the FairCoin network.
