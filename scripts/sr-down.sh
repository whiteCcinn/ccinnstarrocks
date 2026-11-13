#!/usr/bin/env bash
# Removes the containers started by sr-up.sh.
set -euo pipefail
docker ps -a --format '{{.Names}}' | grep '^ccinnsr-it-' | xargs -r docker rm -f
