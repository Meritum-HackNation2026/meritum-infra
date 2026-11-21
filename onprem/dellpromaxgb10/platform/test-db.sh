#!/usr/bin/env bash
# Local check of the database layout (db.sh), not run in pull request CI:
# starts a throwaway meritum-postgres, applies m_db_sql twice and checks the
# schemas, databases and privileges of the API and worker roles per env.
# Usage: ./test-db.sh [image]   (no argument: build postgres/ from this directory)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/db.sh
. "$here/db.sh"
image=${1:-meritum-postgres:test}
[ $# -gt 0 ] || docker build -q -t "$image" "$here/postgres" >/dev/null
name="meritum-postgres-test-db-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" -e POSTGRES_USER=meritum -e POSTGRES_PASSWORD=test \
  -e POSTGRES_DB=meritum "$image" >/dev/null
for i in $(seq 60); do
  docker exec "$name" pg_isready -h 127.0.0.1 -U meritum -d meritum >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { docker logs "$name"; echo "FAIL: postgres not ready" >&2; exit 1; }
  sleep 1
done

for app in api worker; do for env in dev prd; do printf -v "$(pw_var "$app" "$env")" '%s' "pw-$app-$env"; done; done
printf -v "$(pw_var mocks prd)" %s pw-mocks-prd
apply() {
  m_db_sql "dev prd" "prd" | docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$name" \
    psql -q -v ON_ERROR_STOP=1 -U meritum -d meritum >/dev/null
}
# As $1 ($app $env) through the env-file URL to database $3 (app: meritum with search_path).
as() {
  local pw url; pw=$(pw_var "$1" "$2")
  if [ "$3" = app ]; then url=$(M_DB_HOST=127.0.0.1 m_db_url "$(m_role "$1" "$2")" "${!pw}" meritum "$(m_app_schema "$2")")
  else url=$(M_DB_HOST=127.0.0.1 m_db_url "$(m_role "$1" "$2")" "${!pw}" "$3"); fi
  docker exec "$name" psql "$url" -tAq -v ON_ERROR_STOP=1 -c "$4" 2>&1
}
q() { docker exec "$name" psql -h 127.0.0.1 -U meritum -d meritum -tAq -v ON_ERROR_STOP=1 -c "$1"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; fi; }
denied() { case $2 in *"permission denied"* | *"must be owner"*) echo "ok   $1" ;; *) echo "FAIL $1: expected a denial, got '$2'" >&2; fail=1 ;; esac; }

apply
check "schemas app_dev and app_prd" \
  "$(q "SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname LIKE 'app\_%'")" app_dev,app_prd
check "databases meritum_dbos_dev and meritum_dbos_prd" \
  "$(q "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE datname LIKE 'meritum_dbos_%'")" meritum_dbos_dev,meritum_dbos_prd
check "worker dev owns app_dev" "$(q "SELECT nspowner::regrole FROM pg_namespace WHERE nspname = 'app_dev'")" meritum_worker_dev
check "worker dev creates a table in app_dev (search_path from the URL)" \
  "$(as worker dev app "CREATE TABLE t (id serial PRIMARY KEY, v text); SELECT current_schema()")" app_dev
check "api dev reads and writes app_dev" \
  "$(as api dev app "INSERT INTO t (v) VALUES ('a'); UPDATE t SET v = 'b'; SELECT v FROM t")" b
denied "api dev has no DDL in app_dev" "$(as api dev app "CREATE TABLE u (id int)")"
denied "api dev cannot drop the worker's table" "$(as api dev app "DROP TABLE t")"
denied "api dev has no access to app_prd" "$(as api dev app "SELECT * FROM app_prd.x")"
denied "worker dev has no access to app_prd" "$(as worker dev app "CREATE TABLE app_prd.x (id int)")"
check "worker dev creates schema dbos in its DBOS database" \
  "$(as worker dev meritum_dbos_dev "CREATE SCHEMA dbos; SELECT 1")" 1
check "api dev connects to meritum_dbos_dev" "$(as api dev meritum_dbos_dev "SELECT current_database()")" meritum_dbos_dev
denied "api dev cannot connect to meritum_dbos_prd" "$(as api dev meritum_dbos_prd "SELECT 1")"
denied "worker dev cannot connect to meritum_dbos_prd" "$(as worker dev meritum_dbos_prd "SELECT 1")"

apply
check "second run keeps data" "$(as api dev app "SELECT v FROM t")" b
check "second run keeps the DBOS schema" "$(as worker dev meritum_dbos_dev "SELECT count(*) FROM pg_namespace WHERE nspname = 'dbos'")" 1
check "second run keeps passwords" "$(as api prd app "SELECT current_user")" meritum_api_prd
exit "$fail"
