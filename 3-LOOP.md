
First, lets start a new node named carol.

    Alice ---------------> Bob -----------> Carol
(Boltz client)       (Boltz server)      (Loop server)
(Loop client)

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

# Sometimes loopd does not recognize lnd until new block comes.
./docker-bitcoin-cli.sh generatetoaddress 1 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
```

Now let's check terms for loop service
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
