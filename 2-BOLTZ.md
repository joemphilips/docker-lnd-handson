# Submarine Swap against [Boltz server](https://github.com/BoltzExchange/boltz-backend)

Make sure you have done the [basic tutorial for lnd](./1-LND.md) before working for this one.

In this tutorial we will go through creating submarine swap for Lightning-BTC/onchain-BTC

First, lets run every necessary contains and prepare lnd, we assume that bob is the one running the boltz server.

## Why Boltz?

At the time of writing, The most common service for managing the channel balance is using [Lightning Loop](https://github.com/lightninglabs/loop).
The downside is that currently its server side is not open source.

In our case, we wanted to first act as liquidity taker (i.e. user of the service),
but wanted to leave a choice to become a liquidity maker (i.e. run service by ourselves) later,
so the fact that we can not get serverside run by ourselves is a big downside.

Among following choices, we first decided to try Boltz, since its documents and codebase seemed better.

* [Submarine Swaps service](https://github.com/submarineswaps/swaps-service)
* [Boltz-backend](https://github.com/BoltzExchange/boltz-backend)

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
Please go back to previous tutorial if you forget how to do it.

## Create Submarine Swap

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

### Perform Submarine Swap

#### Alice requests reverse-submarine swap.

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
echo $createswap_resp
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
swap_tx_hex=$(echo $swapstatus_mempool | jq .transaction.hex)
swap_tx_id=$(echo $swapstatus_mempool | jq .transaction.id) 
swap_tx=$(echo $swap_tx_id | xargs -IXX ./docker-bitcoin-cli.sh getrawtransaction XX true)
lockup_address=$(echo $createswap_resp | jq .lockupAddress)
swap_txo=$(echo $swap_tx | jq '.vout[] | select(.scriptPubKey.addresses[0] == '$lockup_address')')

# And check if it has the expected `vout`.
actual_onchain_amount_sats=$(echo $swap_txo | jq ".value" | bx btc-to-satoshi)
[[ $onchain_amount == $actual_onchain_amount_sats ]] && echo Ok || echo "Bogus onchain amount"

# Alice should wait 1 or 2 confirmations for the tx at this point...

# Alice must claim the on-chain fund.
# Probably she want to do it programatically in real situation, but lets proceed as cli
# for the sake of consistency and understanding.
swap_vout=$(echo $swap_txo | jq .n)
alice_payout_address=$(./docker-lncli-alice.sh newaddress p2wkh | jq ."address")

feerate_sat_per_kbyte=$(./docker-bitcoin-cli.sh estimatesmartfee 5 | jq ".feerate" | bx btc-to-satoshi)
```

Unfortunately I could not find any convenient way to create HTLC spending TX from CLI,
So I created a small cli by myself, using low-level api of [NBitcoin](https://github.com/MetacoSA/NBitcoin)

[Here's the repository](https://github.com/joemphilips/HTLCSpendTxCreator) You can run by following command but please make sure do two things before running.
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
./docker-bitcoin-cli.sh generatetoaddress 6
```

> ... Here we are stucked since Bob must claim his on-chain funds, but he does not do anything.
> TODO: write rest of the article when [the issue is solved](https://github.com/BoltzExchange/boltz-backend/issues/241)
