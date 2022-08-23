#!/bin/bash

docker-compose exec -T peerswap_alice pscli --rpchost="localhost:42069" $@

