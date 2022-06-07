
## Tutorial for c-lightning

First, make sure you have done [the tutorial with LND](./1-LND.md). Here, we are going to do the same with c-lightning. with how to manage plugins.

### preliminiary

Make sure you to load `env.sh` before running anything for a docker.

And make sure you know how to reset the state, as we did in lnd.

```sh
docker-compose down -v
rm -rf ./data
git checkout -- data
docker-compose up -d bitcoind lnd_alice lnd_bob
```

Unlike lnd, c-lightning does not have a nice help message for each rpc.
Check [its official document](https://lightning.readthedocs.io/) when you need a help.

## c-lightning walkthrough

### setup

```sh
# Start c-lightning, and lnd for the counterparty.
docker-compose up clightning_alice lnd_bob

# see the basic info for c-lightning node
./docker-lightning-cli-alice.sh getinfo 

# You have no peers connected yet, so this must return empty array.
./docker-lightning-cli-alice.sh listpeers

# initialize the bob's wallet.
docker-compose exec lnd_bob bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 create

# connect

## "connection string" is a term used in LN to describe the endpoint for p2p connection.
## (ip endpoint, identity pubkey) pair.
bob_connection_string=$(./docker-lncli-bob.sh getinfo | jq ".uris[0]")
./docker-lightning-cli-alice.sh connect $bob_connection_string

## now we can see bob is connected.
./docker-lightning-cli-alice.sh listpeers

## "nodeid" is a term used in LN to describe identity pubkey
## for the node. it does not change in the node lifetime.
## it is used for ECDH for p2p messaging layer. Thus its
## private key is used for message encryption.
bob_id=$(./docker-lncli-bob.sh getinfo | jq -r ".identity_pubkey") 
## Make sure Alice can reach Bob.
./docker-lightning-cli-alice.sh ping $bob_id 
```

### Opening channel

```bash

# Our funds must be empty. Let's check by
./docker-lightning-cli-alice.sh listfunds 

# --- prepare on-chain funds ---
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1

# p2wpkh address
addr1=$(./docker-lightning-cli-alice.sh newaddr bech32 | jq -r ".bech32")

# p2sh-p2wsh address
addr2=$(./docker-lightning-cli-alice.sh newaddr p2sh-segwit | jq -r '."p2sh-segwit"')

./docker-bitcoin-cli.sh sendtoaddress $addr1 1
./docker-bitcoin-cli.sh sendtoaddress $addr2 1

# 2 conf must be enough
./docker-bitcoin-cli.sh generatetoaddress 2 bcrt1qwp4sf7dahg0f97ksa798jgewfzcdxxflw7y89u 

# check c-lightning recognizes its fund.
./docker-lightning-cli-alice.sh listfunds 

# We can also see it by summary plugin.
# check `num_utxos` and `utxo_amount`
./docker-lightning-cli-alice.sh summary
# --- ---

# --- open channel ---

# open **public** channel.
## in c-lightning, an amount is always denominated by either
## "msat" | "sat" | "btc"
fundchannel_resp=$(./docker-lightning-cli-alice.sh fundchannel $bob_id 500000sat)
echo $fundchannel_resp
# * tx ... funding tx
# * txid ... funding tx id
# * channel_id: funding tx id * outnum
# * outnum ... vout (tx output index for funding txo)
```

`channel_id` is used to refer to the channel before it gets confirmed (thus gets opened.) 
after it gets opened, we usually use `short_channel_id`, after it gets confirmed, this is a triplet separated by `x`, that is `<block_height>x<txindex>x<txo>`

* `block_height` ... height of the block funding tx got confirmed.
* `txindex` ... tx index inside the block. coinbase tx is 0.
* `txo` ... same with `outnum` in fundchannel response.

In LND, `short_channel_id` is handled in uint64 serialized form.
but in c-lightning, it is represented in more human-readable triplet.

```bash

# unlike lnd, `listpeers`  contains a channel information too.
# note that now we have a channel with `"state":"CHANNELD_AWAITING_LOCKIN"`
./docker-lightning-cli-alice.sh listpeers
```

Check `"status"` field, and we can tell that it requires 3 conf for channel to be opened.

```bash
 ./docker-bitcoin-cli.sh generatetoaddress 3  bcrt1qwp4sf7dahg0f97ksa798jgewfzcdxxflw7y89u

# now we have a channel with `CHANNELD_NORMAL`
 ./docker-lightning-cli-alice.sh listpeers
# you can also see `short_channel_id` field which we did not have before.

# there must be a short summary for the channel.
./docker-lightning-cli-alice.sh summary
```

### bolt11 payment

```bash
## --- outgoing payment ---
bob_invoice=$(./docker-lncli-bob.sh addinvoice --amt 275000 | jq -r ".payment_request")

# synchronously pay to bob.
./docker-lightning-cli-alice.sh pay $bob_invoice 

# check `"out_payments_fulfilled"` is now `1`.
./docker-lightning-cli-alice.sh listpeers

# Let's see the detail of the finished payment
./docker-lightning-cli-alice.sh listsendpays

# check now we have `avail_in` (inbound liquidity)
./docker-lightning-cli-alice.sh summary
## --- ---

## --- incoming payment ---

invoice_resp=$(./docker-lightning-cli-alice.sh invoice 200000sat "invoice_label_for_internal_use" "電気代")
./docker-lncli-bob.sh payinvoice $(echo $invoice_resp  | jq -r ".bolt11") 

# check the detail of past incoming payments.
./docker-lightning-cli-alice.sh listpays  
## --- ---
```

## Plugins

plugins are binaries which work along with c-lightning.
c-lightning starts binaries as a subprocess, and interact it with stdin/stdout.

> Note: The way it communicates through stdin/stdout makes c-lightning harder to conveniently be used in docker-compose, since
> those plugins must resize in the same docker image.
> Thus the following tutorial may be a bit awkword.

Plugins will augment the functionality of the c-lightning in a several ways, e.g.

* expose new RPC method
  * the request/response will pass-through to the plugin. Thus it works as if c-lightning's own RPC.
  *  the `summary` you used above is one example.
* expose new commandline options for c-lightning startup

There are several other methodologies that plugins can utilize for interacting with c-lightning,
but above two are enough for most user's perspective.

Following plugins are included in the docker image.
But only few of them are turned on by default.

* [default (official) plugins](https://github.com/ElementsProject/lightning/tree/master/plugins)
* [Community curated list of plugins](https://github.com/lightningd/plugins)

```sh
# Check bundled plugins we have in the image.
docker-compose exec clightning_alice ls /opt/lightningd/plugins 
```

We have turned on `helpme` by default.
This is because c-lightning will automatically scan `$LIGHTNING_DIR/plugins`
(where `$LIGHTNING_DIR` can be specified by `--lightning-dir` standup option.)

You can see that bundled plugins under `/opt/lightningd/plugins` are copied to `$LIGHTNING_DIR/plugins` in the docker's entrypoint script.

Let's see we have turned on `helpme` plugin.

```sh
cat Dockerfiles/lightning-entrypoint.sh | helpme
```

That means, we can call `helpme` rpc with c-lightning.

```sh
./docker-lightning-cli-alice.sh helpme
# You can try the tutorial offerd by `helpme` as you wish.
```

So if you want to turn other plugins on, then you should just add another line to
 `lightning-entrypoint.sh`,  and run `docker-compose build clightning_alice`
