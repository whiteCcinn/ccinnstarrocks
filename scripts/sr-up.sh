#!/usr/bin/env bash
# Starts StarRocks all-in-one containers for integration tests and seeds demo data.
#
#   scripts/sr-up.sh            # StarRocks 3.3 and 4.1
#   scripts/sr-up.sh 4.1        # selected versions
#
# Prints the CCINNSR_IT_URIS value to export before running `swift test --filter IntegrationTests`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS=("${@:-3.3 4.1}")
# shellcheck disable=SC2206
VERSIONS=(${VERSIONS[*]})

port_for() {
  case "$1" in
    3.3) echo 19033 ;; 3.4) echo 19034 ;; 3.5) echo 19035 ;; 4.0) echo 19040 ;; 4.1) echo 19041 ;;
    *) echo "unsupported version $1" >&2; exit 1 ;;
  esac
}

targets=()
for version in "${VERSIONS[@]}"; do
  name="ccinnsr-it-${version/./}"
  port="$(port_for "$version")"
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" -p "127.0.0.1:${port}:9030" "starrocks/allin1-ubuntu:${version}-latest" >/dev/null
    echo "started $name on port $port" >&2
  fi
  echo "waiting for $name to report an alive backend…" >&2
  for _ in $(seq 1 180); do
    if docker exec "$name" mysql -P9030 -h127.0.0.1 -uroot -e "SHOW BACKENDS" 2>/dev/null | grep -q "true"; then break; fi
    sleep 2
  done
  docker cp "$ROOT/scripts/seed-demo.sql" "$name:/tmp/seed-demo.sql"
  seeded=false
  for attempt in 1 2 3; do
    if docker exec "$name" sh -c "mysql -P9030 -h127.0.0.1 -uroot < /tmp/seed-demo.sql" >&2; then seeded=true; break; fi
    echo "seeding $name failed (attempt $attempt), retrying…" >&2
    sleep 10
  done
  if [[ "$seeded" != true ]]; then echo "could not seed $name" >&2; exit 1; fi
  # Knowledge tests: an ADX-style schema with a declared foreign key and a view.
  docker cp "$ROOT/scripts/seed-knowledge.sql" "$name:/tmp/seed-knowledge.sql"
  docker exec "$name" sh -c "mysql -P9030 -h127.0.0.1 -uroot < /tmp/seed-knowledge.sql" >&2 || { echo "could not seed kb_demo in $name" >&2; exit 1; }
  targets+=("${version}=127.0.0.1:${port}")
done

joined="$(IFS=,; echo "${targets[*]}")"
echo "export CCINNSR_IT_URIS=\"${joined}\""
