#!/usr/bin/env bash

set -eu

./docker-lncli-alice.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-lncli-bob.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1
./docker-lncli-carol.sh newaddress p2wkh | jq -r ".address" | xargs -IXX ./docker-bitcoin-cli.sh sendtoaddress XX 1

./docker-bitcoin-cli.sh generatetoaddress 6 bcrt1qjwfqxekdas249pr9fgcpxzuhmndv6dqlulh44m
