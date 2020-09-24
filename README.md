
## How to run tutorial

```sh
source env.sh
docker-compose up

## Make sure everything is working fine.
./docker-bitcoin-cli.sh getblockchaininfo
./docker-lncli-alice.sh getinfo
./docker-lncli-bob.sh getinfo

# check it does not have known peers
./docker-lncli-alice.sh listpeers

## connect from alice to bob
./docker-lncli-alice.sh getinfo | jq ".uris[0]" | xargs -IXX ./docker-lncli-bob.sh connect XX  

# check now we have one
./docker-lncli-alice.sh listpeers
./docker-lncli-bob.sh listpeers

## To open the channel, we need to estimate fee, so first fill txs into mempool and several blocks
./cliutils/prepare_tx_for_fee.sh

# Next we are going to prepare wallet.
# We don't use `--noseedbackup` option because we want to take a backup in aezeed mnemonic.
# So we must first run `create` command
# `./docker-lncli-alice.sh create` ... this does not work because it requires interactive setup.
# So
docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create
# This will show wallet cipher seed so take backup.

# DO the same with bob
docker-compose exec lnd_bob bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 create

# check we don't have any utxos to use
./docker-lncli-alice.sh listunspent

# send on-chain funds to both sides.
./docker-lncli-alice.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

# check that we now have one.
./docker-lncli-alice.sh listunspent
./docker-lncli-bob.sh listunspent

# check we don't have any known channels
./docker-lncli-alice.sh listchannels
./docker-lncli-alice.sh pendingchannels

# open chanenl with 500000 satoshis from bob to alice
./docker-lncli-alice.sh getinfo | jq ".identity_pubkey" | xargs -IXX ./docker-lncli-bob.sh openchannel XX 500000

# check we now have pending channel (but no confirmed channel)
./docker-lncli-alice.sh pendingchannels # should not be empty
./docker-lncli-bob.sh pendingchannels # should not be empty
./docker-lncli-alice.sh listchannels # should be empty
./docker-lncli-bob.sh listchannels # should be empty

# confirm
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

./docker-lncli-alice.sh pendingchannels # should be empty
./docker-lncli-bob.sh pendingchannels # should be empty
./docker-lncli-alice.sh listchannels # should not be empty
./docker-lncli-bob.sh listchannels # should not be empty

# now lets stop nodes
docker-compose down
# This does not work, we must unlock the wallet
./docker-lncli-alice.sh getinfo

docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create
```