#!/bin/bash

docker-compose exec -T clightning_bob lightning-cli --rpc-file /root/.lightning/lightning-rpc --network regtest --lightning-dir /root/.lightning $@

