# Submarine Swap against [Boltz server](https://github.com/BoltzExchange/boltz-backend)

Make sure you have done the [basic tutorial for lnd](./README.md) before working for this one.

In this tutorial we will go through creating submarine swap for Lightning-BTC/onchain-BTC

First, lets run every necessary contains and prepare lnd, we assume that bob is the one running the boltz server.

## Prepare

```sh
source env.sh
docker-compose up -d bitcoind lnd_alice lnd_bob

# Don't forget to `create` the lnd wallet before using for anything.
# You may have to `unlock` instead if you already done this and not have cleaned up the ``data/`
## alice
docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create

## bob
docker-compose exec lnd_bob bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 create

# Run in foreground to see there is no error on console.
docker-compose up boltz
```
And in different terminal...

```sh
# check REST api to make sure boltz working fine.
curl localhost:9001/version

# let's make sure the node is the one bob owns.
curl localhost:9001/getnodes
# and compare with the response of `./docker-lncli-bob.sh getinfo `
```

Make sure Alice and Bob are both funded and know each other on transport layer.
Please go back to previous tutorial if you forget how to do it.

## Create Submarine Swap

You must first read [the Swap Lifecycle](https://docs.boltz.exchange/en/latest/lifecycle/) section of the boltz API reference.

Let's say Alice wants to create channel against Bob and get inbound capacity with submarine swap.
In this case, what Alice want to do is to create "Reverse" submarine swap, in which she
1. Get invoice from Bob's boltz server.
2. Pay to that invoice
3. Atomically get on-chain bitcoin fund.

```
# Create channel from Alice to Bob
./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -IXX ./docker-lncli-alice.sh openchannel XX 500000
# confirm the channel
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

./docker-lncli-alice.sh addinvoice --memo 'For_Submarine_Swap_againt_bob' --amt 250000 

curl -XPOST -H "Content-Type: application/json" -d '{"id": ""}' localhost:9001/swapstatus 
```

