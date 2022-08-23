# Tutorial for c-lightning, dual-funding and an offer

First, make sure you have done [the tutorial with LND](./1-LND.md). Here, we are going to do the same with c-lightning.
with some additional functionalities of c-lightning such as

* plugin mangement
* dual funding channel
* offer (some times referred as "static invoice")

## preliminiary

Make sure to load `env.sh` before running anything for a docker.

And make sure you know how to reset the state, as we did in lnd.

```sh
docker-compose down -v
rm -rf ./data
git checkout -- data
```

## c-lightning walkthrough

### setup

```sh
# Start c-lightning, and lnd for the counterparty.
# clighting_bob will be used later, when we need counterparty to support
# c-lightning specific features.
docker-compose up clightning_alice lnd_bob clightning_bob

# list of available rpcs.
./docker-lightning-cli-alice.sh help

# calling help for each rpc can be done in a bitcoind-style `help` rpc.
./docker-lightning-cli-alice.sh help getinfo 

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

# Our funds must be empty. Let's check it by
./docker-lightning-cli-alice.sh listfunds 

# --- prepare on-chain funds ---
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1

# p2wpkh address
addr1=$(./docker-lightning-cli-alice.sh newaddr bech32 | jq -r ".bech32")

# p2sh-p2wsh address
addr2=$(./docker-lightning-cli-alice.sh newaddr p2sh-segwit | jq -r '."p2sh-segwit"')

./docker-bitcoin-cli.sh sendtoaddress $addr1 1
./docker-bitcoin-cli.sh sendtoaddress $addr2 1

# 3 conf must be enough
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qwp4sf7dahg0f97ksa798jgewfzcdxxflw7y89u 

# check c-lightning recognizes its fund.
./docker-lightning-cli-alice.sh listfunds 

# We can also see it by summary plugin.
# check `num_utxos` and `utxo_amount`
./docker-lightning-cli-alice.sh summary
```

##### open **private** channel.

in c-lightning rpc,
an amount is always denominated by either

* `"msat"`
* `"sat"`
* `"btc"`

Sometimes it also takes `"any"` or `"all"`, e.g. when you don't want to specify an amount for invoice you can use `"any"`

and feerate is one of

* estimated by internal estimator
  * `slow`
  * `normal`
  * `urgent`
* Manually specified
  * `<int>perkb`
  * `<int>perkw`

```bash

# create **private** channel.
# note: most RPC can use named arguments by `-k` option, that means this RPC call is same as
# `fundchanel_resp=$(./docker-lightning-cli-alice.sh fundchannel $bob_id 500000sat 20perkw false)`
fundchannel_resp=$(./docker-lightning-cli-alice.sh fundchannel -k id=$bob_id amount=500000sat feerate=20perkw announce=false)

echo $fundchannel_resp
# * tx ... funding tx
# * txid ... funding tx id
# * channel_id: funding tx id * outnum
# * outnum ... vout (tx output index for funding txo)
```

`channel_id` is used to refer to the channel before it gets confirmed (thus gets opened.) . in LND, sometimes it is called `channel_point`
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

# on contrary, `listnodes` does not include any info yet.
# this is because this RPC shows a node information associated to 
# `node_annoucement` P2P message (see: https://github.com/lightning/bolts/blob/master/07-routing-gossip.md#the-node_announcement-message)
# And we do not accept the message from a node which is not associated with already-known channel (to prevent DoS).
./docker-lightning-cli-alice.sh listnodes
```

Check `"status"` field, and we can tell that it requires 3 conf for channel to be opened.

```bash
 ./docker-bitcoin-cli.sh generatetoaddress 3  bcrt1qwp4sf7dahg0f97ksa798jgewfzcdxxflw7y89u

# now we have a channel with `CHANNELD_NORMAL`
 ./docker-lightning-cli-alice.sh listpeers
 ./docker-lightning-cli-alice.sh listchannels
# you can also see `short_channel_id` field which we did not have before.

# there must be a short summary for the channel.
./docker-lightning-cli-alice.sh summary

# Also, `listfunds` rpc contains not only our on-chain funds but also off-chain funds.
# So there must be a new entry in `channels` array
./docker-lightning-cli-alice.sh listfunds 

# get total on-chain balance
./docker-lightning-cli-alice.sh listfunds | jq "[.outputs[] | .value] | add"
# get total off-chain balance
/docker-lightning-cli-alice.sh listfunds | jq "[.channels[] | .channel_sat] | add"
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

# check the alice's invoice
./docker-lightning-cli-alice.sh listinvoices

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
  * Experimental features described below are all provided as a default plugin.
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

In other environment you may be able to just use `--plugin` , `--plugin-dir` startup options
to specify plugins other than those exists in a directory besides `$LIGHTNING_DIR/plugins`

You can also manage plugin by `plugin` rpc.
Let's see the list of plugins we are using right now.

```bash
./docker-lightning-cli-alice.sh plugin list 
```

Good enough for now! let's once close the channel for the next section.

