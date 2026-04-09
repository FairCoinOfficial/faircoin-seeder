# FairCoin-seeder

DNS seeder for the FairCoin network. Based on [sipa/bitcoin-seeder](https://github.com/sipa/bitcoin-seeder).

## Build

    sudo apt-get install build-essential libboost-all-dev libssl-dev
    make

## Usage

    ./dnsseed -h seed1.fairco.in -n vps1.fairco.in -m admin.fairco.in

Default FairCoin mainnet: P2P port 46372, magic bytes a3 d7 e1 b4.
Use --testnet for testnet (port 46374).
