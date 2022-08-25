# swap with [peerswap](https://github.com/ElementsProject/peerswap)

> This document is written under [this version of peerswap](https://github.com/ElementsProject/peerswap/tree/e6316e892211bd1b37fd9611da234d8cfdd24d15)

PeerSwap is a submarine-swap client/server. It has following differnce compared to other softwares we have been seen such as boltz/loop.

* Supports multi-asset swap (primarily with [elements](https://github.com/ElementsProject/elements))
* It does not have a client-server model. Both sides uses same software. i.e. pure-P2P.
* It Uses the same transport with Lightning Network deamon to communicate with a counterparty. (no outbound http)
* It only supports a swap against the next peer.

peerswap supports both lnd and c-lightning, we are going to use lnd first.

## setup

```sh
# read configuration
source env.sh # don't forget to do this in every terminal

docker-compose up -d \
  bitcoind \
  lnd_alice \
  lnd_bob

 # lnd does not work with empty bitcoind
./docker-bitcoin-cli.sh generatetoaddress 1 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

# initialize lnd as usual
docker-compose exec lnd_alice bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32777 create # or `unlock` if its already created
docker-compose exec lnd_bob bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 create # or `unlock` if its already crated
```

And we prepare lnd funds as we done before.

```sh
./docker-lncli-alice.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m # Just for confirmation.

# connect
./docker-lncli-alice.sh getinfo | jq ".uris[0]" | xargs -IXX ./docker-lncli-bob.sh connect XX  

# open channel from alice to bob
./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -IXX ./docker-lncli-alice.sh openchannel XX 500000

# confirm
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

## start peerswap

```
docker-compose up -d \
  peerswap_alice \
  peerswap_bob

 # It seems that peerswap waits for lnd to get synced before start listening...
 ./docker-bitcoin-cli.sh generatetoaddress 1 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

# check if its working
./docker-pscli-alice.sh listpeers
./docker-pscli-bob.sh listpeers

# At this point you may want to see the full list of RPC commands.
./docker-pscli-alice.sh help

# Add bob to alice's list of known peerswap peers
./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -IXX ./docker-pscli-alice.sh addpeer --peer_pubkey XX
```

Note that `addpeer` enables other party to perform DoS against you if they are malicious,
you may lose your funds in the worst case.
Don't forget that it is still in open-beta!

## Perform Swap

Let's start from BTC-to-Lightning_BTC swap.

```sh
./docker-lncli-alice.sh listchannels | jq -c ".channels[].chan_id" | xargs -IXX ./docker-pscli-alice.sh swapout --sat_amt=200000 --channel_id=XX --asset=btc 
```

It must return something like

```json
{
    "swap": {
        "id": "af871fc101ed1a397047727bdac7548aa1489dd3482f9c7efb98d7fadd5af938",
        "created_at": "2022-08-23 12:43:34 +0000 UTC",
        "type": "swap-out",
        "role": "sender",
        "state": "State_SwapOutSender_AwaitTxConfirmation",
        "initiator_node_id": "02b250fdeebabcb1bce4b797dae246c14af8e9bf7119cc479324bdfc09df039d49",
        "peer_node_id": "037b4957e62a9849172b4eec86def66d14140e196246fea91f182d6908b4a357e7",
        "amount": "200000",
        "channel_id": "180:1:0",
        "opening_tx_id": "0bd40944e5d4bead96d85371a5a8214ba830a0db5eaf5d7a89e6110358e2e74f",
        "claim_tx_id": "",
        "cancel_message": ""
    }
}
```

This can also be seen by `listswaps`

```sh
./docker-pscli-alice.sh listswaps 
./docker-pscli-alice.sh listactiveswaps # active one only
./docker-pscli-bob.sh listswaps 
```

`swapout` will cause other peer to broadcast the opening tx.
It is what called `swap-tx` in loop/boltz.

We must claim the tx. otherwise we are DoSing counterparty.
`peerswapd` will automatically broadcast claim tx after some confirmation.

`"state"` field in the bob side must be `"State_SwapOutReceiver_AwaitClaimInvoicePayment"`

The state-transition of both swap-[in|out] [receiver|sender] can be found at https://github.com/ElementsProject/peerswap/blob/master/docs/states.md
I recommend you to check one-by-one while performing the swap.

After three confirmations,

```sh
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

The state must be `ClaimedPreimage`. It means it is finished.

Let's confirm that swap has worked correctly by `listchannels`, `listunspent`

```sh
./docker-lncli-alice.sh listchannels #  Check local_balance/remote_balance

 # The on-chain amount you've got must be smaler than what you have paid.
 # its because of (onchain-fee + swap fee + prepayment)
./docker-lncli-alice.sh listunspent

# check the off-chain payment.
# there must be two. 1. for prepayment 2. and swap payment.
./docker-lncli-alice.sh listpayments
```

It seems that currently prepayment amount is not configurable.

## swap in with lbtc

```sh
# prepare elements funds.
elements_addr=$(./docker-elements-cli.sh getnewaddress)
./docker-elements-cli.sh generatetoaddress 102 $elements_addr
```

perform swapin

```sh
./docker-lncli-alice.sh listchannels | jq -c ".channels[].chan_id" | xargs -IXX ./docker-pscli-alice.sh swapin --sat_amt=150000 --channel_id=XX --asset=btc
```

And confirm, check as in the case of `swapout`.


## multi-asset swap


###

Let's proceed on Liquid-BTC to Lightning-BTC swap.

We have only one instance of elementsd, but since peerswap specifies 
`--elementsd.rpcwallet=` option, each peerswap daemon for alice and bob uses different wallets.


```sh
# Check which wallet we have.
./docker-elements-cli.sh listwallets
# and how much money they have.
./docker-elements-cli.sh -rpcwallet=swaplnd_alice getbalance 
# or
./docker-pscli-alice.sh lbtc-getbalance # this does the same.

# prepare funds for peerswap wallet.
./docker-pscli-alice.sh lbtc-getaddress | jq ".address" | xargs -IXX ./docker-elements-cli.sh -rpcwallet=swap sendtoaddress XX 2
./docker-pscli-bob.sh lbtc-getaddress | jq ".address" | xargs -IXX ./docker-elements-cli.sh -rpcwallet=swap sendtoaddress XX 2

# confirm.
./docker-elements-cli.sh -rpcwallet=swap getnewaddress | xargs -IXX ./docker-elements-cli.sh generatetoaddress 1 XX

# do it again just for sure.
./docker-pscli-alice.sh lbtc-getaddress | jq ".address" | xargs -IXX ./docker-elements-cli.sh -rpcwallet=swap sendtoaddress XX 2
./docker-pscli-bob.sh lbtc-getaddress | jq ".address" | xargs -IXX ./docker-elements-cli.sh -rpcwallet=swap sendtoaddress XX 2
# confirm.
./docker-elements-cli.sh -rpcwallet=swap getnewaddress | xargs -IXX ./docker-elements-cli.sh generatetoaddress 1 XX
./docker-elements-cli.sh -rpcwallet=swap getnewaddress | xargs -IXX ./docker-elements-cli.sh generatetoaddress 10 XX

# now it must have some funds.
./docker-pscli-alice.sh lbtc-getbalance
./docker-pscli-bob.sh lbtc-getbalance
```

### perform swap

Simply change `--asset` to `lbtc`.

** Note: currently this does not work! The issue is tracked in https://github.com/ElementsProject/peerswap/issues/120 **

```
./docker-lncli-alice.sh listchannels | jq -c ".channels[].chan_id" | xargs -IXX ./docker-pscli-alice.sh swapout --sat_amt=200000 --channel_id=XX --asset=lbtc 
```