

First, lets start a new node named carol.

Alice -----------> Bob --------> Carol
              (Boltz server)   (Loop server)

```bash
# initialize carol's lnd as we done in alice and bob.
docker-compose exec lnd_carol bash
lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32779 create
```

