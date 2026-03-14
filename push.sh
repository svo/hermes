#!/usr/bin/env bash

image=$1 &&
architecture=$2 &&

if [ -z "$architecture" ]; then
  docker push "svanosselaer/hermes-${image}" --all-tags
else
  docker push "svanosselaer/hermes-${image}:${architecture}"
fi