```bash
./docker-lightning-cli-alice.sh close <short_channel_id>

# after confirmation, the channel now must have `CLOSINGD_COMPLETE` state.

# Note: sometimes we must do the following to make the state clear.
# probably because

# generate 100 blocks and re-connect.
./docker-bitcoin-cli.sh generatetoaddress 100 bcrt1qwp4sf7dahg0f97ksa798jgewfzcdxxflw7y89u
./docker-lightning-cli-bob.sh getinfo  | jq '. | "\(.id)@\(.address[0].address):\(.address[0].port)"' | xargs -IXX ./docker-lightning-cli-alice.sh connect XX
```

## experimental features

> Note: these feature are still experimental in `v0.11.1`. it may change in the future. But the basic concept must be the same.

### Dual funding

Dual funding is an experimental feature provided `funder` plugin.
LND does not support yet. So from now on we continue to work against `clightning_bob` node.

We already specified `--experimental-dual-fund` option in c-lightning startup, so let's play with dual-funding-related rpc methods.

Let's say alice is a merchant, and sell some physical goods (e.g. foods, real estate lease, etc.)

Her primary motivation for using LN is to receive the payment, not sending.
So when she opens a channel, she want inbound liquidity at the same time.
So she asks bob to deposit his fund when opening a channel.
She is willing to pay a fee if necessary.

```bash
# connect to bob's c-lightning node.
./docker-lightning-cli-bob.sh getinfo  | jq '. | "\(.id)@\(.address[0].address):\(.address[0].port)"' | xargs -IXX ./docker-lightning-cli-alice.sh connect XX

# check bob's funder parameter
./docker-lightning-cli-bob.sh funderupdate 

# set bob's funder parameter
# Default setting is quite conservative that bob will never contribute his funds.
./docker-lightning-cli-bob.sh funderupdate -k \
  policy=match \
  policy_mod=100 \
  channel_fee_max_base_msat=100sat \
  channel_fee_max_proportional_thousandths=2
```

Usually, from Alice's point of view, the only way to find
the Bob's funder policy (i.e. how much and at what fee he is willing to fund his money into the channel when he is not the one started opening it.)
is through `listnodes` RPC. But this does not work well yet in regtest mode.
So let's just cheat by looking into bob's `funderupdate` rpc for now.

Let's say Alice wants to get 400000 sats inbound liquidity, so she requests Bob to make a dual funded channel.
If both parties supports the dual-funding channel by version2 channel establishment protocol,
c-lightning will automatically use it when you specify `request_amt`

```bash
 ./docker-lightning-cli-alice.sh fundchannel -k id=$bob_id amount=500000sat feerate=20perkw announce=false request_amt=400000sat
```

This will fail with following error message.

```json
{
   "code": -32602,
   "message": "Must pass in 'compact_lease' if requesting funds from peer"
}
```

This is because alice did not make clear her willlingness to pay fee.

Probably in the future there will be a parameter for `fundchannel` that takes care of
Alice's intention to pay fee, but right now the options are not ready,
so let's make it simple by just getting `compact_lease` from bob outside of the protocol.
This means alice will take the fee condition specified by bob as granted.

```bash
compact_lease=$(./docker-lightning-cli-bob.sh funderupdate | jq -r ".compact_lease")

./docker-lightning-cli-alice.sh fundchannel -k \
  id=$bob_id \
  amount=500000sat \
  feerate=20perkw \
  announce=false \
  request_amt=400000sat \
  compact_lease=$compact_lease
```

If it succeeded, check that `"state": "DUALOPEND_AWAITING_LOCKIN"` is set for the
channel status returned by `listpeers`.
It must have a `funding` field something like

```json
"funding": {
    "local_msat": "500000000msat",
    "remote_msat": "404768000msat"
}
```

Looks good!

### static invoice

#### a-1. user-pay-merchant flow (non recursive payment)

Let's say alice wants to sell her t-shirt on her website, or on physical store.

If she use a legacy bolt11 style invoice, she have to create independent invoices for each user,
this has several problems in practice e.g. it is not retry safe from payer's point of view, 
or it can not be printed as a qrcode and tag it to actual item in the physical store.
(because bolt11 invoice can not be paied twice.)

offer (a.k.a. static invoice) will address these problems.

Alice will first create a bolt12 offer, which is a precursor of an invoice.
She wish to sell same t-shirts at batch, up to 50 at once.

```bash
offer_resp=$(./docker-lightning-cli-alice.sh offer -k \
  amount=5000sats \
  description="t-shirt_design_A" \
  vendor=Alice \
  label="t-shirt_design_A_on_website_0001" \
  quantity_min=1 \
  quantity_max=50
)

# List of created offers are stored in c-lightning's db. You can check it by
./docker-lightning-cli-alice.sh listoffers
```

Let's say alice has sent `bolt12` field of `offer_resp` to Bob in her website.
(In reality she can pass to bob in any way, including through physical tag or email.)

Bob can use `decode` RPC to see the detail of the offer.

```bash
offer_from_alice=$(echo $offer_resp | jq -r ".bolt12")
./docker-lightning-cli-bob.sh decode $offer_from_alice 
```

Next step for the bob is to fetch actual one-time invoice from alice, and pay against it.
Let's say he wants to buy two t-shirts.

