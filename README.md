
## How to run tutorial

Notice that You can always reset the state and start all over by resetting the `./data` folder. i.e.

```sh
docker-compose down
rm -rf ./data
git checkout -- data
docker-compose up bitcoind lnd_alice lnd_bob
```

### Basic setup


```sh
source env.sh # don't forget to do this for every terminal you use.
docker-compose up bitcoind lnd_alice lnd_bob

# make sure it returns some kind of macaroon error (because we haven't create wallet, some rpcs don't work)
./docker-lncli-alice.sh getinfo
# First we are going to prepare wallet.
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
```

### Channel open/close

```sh
## To open the channel, we need to estimate the fee, so first fill txs into mempool and several blocks
./cliutils/prepare_tx_for_fee.sh # this should finish in less than one minute.

# Check we have balance
./docker-lncli-alice.sh walletbalance
# check we don't have any utxos to use
./docker-lncli-alice.sh listunspent

# send on-chain funds to both sides.
./docker-lncli-alice.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m # Just for confirmation.

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

./docker-lncli-alice.sh closechannel --funding_txid "<funding_id in listchannels>" --output_index="<output_index in listchannels>"
```

### Payment

First you must open channel according to the above tutorial.

```sh
# Alice Creates payment request for 1000 millisatothis
invoice_alice=`./docker-lncli-alice.sh addinvoice --memo "電気代" --amt 1000 | jq -r ".payment_request"`

# Bob Check the content of the payment request
./docker-lncli-bob.sh decodepayreq $invoice_alice

# Pay from bob to alice
./docker-lncli-bob.sh payinvoice $invoice_alice
```

### Recovery

```sh
# now lets stop nodes
docker-compose restart lnd_alice

# This does not work, we must unlock the wallet
./docker-lncli-alice.sh getinfo

docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 unlock

# lets assume alice lost the wallet file (or she want to run in differnt machine or whatever)
mv data/.lnd_alice/chain/bitcoin/regtest/wallet.db ./trash
mv data/.lnd_alice/chain/bitcoin/regtest/channel.backup ./channel.backup

docker-compose restart lnd_alice
./docker-lncli-alice.sh getinfo # This does not work
docker-compose exec lnd_alice bash
# unlock does not work because she lost the wallet
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 unlock
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create
# recover from the cipher seed backup and its password

# check the balance has been resumed
./docker-lncli-alice.sh walletbalance

# To backup the channel data, it requires latest state of channel.backup file.
# There are [three ways to get this backup.](https://github.com/lightningnetwork/lnd/blob/master/docs/recovery.md#obtaining-scbs)
./docker-lncli-alice.sh restorechanbackup ./channel_backup

# Check that backed up channels are in the closing procedure
./docker-lncli-alice.sh pendingchannels
```

[Next Step: Monitor Lightinng in GUI with Ride the lightning](../RTL.md)