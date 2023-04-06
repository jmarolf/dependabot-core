#!/bin/bash

set -e
cd "$(dirname "$0")/.."

docker-compose build

script/push-to-azdo.sh
