#!/bin/bash

docker-compose exec -T lnd_bob lncli --tlscertpath=/data/tls.cert --macaroonpath=/data/chain/bitcoin/regtest/admin.macaroon --rpcserver=localhost:32778 $@
