#!/bin/bash

docker-compose exec -T clightning_alice lightning-cli --rpc-file /root/.lightning/lightning-rpc --network regtest --lightning-dir /root/.lightning $@