```bash
fetchinvoice_resp=$(./docker-lightning-cli-bob.sh fetchinvoice -k \
  offer=$offer_from_alice \
  quantity=2
  )

echo $fetchinvoice_resp
invoice_for_offer=$(echo $fetchinvoice_resp | jq ".invoice")
```

note that offer has an prefix `lno`, and invoice has `lni`.

Now bob can pay against returned `invoice` field in the same way as we did for `bolt11`.

In a more user-friendly wallet in a future, fetching and payment must be done
in a more fluent way.

```bash
# payment
./docker-lightning-cli-bob.sh pay -k \
  bolt11=$invoice_for_offer \
  label="payment_to_alice_for_t-shirt"

# bolt12 invoices can also be check by `listinvoices`
./docker-lightning-cli-alice.sh listinvoices
```

#### a-2. user-pay-merchant flow (recursive payment)

Let's say alice wants to ask bob to pay his electricity charge recurrently, per months for a year.

Alice will start accepting the payment 2 weeks before the due date.
And she will have a buffer for 1 week after due date,
in case bob will notice that he didn't pay the charge
after his electricity stops.

```bash
recurrence_before_sec=$(python3 -c "print(60 * 60 * 24 * 14)") # 2 week
recurrence_after_sec=$(python3 -c "print(60 * 60 * 24 * 7)") # 1 week
recurse_offer_resp=$(./docker-lightning-cli-alice.sh offer -k \
  amount=10000sats \
  description="電気代" \
  vendor=Alice \
  label="Offer_to_bob_for_electricity_charge_per_month__start_from_1st_January_2021" \
  recurrence=1month \
  recurrence_limit=12 \
  recurrence_paywindow="-$recurrence_before_sec+$recurrence_after_sec"
)

echo $recurse_offer_resp
```

> Note: you can also use other denominations such as "USD" for an `amount`,
but for that we need to build a plugin to perform a currency conversion.

> Note: offer contains a non-signed variant as a `bolt12_unsigned` field.
> in a case that a size of an offer matters (e.g. to make more redable QR code),
> you can use this instead, there should be no security degradation for using it.

Bob can fetch his invoice by `fetchinvoice` as we did in the above t-shirt case,
but this time he has to specify `recurrence_counter` to tell his intention
about that the payment is a first recurrence of payments.
This is necessary to make it retry-safe.

```bash
offer_from_alice=$(echo $recurse_offer_resp | jq -r ".bolt12")
# fetching
fetchinvoice_resp=$(./docker-lightning-cli-bob.sh fetchinvoice -k \
  offer=$offer_from_alice \
  recurrence_counter=0 \
  recurrence_label="first_payment_for_electricity_charge_january_2021")

echo $fetchinvoice_resp
invoice_for_offer=$(echo $fetchinvoice_resp | jq ".invoice")

# payment
./docker-lightning-cli-bob.sh pay -k \
  bolt11=$invoice_for_offer \
  label="payment_to_alice_electricity_charge_january_2021_1"

# bolt12 invoices can also be check by `listinvoices`
./docker-lightning-cli-alice.sh listinvoices
```

#### b. merchant-pays-user flow

Say bob did not like a t-shirt that he purchased,
alice supports cooling off in her terms and conditions.
So bob sends back the t-shirt, after alice confirmed that t-shirt is fine,
she will refund the amount that he received from bob.

In a case like this, we can use another variant of an offer, called "send_invoice offer".
In fact, this is where bolt12 really shines even if it is one-time use.

In legacy bolt11 flow, bob must create refund invoice, and alice has to check that the invoice
does comply the terms and conditions for refunding.
That means, alice has to be there when bob created actual invoice, and there must be a way
for alice to get it out of the protocol, and she has to build a system to check
that the invoice is not malicious.
This makes the communication process rather synchronous and awkward.

in bolt12 flow, you can pass both offer and invoice through p2p transport layer.
So no need for another communication layer.
Alice can start the process by creating offer, and when the invoice from bob comes,
her lightning node can check automatically that the invoice comply the terms that she
specified in her offer.
As a result, she doesn't have to be there when bob asks a refund.

```bash
# somehow get an invoice for past payment to refund.
invoice_to_refund=$(./docker-lightning-cli-alice.sh listinvoices | jq -r '.invoices[] | select((.description | contains("t-shirt")) and .payment_preimage != null) | .bolt12')

offerout_resp=$(./docker-lightning-cli-alice.sh offerout -k \
 vendor=Alice \
 label="refund_for_a_t-shirt_No.10042" \
 refund_for=$invoice_to_refund \
 amount=10000sats \
 description="refunding_for_t-shirt")

 echo $offerout_resp
```

The return value for `offerout` is mostly the same with that of `offer`,
but it is one-time use.

```bash
offerout_from_alice=$(echo $offerout_resp | jq ".bolt12_unsigned")

 ./docker-lightning-cli-bob.sh sendinvoice -k \
    offer=$offerout_from_alice \
    label="invoice_for_asking_refund_for_t-shirt_to_alice"
```

The returned value must have a `"status": "paid"`.
That means, invoice has been sent to alice, and alice's node verified it automatically,
and her payment to bob has been completed.
