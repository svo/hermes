#!/usr/bin/env bash

image=$1

docker manifest rm "svanosselaer/hermes-${image}:latest" 2>/dev/null || true

docker manifest create \
  "svanosselaer/hermes-${image}:latest" \
  --amend "svanosselaer/hermes-${image}:amd64" \
  --amend "svanosselaer/hermes-${image}:arm64" &&
docker manifest push "svanosselaer/hermes-${image}:latest"
