
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
 # 5. loop server for Carol
 # 6. loop client for Alice
docker-compose up -d \
  bitcoind \
  lnd_alice \
  lnd_bob \
  lnd_carol \
  loopserver \
  loopd

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
./docker-loop.sh terms
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

~~We want to simulate a realistic situation here.
So first, we assume that Bob is a Lightning service provider (LSP) that alice uses.
Alice wants to connect Bob privately, because she knows she is liquidity consumer, thus there is no point for making the channel public to promote routing.
Bob, on the otherhand, wants to promote others to use his channel for routing, for the sake of earning routing fee.
So the channel from Alice -> Bob must be private, and Bob -> Carol must be public.~~

since lnd works weirdly when the channel is private, we omit this process and just use public channels.

```bash
./docker-lncli-bob.sh getinfo | jq ".identity_pubkey" | xargs -I XX ./docker-lncli-alice.sh openchannel XX 500000

./docker-lncli-carol.sh getinfo | jq ".identity_pubkey" | xargs -I XX ./docker-lncli-bob.sh openchannel XX 500000
./docker-bitcoin-cli.sh generatetoaddress 3 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m

# Now don't forget to check by `listchannels` 
```

## Autoloop

Let's query the current state of swaps which loopd manages
```bash
./docker-loop.sh listswaps # must return empty array

# We haven't set any rule yet, so this must return an error message something like ...
# "[loop] no rules set for autolooper, please set rules using the setrule command"
./docker-loop.sh suggestswaps
```

### Loop Out

Let's start from checking the behavior of loop-out,
i.e. assume alice is receiving money more than to pay, thus her inbound liquidity tends to 
get exhaused. So she wants to dispatch a loop-out swap when necessary.

In that case, she must set `--incoming_threshold` to the channel by `setrule` rpc.

Let's say she want to dispatch the loop-in when the `local_balance` of the channel
becomes less than `10`% of the whole channel capacity.

```bash
./docker-lncli-alice.sh listchannels | jq -r ".channels[].chan_id"  | xargs -I XX ./docker-loop.sh setrule XX --incoming_threshold=10
```

Let's make sure the rule is set correctly by `getparams` rpc.

```bash
./docker-loop.sh getparams # Check the `"rules"` field in the response is not an empty field.
```

Now let's check how the `listswaps` and `suggestswaps` response has changed.

```bash
./docker-loop.sh listswaps # empty array, same as before.
./docker-loop.sh suggestswaps # Something like below.
```

```json
{
    "loop_out": [
    ],
    "disqualified": [
        {
            "channel_id": "156130651209728",
            "pubkey": null,
            "reason": "AUTO_REASON_LIQUIDITY_OK"
        }
    ]
}
```

