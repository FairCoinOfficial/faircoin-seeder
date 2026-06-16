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

## Docker Compose stack

`docker-compose.yml` runs the seeder alongside the FairCoin nodes it crawls:

| Service | Network | Image | RPC | Notes |
|---------|---------|-------|-----|-------|
| `faircoind` | mainnet | `faircoin-node:latest` (`v3.0.6`) | `40405` | Full node with `-addressindex=1 -txindex=1 -spentindex=1` |
| `faircoind-testnet` | testnet | `faircoin-testnet-node:v3.0.5-testnet5` | `40406` | Primary testnet node — mines, stakes, read by the Explorer |
| `faircoind-testnet-peer` | testnet | `faircoin-testnet-node:v3.0.5-testnet5` | `40407` (localhost) | Companion peer so PoS staking can activate |
| `dnsseed` | mainnet | `faircoin-seeder:latest` | — | The DNS seeder itself |

### Mainnet node (`faircoind`)

Runs **v3.0.6** with the address/spent/transaction indexes enabled
(`-addressindex=1 -txindex=1 -spentindex=1`, RPC on `40405`). These indexes back the
[Explorer](https://github.com/FairCoinOfficial/Explorer)'s address pages and the MCP
wallet tools, which need to resolve the balance and UTXOs of arbitrary addresses
(`getaddressbalance`, `getaddressutxos`).

> Enabling addressindex on a node that already has a chain requires a one-time
> `-reindex` to build the index over existing blocks (the daemon enforces this). It
> was run once when the mainnet node was upgraded to v3.0.6, then dropped.

### Testnet nodes

The testnet is a **completely separate chain** — its own genesis, network magic, ports,
and data volumes — built from a custom `v3.0.5-testnet*` binary (the testnet image is
tagged distinctly so it can never overwrite mainnet's `faircoin-node:latest`). Two nodes
run side by side:

- **`faircoind-testnet`** — the primary node (RPC `40406`). It mines the PoW phase and
  stakes, and is the RPC the Explorer reads via `FAIRCOIN_TESTNET_RPC_*`.
- **`faircoind-testnet-peer`** — a companion node (RPC `40407` on localhost, P2P `46378`).
  PoS staking requires at least one peer (the staker sleeps while it has no connections),
  so the two nodes peer with each other over localhost.

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
