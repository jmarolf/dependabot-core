#!/bin/bash

# Check if a registry argument was provided
if [ -z "$1" ]; then
  echo "Usage: $0 <container_registry>"
  exit 1
fi

set -e
cd "$(dirname "$0")/.."

docker-compose build

# Pass the registry argument to the push-to-private-registry.sh script
script/push-to-private-registry.sh "$1"