The `"reason"` field indicates the reason why autolooper does **not** suggest swap for the channel.
`AUTO_REASON_LIQUIDITY` means "The remaining liquidity in this channel is larger than the threshold specified(10%)."
You can see the whole list of reasons in [here](https://github.com/lightninglabs/loop/blob/master/liquidity/reasons.go).

Now, lets consume inbound liquidity by receiving money on LN.

```bash
alice_incoming_liquidity=$(./docker-lncli-alice.sh listchannels | jq -r ".channels[].remote_balance")
amount_to_pay=$(echo $alice_incoming_liquidity - 20000 | bc)
alice_invoice=$(./docker-lncli-alice.sh addinvoice --amt $amount_to_pay | jq -r ".payment_request")

./docker-lncli-carol.sh payinvoice $alice_invoice
./docker-loop.sh suggestswaps
```

This will probably tell you that a swap is disqualified because of `"reason": "AUTO_REASON_MINER_FEE"`

This can be avoid by setting parameters.

#### Required parameters

```bash
# The total fee percent must be set independently from other parameters.
./docker-loop.sh setparams \
    --feepercent=8

./docker-loop.sh setparams \
    --maxminer=20000 \
    --maxswapfee=10 \
    --sweeplimit=50 \
    --maxprepay=4000 \
    --maxroutingfee=1 \
    --maxprepayfee=2
```

Let's see step by step.

* `--maxminer`
 * unit: satoshi
* `--maxswapfee`
 * unit: percentage
* `--sweeplimit`
 * unit: satoshi/vByte
* `--maxprepay`
 * unit: satoshi
* `--maxroutingfee`
 * unit: percentage
* `--maxprepayfee=2`
 * unit: percentage

These options are those at least necessary to turn on the autoloop feature.
There are more options if you prefer, check it by `setparams --help`

#### Dispatch control

You'd better tweek these two parameters as a pair.

* `--sweepconf`
 * The confirmation block number from which we treat a sweep tx as confirmed.
 * default: 100
* `--autoinflight`
 * The number of swap we allow autolooper to run at once.
 * default: 1

The optimal settings for these two parameters depends on the size of the channel and how often you dispatch the swaps.

But you probably want to allow more concurren execution than the default in general.
So let's loose the restriction.

```bash
./docker-loop.sh setparams \
  --sweepconf=40 \
  --autoinflight=2
```

#### Swap size

`--minamt`, `--maxamt` is for controling the size of the swap.
This is probably useless in most cases, so I will omit the explanation.

### Loop Out: Swap Execution

From now on, we will explain the actual exectuion of the swap, first 
manulally, than automaticaly, automatic execution requires you to set the budget.

#### Manual swap dispatch

Before actually dispatching the swap, let's change the failure backoff time to suite our regtest environment

```bash
./docker-loop.sh setparams --failurebackoff=10
```

`failurebackoff` is a duration time (in seconds) to not perform another swap when once it failed.
The default value is `86400`, which is too long for a regtest environment.
We wan't to retry as soon as possible when the swap failes.

```bash
swapsuggestion=$(./docker-loop.sh suggestswaps)
amt=$(echo $swapsuggestion | jq -r ".loop_out[0].amt")
```

Let's check the quote

```bash
./docker-loop.sh quote out $amt
```

The fee must match the sum of those suggest in the `suggestswap` rpc.

Now, let's perform actual loop-out swap manually.

```bash
label=$(echo $swapsuggestion | jq -r ".loop_out[0].label")
./docker-loop.sh out \
  --amt=$amt \
  --channel=$(echo $swapsuggestion | jq -r ".loop_out[0].outgoing_chan_set[0]") \
  --max_swap_routing_fee=$(echo $swapsuggestion | jq -r ".loop_out[0].max_swap_routing_fee") \
  --label=$(echo "manual_dispatch-${label}") \
  --fast
```

`--fast` option is necessary because without it, loopserver tries to batch the swap tx to keep a fee cheaper.
But in regtest there is no other loop-out request to batch, so the loopserver will wait indefinitely.

Now let's monitor this swap and verify that it finishes correctly when new blocks come.

```bash
./docker-loop.sh monitor

# In another tty...
 ./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

You can confirm that the swap was successful by `listswaps`

#### Check the autoloop is working fine

Next we are going to set the autoloop feature on,

```bash
./docker-loop.sh setparams \
  --autoloop=true
```

Then check the swap is working fine in the same way you did in above.

#### Budget

Less importantly, you can specify the budget for the swap.

> NOTE: autoloop budget does not include the actual funds which is getting swapped.
> Instead, it represents an amount which gets lost in the swap. e.g. miner-fee, routing-fee, swap-fee.

* `--autobudget`
 * unit: satoshis
 * The amount of budget you are willing to use in swaps.
* `--budgetstart`
 * unit: unixtime
 * The time it starts to use budget. Before this time period reaches, it will not execute any swaps.
 * not really important.


### Loop In

> TODO: Explain loopin when https://github.com/lightninglabs/loop/pull/419/ gets merged.
