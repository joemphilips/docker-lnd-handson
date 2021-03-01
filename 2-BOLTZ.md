# Submarine Swap against [Boltz server](https://github.com/BoltzExchange/boltz-backend)

Make sure you have done the [basic tutorial for lnd](./1-LND.md) before working for this one.

In this tutorial we will go through creating submarine swap for Lightning-BTC/onchain-BTC

## Why Submarine Swap?

Submarine swap is just an atomic exchange of LN funds and on-chain funds,
it can be used for preventing channel from closing by maintaining the channel funds in a balanced state.
The main reason to do this is to maintain in/outbound liquidity (i.e. ability to both receive/send funds through hop.)

Another way to achieve this goal is to ask other node to open channel to your own node when your inbound liquidity run out.
This methodology seems to have almost the same running cost with the submarine-swap methodology,
but it has a following downside.

1. More complex state management of the channels complared to having just one channel.
2. You can not use an altcoin which has lower on-chain fee to reduce the cost (which is possible in case of submarine swap.)

## Why Boltz?

At the time of writing, The most common service for managing the channel balance by submarine swap is
[Lightning Loop](https://github.com/lightninglabs/loop).
The downside is that currently its liquidity maker (who takes small fee in contingent on the swap) side is proprietary and not open source.

In our case, we wanted to first act as a liquidity taker (i.e. user of the service),
but wanted to leave a choice to become a liquidity maker (i.e. run service by ourselves) later.
So the fact that we can not run everything by ourselves is a big downside.

Among following choices, we first decided to try Boltz, since its documents and codebase seemed better.

* [Submarine Swaps service](https://github.com/submarineswaps/swaps-service)
* [Boltz-backend](https://github.com/BoltzExchange/boltz-backend)

The purpose of this tutorial is to learn the basic concept and operation in CLI.
In reality you might want to consider writing your own program using
[boltz-core](https://github.com/BoltzExchange/boltz-core)

## Prepare

First, lets prepare lnd, we assume that bob is the one running the boltz server.

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

# then run boltz server
docker-compose up -d boltz
docker-compose logs -f boltz
```
And in different terminal...

```sh
# check REST api to make sure boltz working fine.
curl localhost:9001/version

# let's make sure the node is the one bob owns.
curl localhost:9001/getnodes | jq
# and compare with the response of `./docker-lncli-bob.sh getinfo `
```

Make sure Alice and Bob are both funded and know each other on transport layer.
Please go back to previous tutorial if you forgot how to do it.

### Outline

You must first read [the Swap Lifecycle](https://docs.boltz.exchange/en/latest/lifecycle/) section of the boltz API reference.

Let's say Alice wants to create channel against Bob and get inbound capacity with submarine swap.
In this case, what Alice want to do is to create "Reverse" submarine swap, in which she
1. Get invoice from Bob's boltz server.
2. Pay to that invoice
3. Atomically get on-chain bitcoin fund.

### Check fee and make a channel.

Next, Alice wants to make sure that Bob supports "BTC/BTC" pair swap. And the fee is not
excessive.

```sh
curl http://localhost:9001/getpairs | jq
```

She will see something like
```json
{
  "info": [],
  "warnings": [],
  "pairs": {
    "BTC/BTC": {
      "hash": "3069580d6467d7ca2371188ce21a5a84f849bd162de282bd508cb16b08eeca30",
      "rate": 1,
      "limits": {
        "maximal": 10000000,
        "minimal": 10000,
        "maximalZeroConf": {
          "baseAsset": 10000000,
          "quoteAsset": 10000000
        }
      },
      "fees": {
        "percentage": 1,
        "minerFees": {
          "baseAsset": {
            "normal": 3400,
            "reverse": {
              "claim": 2760,
              "lockup": 3060
            }
          },
          "quoteAsset": {
            "normal": 3400,
            "reverse": {
              "claim": 2760,
              "lockup": 3060
            }
          }
        }
      }
    }
  }
}
```

If the `"fees"` are in acceptable range, she will proceed with creating channel against the Bob.

```s
# connect in transport layer
curl localhost:9001/getnodes | jq ".nodes.BTC.uris[0]" | xargs -I XX ./docker-lncli-alice.sh connect XX

# Create channel from Alice to Bob (If you have enough funds, send from bitcoind. If you forget how to, go back to previous article)
curl localhost:9001/getnodes | jq ".nodes.BTC.nodeKey" | xargs -I XX ./docker-lncli-alice.sh openchannel --private XX 500000
# Or instead you can run `./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -IXX ./docker-lncli-alice.sh openchannel --private XX 500000`

# confirm the channel
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m


# check your channel is really open with `listchannel` command.
```

Note that since this is a private channel, when you issue an invoice you must always
add route hint by `--private` option to `addinvoice` command.


## Perform Reverse Submarine Swap

### Alice requests reverse-submarine swap.

Next, Alice will request the invoice to Bob, but for she needs to tell aditional info more than regular LN payment so that Bob can make on-chain payment to Alice contingent to her off-chain payment.

So she must prepare some hash/preimage pair, this can be done in many ways but here we
use `bx` cli tool from [libbitcoin-explorer](https://github.com/libbitcoin/libbitcoin-explorer)
It is a swice army knife for bitcoin-related tasks, so it is worth getting used to it.

```sh
# Preimage/Pubkey pair that Alice can use to claim on-chain funds.
preimage=$(bx seed -b 256)
preimage_hash=$(echo $preimage | bx sha256)
claim_privkey=$(bx seed | bx ec-new)
claim_pubkey=$(echo $claim_privkey | bx ec-to-public)

# Create swap.
createswap_resp=$(curl -XPOST -H "Content-Type: application/json" -d '{"type": "reversesubmarine", "pairId": "BTC/BTC", "orderSide": "buy", "invoiceAmount": 250000, "preimageHash": "'$preimage_hash'", "claimPublicKey": "'$claim_pubkey'" }' http://localhost:9001/createswap)

# check the return value.
echo $createswap_resp | jq
# Since alice does not trust Bob, she must check the `payment_hash` in the invoice is equal
# To the one she sent to Bob, thus Bob can not claim the payment unless Alice reveals
# her preimage
[[ $preimage_hash == $(echo $createswap_resp | jq .invoice | xargs ./docker-lncli-alice.sh decodepayreq | jq -r .payment_hash ) ]] && echo Ok || echo "Bob cheated"
# Also check the amount to make sure the fee is not too high.
expected_max_fee=20000
onchain_amount=$(echo $createswap_resp | jq -r .onchainAmount)
swap_service_fee=$(echo "250000 - $onchain_amount" | bc)
[[ swap_service_fee -lt $expected_max_fee ]] && echo Ok || echo "The fee for swap service is too high"

# Also make sure that the preimage+claim_privkey pair is enough to claim the funds from the redeemScript.
preimage_hash_hash=$(echo $preimage_hash | bx ripemd160)
redeem_hex=$(echo $createswap_resp | jq -r .redeemScript)
echo $redeem_hex | bx script-decode
# (In practice you must programatically check but lets just go on for now.)
# This must be something like ...
"size [20] if hash160 [$preimage_hash_hash] equalverify [$claim_pubkey] else drop [<refund block height>] cltv drop [<key to refund bob>] end if checksig"

# check the swap status. It must return `{"status":"swap.created"}`
echo $createswap_resp | jq ".id" | xargs -IXXX curl -XPOST -H "Content-Type: application/json" -d '{"id": "'XXX'"}' localhost:9001/swapstatus
```

If Alice is sure that Bob did not violate the protocol, she proceeds by offering a payment.

#### Alice performs swap.

```sh
# Alice pays to the invoice. This payment is not settled until alice receives on-chain payment and reveals her `preimage` to Bob.
# IMPORTANT: This will hang your terminal until it resolves, so you must run in another terminal
./docker-lncli-alice.sh payinvoice <invoice field in $createswap_resp>

# Coming back to the original terminal, let's check the swap status again.
# This time it must be `"status": "transaction.mempool"`
swapstatus_mempool=$(curl -XPOST -H "Content-Type: application/json" -d '{"id": "'$(echo $createswap_resp | jq -r .id)'"}' localhost:9001/swapstatus  | jq)
echo $swapstatus_mempool

# Also, lets check that HTLC is on flight.
./docker-lncli-alice.sh listchannels | jq ".channels[].pending_htlcs"

# Let's make sure that Bob has really broadcasted the tx, and the tx amount is the one expected.
# nit: we are querying to the blockchain just to make sure it has been broadcasted, but
# If you don't want to make a query you might just well decode the `hex` field in the response. You can do that with `bx tx-decode` or `bitcoin-cli decoderawtransaction` command.
swap_tx_hex=$(echo $swapstatus_mempool | jq -r .transaction.hex)
swap_tx_id=$(echo $swapstatus_mempool | jq -r .transaction.id) 
swap_tx=$(./docker-bitcoin-cli.sh getrawtransaction $swap_tx_id true)
lockup_address=$(echo $createswap_resp | jq .lockupAddress)
swap_txo=$(echo $swap_tx | jq '.vout[] | select(.scriptPubKey.addresses[0] == '$lockup_address')')

# And check if it has the expected `vout`.
actual_onchain_amount_sats=$(echo $swap_txo | jq ".value" | bx btc-to-satoshi)
[[ $onchain_amount == $actual_onchain_amount_sats ]] && echo Ok || echo "Bogus onchain amount"

# Unless Alice is ok to receive 0-conf TX, she must
# wait 1 or 2 confirmations for the tx at this point.
./docker-bitcoin-cli.sh generatetoaddress 2 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
echo $createswap_resp | jq ".id" | xargs -IXXX curl -XPOST -H "Content-Type: application/json" -d '{"id": "'XXX'"}' localhost:9001/swapstatus
# Make sure this returns "transaction.confirmed" status.

# Alice must claim the on-chain fund.
# Probably she want to do it programatically in real situation, but lets proceed as cli
# for the sake of consistency and understanding.
swap_vout=$(echo $swap_txo | jq .n)
alice_payout_address=$(./docker-lncli-alice.sh newaddress p2wkh | jq ."address")

feerate_sat_per_kbyte=$(./docker-bitcoin-cli.sh estimatesmartfee 5 | jq ".feerate" | bx btc-to-satoshi)
```

Unfortunately I could not find any convenient way to create HTLC spending TX from CLI,
So I created a small cli by myself, using low-level api of [NBitcoin](https://github.com/MetacoSA/NBitcoin)

[Here's the repository](https://github.com/joemphilips/HTLCSpendTxCreator) You can run by following command but please make sure to do two things before running.
1. I haven't done anoything malicious in the codebase.
2. You have installed [dotnet sdk 5](https://dotnet.microsoft.com/download/dotnet/5.0)

```
git clone https://github.com/joemphilips/HTLCSpendTxCreator
cd HTLCSpendTxCreator

alice_claim_tx=$(dotnet run -- --redeem $redeem_hex --txid $swap_tx_id --fee $feerate_sat_per_kbyte --amount $actual_onchain_amount_sats --outindex $swap_vout --privkey $claim_privkey --preimage $preimage --address $alice_payout_address --network regtest)
cd ..
```

Then, broadcast and claim.

```
alice_claim_tx_id=$(./docker-bitcoin-cli.sh sendrawtransaction $alice_claim_tx)
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

This should resolve the hanging off-chain payment. Let's check swap status again.

```sh
curl -XPOST -H "Content-Type: application/json" -d '{"id": "'$(echo $createswap_resp | jq -r .id)'"}' localhost:9001/swapstatus  | jq
```
This should show

```json
{
  "status": "invoice.settled"
}
```

Also, let's check the alice has less off-chain balance and more on-chain balance
just to make sure.
```sh
./docker-lncli-alice.sh listunspent # see there is one more UTXO she holds. the diff for this amount and 250000 is what she has lost in this swap (miner fee and swap service fee).
./docker-lncli-alice.sh listchannels # see remote_balance has increased 250000
```

## Perform Normal Submarine Swap

Next, Alice will perchase outbound liquidity.
This is less likely since she can just open another channel to get outbound liquidity.
Avoiding close/reopen might have an advantage in terms of operation simplicity,
and for assuring that there is always one channel that she has to take care of.

Let's say alice sent some outbound payment to perchase something, and she wants to regain her outbound liquidity to avoid closing channel.

### Alice consumes her outbound liquidity

In reality she will pay to some other service, but let's just pay to Bob to keep it simple.

```sh
payreq=$(./docker-lncli-bob.sh addinvoice --memo "家賃" --amt 200000 | jq ".payment_request")
./docker-lncli-alice.sh payinvoice $payreq
```


### Alice requests submarine swap

```sh
# This is a key to get her onchain balanace when the counterparty becomes unresponsive.
# We won't use it here but in reality she must keep it and use before refund timeout.
refund_privkey=$(bx seed | bx ec-new)
refund_pubkey=$(echo $refund_privkey | bx ec-to-public)

# This time, alice must create her invoice.

alice_addinvoice_resp=$(./docker-lncli-alice.sh addholdinvoice --memo "For_submarine_swap" --amt 250000)

# Create swap.
createswap_resp=$(curl -XPOST -H "Content-Type: application/json" -d '{"type": "submarine", "pairId": "BTC/BTC", "orderSide": "buy", "invoice": '$(echo $alice_addinvoice_resp | jq .payment_request)', "refundPublicKey": "'$refund_pubkey'" }' http://localhost:9001/createswap)

echo $createswap_resp

# Now the swapstatus must be `invoice.set`
curl -XPOST -H "Content-Type: application/json" -d '{"id": "'$(echo $createswap_resp | jq -r .id)'"}' localhost:9001/swapstatus  | jq
```

Notice the difference with the reverse swap.

###### difference in Request
* `type` field is now `submarine` instead of `reversesubmarine`
* Following fields are lost.
  * `preiamgeHash`
  * `claimPublicKey`
  * `invoiceAmount`
* Following fields are added.
  * `invoice` ... so that bob can offer alice a off-chain payment
  * `refundPublicKey` ... so that Alice can get her fund back when Bob is unresponsive.

###### difference in Response

### Alice validates the response

```sh
# Check if address and redeem script matches.
redeem_hex=$(echo $createswap_resp | jq -r .redeemScript)
[[ $(./docker-bitcoin-cli.sh validateaddress $(echo $createswap_resp | jq -r .address) | jq -r .witness_program) == $(echo $redeem_hex | bx sha256) ]] && echo ok || echo "Bob_cheated"

preimage_hash=$(echo $alice_addinvoice_resp | jq -r .r_hash)
preimage_hash_hash=$(echo $preimage_hash | bx ripemd160)
echo $redeem_hex | bx script-decode
# It must be something like this.
hash160 [$preimage_hash_hash] equal if [<some pubkey that only bob knows the secret>] else [b300] checklocktimeverify drop [$refund_pubkey] endif checksig

## Then she must make sure that Bob has created off-chain payment offer with the `$preimage_hash`
## There are many ways to do this but this time lets use `lookupinvoice` command
./docker-lncli-alice.sh lookupinvoice $preimage_hash # Notice "state" is not "SETTLED" (i.e. payment finished), nor "OPEN" (i.e. payment has not started).
```

### Alice performs swap

```sh
htlc_id=$($(./docker-lncli-alice.sh sendcoins --addr $(echo $createswap_resp | jq -r .address) --amt $(echo $createswap_resp | jq .expectedAmount) --label 'HTLC for Submarine Swap') | jq .txid)

# Alice must prepare a TX to refund her from HTLC when it times out (unhappy path), but we omit for simplicity.

# Just in case that boltz server does not accept 0-conf HTLC, confirm the HTLC tx.
./docker-bitcoin-cli.sh generatetoaddress 1 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

The boltz server logs something like this.
```
boltz        | 28/02/2021 13:19:27:091 verbose: Found unconfirmed lockup transaction for Swap cExNMK: 160876e021760c4802238f13a02b588c2b18fe80a50fd01563810d0d286d8b6a
boltz        | 28/02/2021 13:19:27:146 debug: Accepted 0-conf lockup transaction for Swap cExNMK: 160876e021760c4802238f13a02b588c2b18fe80a50fd01563810d0d286d8b6a
boltz        | 28/02/2021 13:19:27:148 debug: Swap cExNMK update: {
boltz        |   "status": "transaction.mempool"
boltz        | }
boltz        | 28/02/2021 13:19:27:168 verbose: Paying invoice of Swap cExNMK
boltz        | 28/02/2021 13:19:27:197 debug: Swap cExNMK update: {
boltz        |   "status": "invoice.pending"
boltz        | }
boltz        | 28/02/2021 13:19:27:439 debug: Paid invoice of Swap cExNMK: 0a29dda440a4dd08dd90ab273c744b048c7d501c3a1c681d08baffb560563f20
boltz        | 28/02/2021 13:19:27:469 debug: Swap cExNMK update: {
boltz        |   "status": "invoice.paid"
boltz        | }
boltz        | 28/02/2021 13:19:27:499 info: Claimed BTC of Swap cExNMK in: b09631c9ec14f6940bb8ac6a628c7f3e797de5609cc5da781e4a97e6c1de123d
boltz        | 28/02/2021 13:19:27:528 verbose: Swap cExNMK succeeded
boltz        | 28/02/2021 13:19:27:528 debug: Swap cExNMK update: {
boltz        |   "status": "transaction.claimed"
boltz        | }
```

As you can see from the log, the status must be `"transaction.claimed"`.
Let's double check by querying the swapstatus again
```sh
curl -XPOST -H "Content-Type: application/json" -d '{"id": "'$(echo $createswap_resp | jq -r .id)'"}' localhost:9001/swapstatus  | jq
```

This means that Bob has claimed his on-chain funds and 
