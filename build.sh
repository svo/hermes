#!/usr/bin/env bash

image=$1 &&
architecture=$2 &&

if [ -z "$architecture" ]; then
  docker run --rm -v "$(pwd)":/working-dir -v /var/run/docker.sock:/var/run/docker.sock --entrypoint ./bin/create-image svanosselaer/hermes-builder:latest "${image}"
else
  docker run --rm -v "$(pwd)":/working-dir -v /var/run/docker.sock:/var/run/docker.sock --entrypoint ./bin/create-image "svanosselaer/hermes-builder:${architecture}" "${image}" "${architecture}"
fi
