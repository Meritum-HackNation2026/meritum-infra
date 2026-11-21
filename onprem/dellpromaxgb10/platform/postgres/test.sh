#!/usr/bin/env bash
# Local check of the meritum-postgres image (not run in pull request CI):
# builds it, starts a throwaway container and checks that `public.polish`
# stems "Tuska" and "Tusk" alike and that vector and pg_trgm are installed.
# Usage: ./test.sh [image]   (no argument: build from this directory)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=${1:-meritum-postgres:test}
[ $# -gt 0 ] || docker build -q -t "$image" "$here" >/dev/null
name="meritum-postgres-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" -e POSTGRES_USER=meritum -e POSTGRES_PASSWORD=test \
  -e POSTGRES_DB=meritum "$image" >/dev/null

# The entrypoint restarts postgres after the init scripts; wait for the final server on TCP.
for i in $(seq 60); do
  docker exec "$name" pg_isready -h 127.0.0.1 -U meritum -d meritum >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { docker logs "$name"; echo "FAIL: postgres not ready" >&2; exit 1; }
  sleep 1
done

q() { docker exec "$name" psql -h 127.0.0.1 -U meritum -d meritum -tAq -v ON_ERROR_STOP=1 -c "$1"; }
fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; fi
}
check "Tuska stems like Tusk" \
  "$(q "SELECT to_tsvector('public.polish', 'Tuska') = to_tsvector('public.polish', 'Tusk')")" t
check "extensions vector and pg_trgm" \
  "$(q "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('vector', 'pg_trgm')")" pg_trgm,vector
exit "$fail"
