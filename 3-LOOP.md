
# Lightning Loop, Multi-hop and automatic liquidity management.

First, lets start a new node named carol.

    Alice ---------------> Bob -----------> Carol
(Boltz client)       (Boltz server)      (Loop server)
(Loop client)


## Preperation

### Basic preperation

```bash
 # Start 7 services
 # 1. bitcoind
 # 2. lnd_alice
 # 3. lnd_bob
 # 4. lnd_carol
 # 5. Boltz server for Bob (unneccessary really)
 # 6. loop server for Carol
 # 7. loop client for Alice
docker-compose up

# Create (or unlock) three lnd_servers
docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create

docker-compose exec lnd_bob bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 create

docker-compose exec lnd_carol bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32779 create

# Sometimes loopd does not recognize lnd until a new block comes.
./docker-bitcoin-cli.sh generatetoaddress 1 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

Now let's check that the loop service is working correctly by querying the
detail of the service to the server.

```bash
./docker-loopd.sh terms
```

This should output something like

```
Loop Out
--------
Amount: 250000 - 5000000
Cltv delta: 50 - 250

Loop In
------
Amount: 250000 - 5000000
```

### LN graph setup


```sh
# setup some blocks and funds.
./cliutils/prepare_tx_for_fee.sh
./cliutils/prepare_funds.sh

# connect lnds to each other
./docker-lncli-alice.sh getinfo | jq ".uris[0]" | xargs -IXX ./docker-lncli-bob.sh connect XX
./docker-lncli-alice.sh getinfo | jq ".uris[0]" | xargs -IXX ./docker-lncli-carol.sh connect XX
./docker-lncli-bob.sh getinfo | jq ".uris[0]" | xargs -IXX ./docker-lncli-carol.sh connect XX
```

We want to simulate the realistic situation here.
So first, we assume Bob is Lightning service provider (LSP) that alice uses.
Alice wants to connect Bob privately, because she knows she is liquidity consumer, thus there is no point for making the channel public to promote routing.

Bob, on the otherhand, wants to promote others to use his channel for routing, for the sake of 
earning routing fee.

So the channel from Alice -> Bob must be private, and Bob -> Carol must be public.

```bash
./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -I XX ./docker-lncli-alice.sh openchannel --private XX 500000

./docker-lncli-carol.sh getinfo | jq ".identity_pubkey" | xargs -I XX ./docker-lncli-bob.sh openchannel XX 500000
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

# Now don't forget to check by `listchannels` 


# manual rebalance
carol_invoice=$(./docker-lncli-carol.sh addinvoice --amt=250000 | jq -r ".payment_request")
./docker-lncli-alice.sh payinvoice $carol_invoice
```

## Autoloop

