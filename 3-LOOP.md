

First, lets start a new node named carol.

    Alice ---------------> Bob -----------> Carol
(Boltz client)       (Boltz server)      (Loop server)
(Loop client)

```bash
# initialize carol's lnd as we done in alice and bob.
docker-compose exec lnd_carol bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32779 create
```

