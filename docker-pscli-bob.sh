#!/bin/bash

docker-compose exec -T peerswap_bob pscli --rpchost="localhost:42069" $@

