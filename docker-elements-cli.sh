#!/bin/bash

docker-compose exec -T elementsd elements-cli -datadir="/data" -rpcport=43782 -rpcpassword=${BITCOIND_RPC_PASS} -rpcuser=${BITCOIND_RPC_USER} "$@"
